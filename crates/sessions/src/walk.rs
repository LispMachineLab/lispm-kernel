// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Directory effects: listing the transcripts the desktop's Elisp lists.
//!
//! Codex: `(directory-files-recursively ROOT "\\`rollout-.*\\.jsonl\\'")`.
//! Its FOLLOW-SYMLINKS argument is nil, so symlinked directories are neither
//! entered nor listed; every other entry whose name matches is a transcript,
//! symlinks to files included. `case-fold-search` is t where the desktop
//! calls it, so the name matches ASCII case-insensitively.
//!
//! Claude: `(file-expand-wildcards "ROOT/*/*.jsonl")`. Every entry of the
//! root that `file-directory-p` (which follows symlinks) accepts is a project;
//! every project entry whose name ends in `.jsonl`, case-sensitively, is a
//! transcript.
//!
//! Both follow a symlinked root. Codex, which recurses, does not enter a
//! directory that is its own ancestor again (cycle protection); Claude lists
//! one fixed level of projects, as Elisp's wildcard does, so it needs none.
//! Structural bounds (1,000,000 entries, depth 16) and a directory below the
//! root that cannot be listed to its end truncate the listing instead of
//! failing it; a truncated listing never sweeps the cache. Only the root's own
//! conditions are fatal: absent, no directory, or not listable to its end.

use crate::condition::{Condition, Fatal, Skip};
use crate::parse::Agent;
use crate::source::RowPath;
use std::fs::{self, DirEntry, FileType, Metadata, ReadDir};
use std::path::{Path, PathBuf};

/// Structural bounds on one listing.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Bounds {
    /// Directory entries visited, over all directories.
    pub(crate) entries: usize,
    /// Directories open at once, the root included.
    pub(crate) depth: usize,
}

impl Default for Bounds {
    fn default() -> Self {
        Self {
            // Claude keeps a directory beside each transcript, so a corpus
            // lists about two entries per session.
            entries: 1_000_000,
            depth: 16,
        }
    }
}

/// The identity of a directory, for cycle protection.
#[derive(Clone, Copy, Debug)]
struct DirId {
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
}

impl DirId {
    fn of(meta: &Metadata) -> Self {
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        #[cfg(not(unix))]
        let _ = meta;
        Self {
            #[cfg(unix)]
            device: meta.dev(),
            #[cfg(unix)]
            inode: meta.ino(),
        }
    }

    /// Whether both identify one directory.
    #[cfg(unix)]
    fn same_directory(self, other: Self) -> bool {
        self.device == other.device && self.inode == other.inode
    }

    /// Without Unix identities nothing is known to be the same directory, and
    /// only the depth bound stops a cycle.
    #[cfg(not(unix))]
    fn same_directory(self, _other: Self) -> bool {
        false
    }
}

struct Frame {
    entries: ReadDir,
    id: DirId,
    /// 0 for the root.
    depth: usize,
}

/// One visited directory entry: a transcript to read, nothing (passed over,
/// or a directory entered), or a condition.
pub(crate) type Step = Result<Option<RowPath>, Condition>;

/// An incremental listing of one root's transcripts.
///
/// Every visited entry yields exactly one [`Step`], so callers can check for
/// cancellation between entries.
pub(crate) struct Walk {
    agent: Agent,
    bounds: Bounds,
    stack: Vec<Frame>,
    visited: usize,
    truncated: bool,
}

impl Walk {
    /// Starts listing `root`, following a symlinked root.
    ///
    /// A root that is absent or no directory is fatal too: the caller asked
    /// for an explicit directory, and the frontend's fallback decides what an
    /// absent one means.
    pub(crate) fn open(root: &Path, agent: Agent, bounds: Bounds) -> Result<Self, Fatal> {
        let meta = fs::metadata(root).map_err(|error| Fatal::Root(error.kind()))?;
        if !meta.is_dir() {
            return Err(Fatal::NotDirectory);
        }
        let entries = fs::read_dir(root).map_err(|error| Fatal::Root(error.kind()))?;
        Ok(Self {
            agent,
            bounds,
            stack: vec![Frame {
                entries,
                id: DirId::of(&meta),
                depth: 0,
            }],
            visited: 0,
            truncated: false,
        })
    }

    /// Whether entries went unlisted: a structural bound, or a directory below
    /// the root that could not be listed to its end.
    pub(crate) fn truncated(&self) -> bool {
        self.truncated
    }

    fn step(&mut self, entry: &DirEntry, depth: usize) -> Step {
        let kind = entry.file_type().map_err(|e| Skip::from_io(&e))?;
        match (self.agent, depth) {
            (Agent::Codex, _) => self.codex(entry, kind, depth),
            (Agent::Claude, 0) => self.project(entry, kind, depth),
            (Agent::Claude, _) if claude_transcript_name(entry) => transcript(entry),
            (Agent::Claude, _) => Ok(None),
        }
    }

    /// A Codex entry: real directories are entered, symlinked ones ignored,
    /// and anything else whose name matches is a transcript.
    fn codex(&mut self, entry: &DirEntry, kind: FileType, depth: usize) -> Step {
        if kind.is_dir() {
            let meta = entry.metadata().map_err(|e| Skip::from_io(&e))?;
            return self.descend(entry.path(), &meta, depth);
        }
        if !codex_transcript_name(entry) || (kind.is_symlink() && resolves_to_directory(entry)) {
            return Ok(None);
        }
        transcript(entry)
    }

    /// A Claude root entry: a project when `file-directory-p` accepts it.
    fn project(&mut self, entry: &DirEntry, kind: FileType, depth: usize) -> Step {
        let meta = if kind.is_symlink() {
            match fs::metadata(entry.path()) {
                Ok(meta) => meta,
                // A dangling or unreadable symlink is no directory to Elisp.
                Err(_) => return Ok(None),
            }
        } else if kind.is_dir() {
            entry.metadata().map_err(|e| Skip::from_io(&e))?
        } else {
            return Ok(None);
        };
        if !meta.is_dir() {
            return Ok(None);
        }
        self.descend(entry.path(), &meta, depth)
    }

    fn descend(&mut self, path: PathBuf, meta: &Metadata, depth: usize) -> Step {
        let id = DirId::of(meta);
        let recursive = matches!(self.agent, Agent::Codex);
        if recursive && self.stack.iter().any(|frame| frame.id.same_directory(id)) {
            return Err(Skip::Cycle.into());
        }
        if self.stack.len() >= self.bounds.depth {
            self.truncated = true;
            return Ok(None);
        }
        RowPath::check(&path)?;
        let entries = fs::read_dir(&path).map_err(|e| {
            // Its subtree goes unlisted: the listing is incomplete, not complete.
            self.truncated = true;
            Skip::from_io(&e)
        })?;
        self.stack.push(Frame {
            entries,
            id,
            depth: depth + 1,
        });
        Ok(None)
    }
}

impl Iterator for Walk {
    type Item = Step;

    fn next(&mut self) -> Option<Step> {
        loop {
            let frame = self.stack.last_mut()?;
            let depth = frame.depth;
            let Some(entry) = frame.entries.next() else {
                self.stack.pop();
                continue;
            };
            if self.visited >= self.bounds.entries {
                self.truncated = true;
                self.stack.clear();
                return None;
            }
            self.visited += 1;
            return Some(match entry {
                Ok(entry) => self.step(&entry, depth),
                Err(error) if depth == 0 => Err(Fatal::Root(error.kind()).into()),
                Err(error) => {
                    // std's ReadDir stops after an error: the rest goes unlisted.
                    self.truncated = true;
                    Err(Skip::from_io(&error).into())
                }
            });
        }
    }
}

/// A transcript entry, when rows can name its path.
fn transcript(entry: &DirEntry) -> Step {
    Ok(Some(RowPath::new(entry.path())?))
}

/// Whether a symlink entry's target is a directory; a dangling one's is not.
fn resolves_to_directory(entry: &DirEntry) -> bool {
    fs::metadata(entry.path()).is_ok_and(|meta| meta.is_dir())
}

fn codex_transcript_name(entry: &DirEntry) -> bool {
    codex_name(entry.file_name().as_encoded_bytes())
}

fn claude_transcript_name(entry: &DirEntry) -> bool {
    claude_name(entry.file_name().as_encoded_bytes())
}

/// `\`rollout-.*\.jsonl\'` with `case-fold-search` t: `.` matches all but
/// newline, and the suffix follows the prefix.
fn codex_name(name: &[u8]) -> bool {
    let Some((start, rest)) = name.split_at_checked(b"rollout-".len()) else {
        return false;
    };
    start.eq_ignore_ascii_case(b"rollout-")
        && ends_with_ignore_ascii_case(rest, b".jsonl")
        && !name.contains(&b'\n')
}

fn ends_with_ignore_ascii_case(name: &[u8], suffix: &[u8]) -> bool {
    name.len()
        .checked_sub(suffix.len())
        .and_then(|start| name.get(start..))
        .is_some_and(|end| end.eq_ignore_ascii_case(suffix))
}

/// `(wildcard-to-regexp "*.jsonl")`, matched case-sensitively by `directory-files`.
fn claude_name(name: &[u8]) -> bool {
    name.ends_with(b".jsonl")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codex_names_follow_the_elisp_regexp() {
        let table: [(&[u8], bool); 9] = [
            (b"rollout-a.jsonl", true),
            (b"ROLLOUT-B.JSONL", true),
            (b"rollout-.jsonl", true),
            (b"rollout-a.jsonl.bak", false),
            (b"rollout.jsonl", false),
            (b"rollout-jsonl", false),
            (b"xrollout-a.jsonl", false),
            (b"rollout-a\nb.jsonl", false),
            (b"rollout-\xff.jsonl", true),
        ];
        for (name, expected) in table {
            assert_eq!(codex_name(name), expected, "{name:?}");
        }
    }

    #[test]
    fn claude_names_follow_the_elisp_wildcard() {
        let table: [(&[u8], bool); 5] = [
            (b"a.jsonl", true),
            (b".jsonl", true),
            (b".dot.jsonl", true),
            (b"B.JSONL", false),
            (b"a.jsonl.tmp", false),
        ];
        for (name, expected) in table {
            assert_eq!(claude_name(name), expected, "{name:?}");
        }
    }
}
