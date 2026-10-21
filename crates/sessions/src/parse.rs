// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Pure transcript parsing, as the desktop's Elisp parses head/tail objects.
//!
//! Every function maps values to values; none reads a file. The Elisp
//! reference is `lispm-desktop-agent-codex--session`,
//! `lispm-desktop-agent-claude--session` and the helpers of
//! `lispm-desktop-ai.el` they call.

use crate::MAX_FIELDS;
use serde_json::Value;
use std::borrow::Cow;
use std::ffi::OsStr;
use std::fmt;
use std::path::Path;

/// The agent whose transcripts a scan reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Agent {
    /// Codex: `rollout-*.jsonl` transcripts anywhere below the root, named by
    /// the `session_index.jsonl` beside the root.
    Codex,
    /// Claude Code: `PROJECT/*.jsonl` transcripts, titled by the
    /// `PROJECT/SESSION/custom-title.json` beside each.
    Claude,
}

impl Agent {
    /// The agent's name in rows, as the bridge's `submit-scan` accepts it.
    pub fn name(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
        }
    }
}

/// One session as its transcript records it, before external names apply.
///
/// Invariant: every string field holds at most 4096 UTF-8 bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Session {
    /// The agent that wrote the transcript.
    pub agent: Agent,
    /// Codex's metadata id, or the base name of the Claude transcript file.
    pub id: String,
    /// The directory the session ran in.
    pub cwd: String,
    /// The transcript's own title: Codex's first prompt; Claude's last custom
    /// title or summary, else its first prompt.
    pub title: Option<String>,
    /// Codex's start timestamp, as recorded (ISO 8601).
    pub started: Option<String>,
}

impl Session {
    /// Bytes held by the session's strings, for cache accounting.
    pub(crate) fn cost(&self) -> usize {
        self.id.len()
            + self.cwd.len()
            + self.title.as_ref().map_or(0, String::len)
            + self.started.as_ref().map_or(0, String::len)
    }
}

/// A transcript names its session with a value no row can carry: a non-string,
/// or a string beyond 4096 bytes, where the Elisp would list the session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Unrepresentable {
    /// The JSON field holding the value.
    pub field: &'static str,
}

impl fmt::Display for Unrepresentable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "transcript field {} exceeds the row bounds", self.field)
    }
}

impl std::error::Error for Unrepresentable {}

/// Parses the head and tail objects of the transcript at `path` as the
/// desktop's Elisp does: `Ok(None)` wherever the Elisp returns nil.
///
/// Titles are cut to 4096 UTF-8 bytes; external names (the Codex index, Claude
/// custom-title files) are applied by the scanner, not here.
///
/// # Errors
///
/// [`Unrepresentable`] when the Elisp would return a session whose id or cwd no
/// row can carry.
pub fn parse(
    agent: Agent,
    path: &Path,
    head: &[Value],
    tail: &[Value],
) -> Result<Option<Session>, Unrepresentable> {
    match agent {
        Agent::Codex => codex(head),
        Agent::Claude => claude(path, head, tail),
    }
}

/// `lispm-desktop-agent-codex--session`: the first `session_meta` object of the
/// head names the session; its first human prompt titles it.
fn codex(head: &[Value]) -> Result<Option<Session>, Unrepresentable> {
    let meta = head.iter().find(|value| has_type(value, "session_meta"));
    let Some(payload) = meta.and_then(|meta| present(meta, "payload")) else {
        return Ok(None);
    };
    let (Some(id), Some(cwd)) = (present(payload, "id"), present(payload, "cwd")) else {
        return Ok(None);
    };
    Ok(Some(Session {
        agent: Agent::Codex,
        id: identifier(id, "id")?,
        cwd: identifier(cwd, "cwd")?,
        title: head.iter().find_map(codex_prompt),
        started: string(payload, "timestamp"),
    }))
}

/// `lispm-desktop-agent-claude--session`: the last custom title or summary of
/// head and tail, else the head's first human prompt; the first cwd anywhere.
fn claude(path: &Path, head: &[Value], tail: &[Value]) -> Result<Option<Session>, Unrepresentable> {
    let objects = || head.iter().chain(tail);
    let title = objects()
        .rev()
        .find_map(claude_title)
        .or_else(|| head.iter().find_map(claude_prompt));
    let cwd = objects().find_map(|value| present(value, "cwd"));
    let id = path.file_stem().and_then(OsStr::to_str);
    let (Some(title), Some(cwd), Some(id)) = (title, cwd, id) else {
        return Ok(None);
    };
    Ok(Some(Session {
        agent: Agent::Claude,
        id: bounded(id),
        cwd: identifier(cwd, "cwd")?,
        title: Some(title),
        started: None,
    }))
}

fn claude_title(value: &Value) -> Option<String> {
    string(value, "customTitle").or_else(|| {
        has_type(value, "summary")
            .then(|| string(value, "summary"))
            .flatten()
    })
}

/// `lispm-desktop-agent-codex--prompt`.
fn codex_prompt(value: &Value) -> Option<String> {
    let payload = value.get("payload")?;
    let text = if has_type(value, "event_msg") && has_type(payload, "user_message") {
        Cow::Borrowed(payload.get("message")?.as_str()?)
    } else if has_type(value, "response_item")
        && has_type(payload, "message")
        && payload.get("role").and_then(Value::as_str) == Some("user")
    {
        content_text(payload.get("content")?)?
    } else {
        return None;
    };
    human_title(&text)
}

/// The prompt of a Claude `user` object that is not `isMeta`.
fn claude_prompt(value: &Value) -> Option<String> {
    if !has_type(value, "user") || present(value, "isMeta").is_some() {
        return None;
    }
    human_title(&content_text(value.get("message")?.get("content")?)?)
}

/// `lispm-desktop-agent-content-text`: a string, or the joined `text` of parts.
fn content_text(content: &Value) -> Option<Cow<'_, str>> {
    match content {
        Value::String(text) => Some(Cow::Borrowed(text)),
        Value::Array(parts) => Some(Cow::Owned(
            parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect(),
        )),
        _ => None,
    }
}

/// The bounded title of `text` when the whole text reads as a human prompt.
fn human_title(text: &str) -> Option<String> {
    human(text).then(|| bounded(text))
}

/// Elisp's blank characters: `string-trim-left` and `string-blank-p` treat
/// exactly `[ \t\n\r]` as blank, unlike Unicode whitespace.
fn elisp_blank(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\r')
}

/// Whether `text` reads as a prompt a person typed, as
/// `lispm-desktop-agent-human-text-p` decides: not blank, and not an injected
/// tagged block or `# AGENTS.md` guidance.
pub(crate) fn human(text: &str) -> bool {
    let text = text.trim_start_matches(elisp_blank);
    !text.is_empty() && !text.starts_with('<') && !text.starts_with("# AGENTS.md")
}

/// Whether `text` is blank as `string-blank-p` decides.
pub(crate) fn blank(text: &str) -> bool {
    text.chars().all(elisp_blank)
}

/// `value` cut to at most 4096 UTF-8 bytes, at a character boundary.
pub(crate) fn bounded(value: &str) -> String {
    let end = value.floor_char_boundary(MAX_FIELDS);
    value.get(..end).unwrap_or_default().to_owned()
}

/// The bounded string at `key`, when `value` holds a string there.
pub(crate) fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key)?.as_str().map(bounded)
}

/// The value at `key` when Elisp reads it as non-nil: present, neither null
/// nor false (the desktop parses JSON with `:null-object nil :false-object nil`).
fn present<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value
        .get(key)
        .filter(|value| !value.is_null() && value.as_bool() != Some(false))
}

/// Whether `value`'s `type` field is the string `kind`.
fn has_type(value: &Value, kind: &str) -> bool {
    value.get("type").and_then(Value::as_str) == Some(kind)
}

/// An identifier a row can carry, or which field cannot be carried.
fn identifier(value: &Value, field: &'static str) -> Result<String, Unrepresentable> {
    match value.as_str() {
        Some(text) if text.len() <= MAX_FIELDS => Ok(text.to_owned()),
        _ => Err(Unrepresentable { field }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn claude_session(head: &[Value], tail: &[Value]) -> Option<Session> {
        parse(Agent::Claude, Path::new("p/session.jsonl"), head, tail).unwrap()
    }

    #[test]
    fn parsers_filter_injected_context_and_keep_last_claude_title() {
        let head = vec![
            json!({"type":"user","cwd":"/p", "message":{"content":"<context>ignored"}}),
            json!({"type":"user", "isMeta":true,"message":{"content":"ignored"}}),
            json!({"type":"user","message":{"content":[{"text":"hello "},{"text":"wörld €"}]}}),
            json!({"type":"summary","summary":"old"}),
        ];
        let tail = vec![json!({"customTitle":"new"})];
        let parsed = claude_session(&head, &tail).unwrap();
        assert_eq!(parsed.title.as_deref(), Some("new"));
        assert_eq!(parsed.id, "session");
        let parsed = claude_session(&head[..3], &[]).unwrap();
        assert_eq!(parsed.title.as_deref(), Some("hello wörld €"));
    }

    #[test]
    fn human_treats_only_elisp_blanks_as_blank() {
        let table = [
            ("hello", true),
            (" \t\r\n hello", true),
            (" \t\r\n <tag>", false),
            ("   # AGENTS.md guidance", false),
            (" \t\r\n", false),
            ("", false),
            // string-trim-left keeps NBSP, EM SPACE and form feed: they are text.
            ("\u{a0}<tag>", true),
            ("\u{2003}", true),
            ("\u{c}# AGENTS.md", true),
        ];
        for (text, expected) in table {
            assert_eq!(human(text), expected, "{text:?}");
        }
    }

    #[test]
    fn blank_matches_string_blank_p() {
        let table = [
            ("", true),
            (" \t\r\n", true),
            ("\u{a0}", false),
            ("\u{c}", false),
            (" x ", false),
        ];
        for (text, expected) in table {
            assert_eq!(blank(text), expected, "{text:?}");
        }
    }

    #[test]
    fn prompts_are_judged_whole_before_bounding() {
        let text = format!("{}hello", " ".repeat(MAX_FIELDS + 10));
        let head = [json!({"type":"user","cwd":"/p","message":{"content":text}})];
        let title = claude_session(&head, &[]).unwrap().title.unwrap();
        assert_eq!(title.len(), MAX_FIELDS);
    }

    #[test]
    fn bounded_cuts_at_a_character_boundary() {
        let cut = bounded(&"€".repeat(2000));
        assert_eq!(cut.len(), MAX_FIELDS - MAX_FIELDS % 3);
        assert!(cut.chars().all(|c| c == '€'));
    }

    #[test]
    fn claude_uses_the_first_cwd_as_elisp_does() {
        let long = "x".repeat(MAX_FIELDS + 1);
        let prompt = json!({"type":"user","message":{"content":"hi"}});
        let first_short = [json!({"cwd":"/p"}), json!({"cwd":long}), prompt.clone()];
        assert_eq!(claude_session(&first_short, &[]).unwrap().cwd, "/p");
        let first_long = [json!({"cwd":long}), json!({"cwd":"/p"}), prompt.clone()];
        assert_eq!(
            parse(Agent::Claude, Path::new("s.jsonl"), &first_long, &[]),
            Err(Unrepresentable { field: "cwd" })
        );
        // Null and false cwd values are nil to Elisp and so not the first cwd.
        let nil_first = [
            json!({"cwd":null}),
            json!({"cwd":false}),
            json!({"cwd":"/q"}),
            prompt,
        ];
        assert_eq!(claude_session(&nil_first, &[]).unwrap().cwd, "/q");
        // Without any title the Elisp returns nil, so a long cwd does not matter.
        assert_eq!(claude_session(&[json!({"cwd":long})], &[]), None);
    }

    #[test]
    fn codex_needs_metadata_and_keeps_untitled_sessions() {
        let meta = json!({"type":"session_meta","payload":{"id":"i","cwd":"/c","timestamp":"t"}});
        let parsed = parse(Agent::Codex, Path::new("r.jsonl"), &[meta], &[]).unwrap();
        assert_eq!(
            parsed,
            Some(Session {
                agent: Agent::Codex,
                id: "i".into(),
                cwd: "/c".into(),
                title: None,
                started: Some("t".into()),
            })
        );
        let no_cwd = json!({"type":"session_meta","payload":{"id":"i"}});
        assert_eq!(
            parse(Agent::Codex, Path::new("r"), &[no_cwd], &[]),
            Ok(None)
        );
        let numeric = json!({"type":"session_meta","payload":{"id":7,"cwd":"/c"}});
        assert_eq!(
            parse(Agent::Codex, Path::new("r"), &[numeric], &[]),
            Err(Unrepresentable { field: "id" })
        );
    }

    #[test]
    fn codex_titles_come_from_user_messages_only() {
        let meta = json!({"type":"session_meta","payload":{"id":"i","cwd":"/c"}});
        let assistant = json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":"no"}});
        let injected = json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"# AGENTS.md"}]}});
        let user = json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"yes"}]}});
        let head = [meta, assistant, injected, user];
        let parsed = parse(Agent::Codex, Path::new("r"), &head, &[])
            .unwrap()
            .unwrap();
        assert_eq!(parsed.title.as_deref(), Some("yes"));
    }
}
