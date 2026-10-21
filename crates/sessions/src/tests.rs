// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Scan-level tests on fixture trees in temporary directories.

use crate::cache::Cache;
use crate::scan::{Sink, Summary};
use crate::walk::Bounds;
use crate::{Agent, Scanner, HEAD};
use lispm_kernel::{Config, EmitFailure, Error, JobOptions, Kernel, Outcome, WorkClass};
use serde_json::{json, Value};
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "lispm-sessions-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self, path: &str) -> PathBuf {
        self.0.join(path)
    }

    fn write(&self, path: &str, text: &str) -> PathBuf {
        let path = self.path(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, text).unwrap();
        path
    }

    fn dir(&self, path: &str) -> PathBuf {
        let path = self.path(path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[cfg(unix)]
    fn link(&self, target: &str, link: &str) {
        std::os::unix::fs::symlink(target, self.path(link)).unwrap();
    }

    /// Paths of rows relative to the fixture.
    fn files(&self, rows: &[Value]) -> BTreeSet<String> {
        rows.iter()
            .map(|row| {
                let file = Path::new(row["file"].as_str().unwrap());
                file.strip_prefix(&self.0)
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .to_owned()
            })
            .collect()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
fn chmod(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

#[cfg(unix)]
fn fifo(path: &Path) {
    let status = std::process::Command::new("mkfifo")
        .arg(path)
        .status()
        .unwrap();
    assert!(status.success());
}

/// Collects rows in memory, never cancelled.
#[derive(Default)]
struct Collect(RefCell<Vec<Value>>);

impl Sink for Collect {
    fn cancelled(&self) -> bool {
        false
    }

    fn send(&self, row: Vec<u8>) -> Result<(), EmitFailure> {
        self.0
            .borrow_mut()
            .push(serde_json::from_slice(&row).unwrap());
        Ok(())
    }
}

fn scan(scanner: &Scanner, root: &Path, agent: Agent) -> (Vec<Value>, Summary) {
    let sink = Collect::default();
    let summary = scanner.run(&sink, root, agent).unwrap();
    (sink.0.into_inner(), summary)
}

/// Scans through a real kernel job, as the bridge does.
fn run(scanner: &Scanner, root: &Path, agent: Agent) -> (Vec<Value>, Value) {
    let kernel = Kernel::new(Config::default()).unwrap();
    loop {
        let scanner = scanner.clone();
        let root = root.to_owned();
        let options = JobOptions {
            class: WorkClass::Io,
            ..JobOptions::default()
        };
        match kernel.submit_with_options(1, 0, vec![], 1024, options, move |ctx, _| {
            scanner.scan(&ctx, &root, agent)
        }) {
            Ok(_) => break,
            Err(Error::Busy) => std::thread::yield_now(),
            error => panic!("{error:?}"),
        }
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut rows = Vec::new();
    loop {
        assert!(Instant::now() < deadline);
        match kernel.drain(8, 512 * 1024) {
            Ok(events) => {
                for event in events {
                    match event.outcome {
                        Outcome::Chunk { bytes, .. } => {
                            rows.push(serde_json::from_slice(&bytes).unwrap())
                        }
                        Outcome::Success(bytes) => {
                            return (rows, serde_json::from_slice(&bytes).unwrap())
                        }
                        error => panic!("{error:?}"),
                    }
                }
            }
            Err(Error::Busy) => (),
            error => panic!("{error:?}"),
        }
        std::thread::yield_now();
    }
}

fn codex(prompt: &str) -> String {
    format!(
        "{}\n{}\n",
        json!({"type":"session_meta", "payload":{"id":"id-1","cwd":"/project","timestamp":"2026-10-21T00:00:00Z"}}),
        json!({"type":"event_msg","payload":{"type":"user_message","message":prompt}})
    )
}

fn claude(prompt: &str) -> String {
    format!(
        "{}\n",
        json!({"type":"user","cwd":"/project","message":{"content":prompt}})
    )
}

fn summary(files: usize, rows: usize, skipped: usize, cached: usize) -> Summary {
    Summary {
        files,
        rows,
        skipped,
        cached,
        ..Summary::default()
    }
}

#[test]
fn cache_hits_and_content_changes_invalidate() {
    let fixture = Fixture::new();
    let file = fixture.write("sessions/2026/rollout-one.jsonl", &codex("first"));
    let scanner = Scanner::default();
    let (rows, summary) = run(&scanner, &fixture.path("sessions"), Agent::Codex);
    assert_eq!(rows[0]["title"], "first");
    assert_eq!(
        summary,
        json!({"files":1,"rows":1,"empty":0,"skipped":0,"errors":0,"cached":0,"truncated":false})
    );
    let (_, summary) = run(&scanner, &fixture.path("sessions"), Agent::Codex);
    assert_eq!(summary["cached"], 1);
    fs::write(file, codex("second changed")).unwrap();
    let (rows, summary) = run(&scanner, &fixture.path("sessions"), Agent::Codex);
    assert_eq!(rows[0]["title"], "second changed");
    assert_eq!(summary["cached"], 0);
}

#[test]
fn corpus_beyond_the_old_cache_limit_hits_on_every_transcript() {
    let fixture = Fixture::new();
    for n in 0..1500 {
        fixture.write(
            &format!("sessions/{}/rollout-{n}.jsonl", n % 7),
            &codex("p"),
        );
    }
    let scanner = Scanner::default();
    let root = fixture.path("sessions");
    assert_eq!(
        scan(&scanner, &root, Agent::Codex).1,
        summary(1500, 1500, 0, 0)
    );
    assert_eq!(
        scan(&scanner, &root, Agent::Codex).1,
        summary(1500, 1500, 0, 1500)
    );
}

#[test]
fn full_cache_keeps_its_hits_instead_of_thrashing() {
    let fixture = Fixture::new();
    for n in 0..15 {
        fixture.write(&format!("s/rollout-{n}.jsonl"), &codex("p"));
    }
    let scanner = Scanner::with(Cache::with_bounds(10, usize::MAX), Bounds::default());
    let root = fixture.path("s");
    assert_eq!(scan(&scanner, &root, Agent::Codex).1.cached, 0);
    for _ in 0..3 {
        assert_eq!(scan(&scanner, &root, Agent::Codex).1.cached, 10);
    }
}

#[test]
fn complete_scans_sweep_vanished_transcripts_and_truncated_ones_do_not() {
    let fixture = Fixture::new();
    let files = ["a", "b", "c"].map(|n| fixture.write(&format!("s/rollout-{n}.jsonl"), &codex(n)));
    let scanner = Scanner::default();
    let root = fixture.path("s");
    scan(&scanner, &root, Agent::Codex);
    assert_eq!(scanner.cached_entries(), 3);
    let truncating = scanner.with_bounds(Bounds {
        entries: 1,
        depth: 16,
    });
    assert!(scan(&truncating, &root, Agent::Codex).1.truncated);
    assert_eq!(scanner.cached_entries(), 3);
    let [gone, ..] = &files;
    fs::remove_file(gone).unwrap();
    assert_eq!(scan(&scanner, &root, Agent::Codex).1, summary(2, 2, 0, 2));
    assert_eq!(scanner.cached_entries(), 2);
}

#[test]
fn clear_frees_the_cache() {
    let fixture = Fixture::new();
    fixture.write("s/rollout-a.jsonl", &codex("a"));
    let scanner = Scanner::default();
    let root = fixture.path("s");
    scan(&scanner, &root, Agent::Codex);
    scanner.clear();
    assert_eq!(scanner.cached_entries(), 0);
    assert_eq!(scan(&scanner, &root, Agent::Codex).1.cached, 0);
    assert_eq!(scan(&scanner, &root, Agent::Codex).1.cached, 1);
}

#[test]
fn poisoned_cache_is_cleared_and_scanning_continues() {
    let fixture = Fixture::new();
    fixture.write("s/rollout-a.jsonl", &codex("a"));
    let scanner = Scanner::default();
    let root = fixture.path("s");
    scan(&scanner, &root, Agent::Codex);
    scanner.poison();
    let (rows, after) = scan(&scanner, &root, Agent::Codex);
    assert_eq!((rows.len(), after), (1, summary(1, 1, 0, 0)));
    assert_eq!(scan(&scanner, &root, Agent::Codex).1.cached, 1);
}

#[test]
fn codex_index_updates_bypass_transcript_cache() {
    let fixture = Fixture::new();
    fixture.write("sessions/rollout-one.jsonl", &codex("prompt"));
    fixture.write(
        "session_index.jsonl",
        "{\"id\":\"id-1\",\"thread_name\":\"first name\"}\n",
    );
    let scanner = Scanner::default();
    let (rows, _) = scan(&scanner, &fixture.path("sessions"), Agent::Codex);
    assert_eq!(rows[0]["title"], "first name");
    fixture.write(
        "session_index.jsonl",
        "{\"id\":\"id-1\",\"thread_name\":\"new name\"}\n",
    );
    let (rows, summary) = scan(&scanner, &fixture.path("sessions"), Agent::Codex);
    assert_eq!(rows[0]["title"], "new name");
    assert_eq!(summary.cached, 1);
}

#[test]
fn claude_scans_only_project_level_and_refreshes_external_title() {
    let fixture = Fixture::new();
    fixture.write("projects/p/session.jsonl", &claude("hello"));
    fixture.write("projects/p/session/subagent.jsonl", &claude("hello"));
    fixture.write("projects/root.jsonl", &claude("hello"));
    let title = fixture.write(
        "projects/p/session/custom-title.json",
        "{\"customTitle\":\"renamed\"}",
    );
    let scanner = Scanner::default();
    let (rows, summary) = scan(&scanner, &fixture.path("projects"), Agent::Claude);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["title"], "renamed");
    assert_eq!(rows[0]["id"], "session");
    assert_eq!(summary.files, 1);
    fs::write(&title, "{\"customTitle\":\"changed\"}").unwrap();
    let (rows, summary) = scan(&scanner, &fixture.path("projects"), Agent::Claude);
    assert_eq!(rows[0]["title"], "changed");
    assert_eq!(summary.cached, 1);
}

#[test]
fn bounded_regions_skip_cut_lines_and_read_tail_title() {
    let fixture = Fixture::new();
    let mut text = claude("prompt");
    text.push_str(&"x".repeat(usize::try_from(HEAD).unwrap() + 20));
    text.push_str("\n{\"customTitle\":\"tail title\"}\ninvalid JSON\n");
    fixture.write("projects/p/session.jsonl", &text);
    let (rows, _) = scan(
        &Scanner::default(),
        &fixture.path("projects"),
        Agent::Claude,
    );
    assert_eq!(rows[0]["title"], "tail title");
}

#[test]
fn transcripts_without_a_listable_session_count_as_empty() {
    let fixture = Fixture::new();
    fixture.write("s/rollout-none.jsonl", "not JSON\n");
    let meta = json!({"type":"session_meta","payload":{"id":"x","cwd":"/"}});
    fixture.write("s/rollout-untitled.jsonl", &format!("{meta}\n"));
    let (rows, summary) = scan(&Scanner::default(), &fixture.path("s"), Agent::Codex);
    assert!(rows.is_empty());
    assert_eq!((summary.files, summary.empty, summary.skipped), (2, 2, 0));
}

#[test]
fn absent_roots_count_one_error_so_the_frontend_falls_back() {
    let fixture = Fixture::new();
    let file = fixture.write("file", "");
    for root in [fixture.path("missing"), file.clone(), file.join("below")] {
        assert_eq!(
            scan(&Scanner::default(), &root, Agent::Codex).1,
            Summary {
                errors: 1,
                ..Summary::default()
            }
        );
    }
}

#[cfg(unix)]
#[test]
fn unlistable_root_counts_one_error() {
    let fixture = Fixture::new();
    let root = fixture.dir("s");
    fixture.write("s/rollout-a.jsonl", &codex("a"));
    chmod(&root, 0o000);
    let privileged = fs::read_dir(&root).is_ok();
    let (_, summary) = scan(&Scanner::default(), &root, Agent::Codex);
    chmod(&root, 0o755);
    if !privileged {
        assert_eq!(
            summary,
            Summary {
                errors: 1,
                ..Summary::default()
            }
        );
    }
}

#[cfg(unix)]
#[test]
fn per_entry_conditions_are_skipped_not_errors() {
    let fixture = Fixture::new();
    fixture.write("s/rollout-good.jsonl", &codex("good"));
    fixture.link("missing", "s/rollout-dangling.jsonl");
    fifo(&fixture.path("s/rollout-fifo.jsonl"));
    let locked = fixture.write("s/rollout-locked.jsonl", &codex("locked"));
    let closed = fixture.dir("s/closed");
    fixture.write("s/closed/rollout-hidden.jsonl", &codex("hidden"));
    let long_cwd = "x".repeat(crate::MAX_FIELDS + 1);
    let meta = json!({"type":"session_meta","payload":{"id":"i","cwd":long_cwd}});
    fixture.write("s/rollout-long.jsonl", &format!("{meta}\n"));
    chmod(&locked, 0o000);
    chmod(&closed, 0o000);
    let privileged = fs::File::open(&locked).is_ok();
    let (rows, summary) = scan(&Scanner::default(), &fixture.path("s"), Agent::Codex);
    chmod(&locked, 0o644);
    chmod(&closed, 0o755);
    assert_eq!(summary.errors, 0);
    if !privileged {
        assert_eq!(
            fixture.files(&rows),
            BTreeSet::from(["s/rollout-good.jsonl".into()])
        );
        // Dangling, FIFO, unreadable file, unreadable directory, long cwd.
        assert_eq!(summary.skipped, 5);
        // The unreadable directory's transcripts went unlisted.
        assert!(summary.truncated);
    }
}

// Regression: an unlistable directory below the root used to count as a skip
// only, so its subtree's valid cache entries were swept as if gone.
#[cfg(unix)]
#[test]
fn unlistable_subdirectory_truncates_and_keeps_its_cached_transcripts() {
    let fixture = Fixture::new();
    fixture.write("s/2026/10/20/rollout-a.jsonl", &codex("a"));
    fixture.write("s/2026/10/21/rollout-b.jsonl", &codex("b"));
    let root = fixture.path("s");
    let scanner = Scanner::default();
    assert_eq!(scan(&scanner, &root, Agent::Codex).1.rows, 2);
    let closed = fixture.path("s/2026/10/21");
    chmod(&closed, 0o000);
    let privileged = fs::read_dir(&closed).is_ok();
    let (_, partial) = scan(&scanner, &root, Agent::Codex);
    chmod(&closed, 0o755);
    if !privileged {
        assert_eq!((partial.rows, partial.errors), (1, 0));
        assert!(partial.truncated);
        let (_, again) = scan(&scanner, &root, Agent::Codex);
        assert_eq!((again.rows, again.cached), (2, 2));
    }
}

#[cfg(unix)]
#[test]
fn side_files_never_fail_the_scan() {
    let fixture = Fixture::new();
    fixture.write("projects/p/dir.jsonl", &claude("dir title file"));
    fixture.dir("projects/p/dir/custom-title.json");
    fixture.write("projects/p/large.jsonl", &claude("large title file"));
    let large = format!("{{\"customTitle\":\"{}\"}}", "x".repeat(70 * 1024));
    fixture.write("projects/p/large/custom-title.json", &large);
    fixture.write("projects/p/locked.jsonl", &claude("locked title file"));
    let locked = fixture.write(
        "projects/p/locked/custom-title.json",
        "{\"customTitle\":\"t\"}",
    );
    chmod(&locked, 0o000);
    let (rows, summary) = scan(
        &Scanner::default(),
        &fixture.path("projects"),
        Agent::Claude,
    );
    chmod(&locked, 0o644);
    assert_eq!(summary, summary_of(3, 3));
    for row in &rows {
        assert!(row["title"].as_str().unwrap().ends_with("title file") || row["title"] == "t");
    }
    // An unreadable index means no names; a symlinked index is followed.
    fixture.write("codex/sessions/rollout-a.jsonl", &codex("prompt"));
    let index = fixture.write(
        "codex/index",
        "{\"id\":\"id-1\",\"thread_name\":\"named\"}\n",
    );
    fixture.link("index", "codex/session_index.jsonl");
    let root = fixture.path("codex/sessions");
    assert_eq!(
        scan(&Scanner::default(), &root, Agent::Codex).0[0]["title"],
        "named"
    );
    chmod(&index, 0o000);
    let (rows, summary) = scan(&Scanner::default(), &root, Agent::Codex);
    chmod(&index, 0o644);
    assert_eq!(summary, summary_of(1, 1));
    assert!(rows[0]["title"] == "prompt" || rows[0]["title"] == "named");
}

fn summary_of(files: usize, rows: usize) -> Summary {
    summary(files, rows, 0, 0)
}

/// The fixture of `codex_listing_matches_the_elisp`, and what Emacs 31.1's
/// `directory-files-recursively` lists in it.
#[cfg(unix)]
#[test]
fn codex_listing_matches_the_elisp() {
    let fixture = Fixture::new();
    for name in [
        "rollout-a.jsonl",
        "ROLLOUT-B.JSONL",
        "rollout-.jsonl",
        "sub/rollout-c.jsonl",
    ] {
        fixture.write(&format!("codex/{name}"), &codex(name));
    }
    fixture.write("codex/rollout-x.txt", &codex("no"));
    fixture.write(
        "codex/rollout-isdir.jsonl/rollout-nested.jsonl",
        &codex("n"),
    );
    fixture.write("outside/target.jsonl", &codex("t"));
    fixture.write("outside/dir/rollout-in-linked-dir.jsonl", &codex("no"));
    fixture.link("../outside/target.jsonl", "codex/rollout-link.jsonl");
    fixture.link("../outside/dir", "codex/linkdir");
    fixture.link("../outside/dir", "codex/rollout-dirlink.jsonl");
    fixture.link("../missing", "codex/rollout-dangling.jsonl");
    fifo(&fixture.path("codex/rollout-fifo.jsonl"));
    fixture.link("codex", "codexlink");
    // Emacs lists these and also the dangling symlink and the FIFO, which it
    // cannot read: the scan skips those two.
    let listed = [
        "rollout-a.jsonl",
        "ROLLOUT-B.JSONL",
        "rollout-.jsonl",
        "sub/rollout-c.jsonl",
        "rollout-isdir.jsonl/rollout-nested.jsonl",
        "rollout-link.jsonl",
    ];
    for root in ["codex", "codexlink"] {
        let (rows, summary) = scan(&Scanner::default(), &fixture.path(root), Agent::Codex);
        let expected = listed.iter().map(|name| format!("{root}/{name}")).collect();
        assert_eq!(fixture.files(&rows), expected);
        assert_eq!((summary.skipped, summary.errors), (2, 0));
    }
}

/// What Emacs 31.1's `file-expand-wildcards "ROOT/*/*.jsonl"` lists, except
/// a project symlinked to the root itself, which the scan skips as a cycle.
#[cfg(unix)]
#[test]
fn claude_listing_matches_the_elisp() {
    let fixture = Fixture::new();
    for name in [
        "p/a.jsonl",
        "p/.dot.jsonl",
        "p/.jsonl",
        ".hid/h.jsonl",
        "real/r.jsonl",
    ] {
        fixture.write(&format!("claude/{name}"), &claude(name));
    }
    for name in ["p/B.JSONL", "root.jsonl", "p/session/sub.jsonl"] {
        fixture.write(&format!("claude/{name}"), &claude("no"));
    }
    fixture.dir("claude/p/sess.jsonl");
    fixture.write("outside/target.jsonl", &claude("t"));
    fixture.write("outside/dir/inlinked.jsonl", &claude("i"));
    fixture.write("outside/dir/rollout-in-linked-dir.jsonl", &claude("r"));
    fixture.link("../../outside/target.jsonl", "claude/p/linked.jsonl");
    fixture.link("../outside/dir", "claude/linkedproj");
    fixture.link("../missing", "claude/p/dangling.jsonl");
    fixture.link(".", "claude/loop");
    fixture.link("claude", "claudelink");
    // Elisp's ROOT/*/*.jsonl has a fixed depth: a project linked to the root
    // itself lists the root's own transcripts once.
    let listed = [
        "p/a.jsonl",
        "p/.dot.jsonl",
        "p/.jsonl",
        ".hid/h.jsonl",
        "real/r.jsonl",
        "p/linked.jsonl",
        "linkedproj/inlinked.jsonl",
        "linkedproj/rollout-in-linked-dir.jsonl",
        "loop/root.jsonl",
    ];
    for root in ["claude", "claudelink"] {
        let (rows, summary) = scan(&Scanner::default(), &fixture.path(root), Agent::Claude);
        let expected = listed.iter().map(|name| format!("{root}/{name}")).collect();
        assert_eq!(fixture.files(&rows), expected);
        // The directory named sess.jsonl and the dangling symlink.
        assert_eq!((summary.skipped, summary.errors), (2, 0));
    }
}

#[cfg(unix)]
#[test]
fn unreadable_claude_projects_are_skipped() {
    let fixture = Fixture::new();
    fixture.write("claude/open/a.jsonl", &claude("a"));
    let closed = fixture.dir("claude/closed");
    fixture.write("claude/closed/b.jsonl", &claude("b"));
    chmod(&closed, 0o000);
    let privileged = fs::read_dir(&closed).is_ok();
    let (rows, summary) = scan(&Scanner::default(), &fixture.path("claude"), Agent::Claude);
    chmod(&closed, 0o755);
    if !privileged {
        assert_eq!(rows.len(), 1);
        assert_eq!((summary.skipped, summary.errors), (1, 0));
        assert!(summary.truncated);
    }
}

#[test]
fn structural_bounds_truncate_instead_of_failing() {
    let fixture = Fixture::new();
    fixture.write("s/rollout-top.jsonl", &codex("top"));
    fixture.write("s/a/rollout-mid.jsonl", &codex("mid"));
    fixture.write("s/a/b/rollout-deep.jsonl", &codex("deep"));
    let root = fixture.path("s");
    let shallow = Scanner::with(
        Cache::default(),
        Bounds {
            entries: 100,
            depth: 2,
        },
    );
    let (rows, summary) = scan(&shallow, &root, Agent::Codex);
    let expected = ["s/rollout-top.jsonl", "s/a/rollout-mid.jsonl"].map(String::from);
    assert_eq!(fixture.files(&rows), BTreeSet::from(expected));
    assert!(summary.truncated);
    assert_eq!(summary.errors, 0);
    let few = Scanner::with(
        Cache::default(),
        Bounds {
            entries: 2,
            depth: 16,
        },
    );
    let (rows, summary) = scan(&few, &root, Agent::Codex);
    assert!(rows.len() < 3);
    assert!(summary.truncated);
    let (rows, summary) = scan(&Scanner::default(), &root, Agent::Codex);
    assert_eq!((rows.len(), summary.truncated), (3, false));
}

#[test]
fn cancelled_scan_unblocks_when_incremental_queue_is_full() {
    let fixture = Fixture::new();
    for n in 0..8 {
        fixture.write(
            &format!("s/rollout-{n}.jsonl"),
            &format!(
                "{}\n{}\n",
                json!({"type":"session_meta","payload":{"id":n.to_string(),"cwd":"/p"}}),
                json!({"type":"event_msg","payload":{"type":"user_message","message":"hello"}})
            ),
        );
    }
    let root = fixture.path("s");
    let kernel = Kernel::new(Config {
        max_stream_items: 1,
        ..Config::default()
    })
    .unwrap();
    let id = loop {
        let path = root.clone();
        let options = JobOptions {
            class: WorkClass::Io,
            ..JobOptions::default()
        };
        match kernel.submit_with_options(1, 0, vec![], 1024, options, move |ctx, _| {
            Scanner::default().scan(&ctx, &path, Agent::Codex)
        }) {
            Ok(id) => break id,
            Err(Error::Busy) => std::thread::yield_now(),
            e => panic!("{e:?}"),
        }
    };
    let deadline = Instant::now() + Duration::from_secs(3);
    while !kernel.stats().is_ok_and(|s| s.stream_items == 1) {
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    while !matches!(kernel.cancel(id), Ok(true)) {
        std::thread::yield_now();
    }
    while !kernel.stats().is_ok_and(|s| s.completed == 1) {
        assert!(Instant::now() < deadline);
        std::thread::yield_now();
    }
    let events = loop {
        match kernel.drain(8, 65536) {
            Ok(events) => break events,
            Err(Error::Busy) => std::thread::yield_now(),
            e => panic!("{e:?}"),
        }
    };
    // Cancelling drops the scan's undrained chunk; only its final outcome remains.
    assert_eq!(events.last().unwrap().outcome, Outcome::Cancelled);
    assert_eq!(events.len(), 1);
}
