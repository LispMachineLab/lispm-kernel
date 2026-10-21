// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Thin experimental bridge. All Emacs conversion happens on the Emacs thread.
// Dependency macros generate the FFI boundary; handwritten code uses safe APIs.
#![deny(unsafe_code)]
use emacs::{defun, Env, IntoLisp, Result, Value};
use lispm_kernel::{Config, Error, Kernel, Outcome};

emacs::plugin_is_GPL_compatible!();
#[emacs::module(
    name = "lispm-kernel-module",
    defun_prefix = "lispm-kernel-module",
    separator = "-"
)]
fn init(_: &Env) -> Result<()> {
    Ok(())
}

#[defun(user_ptr)]
fn create() -> Result<Kernel> {
    Kernel::new(Config::default()).map_err(|e| emacs::Error::msg(format!("kernel: {e:?}")))
}
fn symbol(error: Error) -> &'static str {
    match error {
        Error::Busy => "busy",
        Error::Capacity => "capacity",
        Error::Closed => "closed",
        _ => "kernel-error",
    }
}

/// Submit an owned UTF-8 echo job to validate the bridge end to end.
#[defun]
fn submit_echo<'e>(
    env: &'e Env,
    kernel: &Kernel,
    owner: u64,
    generation: u64,
    text: Value,
) -> Result<Value<'e>> {
    if env.call("string-bytes", (text,))?.into_rust::<usize>()? > 60 * 1024 {
        return env.intern("too-large");
    }
    let bytes = text.into_rust::<String>()?.into_bytes();
    let limit = bytes.capacity();
    match kernel.submit(owner, generation, bytes, limit, |_, bytes| Ok(bytes)) {
        Ok(id) => id.into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}

/// Drain at most ITEMS and BYTES, with hard bridge caps to bound conversion.
/// Return a vector of [epoch request owner generation kind text key] events.
#[defun]
fn drain<'e>(env: &'e Env, kernel: &Kernel, items: usize, bytes: usize) -> Result<Value<'e>> {
    let events = match kernel.drain(items.min(16), bytes.min(64 * 1024)) {
        Ok(events) => events,
        Err(Error::DrainBudget { required }) => return env.list((env.intern("budget")?, required)),
        Err(error) => return env.intern(symbol(error)),
    };
    let mut values = Vec::with_capacity(events.len());
    for event in events {
        let (kind, payload, key) = match event.outcome {
            Outcome::Chunk { key, bytes } => ("chunk", bytes, key),
            Outcome::Success(bytes) => ("success", bytes, None),
            Outcome::Failed => ("failed", vec![], None),
            Outcome::Cancelled => ("cancelled", vec![], None),
            Outcome::Panicked => ("panicked", vec![], None),
            Outcome::OutputTooLarge => ("output-too-large", vec![], None),
        };
        let key = key.map_or(().into_lisp(env), |key| key.into_lisp(env))?;
        // Echo input is UTF-8. Future binary adapters must define their encoding.
        let text = String::from_utf8(payload)?;
        let fields = [
            event.epoch.into_lisp(env)?,
            event.request.into_lisp(env)?,
            event.owner.into_lisp(env)?,
            event.generation.into_lisp(env)?,
            env.intern(kind)?,
            text.into_lisp(env)?,
            key,
        ];
        values.push(env.call("vector", &fields[..])?);
    }
    env.call("vector", &values[..])
}
#[defun]
fn cancel<'e>(env: &'e Env, kernel: &Kernel, request: u64) -> Result<Value<'e>> {
    match kernel.cancel(request) {
        Ok(value) => value.into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}
#[defun]
fn supersede<'e>(env: &'e Env, kernel: &Kernel, owner: u64, generation: u64) -> Result<Value<'e>> {
    match kernel.supersede(owner, generation) {
        Ok(count) => count.into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}
#[defun]
fn epoch(kernel: &Kernel) -> Result<u64> {
    Ok(kernel.epoch())
}
#[defun]
fn shutdown(kernel: &Kernel) -> Result<()> {
    kernel.shutdown();
    Ok(())
}

/// Monotonic time for soft frontend budgets, independent of wall-clock changes.
#[defun]
fn monotonic() -> Result<f64> {
    static ORIGIN: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    Ok(ORIGIN
        .get_or_init(std::time::Instant::now)
        .elapsed()
        .as_secs_f64())
}

/// Scan an explicit local transcript ROOT for AGENT (codex or claude).
/// Emit JSON session rows followed by a JSON completion summary.
#[defun]
fn submit_scan<'e>(
    env: &'e Env,
    kernel: &Kernel,
    owner: u64,
    generation: u64,
    root: Value,
    agent: Value,
) -> Result<Value<'e>> {
    use lispm_kernel::{JobOptions, WorkClass};
    use lispm_kernel_sessions::{Agent, Scanner};
    if env.call("string-bytes", (root,))?.into_rust::<usize>()? > 4096 {
        return env.intern("too-large");
    }
    if env.call("string-bytes", (agent,))?.into_rust::<usize>()? > 16 {
        return env.intern("invalid-agent");
    }
    let agent = agent.into_rust::<String>()?;
    let agent = match agent.as_str() {
        "codex" => Agent::Codex,
        "claude" => Agent::Claude,
        _ => return env.intern("invalid-agent"),
    };
    let root = root.into_rust::<String>()?.into_bytes();
    static SCANNER: std::sync::OnceLock<Scanner> = std::sync::OnceLock::new();
    let scanner = SCANNER.get_or_init(Scanner::default).clone();
    match kernel.submit_with_options(
        owner,
        generation,
        root,
        1024,
        JobOptions {
            class: WorkClass::Io,
            ..JobOptions::default()
        },
        move |context, bytes| {
            let root = String::from_utf8(bytes).map_err(|_| lispm_kernel::JobFailed)?;
            scanner.scan(&context, std::path::Path::new(&root), agent)
        },
    ) {
        Ok(id) => id.into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}

/// Whether retained events are ready; busy requests a later retry, never a spin.
#[defun]
fn ready_p<'e>(env: &'e Env, kernel: &Kernel) -> Result<Value<'e>> {
    match kernel.stats() {
        Ok(stats) => (stats.ready > 0).into_lisp(env),
        Err(error) => env.intern(symbol(error)),
    }
}

/// ABI/schema version consumed by the Lisp frontend; incompatible modules fall back.
#[defun]
fn protocol_version() -> Result<u64> {
    Ok(1)
}
