//! Bounded, cancellable transcript discovery. Never executes transcript content.
#![forbid(unsafe_code)]
use lispm_kernel::{Context, JobFailed};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::fs::{self, File, Metadata, ReadDir};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

const HEAD: u64 = 65536;
const TAIL: u64 = 16384;
const MAX_ROW: usize = 60 * 1024;
const MAX_FIELDS: usize = 4096;
const MAX_DEPTH: usize = 16;
const MAX_ENTRIES: usize = 100_000;
const CACHE_ENTRIES: usize = 1024;
const CACHE_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Agent {
    Codex,
    Claude,
}
impl Agent {
    fn name(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Session {
    pub agent: Agent,
    pub id: String,
    pub cwd: String,
    pub title: Option<String>,
    pub started: Option<String>,
}
impl Session {
    fn cost(&self) -> usize {
        self.id.len()
            + self.cwd.len()
            + self.title.as_ref().map_or(0, String::len)
            + self.started.as_ref().map_or(0, String::len)
    }
    pub fn json(&self, path: &Path, modified: SystemTime) -> Value {
        json!({"agent": self.agent.name(), "id": self.id, "cwd": self.cwd, "title": self.title,
            "started": self.started, "file": path.to_str(),
            "time": modified.duration_since(SystemTime::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())})
    }
}
#[derive(Clone, PartialEq)]
struct Stamp {
    size: u64,
    modified: SystemTime,
    #[cfg(unix)]
    inode: u64,
    #[cfg(unix)]
    changed: (i64, i64),
}
impl Stamp {
    fn from(meta: &Metadata) -> std::io::Result<Self> {
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Ok(Self {
            size: meta.len(),
            modified: meta.modified()?,
            #[cfg(unix)]
            inode: meta.ino(),
            #[cfg(unix)]
            changed: (meta.ctime(), meta.ctime_nsec()),
        })
    }
}
struct Entry {
    path: PathBuf,
    agent: Agent,
    stamp: Stamp,
    session: Option<Session>,
    cost: usize,
}
#[derive(Default)]
struct Cache {
    entries: VecDeque<Entry>,
    bytes: usize,
}
#[derive(Clone, Default)]
pub struct Scanner {
    cache: Arc<Mutex<Cache>>,
}
#[derive(Default)]
pub struct Counts {
    pub files: usize,
    pub rows: usize,
    pub skipped: usize,
    pub errors: usize,
    pub hits: usize,
}

fn bounded(value: &str) -> String {
    let mut end = value.len().min(MAX_FIELDS);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}
fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key)?.as_str().map(bounded)
}
fn identifier(value: &Value, key: &str) -> Option<String> {
    let value = value.get(key)?.as_str()?;
    (value.len() <= MAX_FIELDS).then(|| value.to_owned())
}
fn open_regular(path: &Path) -> std::io::Result<File> {
    let mut options = fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::other("not a regular file"));
    }
    Ok(file)
}
fn override_title(path: &Path) -> std::io::Result<Option<String>> {
    let file = match open_regular(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let mut bytes = Vec::new();
    file.take(HEAD + 1).read_to_end(&mut bytes)?;
    if bytes.len() > HEAD as usize {
        return Err(std::io::Error::other("title file too large"));
    }
    Ok(serde_json::from_slice::<Value>(&bytes)
        .ok()
        .and_then(|v| string(&v, "customTitle"))
        .filter(|s| !s.trim().is_empty()))
}
fn codex_names(root: &Path) -> std::io::Result<HashMap<String, String>> {
    let path = root.parent().unwrap_or(root).join("session_index.jsonl");
    let file = match open_regular(&path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(HashMap::new()),
        Err(e) => return Err(e),
    };
    let mut bytes = Vec::new();
    file.take(4 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(std::io::Error::other("index exceeds configured read bound"));
    }
    let mut names = HashMap::new();
    for line in bytes.split(|b| *b == b'\n') {
        if let Ok(entry) = serde_json::from_slice::<Value>(line) {
            if let (Some(id), Some(title)) =
                (identifier(&entry, "id"), string(&entry, "thread_name"))
            {
                names.insert(id, title);
            }
        }
    }
    Ok(names)
}
fn content(value: &Value) -> Option<String> {
    if let Some(s) = value.as_str() {
        return Some(bounded(s));
    }
    let mut text = String::new();
    for part in value.as_array()? {
        if let Some(part) = part.get("text").and_then(Value::as_str) {
            let remaining = MAX_FIELDS - text.len();
            let mut end = part.len().min(remaining);
            while !part.is_char_boundary(end) {
                end -= 1;
            }
            text.push_str(&part[..end]);
        }
        if text.len() >= MAX_FIELDS {
            break;
        }
    }
    Some(text)
}
fn human(text: &str) -> bool {
    let text = text.trim_start();
    !text.is_empty() && !text.starts_with('<') && !text.starts_with("# AGENTS.md")
}
fn prompt(value: &Value, agent: Agent) -> Option<String> {
    let text = match agent {
        Agent::Claude
            if value["type"] == "user"
                && !value
                    .get("isMeta")
                    .is_some_and(|v| !v.is_null() && *v != false) =>
        {
            content(&value["message"]["content"])
        }
        Agent::Codex
            if value["type"] == "event_msg" && value["payload"]["type"] == "user_message" =>
        {
            string(&value["payload"], "message")
        }
        Agent::Codex
            if value["type"] == "response_item"
                && value["payload"]["type"] == "message"
                && value["payload"]["role"] == "user" =>
        {
            content(&value["payload"]["content"])
        }
        _ => None,
    }?;
    human(&text).then_some(text)
}

/// Pure parser corresponding to desktop's bounded head/tail session parsers.
/// Titles/paths are capped at 4096 UTF-8 bytes for a bounded bridge row.
pub fn parse(agent: Agent, path: &Path, head: &[Value], tail: &[Value]) -> Option<Session> {
    match agent {
        Agent::Codex => {
            let meta = head.iter().find(|v| v["type"] == "session_meta")?;
            let payload = &meta["payload"];
            Some(Session {
                agent,
                id: identifier(payload, "id")?,
                cwd: identifier(payload, "cwd")?,
                title: head.iter().find_map(|v| prompt(v, agent)),
                started: string(payload, "timestamp"),
            })
        }
        Agent::Claude => {
            let title = head
                .iter()
                .chain(tail)
                .rev()
                .find_map(|v| {
                    string(v, "customTitle").or_else(|| {
                        (v["type"] == "summary")
                            .then(|| string(v, "summary"))
                            .flatten()
                    })
                })
                .or_else(|| head.iter().find_map(|v| prompt(v, agent)))?;
            let cwd = head.iter().chain(tail).find_map(|v| identifier(v, "cwd"))?;
            Some(Session {
                agent,
                id: bounded(path.file_stem()?.to_str()?),
                cwd,
                title: Some(title),
                started: None,
            })
        }
    }
}

fn region(file: &mut File, beg: u64, end: u64, size: u64) -> std::io::Result<Vec<Value>> {
    file.seek(SeekFrom::Start(beg))?;
    let mut bytes = Vec::new();
    file.take(end - beg).read_to_end(&mut bytes)?;
    let mut lines = bytes.split(|b| *b == b'\n').collect::<Vec<_>>();
    if beg > 0 && !lines.is_empty() {
        lines.remove(0);
    }
    if end < size {
        lines.pop();
    }
    Ok(lines
        .into_iter()
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect())
}
fn read_session(
    file: &mut File,
    path: &Path,
    agent: Agent,
    stamp: &Stamp,
) -> std::io::Result<Option<Session>> {
    let head = region(file, 0, stamp.size.min(HEAD), stamp.size)?;
    let tail = if stamp.size > HEAD {
        region(
            file,
            HEAD.max(stamp.size.saturating_sub(TAIL)),
            stamp.size,
            stamp.size,
        )?
    } else {
        Vec::new()
    };
    for value in head.iter().chain(&tail) {
        let fields = if agent == Agent::Codex && value["type"] == "session_meta" {
            vec![value["payload"].get("id"), value["payload"].get("cwd")]
        } else if agent == Agent::Claude {
            vec![value.get("cwd")]
        } else {
            vec![]
        };
        if fields
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .any(|s| s.len() > MAX_FIELDS)
        {
            return Err(std::io::Error::other(
                "session identifiers exceed bridge bounds",
            ));
        }
    }
    Ok(parse(agent, path, &head, &tail))
}

impl Scanner {
    fn cached(&self, path: &Path, agent: Agent) -> std::io::Result<(Option<Session>, Stamp, bool)> {
        let mut file = open_regular(path)?;
        let meta = file.metadata()?;
        if !meta.is_file() {
            return Err(std::io::Error::other("not a regular file"));
        }
        let stamp = Stamp::from(&meta)?;
        let mut cache = self
            .cache
            .lock()
            .map_err(|_| std::io::Error::other("cache poisoned"))?;
        if let Some(index) = cache
            .entries
            .iter()
            .position(|e| e.path == path && e.agent == agent && e.stamp == stamp)
        {
            let entry = cache.entries.remove(index).unwrap();
            let session = entry.session.clone();
            cache.entries.push_back(entry);
            return Ok((session, stamp, true));
        }
        drop(cache); // Never hold the cache lock during filesystem reads/parsing.
        let session = read_session(&mut file, path, agent, &stamp)?;
        if Stamp::from(&file.metadata()?)? != stamp {
            return Err(std::io::Error::other(
                "transcript changed during read; retry scan",
            ));
        }
        let cost = path.as_os_str().len() + session.as_ref().map_or(0, Session::cost);
        let mut cache = self
            .cache
            .lock()
            .map_err(|_| std::io::Error::other("cache poisoned"))?;
        if let Some(index) = cache
            .entries
            .iter()
            .position(|e| e.path == path && e.agent == agent)
        {
            let old = cache.entries.remove(index).unwrap();
            cache.bytes -= old.cost;
        }
        while !cache.entries.is_empty()
            && (cache.entries.len() >= CACHE_ENTRIES
                || cost > CACHE_BYTES.saturating_sub(cache.bytes))
        {
            let old = cache.entries.pop_front().unwrap();
            cache.bytes -= old.cost;
        }
        if cost <= CACHE_BYTES {
            cache.bytes += cost;
            cache.entries.push_back(Entry {
                path: path.to_path_buf(),
                agent,
                stamp: stamp.clone(),
                session: session.clone(),
                cost,
            });
        }
        Ok((session, stamp, false))
    }

    /// Discover one explicit local root. Codex recurses; Claude only reads
    /// project/*.jsonl, matching desktop discovery. Symlink entries are skipped.
    pub fn scan(&self, context: &Context, root: &Path, agent: Agent) -> Result<Vec<u8>, JobFailed> {
        let mut counts = Counts::default();
        let root_type = fs::symlink_metadata(root).map_err(|_| JobFailed)?;
        if !root_type.is_dir() {
            return Err(JobFailed);
        }
        let mut stack: Vec<ReadDir> = vec![fs::read_dir(root).map_err(|_| JobFailed)?];
        let names = if agent == Agent::Codex {
            codex_names(root).map_err(|_| JobFailed)?
        } else {
            HashMap::new()
        };
        let mut visited = 0;
        while let Some(directory) = stack.last_mut() {
            if context.is_cancelled() {
                return Err(JobFailed);
            }
            let Some(entry) = directory.next() else {
                stack.pop();
                continue;
            };
            visited += 1;
            if visited > MAX_ENTRIES {
                return Err(JobFailed);
            }
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => {
                    counts.errors += 1;
                    continue;
                }
            };
            let path = entry.path();
            if path.as_os_str().len() > MAX_FIELDS {
                counts.errors += 1;
                continue;
            }
            let kind = match entry.file_type() {
                Ok(kind) => kind,
                Err(_) => {
                    counts.errors += 1;
                    continue;
                }
            };
            if kind.is_dir() && (agent == Agent::Codex || stack.len() == 1) {
                if stack.len() >= MAX_DEPTH {
                    return Err(JobFailed);
                }
                match fs::read_dir(&path) {
                    Ok(directory) => stack.push(directory),
                    Err(_) => counts.errors += 1,
                }
                continue;
            }
            let wanted = kind.is_file()
                && path.extension().is_some_and(|ext| ext == "jsonl")
                && match agent {
                    Agent::Codex => path
                        .file_name()
                        .and_then(|n| n.to_str())
                        .is_some_and(|n| n.starts_with("rollout-")),
                    Agent::Claude => stack.len() == 2,
                };
            if !wanted {
                continue;
            }
            counts.files += 1;
            match self.cached(&path, agent) {
                Ok((Some(mut session), stamp, hit)) => {
                    // External naming changes independently of transcript cache stamps.
                    if agent == Agent::Codex {
                        if let Some(title) = names.get(&session.id) {
                            session.title = Some(title.clone());
                        }
                    } else {
                        let title_file = path
                            .parent()
                            .unwrap_or(root)
                            .join(path.file_stem().unwrap())
                            .join("custom-title.json");
                        match override_title(&title_file) {
                            Ok(Some(title)) => session.title = Some(title),
                            Ok(None) => (),
                            Err(_) => counts.errors += 1,
                        }
                    }
                    if session.title.is_none() {
                        counts.skipped += 1;
                        continue;
                    }
                    counts.hits += usize::from(hit);
                    if path.to_str().is_none() {
                        counts.errors += 1;
                        continue;
                    }
                    let row = serde_json::to_vec(&session.json(&path, stamp.modified))
                        .map_err(|_| JobFailed)?;
                    if row.len() > MAX_ROW {
                        counts.errors += 1;
                        continue;
                    }
                    context.emit(row).map_err(|_| JobFailed)?;
                    counts.rows += 1;
                }
                Ok((None, _, hit)) => {
                    counts.hits += usize::from(hit);
                    counts.skipped += 1;
                }
                Err(_) => counts.errors += 1,
            }
        }
        serde_json::to_vec(&json!({"files": counts.files, "rows": counts.rows, "skipped": counts.skipped, "errors": counts.errors, "cache_hits": counts.hits})).map_err(|_| JobFailed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lispm_kernel::{Config, Error, JobOptions, Kernel, Outcome, WorkClass};
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
        fn write(&self, path: &str, text: &str) -> PathBuf {
            let path = self.0.join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(&path, text).unwrap();
            path
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn run(scanner: &Scanner, root: &Path, agent: Agent) -> (Vec<Value>, Value) {
        let kernel = Kernel::new(Config::default()).unwrap();
        loop {
            let scanner = scanner.clone();
            let root = root.to_owned();
            match kernel.submit_with_options(
                1,
                0,
                vec![],
                1024,
                JobOptions {
                    class: WorkClass::Io,
                    ..JobOptions::default()
                },
                move |ctx, _| scanner.scan(&ctx, &root, agent),
            ) {
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

    #[test]
    fn parsers_filter_injected_context_and_keep_last_claude_title() {
        let head = vec![
            json!({"type":"user","cwd":"/p", "message":{"content":"<context>ignored"}}),
            json!({"type":"user", "isMeta":true,"message":{"content":"ignored"}}),
            json!({"type":"user","message":{"content":[{"text":"hello "},{"text":"世界"}]}}),
            json!({"type":"summary","summary":"old"}),
        ];
        let tail = vec![json!({"customTitle":"new"})];
        let parsed = parse(Agent::Claude, Path::new("session.jsonl"), &head, &tail).unwrap();
        assert_eq!(parsed.title.as_deref(), Some("new"));
        let parsed = parse(Agent::Claude, Path::new("session.jsonl"), &head[..3], &[]).unwrap();
        assert_eq!(parsed.title.as_deref(), Some("hello 世界"));
        assert!(!human("   # AGENTS.md guidance"));
    }

    #[test]
    fn cache_hits_and_content_changes_invalidate() {
        let fixture = Fixture::new();
        let file = fixture.write("sessions/2026/rollout-one.jsonl", &codex("first"));
        let scanner = Scanner::default();
        let (rows, summary) = run(&scanner, &fixture.0.join("sessions"), Agent::Codex);
        assert_eq!(rows[0]["title"], "first");
        assert_eq!(summary["cache_hits"], 0);
        let (_, summary) = run(&scanner, &fixture.0.join("sessions"), Agent::Codex);
        assert_eq!(summary["cache_hits"], 1);
        fs::write(file, codex("second changed")).unwrap();
        let (rows, summary) = run(&scanner, &fixture.0.join("sessions"), Agent::Codex);
        assert_eq!(rows[0]["title"], "second changed");
        assert_eq!(summary["cache_hits"], 0);
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
        let (rows, _) = run(&scanner, &fixture.0.join("sessions"), Agent::Codex);
        assert_eq!(rows[0]["title"], "first name");
        fixture.write(
            "session_index.jsonl",
            "{\"id\":\"id-1\",\"thread_name\":\"new name\"}\n",
        );
        let (rows, summary) = run(&scanner, &fixture.0.join("sessions"), Agent::Codex);
        assert_eq!(rows[0]["title"], "new name");
        assert_eq!(summary["cache_hits"], 1);
    }

    #[test]
    fn claude_scans_only_project_level_and_refreshes_external_title() {
        let fixture = Fixture::new();
        let text = format!(
            "{}\n",
            json!({"type":"user","cwd":"/project","message":{"content":"hello"}})
        );
        fixture.write("projects/p/session.jsonl", &text);
        fixture.write("projects/p/session/subagent.jsonl", &text);
        fixture.write("projects/root.jsonl", &text);
        fixture.write(
            "projects/p/session/custom-title.json",
            "{\"customTitle\":\"renamed\"}",
        );
        let scanner = Scanner::default();
        let (rows, summary) = run(&scanner, &fixture.0.join("projects"), Agent::Claude);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["title"], "renamed");
        assert_eq!(summary["files"], 1);
        fixture.write(
            "projects/p/session/custom-title.json",
            "{\"customTitle\":\"changed\"}",
        );
        let (rows, summary) = run(&scanner, &fixture.0.join("projects"), Agent::Claude);
        assert_eq!(rows[0]["title"], "changed");
        assert_eq!(summary["cache_hits"], 1);
    }

    #[test]
    fn bounded_regions_skip_cut_lines_and_read_tail_title() {
        let fixture = Fixture::new();
        let mut text = format!(
            "{}\n",
            json!({"type":"user","cwd":"/p","message":{"content":"prompt"}})
        );
        text.push_str(&"x".repeat(HEAD as usize + 20));
        text.push_str("\n{\"customTitle\":\"tail title\"}\ninvalid JSON\n");
        let file = fixture.write("p/session.jsonl", &text);
        let (session, _, _) = Scanner::default().cached(&file, Agent::Claude).unwrap();
        assert_eq!(session.unwrap().title.as_deref(), Some("tail title"));
    }

    #[test]
    fn cache_stays_bounded_and_caches_missing_sessions() {
        let fixture = Fixture::new();
        let scanner = Scanner::default();
        for n in 0..CACHE_ENTRIES + 8 {
            let file = fixture.write(&format!("{n}.jsonl"), "not JSON\n");
            assert!(scanner.cached(&file, Agent::Codex).unwrap().0.is_none());
        }
        let cache = scanner.cache.lock().unwrap();
        assert_eq!(cache.entries.len(), CACHE_ENTRIES);
        assert!(cache.bytes <= CACHE_BYTES);
    }

    #[cfg(unix)]
    #[test]
    fn symlink_transcripts_are_not_followed() {
        let fixture = Fixture::new();
        let file = fixture.write("outside.jsonl", &codex("secret"));
        fs::create_dir(fixture.0.join("sessions")).unwrap();
        std::os::unix::fs::symlink(file, fixture.0.join("sessions/rollout-link.jsonl")).unwrap();
        let (rows, summary) = run(
            &Scanner::default(),
            &fixture.0.join("sessions"),
            Agent::Codex,
        );
        assert!(rows.is_empty());
        assert_eq!(summary["files"], 0);
    }
}

#[cfg(test)]
mod cancellation_tests {
    use super::*;
    use lispm_kernel::{Config, Error, JobOptions, Kernel, Outcome, WorkClass};
    use std::time::{Duration, Instant};
    #[test]
    fn cancelled_scan_unblocks_when_incremental_queue_is_full() {
        let root = std::env::temp_dir().join(format!("lispm-scan-cancel-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        for n in 0..8 {
            fs::write(
                root.join(format!("rollout-{n}.jsonl")),
                format!(
                    "{}\n{}\n",
                    json!({"type":"session_meta","payload":{"id":n.to_string(),"cwd":"/p"}}),
                    json!({"type":"event_msg","payload":{"type":"user_message","message":"hello"}})
                ),
            )
            .unwrap();
        }
        let kernel = Kernel::new(Config {
            max_stream_items: 1,
            ..Config::default()
        })
        .unwrap();
        let id = loop {
            let path = root.clone();
            match kernel.submit_with_options(
                1,
                0,
                vec![],
                1024,
                JobOptions {
                    class: WorkClass::Io,
                    ..JobOptions::default()
                },
                move |ctx, _| Scanner::default().scan(&ctx, &path, Agent::Codex),
            ) {
                Ok(id) => break id,
                Err(Error::Busy) => std::thread::yield_now(),
                e => panic!("{e:?}"),
            }
        };
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            assert!(Instant::now() < deadline);
            if kernel.stats().is_ok_and(|s| s.stream_items == 1) {
                break;
            }
            std::thread::yield_now();
        }
        loop {
            match kernel.cancel(id) {
                Ok(true) => break,
                Err(Error::Busy) => std::thread::yield_now(),
                e => panic!("{e:?}"),
            }
        }
        loop {
            assert!(Instant::now() < deadline);
            if kernel.stats().is_ok_and(|s| s.completed == 1) {
                break;
            }
            std::thread::yield_now();
        }
        let events = loop {
            match kernel.drain(8, 65536) {
                Ok(events) => break events,
                Err(Error::Busy) => std::thread::yield_now(),
                e => panic!("{e:?}"),
            }
        };
        assert_eq!(events.last().unwrap().outcome, Outcome::Cancelled);
        assert_eq!(events.len(), 2);
        fs::remove_dir_all(root).unwrap();
    }
}
