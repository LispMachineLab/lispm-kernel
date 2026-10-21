// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! File effects: opening transcripts and reading their bounded head and tail.
//!
//! Opens follow symlinks, as Emacs's `insert-file-contents` does, but use
//! `O_NONBLOCK` on Unix so that a FIFO cannot block a worker, and accept only
//! regular files after following.

use crate::condition::Skip;
use crate::parse::{parse, Agent, Session};
use crate::{HEAD, MAX_FIELDS, TAIL};
use serde_json::Value;
use std::fs::{self, File, Metadata};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// A path a row can name: UTF-8 and at most 4096 bytes.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct RowPath(String);

impl RowPath {
    /// Validates `path` for a row.
    pub(crate) fn new(path: PathBuf) -> Result<Self, Skip> {
        let text = path
            .into_os_string()
            .into_string()
            .map_err(|_| Skip::NotUnicode)?;
        if text.len() > MAX_FIELDS {
            return Err(Skip::TooLong);
        }
        Ok(Self(text))
    }

    /// Whether rows can name `path` and so the files below it, if short enough.
    pub(crate) fn check(path: &Path) -> Result<(), Skip> {
        match path.to_str() {
            None => Err(Skip::NotUnicode),
            Some(text) if text.len() > MAX_FIELDS => Err(Skip::TooLong),
            Some(_) => Ok(()),
        }
    }

    /// The path as the row's `file` field.
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }

    /// The path to open.
    pub(crate) fn as_path(&self) -> &Path {
        Path::new(&self.0)
    }
}

/// The file state identifying one version of a transcript.
///
/// Law: equal stamps of one path mean an unchanged file, up to the
/// filesystem's timestamp resolution; inode and ctime catch replacement.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Stamp {
    size: u64,
    modified: SystemTime,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
    #[cfg(unix)]
    changed: (i64, i64),
}

impl Stamp {
    /// The stamp of an open file.
    pub(crate) fn of(file: &File) -> Result<Self, Skip> {
        let meta = file.metadata().map_err(|e| Skip::from_io(&e))?;
        Self::from_metadata(&meta)
    }

    fn from_metadata(meta: &Metadata) -> Result<Self, Skip> {
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Ok(Self {
            size: meta.len(),
            modified: meta.modified().map_err(|e| Skip::from_io(&e))?,
            #[cfg(unix)]
            device: meta.dev(),
            #[cfg(unix)]
            inode: meta.ino(),
            #[cfg(unix)]
            changed: (meta.ctime(), meta.ctime_nsec()),
        })
    }

    /// The modification time, the row's `time`.
    pub(crate) fn modified(&self) -> SystemTime {
        self.modified
    }
}

/// Opens `path`, following symlinks, without blocking on FIFOs.
///
/// Post: the returned file is a regular file.
pub(crate) fn open_regular(path: &Path) -> Result<File, Skip> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path).map_err(|e| Skip::from_io(&e))?;
    let meta = file.metadata().map_err(|e| Skip::from_io(&e))?;
    if !meta.is_file() {
        return Err(Skip::NotRegular);
    }
    Ok(file)
}

/// Reads at most `limit` bytes of `path` when it is a regular file of at most
/// `limit` bytes; `None` for anything else (missing, unreadable, special,
/// larger), as Elisp ignores such side files.
pub(crate) fn small_file(path: &Path, limit: u64) -> Option<Vec<u8>> {
    let file = open_regular(path).ok()?;
    let mut bytes = Vec::new();
    file.take(limit.saturating_add(1))
        .read_to_end(&mut bytes)
        .ok()?;
    (u64::try_from(bytes.len()).ok()? <= limit).then_some(bytes)
}

/// Reads and parses the head and tail of an open transcript as
/// `lispm-desktop-agent-read-transcript` does.
///
/// Pre: `stamp` is the stamp of `file`. The caller rechecks the stamp after.
pub(crate) fn read_session(
    file: &mut File,
    path: &Path,
    agent: Agent,
    stamp: Stamp,
) -> Result<Option<Session>, Skip> {
    let size = stamp.size;
    let head = region(file, 0, size.min(HEAD), size)?;
    let tail = if size > HEAD {
        region(file, HEAD.max(size.saturating_sub(TAIL)), size, size)?
    } else {
        Vec::new()
    };
    Ok(parse(agent, path, &head, &tail)?)
}

/// The JSON objects on the complete lines of `file` between `beg` and `end`,
/// as `lispm-desktop-agent-read-json-region` reads them: a line cut by `beg`,
/// or by `end` short of `size`, is dropped, as is any line that is not JSON.
///
/// Pre: `beg <= end`.
fn region(file: &mut File, beg: u64, end: u64, size: u64) -> Result<Vec<Value>, Skip> {
    let read = |file: &mut File| -> std::io::Result<Vec<u8>> {
        file.seek(SeekFrom::Start(beg))?;
        let mut bytes = Vec::new();
        file.take(end.saturating_sub(beg)).read_to_end(&mut bytes)?;
        Ok(bytes)
    };
    let bytes = read(file).map_err(|e| Skip::from_io(&e))?;
    let mut lines = bytes
        .split(|byte| *byte == b'\n')
        .skip(usize::from(beg > 0))
        .collect::<Vec<_>>();
    if end < size {
        lines.pop();
    }
    Ok(lines
        .into_iter()
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn row_paths_must_be_short_utf8() {
        let long = PathBuf::from("x".repeat(MAX_FIELDS + 1));
        assert_eq!(RowPath::new(long.clone()), Err(Skip::TooLong));
        assert_eq!(RowPath::check(&long), Err(Skip::TooLong));
        let fits = PathBuf::from("y".repeat(MAX_FIELDS));
        assert_eq!(RowPath::new(fits).map(|p| p.as_str().len()), Ok(MAX_FIELDS));
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt;
            let raw = PathBuf::from(std::ffi::OsStr::from_bytes(b"rollout-\xff.jsonl"));
            assert_eq!(RowPath::new(raw.clone()), Err(Skip::NotUnicode));
            assert_eq!(RowPath::check(&raw), Err(Skip::NotUnicode));
        }
    }
}
