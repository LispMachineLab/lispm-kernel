// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Why a visited entry produced no row: skipped alone, or fatal to the scan.
//!
//! A [`Skip`] concerns one entry; the scan counts it in `"skipped"` and goes
//! on. A [`Fatal`] condition makes the whole result untrustworthy; the scan
//! counts it in `"errors"` and stops.

use crate::parse::Unrepresentable;
use std::fmt;
use std::io;

/// A per-entry condition: the entry contributes no row and the scan continues.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Skip {
    /// The entry, or its symlink's target, does not exist (any more).
    Missing,
    /// The transcript changed while it was read, again on the retry.
    Changed,
    /// The path is not UTF-8, so no JSON row can name it.
    NotUnicode,
    /// The path exceeds the row bound of 4096 bytes.
    TooLong,
    /// The entry exists but cannot be opened, listed or inspected.
    Unreadable(io::ErrorKind),
    /// After following symlinks, the entry is not a regular file.
    NotRegular,
    /// The transcript names its session with a value no row can carry.
    Unrepresentable(Unrepresentable),
    /// The row would exceed the bridge's row bound.
    RowTooLarge,
    /// The directory is one of its own ancestors.
    Cycle,
}

/// A condition that makes the whole scan result untrustworthy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Fatal {
    /// The root is absent, or cannot be inspected or listed to its end.
    Root(io::ErrorKind),
    /// The root is not a directory.
    NotDirectory,
}

/// The result of a visited entry that yields no transcript.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Condition {
    /// Count the entry as skipped and continue.
    Skip(Skip),
    /// Count an error and stop: the result would be incomplete.
    Fatal(Fatal),
}

impl Skip {
    /// Classifies an I/O error on one entry.
    pub(crate) fn from_io(error: &io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::NotFound => Self::Missing,
            kind => Self::Unreadable(kind),
        }
    }
}

impl From<Skip> for Condition {
    fn from(skip: Skip) -> Self {
        Self::Skip(skip)
    }
}

impl From<Fatal> for Condition {
    fn from(fatal: Fatal) -> Self {
        Self::Fatal(fatal)
    }
}

impl From<Unrepresentable> for Skip {
    fn from(field: Unrepresentable) -> Self {
        Self::Unrepresentable(field)
    }
}

impl fmt::Display for Skip {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Missing => f.write_str("entry vanished or its symlink dangles"),
            Self::Changed => f.write_str("transcript changed while being read"),
            Self::NotUnicode => f.write_str("path is not UTF-8"),
            Self::TooLong => f.write_str("path exceeds the row bound"),
            Self::Unreadable(kind) => write!(f, "entry unreadable: {kind}"),
            Self::NotRegular => f.write_str("not a regular file"),
            Self::Unrepresentable(field) => field.fmt(f),
            Self::RowTooLarge => f.write_str("row exceeds the bridge bound"),
            Self::Cycle => f.write_str("directory is its own ancestor"),
        }
    }
}

impl fmt::Display for Fatal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Root(kind) => write!(f, "root cannot be listed: {kind}"),
            Self::NotDirectory => f.write_str("root is not a directory"),
        }
    }
}

impl fmt::Display for Condition {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Skip(skip) => skip.fmt(f),
            Self::Fatal(fatal) => fatal.fmt(f),
        }
    }
}

impl std::error::Error for Skip {}
impl std::error::Error for Fatal {}
impl std::error::Error for Condition {}
