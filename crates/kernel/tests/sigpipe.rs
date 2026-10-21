// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! A hint write to a closed reader must never raise SIGPIPE.
//!
//! Emacs keeps the default SIGPIPE disposition (terminate), while the Rust test
//! harness ignores SIGPIPE. The test therefore re-executes itself as a child,
//! restores the default disposition there, and checks that the child exits
//! normally after the kernel writes a hint to a closed reader.
#![cfg(unix)]

use lispm_kernel::{Config, Error, Kernel};
use std::os::unix::process::ExitStatusExt;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

const CHILD: &str = "LISPM_KERNEL_SIGPIPE_CHILD";
const TEST: &str = "hint_write_to_closed_reader_does_not_raise_sigpipe";

fn retry<T>(mut call: impl FnMut() -> Result<T, Error>) -> T {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match call() {
            Err(Error::Busy) if Instant::now() < deadline => thread::yield_now(),
            result => return result.unwrap(),
        }
    }
}

/// Runs in the child: SIGPIPE terminates the process, as it does in Emacs.
fn write_hint_to_closed_reader() {
    // SAFETY: `signal` takes no pointers from us; SIG_DFL only resets the
    // process-wide SIGPIPE disposition, which no other code here relies on.
    let previous = unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
    assert_ne!(previous, libc::SIG_ERR);
    let kernel = Kernel::new(Config::default()).unwrap();
    drop(retry(|| kernel.attach_notifications()));
    retry(|| kernel.submit(1, 0, vec![], 0, |_, _| Ok(vec![])));
    let deadline = Instant::now() + Duration::from_secs(3);
    while retry(|| kernel.stats()).completed < 1 {
        assert!(Instant::now() < deadline, "job did not complete");
        thread::yield_now();
    }
    // The worker attempted the hint under the same lock that counted completion.
    assert!(retry(|| kernel.stats()).notifications_broken);
}

#[test]
fn hint_write_to_closed_reader_does_not_raise_sigpipe() {
    if std::env::var_os(CHILD).is_some() {
        write_hint_to_closed_reader();
        return;
    }
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", TEST, "--nocapture", "--test-threads=1"])
        .env(CHILD, "1")
        .output()
        .unwrap();
    assert_eq!(
        output.status.signal(),
        None,
        "child killed by a signal: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        output.status.success(),
        "child failed: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    // Guard against a vacuous pass: the child really ran this scenario.
    assert!(String::from_utf8_lossy(&output.stdout).contains("1 passed"));
}
