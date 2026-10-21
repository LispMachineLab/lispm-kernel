// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Thin experimental bridge. All Emacs conversion happens on the Emacs thread.
//!
//! The Lisp-owned handle is a `Runtime`: the kernel plus the events drained
//! from it that Lisp does not hold yet (see `carry`).
// Dependency macros generate the FFI boundary; handwritten code uses safe APIs.
#![deny(unsafe_code)]
#![deny(missing_docs)]

mod carry;

use carry::{Budget, Carry};
use emacs::{defun, Env, IntoLisp, Result, Value};
use lispm_kernel::{Config, Error, Event, JobFailed, JobOptions, Kernel, Outcome, WorkClass};
use lispm_kernel_sessions::{Agent, Scanner};
use std::borrow::Cow;
use std::cell::RefCell;
use std::path::Path;
use std::sync::OnceLock;

/// The protocol `lispm-kernel.el` checks before using the module.
const PROTOCOL_VERSION: u64 = 1;
/// Largest echo payload, checked in Emacs before copying into Rust.
const MAX_ECHO_BYTES: usize = 60 * 1024;
/// Largest scan root, in bytes.
const MAX_ROOT_BYTES: usize = 4096;

emacs::plugin_is_GPL_compatible!();

#[emacs::module(
    name = "lispm-kernel-module",
    defun_prefix = "lispm-kernel-module",
    separator = "-"
)]
fn init(_: &Env) -> Result<()> {
    Ok(())
}

/// The runtime behind a Lisp handle: the kernel, and the events drained from
/// it but not yet delivered to Lisp.
struct Runtime {
    kernel: Kernel,
    carry: RefCell<Carry>,
}

/// Create a native runtime and return its handle.
#[defun(user_ptr)]
fn create() -> Result<Runtime> {
    let kernel =
        Kernel::new(Config::default()).map_err(|e| emacs::Error::msg(format!("kernel: {e:?}")))?;
    Ok(Runtime {
        kernel,
        carry: RefCell::new(Carry::default()),
    })
}

/// The Lisp symbol for a kernel error.
fn symbol(error: Error) -> &'static str {
    match error {
        Error::Busy => "busy",
        Error::Capacity => "capacity",
        Error::Closed => "closed",
        // Other kernel errors, present and future, share one symbol.
        _ => "kernel-error",
    }
}

/// Submit an owned UTF-8 echo job to validate the bridge end to end.
#[defun]
fn submit_echo<'e>(
    env: &'e Env,
    runtime: &Runtime,
    owner: u64,
    generation: u64,
    text: Value,
) -> Result<Value<'e>> {
    if env.call("string-bytes", (text,))?.into_rust::<usize>()? > MAX_ECHO_BYTES {
        return env.intern("too-large");
    }
    let bytes = text.into_rust::<String>()?.into_bytes();
    let limit = bytes.capacity();
    match runtime
        .kernel
        .submit(owner, generation, bytes, limit, |_, bytes| Ok(bytes))
    {
        Ok(id) => id.into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}

/// Drain at most ITEMS events and BYTES bytes, capped at 16 events and 64 KiB.
/// Return a vector of [epoch request owner generation kind text key] events,
/// oldest first, or busy, capacity, closed or kernel-error.
/// When the oldest event alone exceeds BYTES, the vector holds just that event.
/// Events leave the runtime only once their vector exists: after a conversion
/// failure or a non-local exit, the next drain delivers them again.
/// Payload text that is not UTF-8 is decoded lossily (U+FFFD).
#[defun]
fn drain<'e>(env: &'e Env, runtime: &Runtime, items: usize, bytes: usize) -> Result<Value<'e>> {
    // A drain reentered from Lisp run during conversion retries later.
    let Ok(mut carry) = runtime.carry.try_borrow_mut() else {
        return env.intern("busy");
    };
    let count = match carry.select(&runtime.kernel, Budget::new(items, bytes)) {
        Ok(count) => count,
        Err(error) => return env.intern(symbol(error)),
    };
    let events = carry
        .front(count)
        .map(|event| event_vector(env, event))
        .collect::<Result<Vec<_>>>()?;
    let vector = env.call("vector", &events[..])?;
    carry.delivered(count);
    Ok(vector)
}

/// The Lisp vector [epoch request owner generation kind text key] of `event`.
fn event_vector<'e>(env: &'e Env, event: &Event) -> Result<Value<'e>> {
    let (kind, payload, key) = match &event.outcome {
        Outcome::Chunk { key, bytes } => ("chunk", bytes.as_slice(), *key),
        Outcome::Success(bytes) => ("success", bytes.as_slice(), None),
        Outcome::Failed => ("failed", &[][..], None),
        Outcome::Cancelled => ("cancelled", &[][..], None),
        Outcome::Panicked => ("panicked", &[][..], None),
        Outcome::OutputTooLarge => ("output-too-large", &[][..], None),
    };
    let fields = [
        event.epoch.into_lisp(env)?,
        event.request.into_lisp(env)?,
        event.owner.into_lisp(env)?,
        event.generation.into_lisp(env)?,
        env.intern(kind)?,
        text(payload).as_ref().into_lisp(env)?,
        key.into_lisp(env)?,
    ];
    env.call("vector", &fields[..])
}

/// Payload text: UTF-8 as is, anything else with U+FFFD, so it never fails.
fn text(payload: &[u8]) -> Cow<'_, str> {
    String::from_utf8_lossy(payload)
}

/// Request cooperative cancellation of REQUEST; return t, nil or busy.
#[defun]
fn cancel<'e>(env: &'e Env, runtime: &Runtime, request: u64) -> Result<Value<'e>> {
    match runtime.kernel.cancel(request) {
        Ok(value) => value.into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}

/// Cancel OWNER's requests older than GENERATION; return their count or busy.
#[defun]
fn supersede<'e>(
    env: &'e Env,
    runtime: &Runtime,
    owner: u64,
    generation: u64,
) -> Result<Value<'e>> {
    match runtime.kernel.supersede(owner, generation) {
        Ok(count) => count.into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}

/// The runtime's epoch, which every event of this runtime carries.
#[defun]
fn epoch(runtime: &Runtime) -> Result<u64> {
    Ok(runtime.kernel.epoch())
}

/// Close admission and request cancellation, without waiting for workers.
#[defun]
fn shutdown(runtime: &Runtime) -> Result<()> {
    runtime.kernel.shutdown();
    Ok(())
}

/// Monotonic time for soft frontend budgets, independent of wall-clock changes.
#[defun]
fn monotonic() -> Result<f64> {
    static ORIGIN: OnceLock<std::time::Instant> = OnceLock::new();
    Ok(ORIGIN
        .get_or_init(std::time::Instant::now)
        .elapsed()
        .as_secs_f64())
}

/// The scanner whose parse cache every runtime's scans share.
fn scanner() -> &'static Scanner {
    static SCANNER: OnceLock<Scanner> = OnceLock::new();
    SCANNER.get_or_init(Scanner::default)
}

/// Scan an explicit local transcript ROOT for AGENT (codex or claude).
/// Emit JSON session rows, then succeed with the JSON summary
/// {files rows empty skipped errors cached truncated}.
#[defun]
fn submit_scan<'e>(
    env: &'e Env,
    runtime: &Runtime,
    owner: u64,
    generation: u64,
    root: Value,
    agent: Value,
) -> Result<Value<'e>> {
    if env.call("string-bytes", (root,))?.into_rust::<usize>()? > MAX_ROOT_BYTES {
        return env.intern("too-large");
    }
    if env.call("string-bytes", (agent,))?.into_rust::<usize>()? > 16 {
        return env.intern("invalid-agent");
    }
    let agent = match agent.into_rust::<String>()?.as_str() {
        "codex" => Agent::Codex,
        "claude" => Agent::Claude,
        _ => return env.intern("invalid-agent"),
    };
    let root = root.into_rust::<String>()?.into_bytes();
    let scanner = scanner();
    let options = JobOptions {
        class: WorkClass::Io,
        ..JobOptions::default()
    };
    let job = move |context, bytes| {
        let root = String::from_utf8(bytes).map_err(|_| JobFailed)?;
        scanner.scan(&context, Path::new(&root), agent)
    };
    match runtime
        .kernel
        .submit_with_options(owner, generation, root, 1024, options, job)
    {
        Ok(id) => id.into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}

/// Free the session scanner's parse cache and return nil. Scans running
/// meanwhile stop using it; later scans build a new one.
#[defun]
fn clear_session_cache() -> Result<()> {
    scanner().clear();
    Ok(())
}

/// Whether events are ready, including undelivered ones; busy requests a
/// later retry, never a spin.
#[defun]
fn ready_p<'e>(env: &'e Env, runtime: &Runtime) -> Result<Value<'e>> {
    let carried = runtime
        .carry
        .try_borrow()
        .is_ok_and(|carry| carry.front(1).next().is_some());
    if carried {
        return true.into_lisp(env);
    }
    match runtime.kernel.stats() {
        Ok(stats) => (stats.ready > 0).into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}

/// ABI/schema version consumed by the Lisp frontend; incompatible modules fall back.
#[defun]
fn protocol_version() -> Result<u64> {
    Ok(PROTOCOL_VERSION)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payload_text_never_fails() {
        assert_eq!(text("λ €".as_bytes()), "λ €");
        assert_eq!(text(&[b'f', 0xff, b'g']), "f\u{fffd}g");
    }
}
