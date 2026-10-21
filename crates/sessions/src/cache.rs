// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! The parse cache: a pure data structure, without I/O or locks.
//!
//! Entries are keyed by agent and transcript path and are valid only for the
//! file [`Stamp`] they were parsed at. Each scan of a root takes a [`Ticket`];
//! a scan that lists its root completely sweeps the root's entries it did not
//! see. Admission is bounded by entry count and retained bytes and never
//! evicts: when the cache is full, new transcripts are parsed uncached, so a
//! corpus larger than the cache keeps hitting on the entries it holds instead
//! of evicting each next one, as an LRU walked in scan order did.
//!
//! Invariant: `bytes` is the sum of all entry costs, `len() <= max_entries`
//! and `bytes <= max_bytes`.

use crate::parse::{Agent, Session};
use crate::source::Stamp;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Default bound on cached transcripts: a hundred thousand per agent.
const MAX_ENTRIES: usize = 250_000;
/// Default bound on retained bytes, counted by [`cost`].
const MAX_BYTES: usize = 64 * 1024 * 1024;
/// Estimated per-entry bytes beyond the strings: key, entry, `Arc` and table slot.
const ENTRY_OVERHEAD: usize = 256;
/// Bound on distinct scanned roots; one more empties the cache.
const MAX_ROOTS: usize = 64;

/// A scan's claim on the cache: the root it lists and its generation.
///
/// A ticket taken before [`Cache::clear`] no longer reads or writes entries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Ticket {
    epoch: u64,
    root: u64,
    generation: u64,
}

struct Entry {
    stamp: Stamp,
    session: Option<Arc<Session>>,
    cost: usize,
    /// The root of the latest scan that saw the entry.
    root: u64,
    /// The highest generation of a scan that saw the entry.
    seen: u64,
}

impl Entry {
    /// Whether the scan holding `ticket` completed without seeing this entry
    /// of its root, so that the transcript is gone from the root.
    fn unseen_by(&self, ticket: Ticket) -> bool {
        self.root == ticket.root && self.seen < ticket.generation
    }
}

/// Cached parses of both agents' transcripts.
pub(crate) struct Cache {
    codex: HashMap<PathBuf, Entry>,
    claude: HashMap<PathBuf, Entry>,
    roots: HashMap<(Agent, PathBuf), u64>,
    bytes: usize,
    epoch: u64,
    /// Source of root ids and generations; never reset, so they stay unique.
    next: u64,
    max_entries: usize,
    max_bytes: usize,
}

impl Default for Cache {
    fn default() -> Self {
        Self::with_bounds(MAX_ENTRIES, MAX_BYTES)
    }
}

/// Bytes an entry retains, as admission counts them.
fn cost(path: &Path, session: Option<&Session>) -> usize {
    ENTRY_OVERHEAD + path.as_os_str().len() + session.map_or(0, Session::cost)
}

impl Cache {
    /// An empty cache admitting at most `max_entries` entries and `max_bytes` bytes.
    pub(crate) fn with_bounds(max_entries: usize, max_bytes: usize) -> Self {
        Self {
            codex: HashMap::new(),
            claude: HashMap::new(),
            roots: HashMap::new(),
            bytes: 0,
            epoch: 0,
            next: 0,
            max_entries,
            max_bytes,
        }
    }

    /// Starts a scan of `root` for `agent`.
    pub(crate) fn begin(&mut self, agent: Agent, root: &Path) -> Ticket {
        let key = (agent, root.to_path_buf());
        let root = match self.roots.get(&key) {
            Some(root) => *root,
            None => {
                if self.roots.len() >= MAX_ROOTS {
                    drop(self.clear());
                }
                let root = self.allocate();
                self.roots.insert(key, root);
                root
            }
        };
        Ticket {
            epoch: self.epoch,
            root,
            generation: self.allocate(),
        }
    }

    /// The cached parse of `path` when it was parsed at `stamp`, marking it seen.
    pub(crate) fn lookup(
        &mut self,
        ticket: Ticket,
        agent: Agent,
        path: &Path,
        stamp: Stamp,
    ) -> Option<Option<Arc<Session>>> {
        if !self.issued(ticket) {
            return None;
        }
        let entry = self
            .shelf(agent)
            .get_mut(path)
            .filter(|entry| entry.stamp == stamp)?;
        entry.root = ticket.root;
        entry.seen = entry.seen.max(ticket.generation);
        Some(entry.session.clone())
    }

    /// Caches the parse of `path` at `stamp`, replacing an older one; returns
    /// whether it was admitted.
    pub(crate) fn insert(
        &mut self,
        ticket: Ticket,
        agent: Agent,
        path: &Path,
        stamp: Stamp,
        session: Option<Arc<Session>>,
    ) -> bool {
        if !self.issued(ticket) {
            return false;
        }
        let mut seen = ticket.generation;
        if let Some(old) = self.shelf(agent).remove(path) {
            self.bytes = self.bytes.saturating_sub(old.cost);
            // An older scan overlapping a newer one must not hide the entry from
            // the newer scan's sweep.
            seen = seen.max(old.seen);
        }
        let cost = cost(path, session.as_deref());
        if !self.admits(cost) {
            return false;
        }
        self.bytes += cost;
        let entry = Entry {
            stamp,
            session,
            cost,
            root: ticket.root,
            seen,
        };
        self.shelf(agent).insert(path.to_path_buf(), entry);
        true
    }

    /// Drops the entries of the ticket's root that its complete scan did not see.
    pub(crate) fn sweep(&mut self, ticket: Ticket) {
        if !self.issued(ticket) {
            return;
        }
        let mut freed = 0;
        for shelf in [&mut self.codex, &mut self.claude] {
            shelf.retain(|_, entry| {
                let unseen = entry.unseen_by(ticket);
                if unseen {
                    freed += entry.cost;
                }
                !unseen
            });
        }
        self.bytes = self.bytes.saturating_sub(freed);
    }

    /// Empties the cache and invalidates every ticket; returns the old contents
    /// so that the caller can free them after releasing its lock.
    #[must_use]
    pub(crate) fn clear(&mut self) -> Self {
        let mut fresh = Self::with_bounds(self.max_entries, self.max_bytes);
        fresh.epoch = self.epoch.wrapping_add(1);
        fresh.next = self.next;
        std::mem::replace(self, fresh)
    }

    /// Number of cached transcripts.
    pub(crate) fn len(&self) -> usize {
        self.codex.len() + self.claude.len()
    }

    /// Retained bytes, as admission counts them.
    #[cfg(test)]
    pub(crate) fn bytes(&self) -> usize {
        self.bytes
    }

    fn admits(&self, cost: usize) -> bool {
        self.len() < self.max_entries && cost <= self.max_bytes.saturating_sub(self.bytes)
    }

    fn issued(&self, ticket: Ticket) -> bool {
        ticket.epoch == self.epoch
    }

    fn shelf(&mut self, agent: Agent) -> &mut HashMap<PathBuf, Entry> {
        match agent {
            Agent::Codex => &mut self.codex,
            Agent::Claude => &mut self.claude,
        }
    }

    /// A fresh root id or generation. Saturation only stops sweeping.
    fn allocate(&mut self) -> u64 {
        self.next = self.next.saturating_add(1);
        self.next
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn stamp(text: &str) -> Stamp {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("lispm-cache-{}-{n}", std::process::id()));
        fs::write(&path, text).unwrap();
        let stamp = Stamp::of(&fs::File::open(&path).unwrap()).unwrap();
        fs::remove_file(path).unwrap();
        stamp
    }

    fn session(title: &str) -> Option<Arc<Session>> {
        Some(Arc::new(Session {
            agent: Agent::Codex,
            id: "id".into(),
            cwd: "/".into(),
            title: Some(title.into()),
            started: None,
        }))
    }

    #[test]
    fn hits_require_the_parsed_stamp() {
        let mut cache = Cache::default();
        let (old, new) = (stamp("a"), stamp("bb"));
        let ticket = cache.begin(Agent::Codex, Path::new("/root"));
        assert!(cache.insert(
            ticket,
            Agent::Codex,
            Path::new("/root/f"),
            old,
            session("t")
        ));
        let hit = cache.lookup(ticket, Agent::Codex, Path::new("/root/f"), old);
        assert_eq!(
            hit.flatten().and_then(|s| s.title.clone()).as_deref(),
            Some("t")
        );
        assert!(cache
            .lookup(ticket, Agent::Codex, Path::new("/root/f"), new)
            .is_none());
        // Keys include the agent.
        assert!(cache
            .lookup(ticket, Agent::Claude, Path::new("/root/f"), old)
            .is_none());
    }

    #[test]
    fn full_cache_refuses_new_entries_and_keeps_old_ones() {
        let mut cache = Cache::with_bounds(2, usize::MAX);
        let ticket = cache.begin(Agent::Codex, Path::new("/r"));
        let s = stamp("x");
        for name in ["a", "b", "c"] {
            cache.insert(ticket, Agent::Codex, Path::new(name), s, None);
        }
        assert_eq!(cache.len(), 2);
        assert!(cache
            .lookup(ticket, Agent::Codex, Path::new("a"), s)
            .is_some());
        assert!(cache
            .lookup(ticket, Agent::Codex, Path::new("c"), s)
            .is_none());
        // Replacing an entry never needs room beyond its own.
        assert!(cache.insert(ticket, Agent::Codex, Path::new("a"), s, session("t")));
    }

    #[test]
    fn byte_accounting_matches_the_sum_of_costs() {
        let limit = 2 * cost(Path::new("a"), None) + 1;
        let mut cache = Cache::with_bounds(usize::MAX, limit);
        let ticket = cache.begin(Agent::Claude, Path::new("/r"));
        let s = stamp("x");
        assert!(cache.insert(ticket, Agent::Claude, Path::new("a"), s, None));
        assert!(cache.insert(ticket, Agent::Claude, Path::new("b"), s, None));
        assert!(!cache.insert(ticket, Agent::Claude, Path::new("c"), s, None));
        assert!(!cache.insert(ticket, Agent::Claude, Path::new("a"), s, session("x")));
        assert_eq!(cache.bytes(), cost(Path::new("b"), None));
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn sweep_drops_only_unseen_entries_of_its_root() {
        let mut cache = Cache::default();
        let s = stamp("x");
        let first = cache.begin(Agent::Codex, Path::new("/one"));
        let other = cache.begin(Agent::Codex, Path::new("/two"));
        cache.insert(first, Agent::Codex, Path::new("/one/kept"), s, None);
        cache.insert(first, Agent::Codex, Path::new("/one/gone"), s, None);
        cache.insert(other, Agent::Codex, Path::new("/two/x"), s, None);
        let second = cache.begin(Agent::Codex, Path::new("/one"));
        assert!(cache
            .lookup(second, Agent::Codex, Path::new("/one/kept"), s)
            .is_some());
        cache.sweep(second);
        assert_eq!(cache.len(), 2);
        assert!(cache
            .lookup(second, Agent::Codex, Path::new("/one/gone"), s)
            .is_none());
        assert!(cache
            .lookup(other, Agent::Codex, Path::new("/two/x"), s)
            .is_some());
    }

    #[test]
    fn overlapping_scans_keep_what_the_newer_one_saw() {
        // Law: seen = max over scans, so an older scan finishing late never
        // makes a newer scan's sweep drop an entry the newer one saw.
        let mut cache = Cache::default();
        let s = stamp("x");
        let older = cache.begin(Agent::Codex, Path::new("/r"));
        let newer = cache.begin(Agent::Codex, Path::new("/r"));
        cache.insert(newer, Agent::Codex, Path::new("/r/f"), s, None);
        assert!(cache
            .lookup(older, Agent::Codex, Path::new("/r/f"), s)
            .is_some());
        cache.sweep(newer);
        cache.sweep(older);
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn clear_invalidates_outstanding_tickets() {
        let mut cache = Cache::default();
        let s = stamp("x");
        let ticket = cache.begin(Agent::Codex, Path::new("/r"));
        cache.insert(ticket, Agent::Codex, Path::new("/r/f"), s, None);
        let old = cache.clear();
        assert_eq!((old.len(), cache.len(), cache.bytes()), (1, 0, 0));
        assert!(!cache.insert(ticket, Agent::Codex, Path::new("/r/f"), s, None));
        assert!(cache
            .lookup(ticket, Agent::Codex, Path::new("/r/f"), s)
            .is_none());
        let fresh = cache.begin(Agent::Codex, Path::new("/r"));
        assert!(cache.insert(fresh, Agent::Codex, Path::new("/r/f"), s, None));
    }

    #[test]
    fn too_many_roots_empty_the_cache() {
        let mut cache = Cache::default();
        let s = stamp("x");
        let first = cache.begin(Agent::Codex, Path::new("/r0"));
        cache.insert(first, Agent::Codex, Path::new("/r0/f"), s, None);
        for n in 1..=MAX_ROOTS {
            cache.begin(Agent::Codex, &PathBuf::from(format!("/r{n}")));
        }
        assert_eq!(cache.len(), 0);
        assert_eq!(cache.roots.len(), 1);
    }
}
