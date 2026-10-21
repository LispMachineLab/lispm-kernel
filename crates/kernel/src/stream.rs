// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Incremental emission from running jobs.

use crate::state::PushRefused;
use crate::{Context, Corrupt};
use std::fmt;

/// Why a chunk was not emitted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EmitFailure {
    /// Stream capacity is exhausted for now; drain or cancellation frees it.
    Backpressure,
    /// The chunk exceeds a global or per-owner stream byte limit on its own.
    TooLarge,
    /// The request was cancelled or the runtime is shutting down.
    Cancelled,
    /// The request already completed, or the runtime is gone.
    Closed,
    /// The state lock was poisoned and its invariant audit failed.
    Poisoned,
}

impl fmt::Display for EmitFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Backpressure => "stream capacity exhausted",
            Self::TooLarge => "chunk exceeds the stream limits",
            Self::Cancelled => "request cancelled",
            Self::Closed => "request closed",
            Self::Poisoned => "kernel state failed its audit after a panic",
        })
    }
}

/// A rejected chunk, returned to the adapter so no chunk is silently lost.
#[derive(Debug, PartialEq, Eq)]
pub struct EmitError {
    /// Why the chunk was rejected.
    pub reason: EmitFailure,
    /// The rejected payload, unchanged.
    pub bytes: Vec<u8>,
}

impl fmt::Display for EmitError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "chunk of {} bytes not emitted: {}",
            self.bytes.len(),
            self.reason
        )
    }
}

impl std::error::Error for EmitError {}

impl Context {
    /// Emit a reliable chunk now, or return it with `Backpressure`.
    ///
    /// Worker-only. Each chunk is charged its allocation capacity plus
    /// `EVENT_OVERHEAD` against the global and per-owner stream limits.
    pub fn try_emit(&self, bytes: Vec<u8>) -> Result<(), EmitError> {
        self.publish(None, bytes, false)
    }

    /// Emit a reliable chunk, waiting on the worker thread for stream capacity.
    ///
    /// Cancellation and shutdown end the wait with `Cancelled`.
    pub fn emit(&self, bytes: Vec<u8>) -> Result<(), EmitError> {
        self.publish(None, bytes, true)
    }

    /// Replace the undrained state update with the same key, or append one.
    ///
    /// The old update is removed and the new one appended, so it is ordered after
    /// everything emitted before it. A replacement reuses its predecessor's item but
    /// must fit the byte limits. Reliable chunks use `emit`/`try_emit` and are
    /// never coalesced.
    pub fn try_replace(&self, key: u64, bytes: Vec<u8>) -> Result<(), EmitError> {
        self.publish(Some(key), bytes, false)
    }

    fn publish(&self, key: Option<u64>, bytes: Vec<u8>, wait: bool) -> Result<(), EmitError> {
        let fail = |reason, bytes| Err(EmitError { reason, bytes });
        let Some(shared) = self.shared.upgrade() else {
            return fail(EmitFailure::Closed, bytes);
        };
        let Ok(mut state) = shared.lock() else {
            return fail(EmitFailure::Poisoned, bytes);
        };
        let mut bytes = bytes;
        loop {
            if self.is_cancelled() {
                return fail(EmitFailure::Cancelled, bytes);
            }
            match state.push_chunk(self.request, key, bytes) {
                Ok(replaced) => {
                    shared.hint(&state);
                    drop(state);
                    if replaced.is_some() {
                        // A smaller replacement frees stream bytes for waiting emitters.
                        shared.space.notify_all();
                    }
                    drop(replaced);
                    return Ok(());
                }
                Err(PushRefused::TooLarge(rejected)) => {
                    return fail(EmitFailure::TooLarge, rejected)
                }
                Err(PushRefused::Closed(rejected)) => return fail(EmitFailure::Closed, rejected),
                Err(PushRefused::Full(rejected)) if !wait => {
                    return fail(EmitFailure::Backpressure, rejected)
                }
                Err(PushRefused::Full(rejected)) => bytes = rejected,
            }
            state = match shared.wait_for_space(state) {
                Ok(state) => state,
                Err(Corrupt) => return fail(EmitFailure::Poisoned, bytes),
            };
        }
    }
}
