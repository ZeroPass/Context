use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
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
    InitApp, LoadConfig, OpFinished, RefreshRecent, SaveConfig, SetThemeSeed, UiState,
};

const PROVIDER_CODEX: &str = "codex";
const PROVIDER_KIMI: &str = "kimi";
const RECENT_LIMIT: usize = 3;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ConfigItem {
    kind: String,
    id: String,
    name: String,
    command_id: String,
    color_hex: String,
    #[serde(default = "default_provider")]
    provider: String,
    #[serde(default)]
    fast: bool,
}

fn default_provider() -> String {
    PROVIDER_CODEX.to_owned()
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct RecentContext {
    provider: String,
    id: String,
    title: String,
    updated_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    forked_from_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    work_dir: Option<String>,
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
}

#[derive(Debug)]
struct LoadedRecent {
    codex: Vec<RecentContext>,
    kimi: Vec<RecentContext>,
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
    recent_codex: Vec<RecentContext>,
    recent_kimi: Vec<RecentContext>,
    recent_busy: bool,
    recent_status: Option<String>,
    _owned_tasks: JoinSet<()>,
}

impl Actor for ContextActor {}

impl ContextActor {
    pub fn new(self_addr: Address<Self>) -> Self {
        let mut owned = JoinSet::new();
        owned.spawn(Self::forward_dart_signal::<InitApp>(self_addr.clone()));
        owned.spawn(Self::forward_dart_signal::<LoadConfig>(self_addr.clone()));
        owned.spawn(Self::forward_dart_signal::<RefreshRecent>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<SaveConfig>(self_addr.clone()));
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
            recent_codex: Vec::new(),
            recent_kimi: Vec::new(),
            recent_busy: false,
            recent_status: Some("Recent sessions not loaded.".to_owned()),
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
        let recent_codex_json =
            serde_json::to_string(&self.recent_codex).unwrap_or_else(|_| "[]".to_owned());
        let recent_kimi_json =
            serde_json::to_string(&self.recent_kimi).unwrap_or_else(|_| "[]".to_owned());

        UiState {
            theme_seed_color_value: self.theme_seed_color_value,
            busy: self.busy,
            status: self.status.clone(),
            last_error: self.last_error.clone(),
            sessions_markdown_path: self.sessions_markdown_path.clone(),
            items_json,
            warnings_json,
            recent_codex_json,
            recent_kimi_json,
            recent_busy: self.recent_busy,
            recent_status: self.recent_status.clone(),
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
            let next_path = path.trim().to_owned();
            if next_path != self.sessions_markdown_path {
                self.recent_codex.clear();
                self.recent_kimi.clear();
                self.recent_status = Some("Recent sessions not loaded.".to_owned());
            }
            self.sessions_markdown_path = next_path;
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
                self.status = Some(loaded.status);
                self.last_error = None;
            }
            Ok(Err(error)) => {
                self.items.clear();
                self.warnings.clear();
                self.last_error = Some(error.to_string());
                self.status = Some(format!("Load failed: {error}"));
            }
            Err(error) => {
                self.items.clear();
                self.warnings.clear();
                self.last_error = Some(error.to_string());
                self.status = Some(format!("Load failed: {error}"));
            }
        }

        self.busy = false;
        self.emit_state();
        self.last_error.is_none()
    }

    async fn refresh_recent(&mut self, path_override: Option<String>) -> Result<()> {
        if self.recent_busy || self.busy || !self.initialized {
            return Ok(());
        }

        if let Some(path) = path_override {
            self.sessions_markdown_path = path.trim().to_owned();
        }

        self.recent_busy = true;
        self.recent_status = Some("Refreshing recent sessions...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let result = spawn_blocking(move || load_recent_file(&path)).await;

        let outcome = match result {
            Ok(Ok(loaded)) => {
                self.recent_codex = loaded.codex;
                self.recent_kimi = loaded.kimi;
                self.recent_status = Some(loaded.status);
                Ok(())
            }
            Ok(Err(error)) => {
                self.recent_status = Some(format!("Recent refresh failed: {error}"));
                Err(error)
            }
            Err(error) => {
                let error = anyhow!("Recent refresh task failed: {error}");
                self.recent_status = Some(error.to_string());
                Err(error)
            }
        };

        self.recent_busy = false;
        self.emit_state();
        outcome
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
        let ok = self.load_config(Some(msg.sessions_markdown_path)).await;
        self.finish_op(msg.request_id, ok, self.last_error.clone());
    }
}

#[async_trait]
impl Notifiable<RefreshRecent> for ContextActor {
    async fn notify(&mut self, msg: RefreshRecent, _: &Context<Self>) {
        match self.refresh_recent(Some(msg.sessions_markdown_path)).await {
            Ok(()) => self.finish_op(msg.request_id, true, None),
            Err(error) => self.finish_op(msg.request_id, false, Some(error.to_string())),
        }
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
            status: "Pick a sessions markdown file.".to_owned(),
        });
    }

    let path = PathBuf::from(path_str);
    if !path.is_file() {
        return Ok(LoadedConfig {
            items: Vec::new(),
            warnings: vec![format!("Markdown file not found: {}", path.display())],
            status: format!("Markdown file not found: {}", path.display()),
        });
    }

    let text = fs::read_to_string(&path)
        .with_context(|| format!("Failed to read markdown file: {}", path.display()))?;
    let (items, warnings) = parse_markdown_items(&text);

    Ok(LoadedConfig {
        status: format!("Loaded {} item(s) from {}", items.len(), path.display()),
        items,
        warnings,
    })
}

fn load_recent_file(path_str: &str) -> Result<LoadedRecent> {
    let path_str = path_str.trim();
    if path_str.is_empty() {
        return Ok(LoadedRecent {
            codex: Vec::new(),
            kimi: Vec::new(),
            status: "Pick a sessions markdown file first.".to_owned(),
        });
    }

    let (codex, codex_status) = match load_recent_codex_contexts(path_str) {
        Ok(items) => {
            let count = items.len();
            (items, format!("Codex {count}"))
        }
        Err(error) => (Vec::new(), format!("Codex unavailable: {error}")),
    };
    let (kimi, kimi_status) = match load_recent_kimi_contexts(path_str) {
        Ok(items) => {
            let count = items.len();
            (items, format!("Kimi {count}"))
        }
        Err(error) => (Vec::new(), format!("Kimi unavailable: {error}")),
    };

    Ok(LoadedRecent {
        codex,
        kimi,
        status: format!("{codex_status}  /  {kimi_status}"),
    })
}

fn load_recent_codex_contexts(markdown_path: &str) -> Result<Vec<RecentContext>> {
    let Some(db_path) = infer_codex_db_path(markdown_path) else {
        return Ok(Vec::new());
    };

    if !db_path.is_file() {
        return Ok(Vec::new());
    }

    let codex_home = db_path.parent();
    match query_recent_codex_contexts(&db_path, codex_home) {
        Ok(items) => Ok(items),
        Err(error) if is_locked_sqlite_error(&error) => {
            let snapshot = snapshot_sqlite_database(&db_path)?;
            let result = query_recent_codex_contexts(&snapshot, codex_home)
                .with_context(|| format!("Failed to read snapshot of {}", db_path.display()));
            let _ = remove_snapshot_database(&snapshot);
            result
        }
        Err(error) => Err(error).with_context(|| format!("Failed to read {}", db_path.display())),
    }
}

fn query_recent_codex_contexts(
    db_path: &PathBuf,
    codex_home: Option<&Path>,
) -> rusqlite::Result<Vec<RecentContext>> {
    let connection = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let _ = connection.busy_timeout(Duration::from_millis(250));
    let has_cwd = sqlite_table_has_column(&connection, "threads", "cwd")?;
    let query = if has_cwd {
        "SELECT id, title, updated_at, rollout_path, cwd
         FROM threads
         WHERE archived = 0
         ORDER BY updated_at DESC
         LIMIT 6"
    } else {
        "SELECT id, title, updated_at, rollout_path
         FROM threads
         WHERE archived = 0
         ORDER BY updated_at DESC
         LIMIT 6"
    };
    let mut statement = connection.prepare(query)?;

    let rows = statement.query_map([], |row| {
        let rollout_path = row.get::<_, String>(3)?;
        let resolved_rollout = resolve_codex_rollout_path(codex_home, &rollout_path);
        Ok(RecentContext {
            provider: PROVIDER_CODEX.to_owned(),
            id: row.get::<_, String>(0)?,
            title: row.get::<_, String>(1)?,
            updated_at: normalize_epoch_millis(row.get::<_, i64>(2)?),
            forked_from_id: read_forked_from_id(&resolved_rollout).ok().flatten(),
            work_dir: if has_cwd {
                row.get::<_, Option<String>>(4)?
            } else {
                None
            },
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
        if items.len() == RECENT_LIMIT {
            break;
        }
    }

    Ok(items)
}

fn resolve_codex_rollout_path(codex_home: Option<&Path>, raw_path: &str) -> PathBuf {
    let direct = PathBuf::from(raw_path);
    if direct.is_file() {
        return direct;
    }

    let normalized = raw_path.replace('\\', "/");
    if let (Some(codex_home), Some((_, relative))) = (codex_home, normalized.split_once("/.codex/"))
    {
        return codex_home.join(relative);
    }
    direct
}

#[derive(Clone, Debug)]
struct KimiIndexEntry {
    id: String,
    session_dir: PathBuf,
    work_dir: Option<String>,
}

fn load_recent_kimi_contexts(markdown_path: &str) -> Result<Vec<RecentContext>> {
    let Some(kimi_home) = infer_kimi_home(markdown_path) else {
        return Ok(Vec::new());
    };
    if !kimi_home.is_dir() {
        return Ok(Vec::new());
    }

    let mut entries = std::collections::HashMap::<String, KimiIndexEntry>::new();
    let mut deleted = std::collections::HashSet::<String>::new();
    let index_path = kimi_home.join("session_index.jsonl");
    if index_path.is_file() {
        let file = fs::File::open(&index_path)
            .with_context(|| format!("Failed to open {}", index_path.display()))?;
        for line in BufReader::new(file).lines() {
            let Ok(line) = line else {
                continue;
            };
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) else {
                continue;
            };
            let Some(id) = value
                .get("sessionId")
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
            else {
                continue;
            };
            if value.get("deleted").and_then(serde_json::Value::as_bool) == Some(true) {
                entries.remove(id);
                deleted.insert(id.to_owned());
                continue;
            }
            let Some(raw_session_dir) = value
                .get("sessionDir")
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
            else {
                continue;
            };
            let session_dir = resolve_kimi_session_dir(&kimi_home, raw_session_dir);
            deleted.remove(id);
            let work_dir = value
                .get("workDir")
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(ToOwned::to_owned);
            entries.insert(
                id.to_owned(),
                KimiIndexEntry {
                    id: id.to_owned(),
                    session_dir,
                    work_dir,
                },
            );
        }
    }

    for discovered in discover_kimi_session_dirs(&kimi_home) {
        if !deleted.contains(&discovered.id) {
            entries.entry(discovered.id.clone()).or_insert(discovered);
        }
    }

    let mut recent = Vec::new();
    for entry in entries.into_values() {
        let state_path = entry.session_dir.join("state.json");
        if !state_path.is_file() {
            continue;
        }
        let Ok(text) = fs::read_to_string(&state_path) else {
            continue;
        };
        let Ok(state) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        if state.get("archived").and_then(serde_json::Value::as_bool) == Some(true) {
            continue;
        }

        let title = ["customTitle", "title", "lastPrompt"]
            .iter()
            .find_map(|key| {
                state
                    .get(key)
                    .and_then(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
            })
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| short_session_id(&entry.id));
        let updated_at = state
            .get("updatedAt")
            .and_then(parse_kimi_timestamp)
            .or_else(|| state.get("createdAt").and_then(parse_kimi_timestamp))
            .unwrap_or_else(|| modified_at_ms(&state_path));
        let work_dir = ["workDir", "cwd"]
            .iter()
            .find_map(|key| {
                state
                    .get(key)
                    .and_then(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
            })
            .map(ToOwned::to_owned)
            .or(entry.work_dir);
        let forked_from_id = state
            .get("forkedFrom")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned);

        recent.push(RecentContext {
            provider: PROVIDER_KIMI.to_owned(),
            id: entry.id,
            title,
            updated_at,
            forked_from_id,
            work_dir,
        });
    }

    recent.sort_by_key(|item| std::cmp::Reverse(item.updated_at));
    recent.truncate(RECENT_LIMIT);
    Ok(recent)
}

fn infer_kimi_home(markdown_path: &str) -> Option<PathBuf> {
    if let Some(explicit) = std::env::var_os("KIMI_CODE_HOME") {
        let path = PathBuf::from(explicit);
        if path.is_dir() {
            return Some(path);
        }
    }
    infer_user_home_root(markdown_path).map(|root| root.join(".kimi-code"))
}

fn resolve_kimi_session_dir(kimi_home: &Path, raw_session_dir: &str) -> PathBuf {
    let direct = PathBuf::from(raw_session_dir);
    if direct.is_dir() {
        return direct;
    }

    let normalized = raw_session_dir.replace('\\', "/");
    if let Some((_, relative)) = normalized.split_once("/sessions/") {
        return kimi_home.join("sessions").join(relative);
    }
    direct
}

fn discover_kimi_session_dirs(kimi_home: &Path) -> Vec<KimiIndexEntry> {
    let sessions_root = kimi_home.join("sessions");
    let Ok(buckets) = fs::read_dir(&sessions_root) else {
        return Vec::new();
    };

    let mut entries = Vec::new();
    for bucket in buckets.flatten() {
        let bucket_path = bucket.path();
        if !bucket_path.is_dir() {
            continue;
        }
        let Ok(sessions) = fs::read_dir(bucket_path) else {
            continue;
        };
        for session in sessions.flatten() {
            let session_dir = session.path();
            if !session_dir.is_dir() {
                continue;
            }
            let id = session.file_name().to_string_lossy().trim().to_owned();
            if id.is_empty() {
                continue;
            }
            entries.push(KimiIndexEntry {
                id,
                session_dir,
                work_dir: None,
            });
        }
    }
    entries
}

fn parse_kimi_timestamp(value: &serde_json::Value) -> Option<i64> {
    if let Some(number) = value.as_i64() {
        return Some(normalize_epoch_millis(number));
    }
    if let Some(number) = value.as_u64() {
        return i64::try_from(number).ok().map(normalize_epoch_millis);
    }
    value.as_str().and_then(parse_iso8601_utc_ms)
}

fn normalize_epoch_millis(value: i64) -> i64 {
    if value.unsigned_abs() < 100_000_000_000 {
        value.saturating_mul(1_000)
    } else {
        value
    }
}

fn sqlite_table_has_column(
    connection: &Connection,
    table: &str,
    target_column: &str,
) -> rusqlite::Result<bool> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement.query_map([], |row| row.get::<_, String>(1))?;
    for column in columns {
        if column? == target_column {
            return Ok(true);
        }
    }
    Ok(false)
}

fn parse_iso8601_utc_ms(value: &str) -> Option<i64> {
    let bytes = value.as_bytes();
    if bytes.len() < 19
        || bytes.get(4) != Some(&b'-')
        || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T')
        || bytes.get(13) != Some(&b':')
        || bytes.get(16) != Some(&b':')
    {
        return None;
    }

    let year = parse_decimal(bytes, 0, 4)?;
    let month = parse_decimal(bytes, 5, 7)?;
    let day = parse_decimal(bytes, 8, 10)?;
    let hour = parse_decimal(bytes, 11, 13)?;
    let minute = parse_decimal(bytes, 14, 16)?;
    let second = parse_decimal(bytes, 17, 19)?;
    let millis = if bytes.get(19) == Some(&b'.') {
        let mut out = 0_i64;
        let mut digits = 0;
        for byte in bytes.iter().skip(20) {
            if !byte.is_ascii_digit() || digits == 3 {
                break;
            }
            out = out * 10 + i64::from(byte - b'0');
            digits += 1;
        }
        while digits < 3 {
            out *= 10;
            digits += 1;
        }
        out
    } else {
        0
    };

    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let days = days_from_civil(year, month, day);
    Some((((days * 24 + hour) * 60 + minute) * 60 + second) * 1000 + millis)
}

fn parse_decimal(bytes: &[u8], start: usize, end: usize) -> Option<i64> {
    let mut value = 0_i64;
    for byte in bytes.get(start..end)? {
        if !byte.is_ascii_digit() {
            return None;
        }
        value = value * 10 + i64::from(byte - b'0');
    }
    Some(value)
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = year - if month <= 2 { 1 } else { 0 };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let adjusted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn modified_at_ms(path: &Path) -> i64 {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .and_then(|duration| i64::try_from(duration.as_millis()).ok())
        .unwrap_or_default()
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
            matches!(
                inner.code,
                ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked
            )
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

fn remove_snapshot_database(snapshot_db: &Path) -> Result<()> {
    let Some(dir) = snapshot_db.parent() else {
        return Ok(());
    };
    fs::remove_dir_all(dir).with_context(|| format!("Failed to remove {}", dir.display()))
}

fn infer_codex_db_path(markdown_path: &str) -> Option<PathBuf> {
    let home_root = infer_user_home_root(markdown_path)?;
    Some(home_root.join(".codex").join("state_5.sqlite"))
}

fn infer_user_home_root(markdown_path: &str) -> Option<PathBuf> {
    let trimmed = markdown_path.trim();
    let normalized = trimmed.replace('\\', "/");

    if !normalized.is_empty()
        && let Some(prefix) = normalized.strip_suffix("/codex sessions.md")
        && let Some(home_root) = prefix.strip_suffix("/codex-out")
    {
        if trimmed.contains('\\') {
            return Some(PathBuf::from(home_root.replace('/', "\\")));
        }
        return Some(PathBuf::from(home_root));
    }

    std::env::var_os("HOME").map(PathBuf::from)
}

fn save_config_file(path_str: &str, items: &[ConfigItem]) -> Result<String> {
    let path_str = path_str.trim();
    if path_str.is_empty() {
        return Err(anyhow!("Pick a markdown file before saving."));
    }

    let path = PathBuf::from(path_str);
    if let Some(parent) = path.parent()
        && !parent.as_os_str().is_empty()
    {
        fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
    }

    let text = render_markdown_items(items);
    fs::write(&path, text).with_context(|| format!("Failed to write {}", path.display()))?;
    Ok(format!(
        "Saved {} item(s) to {}",
        items.len(),
        path.display()
    ))
}

#[derive(Debug, PartialEq, Eq)]
struct ParsedSessionCommand {
    provider: String,
    command_id: String,
    fast: bool,
}

fn parse_session_command(line: &str) -> Option<ParsedSessionCommand> {
    let command = line.rsplit("&&").next()?.trim();
    let tokens = command.split_whitespace().collect::<Vec<_>>();
    let executable = tokens
        .first()?
        .trim_matches(['\'', '"'])
        .to_ascii_lowercase();

    if executable == PROVIDER_CODEX {
        if tokens.len() < 3 || !matches!(tokens[1].to_ascii_lowercase().as_str(), "resume" | "fork")
        {
            return None;
        }
        let command_id = normalize_session_id(tokens[2], PROVIDER_CODEX)?;
        let lower = command.to_ascii_lowercase();
        let fast = lower.contains("--full-auto")
            || (lower.contains("service_tier") && lower.contains("fast"));
        return Some(ParsedSessionCommand {
            provider: PROVIDER_CODEX.to_owned(),
            command_id,
            fast,
        });
    }

    if executable == PROVIDER_KIMI {
        for (index, token) in tokens.iter().enumerate().skip(1) {
            let normalized = token.to_ascii_lowercase();
            if let Some((flag, value)) = normalized.split_once('=')
                && matches!(flag, "--session" | "--resume" | "-s" | "-r")
            {
                let command_id = normalize_session_id(value, PROVIDER_KIMI)?;
                return Some(ParsedSessionCommand {
                    provider: PROVIDER_KIMI.to_owned(),
                    command_id,
                    fast: false,
                });
            }
            if matches!(normalized.as_str(), "--session" | "--resume" | "-s" | "-r") {
                let command_id = normalize_session_id(tokens.get(index + 1)?, PROVIDER_KIMI)?;
                return Some(ParsedSessionCommand {
                    provider: PROVIDER_KIMI.to_owned(),
                    command_id,
                    fast: false,
                });
            }
        }
    }

    None
}

fn normalize_session_id(value: &str, provider: &str) -> Option<String> {
    let trimmed = value
        .trim()
        .trim_matches(['\'', '"'])
        .trim_end_matches([',', ';']);
    if trimmed.is_empty()
        || !trimmed
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.'))
    {
        return None;
    }
    Some(if provider == PROVIDER_CODEX {
        trimmed.to_ascii_lowercase()
    } else {
        trimmed.to_owned()
    })
}

fn normalize_provider(value: &str) -> String {
    if value.trim().eq_ignore_ascii_case(PROVIDER_KIMI) {
        PROVIDER_KIMI.to_owned()
    } else {
        PROVIDER_CODEX.to_owned()
    }
}

fn parse_markdown_items(text: &str) -> (Vec<ConfigItem>, Vec<String>) {
    let group_re =
        match Regex::new(r"(?i)^<!--\s*context-group:\s*([^|>]+)\|([^|>]+)\|(#[0-9a-f]{6})\s*-->$")
        {
            Ok(regex) => regex,
            Err(error) => return (Vec::new(), vec![format!("Invalid group parser: {error}")]),
        };
    let group_end_re = match Regex::new(r"(?i)^<!--\s*/context-group\s*-->$") {
        Ok(regex) => regex,
        Err(error) => {
            return (
                Vec::new(),
                vec![format!("Invalid group-end parser: {error}")],
            );
        }
    };

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
                    provider: String::new(),
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
                provider: String::new(),
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
                    provider: String::new(),
                    fast: false,
                }),
                None => warnings.push(format!("Ignored unopened group end marker: {trimmed}")),
            }
            pending_title.clear();
            continue;
        }

        if let Some(command) = parse_session_command(trimmed) {
            let command_id = command.command_id;
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
                provider: command.provider,
                fast: command.fast,
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
            provider: String::new(),
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
            let provider = normalize_provider(&item.provider);
            let command_id = if provider == PROVIDER_CODEX {
                item.command_id.trim().to_ascii_lowercase()
            } else {
                item.command_id.trim().to_owned()
            };
            let title = if item.name.trim().is_empty() {
                short_session_id(&command_id)
            } else {
                item.name.trim().to_owned()
            };
            out.push_str("# ");
            out.push_str(&title);
            out.push('\n');
            if provider == PROVIDER_KIMI {
                out.push_str("kimi --session ");
                out.push_str(&command_id);
            } else {
                out.push_str("codex resume ");
                out.push_str(&command_id);
                if item.fast {
                    out.push_str(" -c 'service_tier=\"fast\"'");
                }
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
        item.provider = normalize_provider(&item.provider);
        item.command_id = if item.provider == PROVIDER_CODEX {
            item.command_id.trim().to_ascii_lowercase()
        } else {
            item.command_id.trim().to_owned()
        };
        item.color_hex = normalize_color_hex(&item.color_hex);

        if item.is_group() {
            item.id = normalize_group_id(&item.id);
            if item.name.is_empty() {
                item.name = "Group".to_owned();
            }
            item.command_id.clear();
            item.provider.clear();
            item.fast = false;
        } else if item.is_group_end() {
            item.kind = "group_end".to_owned();
            item.id = normalize_group_id(&item.id);
            item.name.clear();
            item.command_id.clear();
            item.color_hex.clear();
            item.provider.clear();
            item.fast = false;
        } else {
            if item.command_id.is_empty() {
                item.command_id = if item.provider == PROVIDER_CODEX {
                    item.id.to_ascii_lowercase()
                } else {
                    item.id.clone()
                };
            }
            item.id = item.command_id.clone();
            item.color_hex.clear();
            item.kind = "session".to_owned();
            if item.provider == PROVIDER_KIMI {
                item.fast = false;
            }
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
    if let Some(rest) = trimmed.strip_prefix('#')
        && rest.len() == 6
        && rest.chars().all(|ch| ch.is_ascii_hexdigit())
    {
        return format!("#{}", rest.to_ascii_uppercase());
    }
    "#83A598".to_owned()
}

fn short_session_id(id: &str) -> String {
    id.rsplit('-').next().unwrap_or(id).to_owned()
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{
        ConfigItem, PROVIDER_CODEX, PROVIDER_KIMI, load_recent_kimi_contexts, parse_iso8601_utc_ms,
        parse_markdown_items, parse_session_command, render_markdown_items,
    };

    #[test]
    fn parses_groups_and_both_providers() {
        let text = "<!-- context-group: work|Work|#FB4934 -->\n\n# First\ncodex resume 11111111-1111-1111-1111-111111111111\n\n# Second\nkimi --session session_22222222-2222-2222-2222-222222222222\n\n<!-- /context-group -->\n";
        let (items, warnings) = parse_markdown_items(text);

        assert!(warnings.is_empty());
        assert_eq!(items.len(), 4);
        assert_eq!(items[0].kind, "group");
        assert_eq!(items[0].color_hex, "#FB4934");
        assert_eq!(items[1].kind, "session");
        assert_eq!(items[1].provider, PROVIDER_CODEX);
        assert_eq!(items[2].provider, PROVIDER_KIMI);
        assert_eq!(
            items[2].command_id,
            "session_22222222-2222-2222-2222-222222222222"
        );
        assert!(!items[1].fast);
        assert!(!items[2].fast);
        assert_eq!(items[3].kind, "group_end");
    }

    #[test]
    fn upgrades_legacy_codex_fast_command() {
        let text = "# Fast\ncodex resume 11111111-1111-1111-1111-111111111111 --full-auto\n";
        let (items, warnings) = parse_markdown_items(text);

        assert!(warnings.is_empty());
        assert_eq!(items.len(), 1);
        assert!(items[0].fast);
        assert_eq!(
            render_markdown_items(&items),
            "# Fast\ncodex resume 11111111-1111-1111-1111-111111111111 -c 'service_tier=\"fast\"'\n"
        );
    }

    #[test]
    fn kimi_permission_flags_do_not_enable_fast() {
        let parsed = match parse_session_command(
            "cd /home/luka/codex-out && kimi --auto --resume session_1234",
        ) {
            Some(parsed) => parsed,
            None => panic!("Kimi command should parse"),
        };

        assert_eq!(parsed.provider, PROVIDER_KIMI);
        assert_eq!(parsed.command_id, "session_1234");
        assert!(!parsed.fast);
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
                provider: String::new(),
                fast: false,
            },
            ConfigItem {
                kind: "session".to_owned(),
                id: "11111111-1111-1111-1111-111111111111".to_owned(),
                name: "First".to_owned(),
                command_id: "11111111-1111-1111-1111-111111111111".to_owned(),
                color_hex: String::new(),
                provider: PROVIDER_CODEX.to_owned(),
                fast: true,
            },
            ConfigItem {
                kind: "session".to_owned(),
                id: "session_22222222-2222-2222-2222-222222222222".to_owned(),
                name: "Kimi".to_owned(),
                command_id: "session_22222222-2222-2222-2222-222222222222".to_owned(),
                color_hex: String::new(),
                provider: PROVIDER_KIMI.to_owned(),
                fast: false,
            },
            ConfigItem {
                kind: "group_end".to_owned(),
                id: "work".to_owned(),
                name: String::new(),
                command_id: String::new(),
                color_hex: String::new(),
                provider: String::new(),
                fast: false,
            },
        ]);

        assert_eq!(
            text,
            "<!-- context-group: work|Work|#FB4934 -->\n\n# First\ncodex resume 11111111-1111-1111-1111-111111111111 -c 'service_tier=\"fast\"'\n\n# Kimi\nkimi --session session_22222222-2222-2222-2222-222222222222\n\n<!-- /context-group -->\n"
        );
    }

    #[test]
    fn parses_kimi_iso_timestamps() {
        assert_eq!(parse_iso8601_utc_ms("1970-01-01T00:00:00.000Z"), Some(0));
        assert_eq!(
            parse_iso8601_utc_ms("1970-01-01T00:00:01.250Z"),
            Some(1_250)
        );
    }

    #[test]
    fn loads_kimi_recent_sessions_and_honors_tombstones() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root =
            std::env::temp_dir().join(format!("context-kimi-test-{}-{stamp}", std::process::id()));
        let home = root.join("home").join("tester");
        let codex_out = home.join("codex-out");
        let markdown = codex_out.join("codex sessions.md");
        let kimi_home = home.join(".kimi-code");
        let active_dir = kimi_home
            .join("sessions")
            .join("wd_test")
            .join("session_active");
        let deleted_dir = kimi_home
            .join("sessions")
            .join("wd_test")
            .join("session_deleted");
        fs::create_dir_all(codex_out)?;
        fs::create_dir_all(&active_dir)?;
        fs::create_dir_all(&deleted_dir)?;
        fs::write(&markdown, "")?;
        fs::write(
            kimi_home.join("session_index.jsonl"),
            concat!(
                "{\"sessionId\":\"session_active\",\"sessionDir\":\"/home/tester/.kimi-code/sessions/wd_test/session_active\",\"workDir\":\"/home/tester/codex-out\"}\n",
                "{\"sessionId\":\"session_deleted\",\"deleted\":true}\n"
            ),
        )?;
        fs::write(
            active_dir.join("state.json"),
            r#"{"createdAt":"2026-07-26T19:00:00.000Z","updatedAt":"2026-07-26T20:00:01.250Z","title":"Kimi fixture","workDir":"/home/tester/codex-out","forkedFrom":"session_parent"}"#,
        )?;
        fs::write(
            deleted_dir.join("state.json"),
            r#"{"updatedAt":"2026-07-26T21:00:00.000Z","title":"Deleted"}"#,
        )?;

        let recent = load_recent_kimi_contexts(&markdown.to_string_lossy())?;
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].id, "session_active");
        assert_eq!(recent[0].title, "Kimi fixture");
        assert_eq!(recent[0].provider, PROVIDER_KIMI);
        assert_eq!(recent[0].forked_from_id.as_deref(), Some("session_parent"));
        assert_eq!(recent[0].updated_at, 1_785_096_001_250);

        fs::remove_dir_all(root)?;
        Ok(())
    }
}
