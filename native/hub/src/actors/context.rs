use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context as AnyhowContext, Result, anyhow};
use async_trait::async_trait;
use messages::prelude::{Actor, Address, Context, Notifiable};
use regex::Regex;
use rinf::{DartSignal, RustSignal};
use rusqlite::{Connection, ErrorCode, OpenFlags};
use serde::{Deserialize, Serialize};
use tokio::task::{JoinSet, spawn_blocking};

use crate::signals::{
    InitApp, LoadConfig, OpFinished, OpenReference, SaveConfig, SetThemeSeed, UiState,
};

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ConfigItem {
    kind: String,
    id: String,
    name: String,
    command_id: String,
    color_hex: String,
    #[serde(default)]
    fast: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct RecentContext {
    id: String,
    title: String,
    updated_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    forked_from_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct LastAnswer {
    id: String,
    title: String,
    updated_at: i64,
    answer_text: String,
    session_path: String,
}

impl ConfigItem {
    fn is_group(&self) -> bool {
        self.kind == "group"
    }

    fn is_group_end(&self) -> bool {
        self.kind == "group_end"
    }
}

#[derive(Debug)]
struct LoadedConfig {
    items: Vec<ConfigItem>,
    warnings: Vec<String>,
    status: String,
    recent_contexts: Vec<RecentContext>,
}

#[derive(Debug)]
struct LoadedLastAnswers {
    recent_contexts: Vec<RecentContext>,
    last_answers: Vec<LastAnswer>,
    status: String,
}

struct ContextActor {
    initialized: bool,
    theme_seed_color_value: i64,
    sessions_markdown_path: String,
    busy: bool,
    status: Option<String>,
    last_error: Option<String>,
    items: Vec<ConfigItem>,
    warnings: Vec<String>,
    recent_contexts: Vec<RecentContext>,
    last_answers: Vec<LastAnswer>,
    last_answers_busy: bool,
    last_answers_loaded: bool,
    last_answers_status: Option<String>,
    _owned_tasks: JoinSet<()>,
}

impl Actor for ContextActor {}

impl ContextActor {
    pub fn new(self_addr: Address<Self>) -> Self {
        let mut owned = JoinSet::new();
        owned.spawn(Self::forward_dart_signal::<InitApp>(self_addr.clone()));
        owned.spawn(Self::forward_dart_signal::<LoadConfig>(self_addr.clone()));
        owned.spawn(Self::forward_dart_signal::<SaveConfig>(self_addr.clone()));
        owned.spawn(Self::forward_dart_signal::<OpenReference>(self_addr.clone()));
        owned.spawn(Self::forward_dart_signal::<SetThemeSeed>(self_addr));

        Self {
            initialized: false,
            theme_seed_color_value: 0xFFFABD2F,
            sessions_markdown_path: String::new(),
            busy: false,
            status: None,
            last_error: None,
            items: Vec::new(),
            warnings: Vec::new(),
            recent_contexts: Vec::new(),
            last_answers: Vec::new(),
            last_answers_busy: false,
            last_answers_loaded: false,
            last_answers_status: Some("Last Answer not loaded.".to_owned()),
            _owned_tasks: owned,
        }
    }

    async fn forward_dart_signal<T>(mut self_addr: Address<Self>)
    where
        T: DartSignal + Send + 'static,
        Self: Notifiable<T>,
    {
        let receiver = T::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            let _ = self_addr.notify(signal_pack.message).await;
        }
    }

    fn emit_state(&self) {
        let items_json = serde_json::to_string(&self.items).unwrap_or_else(|_| "[]".to_owned());
        let warnings_json =
            serde_json::to_string(&self.warnings).unwrap_or_else(|_| "[]".to_owned());
        let recent_contexts_json =
            serde_json::to_string(&self.recent_contexts).unwrap_or_else(|_| "[]".to_owned());
        let last_answers_json =
            serde_json::to_string(&self.last_answers).unwrap_or_else(|_| "[]".to_owned());

        UiState {
            theme_seed_color_value: self.theme_seed_color_value,
            busy: self.busy,
            status: self.status.clone(),
            last_error: self.last_error.clone(),
            sessions_markdown_path: self.sessions_markdown_path.clone(),
            items_json,
            warnings_json,
            recent_contexts_json,
            last_answers_json,
            last_answers_busy: self.last_answers_busy,
            last_answers_loaded: self.last_answers_loaded,
            last_answers_status: self.last_answers_status.clone(),
        }
        .send_signal_to_dart();
    }

    fn finish_op(&self, request_id: u64, ok: bool, error: Option<String>) {
        if request_id == 0 {
            return;
        }
        OpFinished {
            request_id,
            ok,
            error,
        }
        .send_signal_to_dart();
    }

    async fn load_config(&mut self, path_override: Option<String>) -> bool {
        if self.busy || !self.initialized {
            return true;
        }

        if let Some(path) = path_override {
            self.sessions_markdown_path = path.trim().to_owned();
        }

        self.busy = true;
        self.last_error = None;
        self.status = Some("Loading config...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let result = spawn_blocking(move || load_config_file(&path)).await;

        match result {
            Ok(Ok(loaded)) => {
                self.items = loaded.items;
                self.warnings = loaded.warnings;
                self.recent_contexts = loaded.recent_contexts;
                self.last_answers.clear();
                self.last_answers_busy = false;
                self.last_answers_loaded = false;
                self.last_answers_status = Some("Loading last answers in background...".to_owned());
                self.status = Some(loaded.status);
                self.last_error = None;
            }
            Ok(Err(error)) => {
                self.items.clear();
                self.warnings.clear();
                self.recent_contexts.clear();
                self.last_answers.clear();
                self.last_answers_busy = false;
                self.last_answers_loaded = false;
                self.last_answers_status = Some("Last Answer not loaded.".to_owned());
                self.last_error = Some(error.to_string());
                self.status = Some(format!("Load failed: {error}"));
            }
            Err(error) => {
                self.items.clear();
                self.warnings.clear();
                self.recent_contexts.clear();
                self.last_answers.clear();
                self.last_answers_busy = false;
                self.last_answers_loaded = false;
                self.last_answers_status = Some("Last Answer not loaded.".to_owned());
                self.last_error = Some(error.to_string());
                self.status = Some(format!("Load failed: {error}"));
            }
        }

        self.busy = false;
        self.emit_state();
        self.last_error.is_none()
    }

    async fn load_last_answers(&mut self, path_override: Option<String>) -> bool {
        if self.last_answers_busy || self.busy || !self.initialized {
            return true;
        }

        if let Some(path) = path_override {
            self.sessions_markdown_path = path.trim().to_owned();
        }

        self.last_answers_busy = true;
        self.last_answers_status = Some("Loading last answers...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let result = spawn_blocking(move || load_last_answers_file(&path)).await;

        match result {
            Ok(Ok(loaded)) => {
                self.recent_contexts = loaded.recent_contexts;
                self.last_answers = loaded.last_answers;
                self.last_answers_loaded = true;
                self.last_answers_status = Some(loaded.status);
            }
            Ok(Err(error)) => {
                self.last_answers.clear();
                self.last_answers_loaded = true;
                self.last_answers_status = Some(format!("Last Answer failed: {error}"));
            }
            Err(error) => {
                self.last_answers.clear();
                self.last_answers_loaded = true;
                self.last_answers_status = Some(format!("Last Answer failed: {error}"));
            }
        }

        self.last_answers_busy = false;
        self.emit_state();
        true
    }

    async fn save_config(&mut self, path: String, items_json: String) -> Result<()> {
        let path = path.trim().to_owned();
        let items = deserialize_items(&items_json)?;

        self.sessions_markdown_path = path.clone();
        self.items = items.clone();
        self.last_error = None;
        self.busy = true;
        self.status = Some("Saving config...".to_owned());
        self.emit_state();

        let result = spawn_blocking(move || save_config_file(&path, &items)).await;

        match result {
            Ok(Ok(saved_status)) => {
                self.warnings.clear();
                self.status = Some(saved_status);
                self.last_error = None;
                self.busy = false;
                self.emit_state();
                Ok(())
            }
            Ok(Err(error)) => {
                self.busy = false;
                self.last_error = Some(error.to_string());
                self.status = Some(format!("Save failed: {error}"));
                self.emit_state();
                Err(error)
            }
            Err(error) => {
                let error = anyhow!("Save task failed: {error}");
                self.busy = false;
                self.last_error = Some(error.to_string());
                self.status = Some(format!("Save failed: {error}"));
                self.emit_state();
                Err(error)
            }
        }
    }

    async fn open_reference(&self, target: String) -> Result<()> {
        let target = target.trim().to_owned();
        spawn_blocking(move || open_reference_target(&target))
            .await
            .map_err(|error| anyhow!("Open reference task failed: {error}"))?
    }
}

pub async fn create_actors() {
    let context = Context::new();
    let addr = context.address();
    let actor = ContextActor::new(addr);
    tokio::spawn(context.run(actor));
}

#[async_trait]
impl Notifiable<InitApp> for ContextActor {
    async fn notify(&mut self, msg: InitApp, _: &Context<Self>) {
        self.theme_seed_color_value = msg.theme_seed_color_value;
        self.sessions_markdown_path = msg.sessions_markdown_path.trim().to_owned();
        self.initialized = true;
        self.emit_state();
        let _ = self.load_config(None).await;
    }
}

#[async_trait]
impl Notifiable<LoadConfig> for ContextActor {
    async fn notify(&mut self, msg: LoadConfig, _: &Context<Self>) {
        let ok = if msg.load_last_answers {
            self.load_last_answers(Some(msg.sessions_markdown_path)).await
        } else {
            self.load_config(Some(msg.sessions_markdown_path)).await
        };
        self.finish_op(msg.request_id, ok, self.last_error.clone());
    }
}

#[async_trait]
impl Notifiable<SaveConfig> for ContextActor {
    async fn notify(&mut self, msg: SaveConfig, _: &Context<Self>) {
        let result = self
            .save_config(msg.sessions_markdown_path, msg.items_json)
            .await;
        match result {
            Ok(()) => self.finish_op(msg.request_id, true, None),
            Err(error) => self.finish_op(msg.request_id, false, Some(error.to_string())),
        }
    }
}

#[async_trait]
impl Notifiable<OpenReference> for ContextActor {
    async fn notify(&mut self, msg: OpenReference, _: &Context<Self>) {
        let result = self.open_reference(msg.target).await;
        match result {
            Ok(()) => self.finish_op(msg.request_id, true, None),
            Err(error) => self.finish_op(msg.request_id, false, Some(error.to_string())),
        }
    }
}

#[async_trait]
impl Notifiable<SetThemeSeed> for ContextActor {
    async fn notify(&mut self, msg: SetThemeSeed, _: &Context<Self>) {
        self.theme_seed_color_value = msg.value;
        self.emit_state();
    }
}

fn load_config_file(path_str: &str) -> Result<LoadedConfig> {
    let path_str = path_str.trim();
    if path_str.is_empty() {
        return Ok(LoadedConfig {
            items: Vec::new(),
            warnings: Vec::new(),
            status: "Pick a codex sessions.md file.".to_owned(),
            recent_contexts: Vec::new(),
        });
    }

    let path = PathBuf::from(path_str);
    if !path.is_file() {
        return Ok(LoadedConfig {
            items: Vec::new(),
            warnings: vec![format!("Markdown file not found: {}", path.display())],
            status: format!("Markdown file not found: {}", path.display()),
            recent_contexts: Vec::new(),
        });
    }

    let text = fs::read_to_string(&path)
        .with_context(|| format!("Failed to read markdown file: {}", path.display()))?;
    let (items, parse_warnings) = parse_markdown_items(&text);
    let mut warnings = parse_warnings;
    let recent_contexts = match load_recent_contexts(path_str) {
        Ok(items) => items,
        Err(error) => {
            warnings.push(format!("Couldn't read recent Codex sessions: {error}"));
            Vec::new()
        }
    };

    Ok(LoadedConfig {
        status: format!("Loaded {} item(s) from {}", items.len(), path.display()),
        items,
        warnings,
        recent_contexts,
    })
}

fn load_last_answers_file(path_str: &str) -> Result<LoadedLastAnswers> {
    let path_str = path_str.trim();
    if path_str.is_empty() {
        return Ok(LoadedLastAnswers {
            recent_contexts: Vec::new(),
            last_answers: Vec::new(),
            status: "Pick a codex sessions.md file first.".to_owned(),
        });
    }

    let recent_contexts = load_recent_contexts(path_str)
        .with_context(|| "Couldn't read recent Codex sessions.".to_owned())?;
    let last_answers = load_last_answers(path_str, &recent_contexts)
        .with_context(|| "Couldn't read latest answers.".to_owned())?;

    Ok(LoadedLastAnswers {
        status: format!("Loaded {} last answer(s)", last_answers.len()),
        recent_contexts,
        last_answers,
    })
}

fn load_recent_contexts(markdown_path: &str) -> Result<Vec<RecentContext>> {
    let Some(db_path) = infer_codex_db_path(markdown_path) else {
        return Ok(Vec::new());
    };

    if !db_path.is_file() {
        return Ok(Vec::new());
    }

    match query_recent_contexts(&db_path) {
        Ok(items) => Ok(items),
        Err(error) if is_locked_sqlite_error(&error) => {
            let snapshot = snapshot_sqlite_database(&db_path)?;
            let result = query_recent_contexts(&snapshot)
                .with_context(|| format!("Failed to read snapshot of {}", db_path.display()));
            let _ = remove_snapshot_database(&snapshot);
            result
        }
        Err(error) => {
            Err(error).with_context(|| format!("Failed to read {}", db_path.display()))
        }
    }
}

fn query_recent_contexts(db_path: &PathBuf) -> rusqlite::Result<Vec<RecentContext>> {
    let connection = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let _ = connection.busy_timeout(Duration::from_millis(250));
    let mut statement = connection.prepare(
        "SELECT id, title, updated_at, rollout_path
         FROM threads
         WHERE archived = 0
         ORDER BY updated_at DESC
         LIMIT 6",
    )?;

    let rows = statement.query_map([], |row| {
        let rollout_path = row.get::<_, String>(3)?;
        Ok(RecentContext {
            id: row.get::<_, String>(0)?,
            title: row.get::<_, String>(1)?,
            updated_at: row.get::<_, i64>(2)?,
            forked_from_id: read_forked_from_id(Path::new(&rollout_path)).ok().flatten(),
        })
    })?;

    let mut seen = std::collections::HashSet::new();
    let mut items = Vec::new();
    for row in rows {
        let item = row?;
        if !seen.insert(item.id.clone()) {
            continue;
        }
        items.push(item);
        if items.len() == 3 {
            break;
        }
    }

    Ok(items)
}

fn read_forked_from_id(rollout_path: &Path) -> Result<Option<String>> {
    if !rollout_path.is_file() {
        return Ok(None);
    }

    let file = fs::File::open(rollout_path)
        .with_context(|| format!("Failed to open {}", rollout_path.display()))?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let read = reader
        .read_line(&mut line)
        .with_context(|| format!("Failed to read {}", rollout_path.display()))?;
    if read == 0 {
        return Ok(None);
    }

    let value: serde_json::Value = serde_json::from_str(line.trim_end())
        .with_context(|| format!("Failed to parse {}", rollout_path.display()))?;
    let Some(payload) = value.get("payload") else {
        return Ok(None);
    };
    Ok(payload
        .get("forked_from_id")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned))
}

fn is_locked_sqlite_error(error: &rusqlite::Error) -> bool {
    match error {
        rusqlite::Error::SqliteFailure(inner, _) => {
            matches!(inner.code, ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked)
        }
        _ => false,
    }
}

fn snapshot_sqlite_database(db_path: &PathBuf) -> Result<PathBuf> {
    let file_name = db_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("state_5.sqlite");
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let snapshot_dir =
        std::env::temp_dir().join(format!("context-recent-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&snapshot_dir)
        .with_context(|| format!("Failed to create {}", snapshot_dir.display()))?;

    let snapshot_db = snapshot_dir.join(file_name);
    fs::copy(db_path, &snapshot_db)
        .with_context(|| format!("Failed to copy {}", db_path.display()))?;

    if let Some(parent) = db_path.parent() {
        for suffix in ["-wal", "-shm"] {
            let sidecar_src = parent.join(format!("{file_name}{suffix}"));
            if sidecar_src.is_file() {
                let sidecar_dest = snapshot_dir.join(format!("{file_name}{suffix}"));
                fs::copy(&sidecar_src, &sidecar_dest)
                    .with_context(|| format!("Failed to copy {}", sidecar_src.display()))?;
            }
        }
    }

    Ok(snapshot_db)
}

fn remove_snapshot_database(snapshot_db: &PathBuf) -> Result<()> {
    let Some(dir) = snapshot_db.parent() else {
        return Ok(());
    };
    fs::remove_dir_all(dir).with_context(|| format!("Failed to remove {}", dir.display()))
}

fn infer_codex_db_path(markdown_path: &str) -> Option<PathBuf> {
    let home_root = infer_codex_home_root(markdown_path)?;
    Some(home_root.join(".codex").join("state_5.sqlite"))
}

fn infer_codex_sessions_root(markdown_path: &str) -> Option<PathBuf> {
    let home_root = infer_codex_home_root(markdown_path)?;
    Some(home_root.join(".codex").join("sessions"))
}

fn infer_codex_home_root(markdown_path: &str) -> Option<PathBuf> {
    let trimmed = markdown_path.trim();
    let normalized = trimmed.replace('\\', "/");

    if !normalized.is_empty() {
        if let Some(prefix) = normalized.strip_suffix("/codex sessions.md") {
            if let Some(home_root) = prefix.strip_suffix("/codex-out") {
                if trimmed.contains('\\') {
                    return Some(PathBuf::from(home_root.replace('/', "\\")));
                }
                return Some(PathBuf::from(home_root));
            }
        }
    }

    std::env::var_os("HOME").map(PathBuf::from)
}

fn load_last_answers(markdown_path: &str, recent_contexts: &[RecentContext]) -> Result<Vec<LastAnswer>> {
    let Some(sessions_root) = infer_codex_sessions_root(markdown_path) else {
        return Ok(Vec::new());
    };

    if !sessions_root.is_dir() {
        return Ok(Vec::new());
    }

    let mut items = Vec::new();
    for context in recent_contexts {
        let Some(session_path) = find_rollout_file_for_session(&sessions_root, &context.id)? else {
            continue;
        };
        let Some(answer_text) = extract_last_assistant_message(&session_path)? else {
            continue;
        };
        items.push(LastAnswer {
            id: context.id.clone(),
            title: context.title.clone(),
            updated_at: context.updated_at,
            answer_text,
            session_path: session_path.display().to_string(),
        });
    }

    Ok(items)
}

fn find_rollout_file_for_session(sessions_root: &Path, session_id: &str) -> Result<Option<PathBuf>> {
    let target = session_id.trim().to_ascii_lowercase();
    if target.is_empty() {
        return Ok(None);
    }

    let mut stack = vec![sessions_root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(_) => continue,
        };

        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
                continue;
            }

            let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            if !file_name.ends_with(".jsonl") {
                continue;
            }
            if file_name.to_ascii_lowercase().contains(&target) {
                return Ok(Some(path));
            }
        }
    }

    Ok(None)
}

fn extract_last_assistant_message(session_path: &Path) -> Result<Option<String>> {
    let file = fs::File::open(session_path)
        .with_context(|| format!("Failed to open {}", session_path.display()))?;
    let reader = BufReader::new(file);
    let mut last_message = None;

    for line in reader.lines() {
        let line =
            line.with_context(|| format!("Failed to read {}", session_path.display()))?;
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        if value
            .get("type")
            .and_then(serde_json::Value::as_str)
            != Some("response_item")
        {
            continue;
        }
        let payload = match value.get("payload") {
            Some(payload) => payload,
            None => continue,
        };
        if payload
            .get("type")
            .and_then(serde_json::Value::as_str)
            != Some("message")
            || payload
                .get("role")
                .and_then(serde_json::Value::as_str)
                != Some("assistant")
        {
            continue;
        }

        let text = collect_output_text(payload);
        if !text.trim().is_empty() {
            last_message = Some(text);
        }
    }

    Ok(last_message)
}

fn collect_output_text(payload: &serde_json::Value) -> String {
    let mut parts = Vec::new();
    let Some(content) = payload.get("content").and_then(serde_json::Value::as_array) else {
        return String::new();
    };

    for item in content {
        if item
            .get("type")
            .and_then(serde_json::Value::as_str)
            != Some("output_text")
        {
            continue;
        }
        let Some(text) = item.get("text").and_then(serde_json::Value::as_str) else {
            continue;
        };
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            parts.push(trimmed.to_owned());
        }
    }

    parts.join("\n\n")
}

fn open_reference_target(target: &str) -> Result<()> {
    let target = target.trim();
    if target.is_empty() {
        return Err(anyhow!("Reference target is empty."));
    }

    if cfg!(target_os = "windows") {
        open_reference_windows(target)
    } else if cfg!(target_os = "macos") {
        open_reference_macos(target)
    } else {
        open_reference_linux(target)
    }
}

#[cfg(target_os = "windows")]
fn open_reference_windows(target: &str) -> Result<()> {
    let normalized = normalize_windows_open_target(target);
    let status = Command::new(resolve_windows_cmd_path())
        .args(["/C", "start", "", &normalized])
        .status()
        .with_context(|| format!("Failed to start {}", normalized))?;

    if !status.success() {
        return Err(anyhow!(
            "Open command failed for {} with status {}",
            normalized,
            status
        ));
    }

    Ok(())
}

#[cfg(target_os = "windows")]
fn normalize_windows_open_target(target: &str) -> String {
    if is_web_target(target) {
        return target.trim().to_owned();
    }

    let stripped = strip_reference_suffixes(target);
    if stripped.starts_with(r"\\") || has_windows_drive_prefix(&stripped) {
        return stripped.replace('/', r"\");
    }
    stripped
}

#[cfg(target_os = "windows")]
fn resolve_windows_cmd_path() -> PathBuf {
    std::env::var_os("WINDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"))
        .join("System32")
        .join("cmd.exe")
}

#[cfg(target_os = "windows")]
fn has_windows_drive_prefix(target: &str) -> bool {
    let bytes = target.as_bytes();
    bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'\\' || bytes[2] == b'/')
}

#[cfg(not(target_os = "windows"))]
fn open_reference_windows(_: &str) -> Result<()> {
    unreachable!()
}

#[cfg(target_os = "macos")]
fn open_reference_macos(target: &str) -> Result<()> {
    let normalized = normalize_open_target(target);
    let status = Command::new("open")
        .arg(&normalized)
        .status()
        .with_context(|| format!("Failed to open {}", normalized))?;

    if !status.success() {
        return Err(anyhow!(
            "Open command failed for {} with status {}",
            normalized,
            status
        ));
    }

    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn open_reference_macos(_: &str) -> Result<()> {
    unreachable!()
}

#[cfg(target_os = "linux")]
fn open_reference_linux(target: &str) -> Result<()> {
    let normalized = normalize_open_target(target);
    let status = Command::new("xdg-open")
        .arg(&normalized)
        .status()
        .with_context(|| format!("Failed to open {}", normalized))?;

    if !status.success() {
        return Err(anyhow!(
            "Open command failed for {} with status {}",
            normalized,
            status
        ));
    }

    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn open_reference_linux(_: &str) -> Result<()> {
    unreachable!()
}

fn normalize_open_target(target: &str) -> String {
    if is_web_target(target) {
        return target.trim().to_owned();
    }
    strip_reference_suffixes(target)
}

fn strip_reference_suffixes(target: &str) -> String {
    let trimmed = target.trim();
    if is_web_target(trimmed) {
        return trimmed.to_owned();
    }

    let without_hash = match trimmed.find('#') {
        Some(index) => &trimmed[..index],
        None => trimmed,
    };

    Regex::new(r"^(.*?)(:\d+(?::\d+)?)$")
        .expect("valid reference suffix regex")
        .captures(without_hash)
        .and_then(|captures| captures.get(1).map(|value| value.as_str().trim().to_owned()))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| without_hash.trim().to_owned())
}

fn is_web_target(target: &str) -> bool {
    let trimmed = target.trim();
    trimmed.starts_with("http://") || trimmed.starts_with("https://")
}

fn save_config_file(path_str: &str, items: &[ConfigItem]) -> Result<String> {
    let path_str = path_str.trim();
    if path_str.is_empty() {
        return Err(anyhow!("Pick a markdown file before saving."));
    }

    let path = PathBuf::from(path_str);
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
        }
    }

    let text = render_markdown_items(items);
    fs::write(&path, text).with_context(|| format!("Failed to write {}", path.display()))?;
    Ok(format!(
        "Saved {} item(s) to {}",
        items.len(),
        path.display()
    ))
}

fn parse_markdown_items(text: &str) -> (Vec<ConfigItem>, Vec<String>) {
    let group_re =
        Regex::new(r"(?i)^<!--\s*context-group:\s*([^|>]+)\|([^|>]+)\|(#[0-9a-f]{6})\s*-->$")
            .expect("valid group regex");
    let group_end_re =
        Regex::new(r"(?i)^<!--\s*/context-group\s*-->$").expect("valid group end regex");
    let command_re = Regex::new(
        r"(?i)^codex (?:resume|fork) ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\s+(--full-auto))?$",
    )
    .expect("valid codex command regex");

    let mut items = Vec::new();
    let mut warnings = Vec::new();
    let mut pending_title = String::new();
    let mut open_group_id: Option<String> = None;

    for raw_line in text.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(captures) = group_re.captures(trimmed) {
            let id = normalize_group_id(&captures[1]);
            let name = captures[2].trim();
            let color_hex = normalize_color_hex(&captures[3]);
            if let Some(previous_group_id) = open_group_id.take() {
                items.push(ConfigItem {
                    kind: "group_end".to_owned(),
                    id: previous_group_id,
                    name: String::new(),
                    command_id: String::new(),
                    color_hex: String::new(),
                    fast: false,
                });
            }
            let normalized_id = if id.is_empty() {
                "group".to_owned()
            } else {
                id
            };
            items.push(ConfigItem {
                kind: "group".to_owned(),
                id: normalized_id.clone(),
                name: if name.is_empty() {
                    "Group".to_owned()
                } else {
                    name.to_owned()
                },
                command_id: String::new(),
                color_hex,
                fast: false,
            });
            open_group_id = Some(normalized_id);
            pending_title.clear();
            continue;
        }

        if group_end_re.is_match(trimmed) {
            match open_group_id.take() {
                Some(group_id) => items.push(ConfigItem {
                    kind: "group_end".to_owned(),
                    id: group_id,
                    name: String::new(),
                    command_id: String::new(),
                    color_hex: String::new(),
                    fast: false,
                }),
                None => warnings.push(format!("Ignored unopened group end marker: {trimmed}")),
            }
            pending_title.clear();
            continue;
        }

        if let Some(captures) = command_re.captures(trimmed) {
            let command_id = captures[1].to_ascii_lowercase();
            let fast = captures.get(2).is_some();
            let name = if pending_title.is_empty() {
                short_session_id(&command_id)
            } else {
                pending_title.clone()
            };

            items.push(ConfigItem {
                kind: "session".to_owned(),
                id: command_id.clone(),
                name,
                command_id,
                color_hex: String::new(),
                fast,
            });
            pending_title.clear();
            continue;
        }

        let normalized = normalize_label(trimmed);
        if !normalized.is_empty() {
            pending_title = normalized;
        } else if trimmed.contains("context-group") {
            warnings.push(format!("Ignored malformed group line: {trimmed}"));
        }
    }

    if let Some(group_id) = open_group_id.take() {
        items.push(ConfigItem {
            kind: "group_end".to_owned(),
            id: group_id,
            name: String::new(),
            command_id: String::new(),
            color_hex: String::new(),
            fast: false,
        });
    }

    (items, warnings)
}

fn render_markdown_items(items: &[ConfigItem]) -> String {
    let mut out = String::new();

    for (index, item) in items.iter().enumerate() {
        if item.is_group() {
            let name = if item.name.trim().is_empty() {
                "Group"
            } else {
                item.name.trim()
            };
            out.push_str("<!-- context-group: ");
            out.push_str(&normalize_group_id(&item.id));
            out.push('|');
            out.push_str(name);
            out.push('|');
            out.push_str(&normalize_color_hex(&item.color_hex));
            out.push_str(" -->\n");
        } else if item.is_group_end() {
            out.push_str("<!-- /context-group -->\n");
        } else {
            let command_id = item.command_id.trim().to_ascii_lowercase();
            let title = if item.name.trim().is_empty() {
                short_session_id(&command_id)
            } else {
                item.name.trim().to_owned()
            };
            out.push_str("# ");
            out.push_str(&title);
            out.push('\n');
            out.push_str("codex resume ");
            out.push_str(&command_id);
            if item.fast {
                out.push_str(" --full-auto");
            }
            out.push('\n');
        }

        if index + 1 < items.len() {
            out.push('\n');
        }
    }

    out
}

fn deserialize_items(json_text: &str) -> Result<Vec<ConfigItem>> {
    let mut items: Vec<ConfigItem> =
        serde_json::from_str(json_text).context("Failed to parse config item JSON.")?;

    for item in &mut items {
        item.kind = item.kind.trim().to_ascii_lowercase();
        item.id = item.id.trim().to_owned();
        item.name = item.name.trim().to_owned();
        item.command_id = item.command_id.trim().to_ascii_lowercase();
        item.color_hex = normalize_color_hex(&item.color_hex);

        if item.is_group() {
            item.id = normalize_group_id(&item.id);
            if item.name.is_empty() {
                item.name = "Group".to_owned();
            }
            item.command_id.clear();
            item.fast = false;
        } else if item.is_group_end() {
            item.kind = "group_end".to_owned();
            item.id = normalize_group_id(&item.id);
            item.name.clear();
            item.command_id.clear();
            item.color_hex.clear();
            item.fast = false;
        } else {
            if item.command_id.is_empty() {
                item.command_id = item.id.to_ascii_lowercase();
            }
            item.id = item.command_id.clone();
            item.color_hex.clear();
            item.kind = "session".to_owned();
        }
    }

    Ok(items)
}

fn normalize_label(line: &str) -> String {
    let mut label = line.trim().replace("\\#", "#");
    while let Some(next) = label.strip_prefix('#') {
        label = next.trim().to_owned();
    }
    while let Some(next) = label.strip_prefix('*') {
        label = next.trim().to_owned();
    }
    while let Some(next) = label.strip_prefix('-') {
        label = next.trim().to_owned();
    }
    label.trim().to_owned()
}

fn normalize_group_id(id: &str) -> String {
    let mut out = String::new();
    for ch in id.trim().chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if ch == '-' || ch == '_' {
            out.push(ch);
        }
    }
    if out.is_empty() {
        "group".to_owned()
    } else {
        out
    }
}

fn normalize_color_hex(color: &str) -> String {
    let trimmed = color.trim();
    if let Some(rest) = trimmed.strip_prefix('#') {
        if rest.len() == 6 && rest.chars().all(|ch| ch.is_ascii_hexdigit()) {
            return format!("#{}", rest.to_ascii_uppercase());
        }
    }
    "#83A598".to_owned()
}

fn short_session_id(id: &str) -> String {
    id.rsplit('-').next().unwrap_or(id).to_owned()
}

#[cfg(test)]
mod tests {
    use super::{collect_output_text, parse_markdown_items, render_markdown_items};

    #[test]
    fn parses_groups_and_sessions() {
        let text = "<!-- context-group: work|Work|#FB4934 -->\n\n# First\ncodex resume 11111111-1111-1111-1111-111111111111\n\n# Second\ncodex fork 22222222-2222-2222-2222-222222222222\n\n<!-- /context-group -->\n";
        let (items, warnings) = parse_markdown_items(text);

        assert!(warnings.is_empty());
        assert_eq!(items.len(), 4);
        assert_eq!(items[0].kind, "group");
        assert_eq!(items[0].color_hex, "#FB4934");
        assert_eq!(items[1].kind, "session");
        assert_eq!(items[2].command_id, "22222222-2222-2222-2222-222222222222");
        assert!(!items[1].fast);
        assert_eq!(items[3].kind, "group_end");
    }

    #[test]
    fn parses_fast_sessions() {
        let text = "# Fast\ncodex resume 11111111-1111-1111-1111-111111111111 --full-auto\n";
        let (items, warnings) = parse_markdown_items(text);

        assert!(warnings.is_empty());
        assert_eq!(items.len(), 1);
        assert!(items[0].fast);
    }

    #[test]
    fn renders_grouped_markdown() {
        let text = render_markdown_items(&[
            super::ConfigItem {
                kind: "group".to_owned(),
                id: "work".to_owned(),
                name: "Work".to_owned(),
                command_id: String::new(),
                color_hex: "#FB4934".to_owned(),
                fast: false,
            },
            super::ConfigItem {
                kind: "session".to_owned(),
                id: "11111111-1111-1111-1111-111111111111".to_owned(),
                name: "First".to_owned(),
                command_id: "11111111-1111-1111-1111-111111111111".to_owned(),
                color_hex: String::new(),
                fast: true,
            },
            super::ConfigItem {
                kind: "group_end".to_owned(),
                id: "work".to_owned(),
                name: String::new(),
                command_id: String::new(),
                color_hex: String::new(),
                fast: false,
            },
        ]);

        assert_eq!(
            text,
            "<!-- context-group: work|Work|#FB4934 -->\n\n# First\ncodex resume 11111111-1111-1111-1111-111111111111 --full-auto\n\n<!-- /context-group -->\n"
        );
    }

    #[test]
    fn collects_assistant_output_text() {
        let payload = serde_json::json!({
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "output_text", "text": "First line"},
                {"type": "output_text", "text": "Second line"},
                {"type": "input_text", "text": "ignored"}
            ]
        });

        assert_eq!(collect_output_text(&payload), "First line\n\nSecond line");
    }
}
