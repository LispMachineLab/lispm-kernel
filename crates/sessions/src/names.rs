// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! External naming effects: the Codex session index and Claude custom titles.
//!
//! Both change independently of transcripts, so they are read on every scan
//! and never cached with a transcript's parse. As in the Elisp, a side file
//! that cannot be read only means no names: it never fails a scan.

use crate::parse::{blank, bounded, string, Agent, Session};
use crate::source::{open_regular, small_file};
use crate::MAX_FIELDS;
use serde_json::Value;
use std::borrow::Cow;
use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// The tail of `session_index.jsonl` that is read: its last 4 MiB.
const INDEX_BYTES: u64 = 4 * 1024 * 1024;
/// Largest `custom-title.json` that is read.
const TITLE_BYTES: u64 = 64 * 1024;

/// Titles chosen outside the transcripts, which override theirs.
pub(crate) enum Names {
    /// Thread names by Codex session id; the index's last entry for an id wins.
    Codex(HashMap<String, String>),
    /// Claude titles are per-session files, read for each session.
    Claude,
}

impl Names {
    /// Loads the names of `agent`'s sessions under `root`: for Codex, the
    /// `session_index.jsonl` beside `root` (`~/.codex/` for `~/.codex/sessions`).
    pub(crate) fn load(agent: Agent, root: &Path) -> Self {
        match agent {
            Agent::Codex => Self::Codex(
                root.parent()
                    .map(|home| codex_index(&home.join("session_index.jsonl")))
                    .unwrap_or_default(),
            ),
            Agent::Claude => Self::Claude,
        }
    }

    /// The title chosen for `session`, recorded in `transcript`, if any.
    pub(crate) fn title(&self, session: &Session, transcript: &Path) -> Option<Cow<'_, str>> {
        match self {
            Self::Codex(names) => names
                .get(&session.id)
                .map(|name| Cow::Borrowed(name.as_str())),
            Self::Claude => custom_title(&title_file(transcript)).map(Cow::Owned),
        }
    }
}

/// `lispm-desktop-agent-codex--thread-names`, following a symlinked index and
/// reading at most its last 4 MiB.
fn codex_index(path: &Path) -> HashMap<String, String> {
    let Ok(mut file) = open_regular(path) else {
        return HashMap::new();
    };
    index_window(&mut file)
        .map(|bytes| names(&bytes))
        .unwrap_or_default()
}

/// The thread names of index lines; later lines override earlier ones.
fn names(bytes: &[u8]) -> HashMap<String, String> {
    bytes
        .split(|byte| *byte == b'\n')
        .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
        .filter_map(|entry| {
            let id = entry
                .get("id")?
                .as_str()
                .filter(|id| id.len() <= MAX_FIELDS)?;
            Some((id.to_owned(), string(&entry, "thread_name")?))
        })
        .collect()
}

/// The complete lines among the index's last `INDEX_BYTES` bytes: the whole
/// file when it is that small, else the window without its leading partial line.
fn index_window(file: &mut File) -> io::Result<Vec<u8>> {
    let size = file.metadata()?.len();
    let mut bytes = Vec::new();
    let Some(before) = size.checked_sub(INDEX_BYTES + 1) else {
        file.take(INDEX_BYTES).read_to_end(&mut bytes)?;
        return Ok(bytes);
    };
    // Read from the byte before the window: through the first newline is
    // either that newline alone or the window's partial first line.
    file.seek(SeekFrom::Start(before))?;
    file.take(INDEX_BYTES + 1).read_to_end(&mut bytes)?;
    Ok(match bytes.iter().position(|byte| *byte == b'\n') {
        Some(end) => bytes.split_off(end + 1),
        None => Vec::new(),
    })
}

/// `lispm-desktop-agent-claude--custom-title`: the non-blank `customTitle`
/// string of the file's first JSON value (`json-parse-buffer` ignores what
/// follows it). Nothing when the file is missing, unreadable, not a regular
/// file or larger than 64 KiB.
fn custom_title(path: &Path) -> Option<String> {
    let bytes = small_file(path, TITLE_BYTES)?;
    let value = serde_json::Deserializer::from_slice(&bytes)
        .into_iter::<Value>()
        .next()?
        .ok()?;
    let title = value.get("customTitle")?.as_str()?;
    (!blank(title)).then(|| bounded(title))
}

/// `lispm-desktop-agent-claude--title-file`: `SESSION/custom-title.json`
/// beside the transcript `SESSION.jsonl`.
fn title_file(transcript: &Path) -> PathBuf {
    transcript.with_extension("").join("custom-title.json")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("lispm-names-{}-{name}", std::process::id()))
    }

    fn line(id: &str, name: &str) -> String {
        format!("{}\n", serde_json::json!({"id": id, "thread_name": name}))
    }

    #[test]
    fn index_beyond_the_bound_reads_its_tail_and_last_entries_win() {
        // The window starts at the `{` of a line that is not JSON as a whole:
        // Elisp ignores the line, so its JSON suffix must not name anything.
        let partial = "garbage {\"id\":\"partial\",\"thread_name\":\"wrong\"}\n";
        let start = partial.find('{').unwrap();
        let window = usize::try_from(INDEX_BYTES).unwrap() - (partial.len() - start);
        let mut suffix = line("a", "first") + &line("a", "last");
        let end = line("b", "unterminated").trim_end().to_owned();
        let pad = window - suffix.len() - end.len();
        suffix.push_str(&" ".repeat(pad - 1));
        suffix.push('\n');
        suffix.push_str(&end);
        let text = line("cut", "never read") + partial + &suffix;
        let path = temp("index-large");
        fs::write(&path, &text).unwrap();
        let names = codex_index(&path);
        fs::remove_file(&path).unwrap();
        assert_eq!(names.get("a").map(String::as_str), Some("last"));
        assert_eq!(names.get("b").map(String::as_str), Some("unterminated"));
        assert!(!names.contains_key("partial"));
        assert!(!names.contains_key("cut"));
    }

    #[test]
    fn index_window_keeps_a_first_line_that_starts_at_the_window() {
        let path = temp("index-boundary");
        let first = line("first", "kept");
        let pad = usize::try_from(INDEX_BYTES).unwrap() - first.len();
        let text = format!("{}\n{first}{}", "x".repeat(10), " ".repeat(pad));
        fs::write(&path, &text).unwrap();
        let names = codex_index(&path);
        fs::remove_file(&path).unwrap();
        assert_eq!(names.get("first").map(String::as_str), Some("kept"));
    }

    #[test]
    fn custom_titles_ignore_blank_large_and_special_files() {
        let dir = temp("titles");
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("custom-title.json");
        let table = [
            ("{\"customTitle\":\"named\"} trailing text", Some("named")),
            ("{\"customTitle\":\" \\t\\r\\n\"}", None),
            ("{\"customTitle\":\"\\u00a0\"}", Some("\u{a0}")),
            ("{\"customTitle\":7}", None),
            ("not JSON", None),
        ];
        for (text, expected) in table {
            fs::write(&file, text).unwrap();
            assert_eq!(custom_title(&file).as_deref(), expected, "{text}");
        }
        let large = format!("{{\"customTitle\":\"{}\"}}", "x".repeat(70 * 1024));
        fs::write(&file, large).unwrap();
        assert_eq!(custom_title(&file), None);
        fs::remove_file(&file).unwrap();
        fs::create_dir(&file).unwrap();
        assert_eq!(custom_title(&file), None);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn title_files_sit_beside_their_transcripts() {
        assert_eq!(
            title_file(Path::new("/p/a.b.jsonl")),
            Path::new("/p/a.b/custom-title.json")
        );
    }
}
