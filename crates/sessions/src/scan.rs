// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! The scan: lists a root, reads or recalls each transcript, emits rows.
//!
//! The completion summary is the JSON object
//! `{"files", "rows", "empty", "skipped", "errors", "cached", "truncated"}`:
//! transcripts examined, rows emitted, transcripts without a listable session,
//! entries skipped for a per-entry condition, conditions that make the result
//! untrustworthy (the frontend then falls back), parses recalled from the
//! cache, and whether a structural bound left entries unlisted.

use crate::cache::{Cache, Ticket};
use crate::condition::{Condition, Skip};
use crate::names::Names;
use crate::parse::{Agent, Session};
use crate::source::{open_regular, read_session, RowPath, Stamp};
use crate::walk::{Bounds, Step, Walk};
use crate::MAX_ROW;
use lispm_kernel::{Context, EmitFailure, JobFailed};
use serde_json::{json, Value};
use std::borrow::Cow;
use std::ops::ControlFlow;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::SystemTime;

/// Discovers sessions off the Emacs thread, sharing one parse cache.
///
/// Law: clones are handles to one cache; what one clone's scan caches, every
/// clone's later scans recall.
#[derive(Clone, Default)]
pub struct Scanner {
    cache: Arc<Mutex<Cache>>,
    bounds: Bounds,
}

/// Where rows go: the kernel's stream, or a test's collector.
pub(crate) trait Sink {
    /// Whether the scan must stop.
    fn cancelled(&self) -> bool;
    /// Emits one row, waiting for stream capacity.
    fn send(&self, row: Vec<u8>) -> Result<(), EmitFailure>;
}

impl Sink for Context {
    fn cancelled(&self) -> bool {
        self.is_cancelled()
    }

    fn send(&self, row: Vec<u8>) -> Result<(), EmitFailure> {
        self.emit(row).map_err(|error| error.reason)
    }
}

/// The counts of the completion summary. Each is bounded by the entries the
/// walk visits.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Summary {
    /// Transcripts examined.
    pub(crate) files: usize,
    /// Rows emitted.
    pub(crate) rows: usize,
    /// Transcripts read that list no session, where the Elisp returns nil.
    pub(crate) empty: usize,
    /// Entries skipped for a per-entry condition.
    pub(crate) skipped: usize,
    /// Conditions that make the whole result untrustworthy.
    pub(crate) errors: usize,
    /// Transcripts whose parse the cache recalled.
    pub(crate) cached: usize,
    /// Whether a structural bound left entries unlisted.
    pub(crate) truncated: bool,
}

impl Summary {
    fn json(&self) -> Value {
        json!({"files": self.files, "rows": self.rows, "empty": self.empty,
               "skipped": self.skipped, "errors": self.errors, "cached": self.cached,
               "truncated": self.truncated})
    }

    /// Whether the scan listed its whole root, so that cache entries it did
    /// not see belong to transcripts that are gone.
    fn complete(&self) -> bool {
        self.errors == 0 && !self.truncated
    }
}

/// One transcript, read or recalled.
struct Transcript {
    stamp: Stamp,
    session: Option<Arc<Session>>,
    cached: bool,
}

impl Transcript {
    /// The row of the transcript's session, titled by `names` first; `None`
    /// when it lists no session, as the Elisp returns nil.
    fn row(&self, names: &Names, path: &RowPath) -> Result<Option<Vec<u8>>, Skip> {
        let Some(session) = self.session.as_deref() else {
            return Ok(None);
        };
        let title = names
            .title(session, path.as_path())
            .or_else(|| session.title.as_deref().map(Cow::Borrowed));
        let Some(title) = title else {
            return Ok(None);
        };
        let row = row(session, &title, path.as_str(), self.stamp.modified());
        // Serializing a `Value` cannot fail; a failure would only lose the row.
        let row = serde_json::to_vec(&row).map_err(|_| Skip::RowTooLarge)?;
        if row.len() > MAX_ROW {
            return Err(Skip::RowTooLarge);
        }
        Ok(Some(row))
    }
}

/// A row as `lispm-kernel-sessions--row` reads it.
fn row(session: &Session, title: &str, file: &str, modified: SystemTime) -> Value {
    let time = modified
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0.0, |since| since.as_secs_f64());
    json!({"agent": session.agent.name(), "id": session.id, "cwd": session.cwd,
           "title": title, "started": session.started, "file": file, "time": time})
}

/// Runs `read` once more when the transcript changed while it was read.
fn retrying<T>(mut read: impl FnMut() -> Result<T, Skip>) -> Result<T, Skip> {
    match read() {
        Err(Skip::Changed) => read(),
        outcome => outcome,
    }
}

/// One scan in progress: its ticket, names and counts.
struct Pass<'a, S> {
    scanner: &'a Scanner,
    sink: &'a S,
    agent: Agent,
    ticket: Ticket,
    names: Names,
    summary: Summary,
}

impl<S: Sink> Pass<'_, S> {
    /// Applies one listed entry; breaks when the result is untrustworthy.
    fn step(&mut self, step: Step) -> Result<ControlFlow<()>, JobFailed> {
        match step {
            Ok(Some(path)) => self.visit(&path)?,
            Ok(None) => (),
            Err(Condition::Skip(_)) => self.summary.skipped += 1,
            Err(Condition::Fatal(_)) => {
                self.summary.errors += 1;
                return Ok(ControlFlow::Break(()));
            }
        }
        Ok(ControlFlow::Continue(()))
    }

    fn visit(&mut self, path: &RowPath) -> Result<(), JobFailed> {
        self.summary.files += 1;
        let transcript = self.scanner.transcript(self.ticket, self.agent, path);
        if let Ok(transcript) = &transcript {
            self.summary.cached += usize::from(transcript.cached);
        }
        match transcript.and_then(|transcript| transcript.row(&self.names, path)) {
            Err(_) => self.summary.skipped += 1,
            Ok(None) => self.summary.empty += 1,
            Ok(Some(row)) => match self.sink.send(row) {
                Ok(()) => self.summary.rows += 1,
                Err(EmitFailure::TooLarge) => self.summary.skipped += 1,
                Err(_) => return Err(JobFailed),
            },
        }
        Ok(())
    }
}

impl Scanner {
    /// Scans `root` for `agent`'s transcripts as the desktop's Elisp finds
    /// them, emits one JSON row per titled session through `context`, and
    /// returns the JSON completion summary (see the module documentation).
    ///
    /// A root that is absent, no directory, or not listable counts one error,
    /// so that the frontend falls back; per-entry conditions are skipped.
    ///
    /// # Errors
    ///
    /// [`JobFailed`] when the job is cancelled or its stream closes.
    pub fn scan(&self, context: &Context, root: &Path, agent: Agent) -> Result<Vec<u8>, JobFailed> {
        let summary = self.run(context, root, agent)?;
        serde_json::to_vec(&summary.json()).map_err(|_| JobFailed)
    }

    /// Frees the cache. Scans running meanwhile stop using it; later scans
    /// start filling a new one.
    pub fn clear(&self) {
        let old = self.lock().clear();
        // Freed after the lock is released, so workers wait only for the swap.
        drop(old);
    }

    /// The scan behind [`Scanner::scan`], emitting into any sink.
    pub(crate) fn run(
        &self,
        sink: &impl Sink,
        root: &Path,
        agent: Agent,
    ) -> Result<Summary, JobFailed> {
        let mut walk = match Walk::open(root, agent, self.bounds) {
            Ok(walk) => walk,
            Err(_) => {
                return Ok(Summary {
                    errors: 1,
                    ..Summary::default()
                })
            }
        };
        let mut pass = Pass {
            scanner: self,
            sink,
            agent,
            ticket: self.lock().begin(agent, root),
            names: Names::load(agent, root),
            summary: Summary::default(),
        };
        for step in &mut walk {
            if sink.cancelled() {
                return Err(JobFailed);
            }
            if pass.step(step)?.is_break() {
                break;
            }
        }
        pass.summary.truncated = walk.truncated();
        if pass.summary.complete() {
            self.lock().sweep(pass.ticket);
        }
        Ok(pass.summary)
    }

    /// Reads or recalls the transcript at `path`, retrying once when it
    /// changes while being read.
    fn transcript(&self, ticket: Ticket, agent: Agent, path: &RowPath) -> Result<Transcript, Skip> {
        retrying(|| self.read(ticket, agent, path))
    }

    fn read(&self, ticket: Ticket, agent: Agent, path: &RowPath) -> Result<Transcript, Skip> {
        let mut file = open_regular(path.as_path())?;
        let stamp = Stamp::of(&file)?;
        let recalled = self.lock().lookup(ticket, agent, path.as_path(), stamp);
        if let Some(session) = recalled {
            return Ok(Transcript {
                stamp,
                session,
                cached: true,
            });
        }
        // The cache lock is never held while a file is read or parsed.
        let session = read_session(&mut file, path.as_path(), agent, stamp)?.map(Arc::new);
        if Stamp::of(&file)? != stamp {
            return Err(Skip::Changed);
        }
        // The cache and this scan share the immutable parse.
        let shared = session.clone();
        self.lock()
            .insert(ticket, agent, path.as_path(), stamp, shared);
        Ok(Transcript {
            stamp,
            session,
            cached: false,
        })
    }

    /// The cache, emptied first when a panicking holder poisoned it: its
    /// invariant may be broken, and scanning must go on.
    fn lock(&self) -> MutexGuard<'_, Cache> {
        self.cache.lock().unwrap_or_else(|poisoned| {
            let mut cache = poisoned.into_inner();
            drop(cache.clear());
            self.cache.clear_poison();
            cache
        })
    }

    /// A scanner with its own cache and listing bounds.
    #[cfg(test)]
    pub(crate) fn with(cache: Cache, bounds: Bounds) -> Self {
        Self {
            cache: Arc::new(Mutex::new(cache)),
            bounds,
        }
    }

    /// A handle to this scanner's cache that lists with other bounds.
    #[cfg(test)]
    pub(crate) fn with_bounds(&self, bounds: Bounds) -> Self {
        Self {
            cache: Arc::clone(&self.cache),
            bounds,
        }
    }

    /// Number of cached transcripts.
    #[cfg(test)]
    pub(crate) fn cached_entries(&self) -> usize {
        self.lock().len()
    }

    /// Poisons the cache lock, as a panic while holding it would.
    #[cfg(test)]
    pub(crate) fn poison(&self) {
        let cache = Arc::clone(&self.cache);
        let _ = std::thread::spawn(move || {
            let _guard = cache.lock();
            std::panic::resume_unwind(Box::new("poisoning the cache"));
        })
        .join();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_changed_transcript_is_read_once_more_and_no_more() {
        let outcomes = |list: Vec<Result<u8, Skip>>| {
            let mut list = list.into_iter();
            let mut calls = 0;
            let result = retrying(|| {
                calls += 1;
                list.next().unwrap()
            });
            (result, calls)
        };
        assert_eq!(outcomes(vec![Err(Skip::Changed), Ok(1)]), (Ok(1), 2));
        let twice = vec![Err(Skip::Changed), Err(Skip::Changed), Ok(1)];
        assert_eq!(outcomes(twice), (Err(Skip::Changed), 2));
        assert_eq!(
            outcomes(vec![Err(Skip::Missing), Ok(1)]),
            (Err(Skip::Missing), 1)
        );
        assert_eq!(outcomes(vec![Ok(1)]), (Ok(1), 1));
    }
}
