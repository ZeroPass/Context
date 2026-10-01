use super::{
    PROVIDER_CODEX, infer_codex_db_path, is_codex_subagent_thread_source, is_locked_sqlite_error,
    normalize_epoch_millis, remove_snapshot_database, resolve_codex_rollout_path,
    snapshot_sqlite_database, sqlite_table_has_column,
};
use crate::signals::{OpenWhiteboardFile, ReadWhiteboard, WhiteboardResult};
use anyhow::{Context as AnyhowContext, Result, anyhow};
use rinf::{DartSignal, RustSignal};
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};
use tokio::task::spawn_blocking;

const MAX_TAIL_BYTES: u64 = 32 * 1024 * 1024;
const MAX_RECORD_BYTES: u64 = 4 * 1024 * 1024;

struct ResponseCache {
    path: PathBuf,
    size: u64,
    modified: SystemTime,
    limit: usize,
    responses: Vec<Response>,
    bounded: bool,
}
// Keep only the selected log's result, not a growing transcript cache.
static RESPONSE_CACHE: Mutex<Option<ResponseCache>> = Mutex::new(None);

pub(super) async fn listen() {
    let receiver = ReadWhiteboard::get_dart_signal_receiver();
    // Serialize Whiteboard reads independently of the main account/config actor.
    while let Some(pack) = receiver.recv().await {
        let request = pack.message;
        let id = request.request_id;
        let result = spawn_blocking(move || read_request(request)).await;
        let (payload_json, error) = match result {
            Ok(Ok(payload)) => (payload.to_string(), None),
            Ok(Err(error)) => ("{}".to_owned(), Some(error.to_string())),
            Err(error) => (
                "{}".to_owned(),
                Some(format!("Response read failed: {error}")),
            ),
        };
        WhiteboardResult {
            request_id: id,
            payload_json,
            error,
        }
        .send_signal_to_dart();
    }
}

pub(super) async fn listen_files() {
    let receiver = OpenWhiteboardFile::get_dart_signal_receiver();
    while let Some(pack) = receiver.recv().await {
        let request = pack.message;
        tokio::spawn(async move {
            let id = request.request_id;
            let result = spawn_blocking(move || open_file(&request.path, request.reveal)).await;
            let error = match result {
                Ok(Ok(())) => None,
                Ok(Err(error)) => Some(error.to_string()),
                Err(error) => Some(format!("File open failed: {error}")),
            };
            WhiteboardResult {
                request_id: id,
                payload_json: "{}".into(),
                error,
            }
            .send_signal_to_dart();
        });
    }
}

#[cfg(target_os = "windows")]
fn open_file(path: &str, reveal: bool) -> Result<()> {
    use std::ffi::c_void;
    #[link(name = "shell32")]
    unsafe extern "system" {
        fn ShellExecuteW(
            window: *mut c_void,
            operation: *const u16,
            file: *const u16,
            parameters: *const u16,
            directory: *const u16,
            show: i32,
        ) -> isize;
    }
    if path.contains('\0') || path.contains('"') || path.len() > 32768 {
        return Err(anyhow!("Invalid file location."));
    }
    let web = path.starts_with("https://") || path.starts_with("http://");
    if !web && !Path::new(path).exists() {
        return Err(anyhow!("File no longer exists."));
    }
    if web && reveal {
        return Err(anyhow!("A web link has no local file location."));
    }
    let (file, params) = if reveal {
        (
            "explorer.exe",
            if Path::new(path).is_dir() {
                format!("\"{path}\"")
            } else {
                format!("/select,\"{path}\"")
            },
        )
    } else {
        (path, String::new())
    };
    let wide = |text: &str| {
        text.encode_utf16()
            .chain(std::iter::once(0))
            .collect::<Vec<_>>()
    };
    let file = wide(file);
    let params = wide(&params);
    let operation = wide("open");
    // All strings are NUL-terminated and alive for this call. No command shell
    // is involved: Windows chooses the registered file association directly.
    let result = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            operation.as_ptr(),
            file.as_ptr(),
            params.as_ptr(),
            std::ptr::null(),
            1,
        )
    };
    if result <= 32 {
        return Err(anyhow!(
            "Windows could not open this file (error {result})."
        ));
    }
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn open_file(path: &str, reveal: bool) -> Result<()> {
    let target = if reveal {
        Path::new(path).parent().unwrap_or(Path::new(path))
    } else {
        Path::new(path)
    };
    let result = std::process::Command::new(if cfg!(target_os = "macos") {
        "open"
    } else {
        "xdg-open"
    })
    .arg(target)
    .status()?;
    if !result.success() {
        return Err(anyhow!("Could not open this location."));
    }
    Ok(())
}

fn read_request(request: ReadWhiteboard) -> Result<serde_json::Value> {
    if request.provider != PROVIDER_CODEX {
        return Err(anyhow!(
            "This provider's Whiteboard reader is not available yet."
        ));
    }
    let db = infer_codex_db_path(&request.sessions_markdown_path)
        .ok_or_else(|| anyhow!("Choose your sessions markdown file first."))?;
    if !db.is_file() {
        return Err(anyhow!("Codex session database not found."));
    }
    match read_database(&db, db.parent(), &request) {
        Err(error)
            if error
                .downcast_ref::<rusqlite::Error>()
                .is_some_and(is_locked_sqlite_error) =>
        {
            let snapshot = snapshot_sqlite_database(&db)?;
            let result = read_database(&snapshot, db.parent(), &request);
            let _ = remove_snapshot_database(&snapshot);
            result
        }
        result => result,
    }
}

fn read_database(
    db: &Path,
    home: Option<&Path>,
    request: &ReadWhiteboard,
) -> Result<serde_json::Value> {
    let connection = Connection::open_with_flags(
        db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    connection.busy_timeout(Duration::from_millis(250))?;
    if request.session_id.is_empty() {
        return read_sessions(&connection, home, request.limit.clamp(3, 10) as usize);
    }
    let has_cwd = sqlite_table_has_column(&connection, "threads", "cwd")?;
    let cwd = if has_cwd { "cwd" } else { "NULL" };
    let (raw, work_dir): (String, Option<String>) = connection.query_row(
        &format!("SELECT rollout_path, {cwd} FROM threads WHERE id = ?1"),
        [&request.session_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let path = resolve_codex_rollout_path(home, &raw);
    let limit = request.limit.clamp(1, 3) as usize;
    let metadata = fs::metadata(&path).context("Codex response log is unavailable.")?;
    let modified = metadata.modified()?;
    if let Ok(cache) = RESPONSE_CACHE.lock() {
        if let Some(cached) = cache.as_ref().filter(|cached| {
            cached.path == path
                && cached.size == metadata.len()
                && cached.modified == modified
                && cached.limit >= limit
        }) {
            return Ok(
                serde_json::json!({"responses": cached.responses.iter().take(limit).collect::<Vec<_>>(),
                "work_dir": work_dir, "bounded_history": cached.bounded}),
            );
        }
    }
    let (responses, bounded) = read_responses(&path, limit)?;
    if responses.iter().map(|r| r.text.len()).sum::<usize>() <= 8 * 1024 * 1024 {
        if let Ok(mut cache) = RESPONSE_CACHE.lock() {
            *cache = Some(ResponseCache {
                path,
                size: metadata.len(),
                modified,
                limit,
                responses: responses.clone(),
                bounded,
            });
        }
    }
    Ok(
        serde_json::json!({"responses": responses, "work_dir": work_dir,
        "bounded_history": bounded}),
    )
}

fn read_sessions(
    connection: &Connection,
    home: Option<&Path>,
    limit: usize,
) -> Result<serde_json::Value> {
    let has_source = sqlite_table_has_column(connection, "threads", "thread_source")?;
    let has_cwd = sqlite_table_has_column(connection, "threads", "cwd")?;
    let source = if has_source { "thread_source" } else { "NULL" };
    let cwd = if has_cwd { "cwd" } else { "NULL" };
    // A bounded metadata query; never traverse the entire sessions tree.
    let mut statement = connection.prepare(&format!(
        "SELECT id, title, updated_at, rollout_path, {source}, {cwd} FROM threads
         WHERE archived = 0 ORDER BY updated_at DESC LIMIT 200"
    ))?;
    let mut rows = statement.query([])?;
    let mut sessions = Vec::new();
    while let Some(row) = rows.next()? {
        let source: Option<String> = row.get(4)?;
        let raw: String = row.get(3)?;
        let rollout = resolve_codex_rollout_path(home, &raw);
        if source.as_deref().is_some_and(is_subagent_source) || rollout_is_subagent(&rollout) {
            continue;
        }
        sessions.push(serde_json::json!({
            "provider": "codex", "id": row.get::<_, String>(0)?,
            "title": row.get::<_, String>(1)?,
            "updated_at": normalize_epoch_millis(row.get(2)?),
            "work_dir": row.get::<_, Option<String>>(5)?,
        }));
        if sessions.len() == limit {
            break;
        }
    }
    Ok(serde_json::json!({"sessions": sessions}))
}

fn is_subagent_source(value: &str) -> bool {
    is_codex_subagent_thread_source(value)
        || serde_json::from_str::<serde_json::Value>(value)
            .ok()
            .is_some_and(|source| source.get("subagent").is_some())
}

fn rollout_is_subagent(path: &Path) -> bool {
    let Ok(file) = fs::File::open(path) else {
        return false;
    };
    let mut record = Vec::new();
    if BufReader::new(file.take(64 * 1024))
        .read_until(b'\n', &mut record)
        .is_err()
    {
        return false;
    }
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&record) else {
        return false;
    };
    let source = &value["payload"]["source"];
    source.get("subagent").is_some()
        || source.as_str().is_some_and(is_subagent_source)
        || value["payload"]["thread_source"]
            .as_str()
            .is_some_and(is_subagent_source)
}

#[derive(Clone, Debug, Serialize, PartialEq)]
struct Response {
    text: String,
    timestamp: String,
    turn_id: String,
}

fn read_responses(path: &Path, limit: usize) -> Result<(Vec<Response>, bool)> {
    let mut file = fs::File::open(path).context("Codex response log is unavailable.")?;
    let size = file.metadata()?.len();
    let start = size.saturating_sub(MAX_TAIL_BYTES);
    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::new(file.take(size - start));
    if start > 0 {
        // Discard the partial first record without allocating its contents.
        reader.skip_until(b'\n')?;
    }
    let mut responses = VecDeque::new();
    let mut pending: Option<Response> = None;
    let mut turn_id = String::new();
    loop {
        let mut line = Vec::new();
        let read = reader
            .by_ref()
            .take(MAX_RECORD_BYTES + 1)
            .read_until(b'\n', &mut line)?;
        if read == 0 {
            break;
        }
        if read as u64 > MAX_RECORD_BYTES {
            return Err(anyhow!(
                "A Codex log record exceeds the safe response-read limit."
            ));
        }
        // An incomplete trailing record is expected while Codex is writing.
        if line.last() != Some(&b'\n') {
            break;
        }
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(&line) else {
            continue;
        };
        let payload = &value["payload"];
        let kind = payload["type"].as_str().unwrap_or("");
        let timestamp = value["timestamp"].as_str().unwrap_or("").to_owned();
        match (value["type"].as_str().unwrap_or(""), kind) {
            ("event_msg", "task_started") => {
                pending = None;
                turn_id = payload["turn_id"].as_str().unwrap_or("").to_owned();
            }
            ("response_item", "message")
                if payload["role"] == "assistant" && payload["phase"] == "final_answer" =>
            {
                let text = payload["content"]
                    .as_array()
                    .map(|parts| {
                        parts
                            .iter()
                            .filter(|part| part["type"] == "output_text" || part["type"] == "text")
                            .filter_map(|part| part["text"].as_str())
                            .collect::<Vec<_>>()
                            .join("\n")
                    })
                    .unwrap_or_default();
                pending = Some(Response {
                    text,
                    timestamp,
                    turn_id: turn_id.clone(),
                });
            }
            ("event_msg", "task_complete") => {
                let completed_id = payload["turn_id"].as_str().unwrap_or("");
                let explicit = payload["last_agent_message"]
                    .as_str()
                    .filter(|s| !s.trim().is_empty());
                let candidate = explicit
                    .map(|text| Response {
                        text: text.to_owned(),
                        timestamp: timestamp.clone(),
                        turn_id: completed_id.to_owned(),
                    })
                    .or_else(|| {
                        pending
                            .take()
                            .filter(|p| p.turn_id.is_empty() || p.turn_id == completed_id)
                    });
                if let Some(response) = candidate.filter(|r| !r.text.trim().is_empty()) {
                    if !responses.iter().any(|r: &Response| {
                        !response.turn_id.is_empty() && r.turn_id == response.turn_id
                    }) {
                        responses.push_back(response);
                        if responses.len() > limit {
                            responses.pop_front();
                        }
                    }
                }
                pending = None;
            }
            ("event_msg", "turn_aborted") => pending = None,
            _ => {}
        }
    }
    Ok((responses.into_iter().rev().collect(), start > 0))
}

#[cfg(test)]
mod tests {
    use super::{read_responses, read_sessions};
    use rusqlite::Connection;
    use serde_json::json;

    #[test]
    fn whiteboard_wire_layout_matches_dart() -> anyhow::Result<()> {
        let hex = "01000000000000000100000000000000700500000000000000636f64657801000000000000007303000000";
        let bytes = (0..hex.len())
            .step_by(2)
            .map(|offset| u8::from_str_radix(&hex[offset..offset + 2], 16))
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let request: crate::signals::ReadWhiteboard = bincode::deserialize(&bytes)?;
        assert_eq!(request.request_id, 1);
        assert_eq!(request.provider, "codex");
        assert_eq!(request.sessions_markdown_path, "p");
        assert_eq!(request.session_id, "s");
        assert_eq!(request.limit, 3);
        let result = crate::signals::WhiteboardResult {
            request_id: 1,
            payload_json: "{}".into(),
            error: None,
        };
        assert_eq!(
            bincode::serialize(&result)?,
            [1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 123, 125, 0]
        );
        assert!(super::is_subagent_source(
            r#"{"subagent":{"thread_spawn":{}}}"#
        ));
        Ok(())
    }

    #[test]
    fn completed_answers_only_newest_first_without_duplicates() -> anyhow::Result<()> {
        let path =
            std::env::temp_dir().join(format!("context-whiteboard-{}.jsonl", std::process::id()));
        let records = vec![
            json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}),
            json!({"type":"response_item","payload":{"type":"reasoning","text":"secret"}}),
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"working"}]}}),
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"answer one"}]}}),
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"a","last_agent_message":"answer one"}}),
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"a","last_agent_message":"answer one"}}),
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"b","last_agent_message":"answer two"}}),
            json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"c"}}),
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"unfinished"}]}}),
        ];
        let text = records.iter().map(|v| format!("{v}\n")).collect::<String>() + "{incomplete";
        std::fs::write(&path, text)?;
        let (responses, bounded) = read_responses(&path, 3)?;
        std::fs::remove_file(path)?;
        assert!(!bounded);
        assert_eq!(
            responses
                .iter()
                .map(|r| r.text.as_str())
                .collect::<Vec<_>>(),
            ["answer two", "answer one"]
        );
        Ok(())
    }

    #[test]
    fn metadata_limit_filters_subagents() -> anyhow::Result<()> {
        let connection = Connection::open_in_memory()?;
        connection.execute_batch("CREATE TABLE threads (id TEXT, title TEXT, updated_at INTEGER, rollout_path TEXT, thread_source TEXT, cwd TEXT, archived INTEGER);")?;
        for n in 0..15 {
            connection.execute(
                "INSERT INTO threads VALUES (?1, 'Title', ?2, '/missing', ?3, '/work', 0)",
                rusqlite::params![format!("s{n}"), n, if n == 14 { "subagent" } else { "cli" }],
            )?;
        }
        let data = read_sessions(&connection, None, 10)?;
        assert_eq!(data["sessions"].as_array().map(Vec::len), Some(10));
        assert_eq!(data["sessions"][0]["id"], "s13");
        Ok(())
    }

    #[test]
    fn cached_response_changes_when_log_grows_and_history_expands() -> anyhow::Result<()> {
        use std::io::Write;
        let root =
            std::env::temp_dir().join(format!("context-whiteboard-cache-{}", std::process::id()));
        std::fs::create_dir_all(&root)?;
        let db = root.join("state.sqlite");
        let rollout = root.join("answers.jsonl");
        let connection = Connection::open(&db)?;
        connection.execute_batch("CREATE TABLE threads (id TEXT, rollout_path TEXT);")?;
        connection.execute(
            "INSERT INTO threads VALUES ('session', ?1)",
            [rollout.to_string_lossy()],
        )?;
        drop(connection);
        std::fs::write(
            &rollout,
            format!(
                "{}\n",
                json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"a","last_agent_message":"one"}})
            ),
        )?;
        let mut request = crate::signals::ReadWhiteboard {
            request_id: 1,
            provider: "codex".into(),
            sessions_markdown_path: String::new(),
            session_id: "session".into(),
            limit: 1,
        };
        assert_eq!(
            super::read_database(&db, Some(&root), &request)?["responses"][0]["text"],
            "one"
        );
        let mut file = std::fs::OpenOptions::new().append(true).open(&rollout)?;
        writeln!(
            file,
            "{}",
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"b","last_agent_message":"two"}})
        )?;
        drop(file);
        assert_eq!(
            super::read_database(&db, Some(&root), &request)?["responses"][0]["text"],
            "two"
        );
        request.limit = 3;
        let data = super::read_database(&db, Some(&root), &request)?;
        assert_eq!(data["responses"].as_array().map(Vec::len), Some(2));
        std::fs::remove_dir_all(root)?;
        Ok(())
    }
}
