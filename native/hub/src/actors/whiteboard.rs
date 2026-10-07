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
use std::time::{Duration, Instant, SystemTime};
use tokio::task::spawn_blocking;

const MAX_TAIL_BYTES: u64 = 32 * 1024 * 1024;
const INITIAL_TAIL_BYTES: u64 = 256 * 1024;
const MAX_RECORD_BYTES: u64 = 4 * 1024 * 1024;
const MAX_CACHE_BYTES: usize = 8 * 1024 * 1024;

struct DatabaseCache {
    path: PathBuf,
    created: Option<SystemTime>,
    size: u64,
    connection: Connection,
}
static DATABASE_CACHE: Mutex<Option<DatabaseCache>> = Mutex::new(None);

struct HeaderCache {
    path: PathBuf,
    size: u64,
    modified: Option<SystemTime>,
    subagent: bool,
}
static HEADER_CACHE: Mutex<VecDeque<HeaderCache>> = Mutex::new(VecDeque::new());

struct SessionLocation {
    markdown: String,
    session: String,
    path: PathBuf,
    work_dir: Option<String>,
    checked: Instant,
}
static LOCATIONS: Mutex<VecDeque<SessionLocation>> = Mutex::new(VecDeque::new());

#[derive(Default)]
struct PendingReads {
    recent: VecDeque<ReadWhiteboard>,
    history: Option<ReadWhiteboard>,
}

impl PendingReads {
    fn replace(&mut self, request: ReadWhiteboard) -> Option<ReadWhiteboard> {
        if request.session_id.is_empty() {
            let replaced = self
                .recent
                .iter()
                .position(|r| r.provider == request.provider)
                .and_then(|index| self.recent.remove(index));
            self.recent.push_back(request);
            replaced
        } else {
            self.history.replace(request)
        }
    }

    fn take(&mut self) -> Option<ReadWhiteboard> {
        self.history.take().or_else(|| self.recent.pop_front())
    }
}

struct ResponseCache {
    path: PathBuf,
    size: u64,
    modified: SystemTime,
    limit: usize,
    responses: Vec<Response>,
    bounded: bool,
}
// Bound both entry count and total answer bytes; never retain full transcripts.
static RESPONSE_CACHE: Mutex<VecDeque<ResponseCache>> = Mutex::new(VecDeque::new());

pub(super) async fn listen() {
    let receiver = ReadWhiteboard::get_dart_signal_receiver();
    let mut pending = PendingReads::default();
    // Keep one worker, but discard obsolete queued selections/refreshes.
    loop {
        let request = if let Some(request) = pending.take() {
            request
        } else if let Some(pack) = receiver.recv().await {
            pack.message
        } else {
            break;
        };
        let id = request.request_id;
        let mut worker = spawn_blocking(move || read_request(request));
        loop {
            tokio::select! {
                result = &mut worker => {
                    send_read_result(id, result);
                    break;
                }
                pack = receiver.recv() => {
                    let Some(pack) = pack else {
                        send_read_result(id, worker.await);
                        return;
                    };
                    if let Some(replaced) = pending.replace(pack.message) {
                        WhiteboardResult {
                            request_id: replaced.request_id,
                            payload_json: "{}".into(),
                            error: Some("Superseded by a newer Whiteboard request.".into()),
                        }.send_signal_to_dart();
                    }
                }
            }
        }
    }
}

fn send_read_result(
    id: u64,
    result: std::result::Result<Result<serde_json::Value>, tokio::task::JoinError>,
) {
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
    if request.session_id.is_empty() {
        return super::recent_cache::load(
            &request.sessions_markdown_path,
            &request.provider,
            request.limit.clamp(3, 10) as usize,
        );
    }
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
    // A selected session's log path is stable. Revalidate it periodically rather
    // than requerying a busy WSL database for every answer-content check.
    let location = LOCATIONS.lock().ok().and_then(|cache| {
        cache
            .iter()
            .find(|entry| {
                entry.markdown == request.sessions_markdown_path
                    && entry.session == request.session_id
                    && entry.checked.elapsed() < Duration::from_secs(30)
            })
            .map(|entry| (entry.path.clone(), entry.work_dir.clone()))
    });
    if let Some((path, cwd)) = location {
        if path.is_file() {
            return read_response_payload(&path, cwd, request.limit.clamp(1, 3) as usize);
        }
    }
    match read_cached_database(&db, db.parent(), &request) {
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

pub(super) fn load_recent_codex(markdown: &str) -> Result<Vec<super::RecentContext>> {
    let db = infer_codex_db_path(markdown)
        .ok_or_else(|| anyhow!("Choose your sessions markdown file first."))?;
    super::recent_cache::track_database(&db);
    if !db.is_file() {
        return Ok(Vec::new());
    }
    let request = ReadWhiteboard {
        request_id: 0,
        sessions_markdown_path: markdown.into(),
        provider: PROVIDER_CODEX.into(),
        session_id: String::new(),
        limit: 10,
    };
    let payload = match read_cached_database(&db, db.parent(), &request) {
        Err(error)
            if error
                .downcast_ref::<rusqlite::Error>()
                .is_some_and(is_locked_sqlite_error) =>
        {
            let snapshot = snapshot_sqlite_database(&db)?;
            let result = read_database(&snapshot, db.parent(), &request);
            let _ = remove_snapshot_database(&snapshot);
            result?
        }
        result => result?,
    };
    Ok(serde_json::from_value(payload["sessions"].clone())?)
}

fn read_database(
    db: &Path,
    home: Option<&Path>,
    request: &ReadWhiteboard,
) -> Result<serde_json::Value> {
    let connection = open_database(db)?;
    read_connection(&connection, home, request)
}

fn open_database(db: &Path) -> Result<Connection> {
    let connection = Connection::open_with_flags(
        db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    connection.busy_timeout(Duration::from_millis(250))?;
    Ok(connection)
}

fn read_cached_database(
    db: &Path,
    home: Option<&Path>,
    request: &ReadWhiteboard,
) -> Result<serde_json::Value> {
    let metadata = fs::metadata(db)?;
    let created = metadata.created().ok();
    let mut cache = DATABASE_CACHE
        .lock()
        .map_err(|_| anyhow!("Whiteboard database cache is unavailable."))?;
    let reusable = cache.as_ref().is_some_and(|cached| {
        cached.path == db && cached.created == created && metadata.len() >= cached.size
    });
    if !reusable {
        *cache = Some(DatabaseCache {
            path: db.into(),
            created,
            size: metadata.len(),
            connection: open_database(db)?,
        });
    }
    let cached = cache
        .as_mut()
        .ok_or_else(|| anyhow!("Whiteboard database cache is unavailable."))?;
    cached.size = metadata.len();
    // No transaction is held between checks, so new WAL commits remain visible.
    let result = read_connection(&cached.connection, home, request);
    if result.is_err() {
        *cache = None;
    }
    result
}

fn read_connection(
    connection: &Connection,
    home: Option<&Path>,
    request: &ReadWhiteboard,
) -> Result<serde_json::Value> {
    if request.session_id.is_empty() {
        return read_sessions(&connection, home, request.limit.clamp(3, 10) as usize);
    }
    let has_cwd = sqlite_table_has_column(&connection, "threads", "cwd")?;
    let cwd = if has_cwd { "cwd" } else { "NULL" };
    let (raw, work_dir): (String, Option<String>) = connection
        .prepare_cached(&format!(
            "SELECT rollout_path, {cwd} FROM threads WHERE id = ?1"
        ))?
        .query_row([&request.session_id], |row| Ok((row.get(0)?, row.get(1)?)))?;
    let path = resolve_codex_rollout_path(home, &raw);
    let limit = request.limit.clamp(1, 3) as usize;
    if let Ok(mut cache) = LOCATIONS.lock() {
        cache.retain(|entry| {
            entry.markdown != request.sessions_markdown_path || entry.session != request.session_id
        });
        cache.push_back(SessionLocation {
            markdown: request.sessions_markdown_path.clone(),
            session: request.session_id.clone(),
            path: path.clone(),
            work_dir: work_dir.clone(),
            checked: Instant::now(),
        });
        while cache.len() > 10 {
            cache.pop_front();
        }
    }
    read_response_payload(&path, work_dir, limit)
}

fn read_response_payload(
    path: &Path,
    work_dir: Option<String>,
    limit: usize,
) -> Result<serde_json::Value> {
    let metadata = fs::metadata(&path).context("Codex response log is unavailable.")?;
    let modified = metadata.modified()?;
    if let Ok(mut cache) = RESPONSE_CACHE.lock() {
        if let Some(index) = cache.iter().position(|cached| {
            cached.path == path
                && cached.size == metadata.len()
                && cached.modified == modified
                && cached.limit >= limit
        }) {
            let cached = cache
                .remove(index)
                .ok_or_else(|| anyhow!("Whiteboard response cache changed."))?;
            let result = serde_json::json!({"responses": cached.responses.iter().take(limit).collect::<Vec<_>>(),
                "work_dir": work_dir, "bounded_history": cached.bounded});
            cache.push_back(cached);
            return Ok(result);
        }
        cache.retain(|cached| cached.path != path);
    }
    let (responses, bounded) = read_responses(&path, limit)?;
    if responses.iter().map(|r| r.text.len()).sum::<usize>() <= MAX_CACHE_BYTES {
        if let Ok(mut cache) = RESPONSE_CACHE.lock() {
            cache.push_back(ResponseCache {
                path: path.into(),
                size: metadata.len(),
                modified,
                limit,
                responses: responses.clone(),
                bounded,
            });
            trim_response_cache(&mut cache);
        }
    }
    Ok(
        serde_json::json!({"responses": responses, "work_dir": work_dir,
        "bounded_history": bounded}),
    )
}

fn trim_response_cache(cache: &mut VecDeque<ResponseCache>) {
    while cache.len() > 10
        || cache
            .iter()
            .flat_map(|entry| &entry.responses)
            .map(|r| r.text.len())
            .sum::<usize>()
            > MAX_CACHE_BYTES
    {
        cache.pop_front();
    }
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
    let mut statement = connection.prepare_cached(&format!(
        "SELECT id, title, updated_at, rollout_path, {source}, {cwd} FROM threads
         WHERE archived = 0 ORDER BY updated_at DESC, id DESC LIMIT 200"
    ))?;
    let mut rows = statement.query([])?;
    let mut sessions = Vec::new();
    while let Some(row) = rows.next()? {
        let source: Option<String> = row.get(4)?;
        if source.as_deref().is_some_and(is_subagent_source) {
            continue;
        }
        let raw: String = row.get(3)?;
        let rollout = resolve_codex_rollout_path(home, &raw);
        let metadata = fs::metadata(&rollout).ok();
        if cached_rollout_is_subagent(&rollout, metadata.as_ref()) {
            continue;
        }
        super::recent_cache::track(&rollout);
        let updated_at = normalize_epoch_millis(row.get(2)?);
        let file_updated_at = metadata
            .as_ref()
            .and_then(|m| m.modified().ok())
            .and_then(|time| time.duration_since(SystemTime::UNIX_EPOCH).ok())
            .and_then(|duration| i64::try_from(duration.as_millis()).ok())
            .unwrap_or(updated_at);
        sessions.push(serde_json::json!({
            "provider": "codex", "id": row.get::<_, String>(0)?,
            "title": row.get::<_, String>(1)?,
            "updated_at": updated_at.max(file_updated_at),
            "forked_from_id": super::read_forked_from_id(&rollout).ok().flatten(),
            "work_dir": row.get::<_, Option<String>>(5)?,
        }));
        if sessions.len() == 10 {
            break;
        }
    }
    sessions.sort_by(|a, b| {
        b["updated_at"]
            .as_i64()
            .cmp(&a["updated_at"].as_i64())
            .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
    });
    sessions.truncate(limit);
    Ok(serde_json::json!({"sessions": sessions}))
}

fn cached_rollout_is_subagent(path: &Path, metadata: Option<&fs::Metadata>) -> bool {
    let Some(metadata) = metadata else {
        return false;
    };
    let modified = metadata.modified().ok();
    let size = metadata.len();
    if let Ok(mut cache) = HEADER_CACHE.lock() {
        if let Some(index) = cache.iter().position(|entry| {
            entry.path == path && entry.size == size && entry.modified == modified
        }) {
            if let Some(entry) = cache.remove(index) {
                let result = entry.subagent;
                cache.push_back(entry);
                return result;
            }
        }
        cache.retain(|entry| entry.path != path);
    }
    let subagent = rollout_is_subagent(path);
    if let Ok(mut cache) = HEADER_CACHE.lock() {
        cache.push_back(HeaderCache {
            path: path.into(),
            size,
            modified,
            subagent,
        });
        while cache.len() > 32 {
            cache.pop_front();
        }
    }
    subagent
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
    let mut tail_bytes = INITIAL_TAIL_BYTES;
    loop {
        let (responses, bounded) = read_response_window(path, limit, tail_bytes)?;
        if responses.len() >= limit || !bounded || tail_bytes == MAX_TAIL_BYTES {
            return Ok((responses, bounded));
        }
        tail_bytes = (tail_bytes * 4).min(MAX_TAIL_BYTES);
    }
}

fn read_response_window(
    path: &Path,
    limit: usize,
    tail_bytes: u64,
) -> Result<(Vec<Response>, bool)> {
    let mut file = fs::File::open(path).context("Codex response log is unavailable.")?;
    let size = file.metadata()?.len();
    let start = size.saturating_sub(tail_bytes);
    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::with_capacity(256 * 1024, file.take(size - start));
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
    #[ignore = "requires CONTEXT_WHITEBOARD_MARKDOWN and CONTEXT_WHITEBOARD_SESSION"]
    fn reads_configured_session() -> anyhow::Result<()> {
        let request = crate::signals::ReadWhiteboard {
            request_id: 1,
            provider: "codex".into(),
            sessions_markdown_path: std::env::var("CONTEXT_WHITEBOARD_MARKDOWN")?,
            session_id: std::env::var("CONTEXT_WHITEBOARD_SESSION")?,
            limit: 3,
        };
        let started = std::time::Instant::now();
        let result = super::read_request(request)?;
        let responses = result["responses"]
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("Reader returned no response array."))?;
        println!(
            "{}",
            json!({
                "elapsed_ms": started.elapsed().as_millis(),
                "bounded_history": result["bounded_history"],
                "responses": responses.iter().map(|response| json!({
                    "timestamp": response["timestamp"],
                    "turn_id": response["turn_id"],
                    "text_bytes": response["text"].as_str().map(str::len),
                })).collect::<Vec<_>>(),
            })
        );
        assert!(!responses.is_empty(), "No completed response was read.");
        if let Ok(expected) = std::env::var("CONTEXT_WHITEBOARD_EXPECT_TURN") {
            assert_eq!(responses[0]["turn_id"].as_str(), Some(expected.as_str()));
        }
        Ok(())
    }

    #[test]
    #[ignore = "requires CONTEXT_WHITEBOARD_LOG; reads at most the last 32 MiB per sample"]
    fn compare_response_read_windows() -> anyhow::Result<()> {
        let path = std::path::PathBuf::from(std::env::var("CONTEXT_WHITEBOARD_LOG")?);
        let before = std::fs::metadata(&path)?;
        let mut expected = None;
        for (mode, limit) in [("full", 1), ("adaptive", 1), ("adaptive", 1), ("full", 1)] {
            let started = std::time::Instant::now();
            let (responses, _) = if mode == "full" {
                super::read_response_window(&path, limit, super::MAX_TAIL_BYTES)?
            } else {
                read_responses(&path, limit)?
            };
            println!(
                "{}",
                json!({"mode": mode, "limit": limit,
                "elapsed_us": started.elapsed().as_micros(), "responses": responses.len()})
            );
            if let Some(expected) = &expected {
                assert_eq!(&responses, expected);
            } else {
                assert!(!responses.is_empty());
                expected = Some(responses);
            }
        }
        let after = std::fs::metadata(&path)?;
        assert_eq!(before.len(), after.len(), "Log changed during comparison.");
        assert_eq!(before.modified()?, after.modified()?);
        Ok(())
    }

    #[test]
    fn pending_reads_keep_only_latest_per_category() {
        let request = |id, session: &str| crate::signals::ReadWhiteboard {
            request_id: id,
            sessions_markdown_path: String::new(),
            provider: "codex".into(),
            session_id: session.into(),
            limit: 3,
        };
        let mut pending = super::PendingReads::default();
        assert!(pending.replace(request(1, "")).is_none());
        assert!(pending.replace(request(2, "old")).is_none());
        assert_eq!(
            pending.replace(request(3, "new")).map(|r| r.request_id),
            Some(2)
        );
        assert_eq!(
            pending.replace(request(4, "")).map(|r| r.request_id),
            Some(1)
        );
        assert_eq!(pending.take().map(|r| r.request_id), Some(3));
        assert_eq!(pending.take().map(|r| r.request_id), Some(4));
        assert!(pending.take().is_none());
    }

    #[test]
    fn queued_provider_reads_do_not_supersede_another_provider() {
        let mut pending = super::PendingReads::default();
        for (id, provider) in [(1, "codex"), (2, "kimi"), (3, "qwen")] {
            assert!(
                pending
                    .replace(crate::signals::ReadWhiteboard {
                        request_id: id,
                        sessions_markdown_path: String::new(),
                        provider: provider.into(),
                        session_id: String::new(),
                        limit: 3
                    })
                    .is_none()
            );
        }
        assert_eq!(pending.take().map(|r| r.request_id), Some(1));
        assert_eq!(pending.take().map(|r| r.request_id), Some(2));
        assert_eq!(pending.take().map(|r| r.request_id), Some(3));
    }

    #[test]
    fn response_cache_is_bounded_by_count_and_bytes() {
        let entry = |n: usize, text: String| super::ResponseCache {
            path: format!("{n}").into(),
            size: 1,
            modified: std::time::SystemTime::UNIX_EPOCH,
            limit: 1,
            bounded: false,
            responses: vec![super::Response {
                text,
                timestamp: String::new(),
                turn_id: String::new(),
            }],
        };
        let mut cache = std::collections::VecDeque::new();
        for n in 0..12 {
            cache.push_back(entry(n, "answer".into()));
        }
        super::trim_response_cache(&mut cache);
        assert_eq!(cache.len(), 10);
        assert_eq!(
            cache.front().map(|entry| entry.path.clone()),
            Some("2".into())
        );
        cache.push_back(entry(20, "x".repeat(super::MAX_CACHE_BYTES + 1)));
        super::trim_response_cache(&mut cache);
        assert!(cache.is_empty());
    }

    #[test]
    #[ignore = "requires CONTEXT_WHITEBOARD_MARKDOWN and CONTEXT_WHITEBOARD_SESSION"]
    fn compare_database_connections() -> anyhow::Result<()> {
        let markdown = std::env::var("CONTEXT_WHITEBOARD_MARKDOWN")?;
        let db = super::infer_codex_db_path(&markdown)
            .ok_or_else(|| anyhow::anyhow!("No Codex database."))?;
        let request = crate::signals::ReadWhiteboard {
            request_id: 1,
            provider: "codex".into(),
            sessions_markdown_path: markdown,
            session_id: std::env::var("CONTEXT_WHITEBOARD_SESSION")?,
            limit: 1,
        };
        let expected = super::read_cached_database(&db, db.parent(), &request)?;
        for mode in ["open", "reuse", "reuse", "open"] {
            let started = std::time::Instant::now();
            let result = if mode == "open" {
                super::read_database(&db, db.parent(), &request)?
            } else {
                super::read_cached_database(&db, db.parent(), &request)?
            };
            println!(
                "{}",
                json!({"mode":mode, "elapsed_us":started.elapsed().as_micros()})
            );
            assert_eq!(result, expected, "Session data changed during comparison.");
        }
        Ok(())
    }

    #[test]
    fn adaptive_tail_expands_for_older_answers_and_respects_cap() -> anyhow::Result<()> {
        use std::io::{Seek, SeekFrom, Write};
        let path = std::env::temp_dir().join(format!(
            "context-whiteboard-tail-{}.jsonl",
            std::process::id()
        ));
        let mut file = std::fs::File::create(&path)?;
        writeln!(
            file,
            "{}",
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"old","last_agent_message":"older answer"}})
        )?;
        file.seek(SeekFrom::Start(super::INITIAL_TAIL_BYTES * 2))?;
        writeln!(file)?;
        writeln!(
            file,
            "{}",
            json!({"type":"event_msg","payload":{"type":"task_complete","turn_id":"new","last_agent_message":"newer answer"}})
        )?;
        drop(file);
        let (one, bounded) = read_responses(&path, 1)?;
        assert!(bounded);
        assert_eq!(one[0].text, "newer answer");
        let (three, bounded) = read_responses(&path, 3)?;
        assert!(!bounded);
        assert_eq!(
            three.iter().map(|r| r.text.as_str()).collect::<Vec<_>>(),
            ["newer answer", "older answer"]
        );
        let mut file = std::fs::OpenOptions::new().write(true).open(&path)?;
        file.seek(SeekFrom::Start(
            super::MAX_TAIL_BYTES + super::INITIAL_TAIL_BYTES * 4,
        ))?;
        writeln!(file)?;
        drop(file);
        let (responses, bounded) = read_responses(&path, 3)?;
        assert!(bounded);
        assert!(responses.is_empty());
        std::fs::remove_file(path)?;
        Ok(())
    }

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
    fn cached_database_observes_new_wal_commits() -> anyhow::Result<()> {
        let root =
            std::env::temp_dir().join(format!("context-whiteboard-wal-{}", std::process::id()));
        std::fs::create_dir_all(&root)?;
        let db = root.join("state.sqlite");
        let writer = Connection::open(&db)?;
        writer.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE threads (id TEXT, title TEXT, updated_at INTEGER, rollout_path TEXT, thread_source TEXT, cwd TEXT, archived INTEGER);
            INSERT INTO threads VALUES ('first', 'First', 1, '/missing', 'cli', '/work', 0);")?;
        let request = crate::signals::ReadWhiteboard {
            request_id: 1,
            provider: "codex".into(),
            sessions_markdown_path: String::new(),
            session_id: String::new(),
            limit: 3,
        };
        assert_eq!(
            super::read_cached_database(&db, None, &request)?["sessions"][0]["id"],
            "first"
        );
        writer.execute(
            "INSERT INTO threads VALUES ('new', 'New', 2, '/missing', 'cli', '/work', 0)",
            [],
        )?;
        assert_eq!(
            super::read_cached_database(&db, None, &request)?["sessions"][0]["id"],
            "new"
        );
        writer.execute("UPDATE threads SET archived = 1 WHERE id = 'new'", [])?;
        assert_eq!(
            super::read_cached_database(&db, None, &request)?["sessions"][0]["id"],
            "first"
        );
        if let Ok(mut cache) = super::DATABASE_CACHE.lock() {
            if cache.as_ref().is_some_and(|cached| cached.path == db) {
                *cache = None;
            }
        }
        drop(writer);
        std::fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn log_activity_reorders_recents_before_database_timestamp_catches_up() -> anyhow::Result<()> {
        use std::time::{Duration, SystemTime};
        let root = std::env::temp_dir().join(format!(
            "context-whiteboard-activity-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root)?;
        let a = root.join("a.jsonl");
        let b = root.join("b.jsonl");
        for path in [&a, &b] {
            std::fs::write(
                path,
                "{\"type\":\"session_meta\",\"payload\":{\"source\":\"cli\"}}\n",
            )?;
        }
        let set_time = |path: &std::path::Path, seconds| -> anyhow::Result<()> {
            std::fs::OpenOptions::new()
                .write(true)
                .open(path)?
                .set_times(
                    std::fs::FileTimes::new()
                        .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(seconds)),
                )?;
            Ok(())
        };
        set_time(&a, 2)?;
        set_time(&b, 1)?;
        let connection = Connection::open_in_memory()?;
        connection.execute_batch("CREATE TABLE threads (id TEXT, title TEXT, updated_at INTEGER, rollout_path TEXT, thread_source TEXT, cwd TEXT, archived INTEGER);")?;
        for (id, time, path) in [("a", 2, &a), ("b", 1, &b)] {
            connection.execute(
                "INSERT INTO threads VALUES (?1, 'Title', ?2, ?3, 'cli', '/work', 0)",
                rusqlite::params![id, time, path.to_string_lossy()],
            )?;
        }
        assert_eq!(
            read_sessions(&connection, None, 3)?["sessions"][0]["id"],
            "a"
        );
        set_time(&b, 3)?;
        assert_eq!(
            read_sessions(&connection, None, 3)?["sessions"][0]["id"],
            "b"
        );
        std::fs::write(
            &b,
            "{\"type\":\"session_meta\",\"payload\":{\"source\":{\"subagent\":{}}}}\n",
        )?;
        let result = read_sessions(&connection, None, 3)?;
        assert_eq!(result["sessions"].as_array().map(Vec::len), Some(1));
        assert_eq!(result["sessions"][0]["id"], "a");
        std::fs::remove_dir_all(root)?;
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
