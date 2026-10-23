use super::{RecentContext, muse_home_roots, recent_cache};
use anyhow::Result;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::time::UNIX_EPOCH;

pub(super) fn load(markdown: &str) -> Result<Vec<RecentContext>> {
    let mut files = Vec::new();
    let mut visited = 0;
    for home in muse_home_roots(markdown) {
        let projects = home.join(".claude/projects");
        recent_cache::track(&projects);
        let entries = match fs::read_dir(&projects) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e.into()),
        };
        for project in entries.take(256).flatten() {
            if !project.file_type()?.is_dir() {
                continue;
            }
            recent_cache::track(&project.path());
            for file in fs::read_dir(project.path())?.flatten() {
                visited += 1;
                if visited > 8192 {
                    anyhow::bail!("Claude session inventory exceeds 8192 entries.");
                }
                let path = file.path();
                let id = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                if !valid_id(id)
                    || path.extension().is_none_or(|s| s != "jsonl")
                    || !file.file_type()?.is_file()
                {
                    continue;
                }
                let modified = file
                    .metadata()?
                    .modified()?
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as i64;
                files.push((path, modified));
            }
        }
    }
    files.sort_by_key(|(_, time)| std::cmp::Reverse(*time));
    let mut result = Vec::new();
    for (path, modified) in files.into_iter().take(96) {
        recent_cache::track(&path);
        if let Some(session) = read_session(&path, modified)? {
            if !result.iter().any(|s: &RecentContext| s.id == session.id) {
                result.push(session);
            }
        }
        if result.len() == 10 {
            break;
        }
    }
    Ok(result)
}

fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, ch)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                ch == b'-'
            } else {
                ch.is_ascii_hexdigit()
            }
        })
}

fn read_session(path: &Path, modified: i64) -> Result<Option<RecentContext>> {
    let mut file = File::open(path)?;
    let size = file.metadata()?.len();
    let mut head = Vec::new();
    (&mut file).take(64 * 1024).read_to_end(&mut head)?;
    let mut tail = Vec::new();
    if size > head.len() as u64 {
        file.seek(SeekFrom::Start(size.saturating_sub(128 * 1024)))?;
        file.take(128 * 1024).read_to_end(&mut tail)?;
    }
    Ok(parse_records(
        path.file_stem().and_then(|s| s.to_str()).unwrap_or(""),
        head.split(|b| *b == b'\n')
            .chain(tail.split(|b| *b == b'\n')),
        modified,
    ))
}

fn parse_records<'a>(
    id: &str,
    lines: impl Iterator<Item = &'a [u8]>,
    modified: i64,
) -> Option<RecentContext> {
    let mut title = None;
    let mut first_prompt = None;
    let mut cwd = None;
    let mut seen_session = false;
    for line in lines {
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(line) else {
            continue;
        };
        if value.get("isSidechain").and_then(|v| v.as_bool()) == Some(true) {
            return None;
        }
        if value
            .get("sessionId")
            .and_then(|v| v.as_str())
            .is_some_and(|v| v != id)
        {
            continue;
        }
        seen_session |= value.get("sessionId").and_then(|v| v.as_str()) == Some(id);
        if let Some(dir) = value.get("cwd").and_then(|v| v.as_str()) {
            cwd = Some(dir.to_owned());
        }
        if let Some(name) = value.get("customTitle").and_then(|v| v.as_str()) {
            title = Some(name.to_owned());
        } else if title.is_none() {
            if let Some(name) = value.get("summary").and_then(|v| v.as_str()) {
                title = Some(name.to_owned());
            }
        }
        if first_prompt.is_none() && value.get("type").and_then(|v| v.as_str()) == Some("user") {
            if let Some(text) = value.pointer("/message/content").and_then(|v| v.as_str()) {
                first_prompt = Some(
                    text.split_whitespace()
                        .collect::<Vec<_>>()
                        .join(" ")
                        .chars()
                        .take(160)
                        .collect::<String>(),
                );
            }
        }
    }
    if !seen_session {
        return None;
    }
    Some(RecentContext {
        provider: "claude".into(),
        id: id.into(),
        title: title
            .or(first_prompt)
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "Claude Code session".into()),
        updated_at: modified,
        forked_from_id: None,
        work_dir: cwd,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn claude_command_markdown_roundtrip() {
        let id = "11111111-2222-3333-4444-555555555555";
        let text = format!("# My Claude session\nclaude --resume {id}\n");
        let (items, warnings) = super::super::parse_markdown_items(&text);
        assert!(warnings.is_empty());
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].provider, "claude");
        assert_eq!(super::super::render_markdown_items(&items), text);
    }

    #[test]
    fn claude_bounded_file_read_handles_rename_and_sidechain() {
        let root = std::env::temp_dir().join(format!("context-claude-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let id = "11111111-2222-3333-4444-555555555555";
        let file = root.join(format!("{id}.jsonl"));
        let first = format!(
            "{{\"sessionId\":\"{id}\",\"type\":\"user\",\"cwd\":\"/work\",\"message\":{{\"content\":\"First\"}}}}\n"
        );
        fs::write(
            &file,
            format!(
                "{first}{}\n{{\"sessionId\":\"{id}\",\"customTitle\":\"Final name\"}}\n",
                " ".repeat(200_000)
            ),
        )
        .unwrap();
        assert_eq!(
            read_session(&file, 42).unwrap().unwrap().title,
            "Final name"
        );
        fs::write(
            &file,
            format!("{{\"sessionId\":\"{id}\",\"isSidechain\":true}}\n"),
        )
        .unwrap();
        assert!(read_session(&file, 42).unwrap().is_none());
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn claude_metadata_names_and_sidechains() {
        let rows = br#"{"sessionId":"id","type":"user","cwd":"/work","message":{"content":"First question"}}
{"sessionId":"id","type":"custom-title","customTitle":"Renamed"}
{"sessionId":"other","customTitle":"Wrong"}
"#;
        let item = parse_records("id", rows.split(|b| *b == b'\n'), 123).unwrap();
        assert_eq!(item.title, "Renamed");
        assert_eq!(item.work_dir.as_deref(), Some("/work"));
        assert_eq!(item.provider, "claude");
        assert!(
            parse_records(
                "id",
                [br#"{"sessionId":"id","isSidechain":true}"#.as_slice()].into_iter(),
                0
            )
            .is_none()
        );
        assert!(parse_records("id", [b"broken".as_slice()].into_iter(), 0).is_none());
        assert!(valid_id("11111111-2222-3333-4444-555555555555"));
        assert!(!valid_id("agent-11111111-2222-3333-4444-555555555555"));
    }
}
