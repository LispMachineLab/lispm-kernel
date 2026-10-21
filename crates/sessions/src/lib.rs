// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Bounded, cancellable transcript discovery. Never executes transcript content.
//!
//! The crate finds the transcripts the desktop's Elisp finds
//! (`lispm-desktop-agent-codex.el`, `lispm-desktop-agent-claude.el`), parses
//! them as that Elisp does, and emits one JSON row per titled session followed
//! by a JSON summary. Effects are confined to named modules: `walk` lists
//! directories, `source` and `names` read files, and `scan` emits rows.
//! Parsing (`parse`) and the cache model (`cache`) are pure.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

mod cache;
mod condition;
mod names;
mod parse;
mod scan;
mod source;
mod walk;

pub use parse::{parse, Agent, Session, Unrepresentable};
pub use scan::Scanner;

/// Bytes read from a transcript's start, as `lispm-desktop-agent-transcript-head-bytes`.
const HEAD: u64 = 65536;
/// Bytes read from a transcript's end, as `lispm-desktop-agent-transcript-tail-bytes`.
const TAIL: u64 = 16384;
/// Largest emitted row, in bytes, so that one row always fits a bridge drain.
const MAX_ROW: usize = 60 * 1024;
/// Largest identifier, path or title carried by a row, in UTF-8 bytes.
const MAX_FIELDS: usize = 4096;

#[cfg(test)]
mod tests;
