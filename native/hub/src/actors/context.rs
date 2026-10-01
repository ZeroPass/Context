#[path = "codex_refresh.rs"]
mod codex_refresh;

#[path = "whiteboard.rs"]
mod whiteboard;

#[cfg(test)]
#[path = "context_refresh_tests.rs"]
mod context_refresh_tests;

use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::Mutex;
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
    ClearCodexManualReset, DeleteCodexAccount, InitApp, LoadCodexAccounts, LoadConfig,
    LoadMuseAccounts, LoadZcodeAccounts, OpFinished, RefreshRecent, RenameCodexAccount,
    SaveCodexAccount, SaveConfig, SetCodexManualReset, SetThemeSeed, SwitchCodexAccount, UiState,
};

const PROVIDER_CODEX: &str = "codex";
const PROVIDER_KIMI: &str = "kimi";
const PROVIDER_OPENCODE: &str = "opencode";
const PROVIDER_QWEN: &str = "qwen";
const PROVIDER_MUSE: &str = "muse";
const PROVIDER_ZCODE: &str = "zcode";
const RECENT_LIMIT: usize = 3;
const RECENT_CANDIDATE_LIMIT: usize = RECENT_LIMIT * 4;
const CODEX_ACCOUNTS_DIR: &str = "context-accounts";
const CODEX_AUTH_FILE: &str = "auth.json";
const CODEX_ACCOUNT_METADATA_FILE: &str = "metadata.json";
const CODEX_USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
const CODEX_USAGE_ERROR: &str = "Weekly usage unavailable (network or parse failure).";
const CODEX_USAGE_CREDENTIAL_ERROR: &str =
    "Weekly usage unavailable: API rejected Codex credentials (HTTP 401/403).";
const CODEX_USAGE_MAX_BODY_BYTES: usize = 512 * 1024;
const CODEX_USAGE_CONNECT_TIMEOUT_SECONDS: u64 = 5;
const CODEX_USAGE_TIMEOUT_SECONDS: u64 = 12;
const MUSE_USAGE_CONNECT_TIMEOUT_SECONDS: u64 = 5;
const MUSE_USAGE_TIMEOUT_SECONDS: u64 = 45;
const MUSE_USAGE_MAX_BODY_BYTES: usize = 512 * 1024;
const MUSE_USAGE_URL_PATH: &str = "/responses";
const MUSE_USAGE_MODEL: &str = "muse-spark-1.3";
const MUSE_USAGE_PROMPT: &str = "Reply with exactly: ok";
// POST body carries no secrets, so it is passed via argv; the Bearer key
// always travels through curl's stdin config, never the argument list.
const MUSE_USAGE_ERROR: &str = "Usage currently unavailable (network or parse failure).";
const MUSE_USAGE_CREDENTIAL_ERROR: &str = "Usage currently unavailable: Muse credentials rejected (HTTP 401/403). Run `muse login` again.";
const CODEX_USAGE_MAX_CONCURRENT_READS: usize = 3;
// ZCode keeps per-request usage rows in its local sqlite database. The weekly
// pace is computed on the Dart side (local timezone anchor), so Rust ships raw
// request samples for a window slightly wider than a week, bounded to keep the
// UI-state JSON small.
// ZCode's API exposes a usage/quota endpoint for coding-plan API keys; the
// desktop app reads the same data for its sidebar ("N% used · Resets <date>").
// The key lives in plaintext in ~/.zcode/v2/config.json under
// provider."builtin:zai-coding-plan".options.apiKey. The response carries both
// the 5-hour and the weekly credit limit; the weekly one (furthest reset) is
// what the sidebar displays and what the card shows, mirroring Codex.
const ZCODE_QUOTA_URL: &str = "https://api.z.ai/api/monitor/usage/quota/limit";
const ZCODE_QUOTA_CONNECT_TIMEOUT_SECONDS: u64 = 5;
const ZCODE_QUOTA_TIMEOUT_SECONDS: u64 = 12;
const ZCODE_QUOTA_MAX_BODY_BYTES: usize = 512 * 1024;
const ZCODE_QUOTA_ERROR: &str = "Usage unavailable (network or parse failure).";
const ZCODE_QUOTA_CREDENTIAL_ERROR: &str =
    "Usage unavailable: API rejected the ZCode credentials (HTTP 401/403).";
// Fallback measurement when the quota endpoint is unreachable: count distinct
// user messages (parent_user_message_id) in the provider-style 5h window from
// ZCode's local request log against the Lite plan's 120-prompts allowance.
const ZCODE_WINDOW_SECONDS: i64 = 5 * 60 * 60;
const ZCODE_PROMPT_QUOTA: i64 = 120;
const ZCODE_USAGE_LOOKBACK_MS: i64 = 48 * 60 * 60 * 1000;
const ZCODE_USAGE_ROW_LIMIT: usize = 50000;
const ZCODE_STATE_NOT_FOUND_ERROR: &str =
    "ZCode state not found (no ~/.zcode cli database or v2 config).";
// Only local metadata transactions take this lock, never token or usage requests.
static CODEX_METADATA_LOCK: Mutex<()> = Mutex::new(());
const CODEX_WEEKLY_WINDOW_MIN_SECONDS: i64 = 6 * 24 * 60 * 60;
// Persisted account fingerprints are FNV-1a over the UTF-8 account ID. The versioned prefix
// makes algorithm changes fail closed instead of reusing history under an incompatible key.
const CODEX_ACCOUNT_KEY_PREFIX: &str = "fnv1a64-v1:";
const CODEX_ACCOUNT_KEY_PAYLOAD_LEN: usize = 16;
const FNV1A_64_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
const FNV1A_64_PRIME: u64 = 0x0000_0100_0000_01b3;
const MAX_CODEX_ACCOUNT_DISPLAY_NAME_CHARS: usize = 256;
#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x08000000;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ConfigItem {
    kind: String,
    id: String,
    name: String,
    command_id: String,
    color_hex: String,
    #[serde(default = "default_provider")]
    provider: String,
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

#[derive(Clone, Debug, Serialize)]
struct CodexAccountMetadata {
    slot: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    updated_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    weekly_used_percent: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    weekly_reset_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    manual_reset_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    weekly_window_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    weekly_error: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct CodexAccountLabels {
    #[serde(flatten)]
    labels: std::collections::BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    manual_reset_at: Option<i64>,
    // Read the former per-slot pins so old metadata remains valid, but never write or use them.
    #[serde(default, rename = "weekly_reset_at", skip_serializing)]
    legacy_weekly_reset_at: Option<std::collections::BTreeMap<String, i64>>,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    weekly_usage_state: std::collections::BTreeMap<String, CodexWeeklyUsageState>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
struct CodexWeeklyUsageState {
    account_key: String,
    used_percent: f64,
    reset_at: i64,
    window_seconds: i64,
}

#[derive(Clone, Debug, PartialEq)]
struct WeeklyUsage {
    used_percent: f64,
    reset_at_ms: Option<i64>,
    reset_after_seconds: Option<i64>,
    window_seconds: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct CodexUsageRequestTiming {
    request_started_at_ms: i64,
    response_received_at_ms: i64,
}

#[derive(Clone, Debug, PartialEq)]
struct CodexUsageQuery {
    usage: WeeklyUsage,
    timing: CodexUsageRequestTiming,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CodexUsageError {
    Unavailable,
    CredentialRejected,
}

impl CodexUsageError {
    fn message(self) -> &'static str {
        match self {
            Self::Unavailable => CODEX_USAGE_ERROR,
            Self::CredentialRejected => CODEX_USAGE_CREDENTIAL_ERROR,
        }
    }
}

#[derive(Clone, Debug)]
struct CodexAccountPaths {
    auth_path: PathBuf,
    accounts_dir: PathBuf,
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
    opencode: Vec<RecentContext>,
    qwen: Vec<RecentContext>,
    muse: Vec<RecentContext>,
    zcode: Vec<RecentContext>,
    status: String,
}

#[derive(Debug)]
struct LoadedCodexAccounts {
    accounts: Vec<CodexAccountMetadata>,
    active_slot: Option<String>,
    active_slot_error: Option<String>,
}

struct CodexAccountsRefreshed {
    generation: u64,
    manual_reset_revision: u64,
    result: Result<LoadedCodexAccounts>,
}

#[derive(Clone, Debug, Serialize)]
struct MuseAccountMetadata {
    slot: String,
    name: String,
    updated_at: Option<i64>,
    tier: Option<String>,
    weekly_used_percent: Option<f64>,
    weekly_reset_at: Option<i64>,
    window_used_percent: Option<f64>,
    window_reset_at: Option<i64>,
    window_duration_mins: Option<i64>,
    muse_error: Option<String>,
}

#[derive(Debug)]
struct LoadedMuseAccounts {
    accounts: Vec<MuseAccountMetadata>,
    active_slot: Option<String>,
}

struct MuseAccountsRefreshed {
    generation: u64,
    result: Result<LoadedMuseAccounts>,
}

#[derive(Clone, Debug, Serialize)]
struct ZcodeAccountMetadata {
    slot: String,
    name: String,
    updated_at: Option<i64>,
    tier: Option<String>,
    used_percent: Option<f64>,
    reset_at: Option<i64>,
    window_seconds: Option<i64>,
    zcode_error: Option<String>,
}

#[derive(Debug)]
struct LoadedZcodeAccounts {
    accounts: Vec<ZcodeAccountMetadata>,
}

struct ZcodeAccountsRefreshed {
    generation: u64,
    result: Result<LoadedZcodeAccounts>,
}

struct RecentRefreshed {
    generation: u64,
    result: Result<LoadedRecent>,
}

struct ContextActor {
    self_addr: Address<Self>,
    path_generation: u64,
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
    recent_opencode: Vec<RecentContext>,
    recent_qwen: Vec<RecentContext>,
    recent_muse: Vec<RecentContext>,
    recent_zcode: Vec<RecentContext>,
    recent_busy: bool,
    recent_status: Option<String>,
    recent_requests: Vec<u64>,
    codex_accounts: Vec<CodexAccountMetadata>,
    codex_active_account: Option<String>,
    codex_account_busy: bool,
    codex_account_status: Option<String>,
    codex_account_error: Option<String>,
    codex_account_refreshing: bool,
    codex_account_requests: Vec<u64>,
    codex_manual_reset_at: Option<i64>,
    codex_manual_reset_revision: u64,
    muse_accounts: Vec<MuseAccountMetadata>,
    muse_active_account: Option<String>,
    muse_account_busy: bool,
    muse_account_status: Option<String>,
    muse_account_error: Option<String>,
    muse_account_refreshing: bool,
    muse_account_requests: Vec<u64>,
    zcode_accounts: Vec<ZcodeAccountMetadata>,
    zcode_account_busy: bool,
    zcode_account_status: Option<String>,
    zcode_account_error: Option<String>,
    zcode_account_refreshing: bool,
    zcode_account_requests: Vec<u64>,
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
        owned.spawn(Self::forward_dart_signal::<LoadCodexAccounts>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<LoadMuseAccounts>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<LoadZcodeAccounts>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<SetCodexManualReset>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<ClearCodexManualReset>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<SaveCodexAccount>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<SwitchCodexAccount>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<RenameCodexAccount>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<DeleteCodexAccount>(
            self_addr.clone(),
        ));
        owned.spawn(Self::forward_dart_signal::<SetThemeSeed>(self_addr.clone()));

        Self {
            self_addr,
            path_generation: 0,
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
            recent_opencode: Vec::new(),
            recent_qwen: Vec::new(),
            recent_muse: Vec::new(),
            recent_zcode: Vec::new(),
            recent_busy: false,
            recent_status: Some("Recent sessions not loaded.".to_owned()),
            recent_requests: Vec::new(),
            codex_accounts: Vec::new(),
            codex_active_account: None,
            codex_account_busy: false,
            codex_account_status: Some("Codex accounts not loaded.".to_owned()),
            codex_account_error: None,
            codex_account_refreshing: false,
            codex_account_requests: Vec::new(),
            codex_manual_reset_at: None,
            codex_manual_reset_revision: 0,
            muse_accounts: Vec::new(),
            muse_active_account: None,
            muse_account_busy: false,
            muse_account_status: Some("Muse accounts not loaded.".to_owned()),
            muse_account_error: None,
            muse_account_refreshing: false,
            muse_account_requests: Vec::new(),
            zcode_accounts: Vec::new(),
            zcode_account_busy: false,
            zcode_account_status: Some("ZCode usage not loaded.".to_owned()),
            zcode_account_error: None,
            zcode_account_refreshing: false,
            zcode_account_requests: Vec::new(),
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
        let recent_opencode_json =
            serde_json::to_string(&self.recent_opencode).unwrap_or_else(|_| "[]".to_owned());
        let recent_qwen_json =
            serde_json::to_string(&self.recent_qwen).unwrap_or_else(|_| "[]".to_owned());
        let recent_muse_json =
            serde_json::to_string(&self.recent_muse).unwrap_or_else(|_| "[]".to_owned());
        let recent_zcode_json =
            serde_json::to_string(&self.recent_zcode).unwrap_or_else(|_| "[]".to_owned());
        let codex_accounts_json =
            serde_json::to_string(&self.codex_accounts).unwrap_or_else(|_| "[]".to_owned());
        let muse_accounts_json =
            serde_json::to_string(&self.muse_accounts).unwrap_or_else(|_| "[]".to_owned());
        let zcode_accounts_json =
            serde_json::to_string(&self.zcode_accounts).unwrap_or_else(|_| "[]".to_owned());

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
            recent_opencode_json,
            recent_qwen_json,
            recent_muse_json,
            recent_zcode_json,
            recent_busy: self.recent_busy,
            recent_status: self.recent_status.clone(),
            codex_accounts_json,
            codex_active_account: self.codex_active_account.clone(),
            codex_account_busy: self.codex_account_busy,
            codex_account_status: self.codex_account_status.clone(),
            codex_account_error: self.codex_account_error.clone(),
            muse_accounts_json,
            muse_active_account: self.muse_active_account.clone(),
            muse_account_busy: self.muse_account_busy,
            muse_account_status: self.muse_account_status.clone(),
            muse_account_error: self.muse_account_error.clone(),
            zcode_accounts_json,
            zcode_account_busy: self.zcode_account_busy,
            zcode_account_status: self.zcode_account_status.clone(),
            zcode_account_error: self.zcode_account_error.clone(),
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

    fn set_sessions_markdown_path(&mut self, path: String) -> bool {
        let next_path = path.trim().to_owned();
        let changed = next_path != self.sessions_markdown_path;
        if changed {
            self.path_generation += 1;
            let requests = std::mem::take(&mut self.codex_account_requests)
                .into_iter()
                .chain(std::mem::take(&mut self.muse_account_requests))
                .chain(std::mem::take(&mut self.zcode_account_requests))
                .chain(std::mem::take(&mut self.recent_requests));
            for request_id in requests {
                self.finish_op(
                    request_id,
                    false,
                    Some("Sessions file changed during refresh.".to_owned()),
                );
            }
            self.recent_codex.clear();
            self.recent_kimi.clear();
            self.recent_opencode.clear();
            self.recent_qwen.clear();
            self.recent_muse.clear();
            self.recent_zcode.clear();
            self.recent_status = Some("Recent sessions not loaded.".to_owned());
            self.codex_accounts.clear();
            self.codex_active_account = None;
            self.codex_account_status = Some("Codex accounts not loaded.".to_owned());
            self.codex_account_error = None;
            self.codex_manual_reset_at = None;
            self.muse_accounts.clear();
            self.muse_active_account = None;
            self.muse_account_status = Some("Muse accounts not loaded.".to_owned());
            self.muse_account_error = None;
            self.zcode_accounts.clear();
            self.zcode_account_status = Some("ZCode usage not loaded.".to_owned());
            self.zcode_account_error = None;
        }
        self.sessions_markdown_path = next_path;
        changed
    }

    fn load_codex_accounts(
        &mut self,
        path_override: Option<String>,
        request_id: u64,
    ) -> Result<()> {
        self.load_codex_accounts_with(path_override, request_id, load_codex_accounts_for_markdown)
    }

    fn load_codex_accounts_with<F>(
        &mut self,
        path_override: Option<String>,
        request_id: u64,
        load: F,
    ) -> Result<()>
    where
        F: FnOnce(&str, &str) -> Result<LoadedCodexAccounts> + Send + 'static,
    {
        if self.codex_account_busy && !self.codex_account_refreshing {
            return Err(anyhow!("Codex account operation is already in progress."));
        }

        if let Some(path) = path_override {
            self.set_sessions_markdown_path(path);
        }

        if request_id != 0 {
            self.codex_account_requests.push(request_id);
        }
        if self.codex_account_refreshing {
            return Ok(());
        }

        self.codex_account_refreshing = true;
        self.codex_account_busy = true;
        self.codex_account_error = None;
        self.codex_account_status = Some("Loading Codex accounts...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let current_slot_hint = self.codex_active_account.clone().unwrap_or_default();
        let generation = self.path_generation;
        let manual_reset_revision = self.codex_manual_reset_revision;
        let mut addr = self.self_addr.clone();
        self.reap_tasks();
        self._owned_tasks.spawn(async move {
            let result = spawn_blocking(move || load(&path, &current_slot_hint))
                .await
                .unwrap_or_else(|_| Err(anyhow!("Could not load Codex accounts.")));
            let _ = addr
                .notify(CodexAccountsRefreshed {
                    generation,
                    manual_reset_revision,
                    result,
                })
                .await;
        });
        Ok(())
    }

    fn reap_tasks(&mut self) {
        while self._owned_tasks.try_join_next().is_some() {}
    }

    fn complete_codex_refresh(&mut self, msg: CodexAccountsRefreshed) {
        self.codex_account_refreshing = false;
        self.codex_account_busy = false;
        if msg.generation != self.path_generation {
            let _ = self.load_codex_accounts(None, 0);
            return;
        }
        let outcome = match msg.result {
            Ok(mut loaded) => {
                // A reset edited after this fetch started wins over its older UI snapshot.
                if msg.manual_reset_revision != self.codex_manual_reset_revision {
                    for account in &mut loaded.accounts {
                        account.manual_reset_at = self.codex_manual_reset_at;
                    }
                } else {
                    self.codex_manual_reset_at = loaded
                        .accounts
                        .first()
                        .and_then(|account| account.manual_reset_at);
                }
                self.codex_accounts = loaded.accounts;
                self.codex_active_account = loaded.active_slot;
                self.codex_account_error = loaded.active_slot_error;
                self.codex_account_status = if self.codex_account_error.is_some() {
                    Some("Could not verify the current Codex account slot.".to_owned())
                } else {
                    Some(format!(
                        "{} saved Codex account(s).",
                        self.codex_accounts.len()
                    ))
                };
                Ok(())
            }
            Err(error) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not load Codex accounts.".to_owned());
                Err(error)
            }
        };

        self.emit_state();
        for request_id in std::mem::take(&mut self.codex_account_requests) {
            self.finish_op(
                request_id,
                outcome.is_ok(),
                outcome.as_ref().err().map(ToString::to_string),
            );
        }
    }

    fn load_muse_accounts(&mut self, path_override: Option<String>, request_id: u64) -> Result<()> {
        if self.muse_account_busy && !self.muse_account_refreshing {
            return Err(anyhow!("Muse account operation is already in progress."));
        }

        if let Some(path) = path_override {
            self.set_sessions_markdown_path(path);
        }

        if request_id != 0 {
            self.muse_account_requests.push(request_id);
        }
        if self.muse_account_refreshing {
            return Ok(());
        }

        self.muse_account_refreshing = true;
        self.muse_account_busy = true;
        self.muse_account_error = None;
        self.muse_account_status = Some("Loading Muse usage...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let generation = self.path_generation;
        let mut addr = self.self_addr.clone();
        self.reap_tasks();
        self._owned_tasks.spawn(async move {
            let result = spawn_blocking(move || load_muse_accounts_for_markdown(&path))
                .await
                .unwrap_or_else(|_| Err(anyhow!("Could not load Muse usage.")));
            let _ = addr
                .notify(MuseAccountsRefreshed { generation, result })
                .await;
        });
        Ok(())
    }

    fn complete_muse_refresh(&mut self, msg: MuseAccountsRefreshed) {
        self.muse_account_refreshing = false;
        self.muse_account_busy = false;
        if msg.generation != self.path_generation {
            let _ = self.load_muse_accounts(None, 0);
            return;
        }
        let outcome = match msg.result {
            Ok(loaded) => {
                self.muse_accounts = loaded.accounts;
                self.muse_active_account = loaded.active_slot;
                self.muse_account_error = self
                    .muse_accounts
                    .first()
                    .and_then(|account| account.muse_error.clone());
                self.muse_account_status = if self.muse_account_error.is_some() {
                    Some("Could not load Muse usage.".to_owned())
                } else {
                    Some("Muse usage updated.".to_owned())
                };
                Ok(())
            }
            Err(error) => {
                self.muse_account_error = Some(error.to_string());
                self.muse_account_status = Some("Could not load Muse usage.".to_owned());
                Err(error)
            }
        };

        self.emit_state();
        for request_id in std::mem::take(&mut self.muse_account_requests) {
            self.finish_op(
                request_id,
                outcome.is_ok(),
                outcome.as_ref().err().map(ToString::to_string),
            );
        }
    }

    fn load_zcode_accounts(
        &mut self,
        path_override: Option<String>,
        request_id: u64,
    ) -> Result<()> {
        if self.zcode_account_busy && !self.zcode_account_refreshing {
            return Err(anyhow!("ZCode account operation is already in progress."));
        }

        if let Some(path) = path_override {
            self.set_sessions_markdown_path(path);
        }

        if request_id != 0 {
            self.zcode_account_requests.push(request_id);
        }
        if self.zcode_account_refreshing {
            return Ok(());
        }

        self.zcode_account_refreshing = true;
        self.zcode_account_busy = true;
        self.zcode_account_error = None;
        self.zcode_account_status = Some("Loading ZCode usage...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let generation = self.path_generation;
        let mut addr = self.self_addr.clone();
        self.reap_tasks();
        self._owned_tasks.spawn(async move {
            let result = spawn_blocking(move || load_zcode_accounts_for_markdown(&path))
                .await
                .unwrap_or_else(|_| Err(anyhow!("Could not load ZCode usage.")));
            let _ = addr
                .notify(ZcodeAccountsRefreshed { generation, result })
                .await;
        });
        Ok(())
    }

    fn complete_zcode_refresh(&mut self, msg: ZcodeAccountsRefreshed) {
        self.zcode_account_refreshing = false;
        self.zcode_account_busy = false;
        if msg.generation != self.path_generation {
            let _ = self.load_zcode_accounts(None, 0);
            return;
        }
        let outcome = match msg.result {
            Ok(loaded) => {
                self.zcode_accounts = loaded.accounts;
                self.zcode_account_error = self
                    .zcode_accounts
                    .first()
                    .and_then(|account| account.zcode_error.clone());
                self.zcode_account_status = if self.zcode_account_error.is_some() {
                    Some("Could not load ZCode usage.".to_owned())
                } else {
                    Some("ZCode usage updated.".to_owned())
                };
                Ok(())
            }
            Err(error) => {
                self.zcode_account_error = Some(error.to_string());
                self.zcode_account_status = Some("Could not load ZCode usage.".to_owned());
                Err(error)
            }
        };

        self.emit_state();
        for request_id in std::mem::take(&mut self.zcode_account_requests) {
            self.finish_op(
                request_id,
                outcome.is_ok(),
                outcome.as_ref().err().map(ToString::to_string),
            );
        }
    }

    async fn update_codex_manual_reset(
        &mut self,
        path: String,
        manual_reset_at: Option<i64>,
    ) -> Result<()> {
        self.set_sessions_markdown_path(path);
        let path = self.sessions_markdown_path.clone();
        let result = spawn_blocking(move || match manual_reset_at {
            Some(value) => set_codex_manual_reset_file(&path, value),
            None => clear_codex_manual_reset_file(&path),
        })
        .await;
        let outcome = match result {
            Ok(Ok(())) => {
                self.codex_manual_reset_revision += 1;
                self.codex_manual_reset_at = manual_reset_at;
                for account in &mut self.codex_accounts {
                    account.manual_reset_at = manual_reset_at;
                }
                Ok(())
            }
            Ok(Err(error)) => Err(error),
            Err(_) => Err(anyhow!("Could not save Codex manual reset.")),
        };

        self.emit_state();
        outcome
    }

    async fn save_codex_account(
        &mut self,
        path: String,
        slot: String,
        display_name: String,
    ) -> Result<()> {
        if self.codex_account_busy {
            return Err(anyhow!("Codex account operation is already in progress."));
        }
        let normalized_slot = match validate_codex_account_slot(&slot) {
            Ok(slot) => slot,
            Err(error) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not save Codex account.".to_owned());
                self.emit_state();
                return Err(error);
            }
        };
        let normalized_display_name = match normalize_codex_account_display_name(&display_name) {
            Ok(display_name) => display_name,
            Err(error) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not save Codex account.".to_owned());
                self.emit_state();
                return Err(error);
            }
        };
        self.set_sessions_markdown_path(path);
        self.codex_account_busy = true;
        self.codex_account_error = None;
        self.codex_account_status = Some(format!("Saving Codex account {normalized_slot}..."));
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let operation_slot = normalized_slot.clone();
        let operation_display_name = normalized_display_name.clone();
        let result = spawn_blocking(move || {
            save_codex_account_file(&path, &operation_slot, &operation_display_name)
        })
        .await;
        let outcome = match result {
            Ok(Ok(accounts)) => {
                self.codex_accounts = accounts;
                self.codex_active_account = Some(normalized_slot.clone());
                self.codex_account_status = Some(format!("Saved Codex account {normalized_slot}."));
                Ok(())
            }
            Ok(Err(error)) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not save Codex account.".to_owned());
                Err(error)
            }
            Err(_) => {
                let error = anyhow!("Could not save Codex account.");
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some(error.to_string());
                Err(error)
            }
        };

        self.codex_account_busy = false;
        self.emit_state();
        outcome
    }

    async fn switch_codex_account(
        &mut self,
        path: String,
        current_slot: String,
        target_slot: String,
    ) -> Result<()> {
        if self.codex_account_busy {
            return Err(anyhow!("Codex account operation is already in progress."));
        }
        let target_slot = match validate_codex_account_slot(&target_slot) {
            Ok(slot) => slot,
            Err(error) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not switch Codex account.".to_owned());
                self.emit_state();
                return Err(error);
            }
        };
        self.set_sessions_markdown_path(path);
        self.codex_account_busy = true;
        self.codex_account_error = None;
        self.codex_account_status = Some(format!("Switching to Codex account {target_slot}..."));
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let operation_current_hint = current_slot;
        let operation_target = target_slot.clone();
        let result = spawn_blocking(move || {
            switch_codex_account_file(&path, &operation_current_hint, &operation_target)
        })
        .await;
        let outcome = match result {
            Ok(Ok(accounts)) => {
                self.codex_accounts = accounts;
                self.codex_active_account = Some(target_slot.clone());
                self.codex_account_status =
                    Some(format!("Switched to Codex account {target_slot}."));
                Ok(())
            }
            Ok(Err(error)) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not switch Codex account.".to_owned());
                Err(error)
            }
            Err(_) => {
                let error = anyhow!("Could not switch Codex account.");
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some(error.to_string());
                Err(error)
            }
        };

        self.codex_account_busy = false;
        self.emit_state();
        outcome
    }

    async fn rename_codex_account(
        &mut self,
        path: String,
        slot: String,
        display_name: String,
    ) -> Result<()> {
        if self.codex_account_busy {
            return Err(anyhow!("Codex account operation is already in progress."));
        }
        let normalized_slot = match validate_codex_account_slot(&slot) {
            Ok(slot) => slot,
            Err(error) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not rename Codex account.".to_owned());
                self.emit_state();
                return Err(error);
            }
        };
        let normalized_display_name = match normalize_codex_account_display_name(&display_name) {
            Ok(display_name) => display_name,
            Err(error) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not rename Codex account.".to_owned());
                self.emit_state();
                return Err(error);
            }
        };
        self.set_sessions_markdown_path(path);
        self.codex_account_busy = true;
        self.codex_account_error = None;
        self.codex_account_status = Some(format!("Renaming Codex account {normalized_slot}..."));
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let operation_slot = normalized_slot.clone();
        let operation_display_name = normalized_display_name.clone();
        let result = spawn_blocking(move || {
            rename_codex_account_file(&path, &operation_slot, &operation_display_name)
        })
        .await;
        let outcome = match result {
            Ok(Ok(accounts)) => {
                self.codex_accounts = accounts;
                self.codex_account_status =
                    Some(format!("Renamed Codex account {normalized_slot}."));
                Ok(())
            }
            Ok(Err(error)) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not rename Codex account.".to_owned());
                Err(error)
            }
            Err(_) => {
                let error = anyhow!("Could not rename Codex account.");
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some(error.to_string());
                Err(error)
            }
        };

        self.codex_account_busy = false;
        self.emit_state();
        outcome
    }

    async fn delete_codex_account(&mut self, path: String, slot: String) -> Result<()> {
        if self.codex_account_busy {
            return Err(anyhow!("Codex account operation is already in progress."));
        }
        let normalized_slot = match validate_codex_account_slot(&slot) {
            Ok(slot) => slot,
            Err(error) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not delete Codex account.".to_owned());
                self.emit_state();
                return Err(error);
            }
        };
        self.set_sessions_markdown_path(path);
        self.codex_account_busy = true;
        self.codex_account_error = None;
        self.codex_account_status = Some(format!("Deleting Codex account {normalized_slot}..."));
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let operation_slot = normalized_slot.clone();
        let result =
            spawn_blocking(move || delete_codex_account_file(&path, &operation_slot)).await;
        let outcome = match result {
            Ok(Ok(accounts)) => {
                self.codex_accounts = accounts;
                if self.codex_active_account.as_deref() == Some(normalized_slot.as_str()) {
                    self.codex_active_account = None;
                }
                self.codex_account_status =
                    Some(format!("Deleted Codex account {normalized_slot}."));
                Ok(())
            }
            Ok(Err(error)) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not delete Codex account.".to_owned());
                Err(error)
            }
            Err(_) => {
                let error = anyhow!("Could not delete Codex account.");
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some(error.to_string());
                Err(error)
            }
        };

        self.codex_account_busy = false;
        self.emit_state();
        outcome
    }

    async fn load_config(&mut self, path_override: Option<String>) -> bool {
        if self.busy || !self.initialized {
            return true;
        }

        if let Some(path) = path_override {
            self.set_sessions_markdown_path(path);
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
        let ok = self.last_error.is_none();
        let _ = self.load_codex_accounts(None, 0);
        ok
    }

    fn refresh_recent(&mut self, path_override: Option<String>, request_id: u64) -> Result<()> {
        if self.busy || !self.initialized {
            self.finish_op(request_id, true, None);
            return Ok(());
        }

        let path_changed = path_override
            .map(|path| self.set_sessions_markdown_path(path))
            .unwrap_or(false);

        if request_id != 0 {
            self.recent_requests.push(request_id);
        }
        if path_changed {
            let _ = self.load_codex_accounts(None, 0);
        }
        if self.recent_busy {
            return Ok(());
        }

        self.recent_busy = true;
        self.recent_status = Some("Refreshing recent sessions...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let generation = self.path_generation;
        let mut addr = self.self_addr.clone();
        self.reap_tasks();
        self._owned_tasks.spawn(async move {
            let result = spawn_blocking(move || load_recent_file(&path))
                .await
                .unwrap_or_else(|_| Err(anyhow!("Recent refresh task failed.")));
            let _ = addr.notify(RecentRefreshed { generation, result }).await;
        });
        Ok(())
    }

    fn complete_recent_refresh(&mut self, msg: RecentRefreshed) {
        self.recent_busy = false;
        if msg.generation != self.path_generation {
            let _ = self.refresh_recent(None, 0);
            return;
        }
        let outcome = match msg.result {
            Ok(loaded) => {
                self.recent_codex = loaded.codex;
                self.recent_kimi = loaded.kimi;
                self.recent_opencode = loaded.opencode;
                self.recent_qwen = loaded.qwen;
                self.recent_muse = loaded.muse;
                self.recent_zcode = loaded.zcode;
                self.recent_status = Some(loaded.status);
                Ok(())
            }
            Err(error) => {
                self.recent_status = Some(format!("Recent refresh failed: {error}"));
                Err(error)
            }
        };

        self.emit_state();
        for request_id in std::mem::take(&mut self.recent_requests) {
            self.finish_op(
                request_id,
                outcome.is_ok(),
                outcome.as_ref().err().map(ToString::to_string),
            );
        }
    }

    async fn save_config(&mut self, path: String, items_json: String) -> Result<()> {
        let path = path.trim().to_owned();
        let items = deserialize_items(&items_json)?;

        let path_changed = self.set_sessions_markdown_path(path.clone());
        self.items = items.clone();
        self.last_error = None;
        self.busy = true;
        self.status = Some("Saving config...".to_owned());
        self.emit_state();

        let result = spawn_blocking(move || save_config_file(&path, &items)).await;

        let outcome = match result {
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
        };
        if path_changed {
            let _ = self.load_codex_accounts(None, 0);
        }
        outcome
    }
}

pub async fn create_actors() {
    tokio::spawn(whiteboard::listen());
    tokio::spawn(whiteboard::listen_files());
    let context = Context::new();
    let addr = context.address();
    let actor = ContextActor::new(addr);
    tokio::spawn(context.run(actor));
}

#[async_trait]
impl Notifiable<InitApp> for ContextActor {
    async fn notify(&mut self, msg: InitApp, _: &Context<Self>) {
        self.theme_seed_color_value = msg.theme_seed_color_value;
        self.set_sessions_markdown_path(msg.sessions_markdown_path);
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
        if let Err(error) = self.refresh_recent(Some(msg.sessions_markdown_path), msg.request_id) {
            self.finish_op(msg.request_id, false, Some(error.to_string()));
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
impl Notifiable<LoadCodexAccounts> for ContextActor {
    async fn notify(&mut self, msg: LoadCodexAccounts, _: &Context<Self>) {
        if let Err(error) =
            self.load_codex_accounts(Some(msg.sessions_markdown_path), msg.request_id)
        {
            self.finish_op(msg.request_id, false, Some(error.to_string()));
        }
    }
}

#[async_trait]
impl Notifiable<CodexAccountsRefreshed> for ContextActor {
    async fn notify(&mut self, msg: CodexAccountsRefreshed, _: &Context<Self>) {
        self.complete_codex_refresh(msg);
    }
}

#[async_trait]
impl Notifiable<LoadMuseAccounts> for ContextActor {
    async fn notify(&mut self, msg: LoadMuseAccounts, _: &Context<Self>) {
        if let Err(error) =
            self.load_muse_accounts(Some(msg.sessions_markdown_path), msg.request_id)
        {
            self.finish_op(msg.request_id, false, Some(error.to_string()));
        }
    }
}

#[async_trait]
impl Notifiable<MuseAccountsRefreshed> for ContextActor {
    async fn notify(&mut self, msg: MuseAccountsRefreshed, _: &Context<Self>) {
        self.complete_muse_refresh(msg);
    }
}

#[async_trait]
impl Notifiable<LoadZcodeAccounts> for ContextActor {
    async fn notify(&mut self, msg: LoadZcodeAccounts, _: &Context<Self>) {
        if let Err(error) =
            self.load_zcode_accounts(Some(msg.sessions_markdown_path), msg.request_id)
        {
            self.finish_op(msg.request_id, false, Some(error.to_string()));
        }
    }
}

#[async_trait]
impl Notifiable<ZcodeAccountsRefreshed> for ContextActor {
    async fn notify(&mut self, msg: ZcodeAccountsRefreshed, _: &Context<Self>) {
        self.complete_zcode_refresh(msg);
    }
}

#[async_trait]
impl Notifiable<RecentRefreshed> for ContextActor {
    async fn notify(&mut self, msg: RecentRefreshed, _: &Context<Self>) {
        self.complete_recent_refresh(msg);
    }
}

#[async_trait]
impl Notifiable<SetCodexManualReset> for ContextActor {
    async fn notify(&mut self, msg: SetCodexManualReset, _: &Context<Self>) {
        match self
            .update_codex_manual_reset(msg.sessions_markdown_path, Some(msg.manual_reset_at))
            .await
        {
            Ok(()) => self.finish_op(msg.request_id, true, None),
            Err(error) => self.finish_op(msg.request_id, false, Some(error.to_string())),
        }
    }
}

#[async_trait]
impl Notifiable<ClearCodexManualReset> for ContextActor {
    async fn notify(&mut self, msg: ClearCodexManualReset, _: &Context<Self>) {
        match self
            .update_codex_manual_reset(msg.sessions_markdown_path, None)
            .await
        {
            Ok(()) => self.finish_op(msg.request_id, true, None),
            Err(error) => self.finish_op(msg.request_id, false, Some(error.to_string())),
        }
    }
}

#[async_trait]
impl Notifiable<SaveCodexAccount> for ContextActor {
    async fn notify(&mut self, msg: SaveCodexAccount, _: &Context<Self>) {
        match self
            .save_codex_account(msg.sessions_markdown_path, msg.slot, msg.display_name)
            .await
        {
            Ok(()) => self.finish_op(msg.request_id, true, None),
            Err(error) => self.finish_op(msg.request_id, false, Some(error.to_string())),
        }
    }
}

#[async_trait]
impl Notifiable<SwitchCodexAccount> for ContextActor {
    async fn notify(&mut self, msg: SwitchCodexAccount, _: &Context<Self>) {
        match self
            .switch_codex_account(
                msg.sessions_markdown_path,
                msg.current_slot,
                msg.target_slot,
            )
            .await
        {
            Ok(()) => self.finish_op(msg.request_id, true, None),
            Err(error) => self.finish_op(msg.request_id, false, Some(error.to_string())),
        }
    }
}

#[async_trait]
impl Notifiable<RenameCodexAccount> for ContextActor {
    async fn notify(&mut self, msg: RenameCodexAccount, _: &Context<Self>) {
        match self
            .rename_codex_account(msg.sessions_markdown_path, msg.slot, msg.display_name)
            .await
        {
            Ok(()) => self.finish_op(msg.request_id, true, None),
            Err(error) => self.finish_op(msg.request_id, false, Some(error.to_string())),
        }
    }
}

#[async_trait]
impl Notifiable<DeleteCodexAccount> for ContextActor {
    async fn notify(&mut self, msg: DeleteCodexAccount, _: &Context<Self>) {
        match self
            .delete_codex_account(msg.sessions_markdown_path, msg.slot)
            .await
        {
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
            opencode: Vec::new(),
            qwen: Vec::new(),
            muse: Vec::new(),
            zcode: Vec::new(),
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
    let (opencode, opencode_status) = match load_recent_opencode_contexts(path_str) {
        Ok(items) => {
            let count = items.len();
            (items, format!("OpenCode {count}"))
        }
        Err(error) => (Vec::new(), format!("OpenCode unavailable: {error}")),
    };
    let (qwen, qwen_status) = match load_recent_qwen_contexts(path_str) {
        Ok(items) => {
            let count = items.len();
            (items, format!("Qwen {count}"))
        }
        Err(error) => (Vec::new(), format!("Qwen unavailable: {error}")),
    };
    let (muse, muse_status) = match load_recent_muse_contexts(path_str) {
        Ok(items) => {
            let count = items.len();
            (items, format!("Muse {count}"))
        }
        Err(error) => (Vec::new(), format!("Muse unavailable: {error}")),
    };
    let (zcode, zcode_status) = match load_recent_zcode_contexts(path_str) {
        Ok(items) => {
            let count = items.len();
            (items, format!("ZCode {count}"))
        }
        Err(error) => (Vec::new(), format!("ZCode unavailable: {error}")),
    };

    Ok(LoadedRecent {
        codex,
        kimi,
        opencode,
        qwen,
        muse,
        zcode,
        status: format!(
            "{codex_status}  /  {kimi_status}  /  {opencode_status}  /  {qwen_status}  /  {muse_status}  /  {zcode_status}"
        ),
    })
}

fn load_recent_qwen_contexts(markdown_path: &str) -> Result<Vec<RecentContext>> {
    let mut session_files = Vec::<(PathBuf, i64)>::new();
    let mut seen_chats_dirs = std::collections::HashSet::new();

    for runtime_base in infer_qwen_runtime_bases(markdown_path) {
        let projects_dir = runtime_base.join("projects");
        let Ok(projects) = fs::read_dir(&projects_dir) else {
            continue;
        };
        for project in projects.flatten() {
            let project_path = project.path();
            if !project_path.is_dir() {
                continue;
            }
            let chats_dir = project_path.join("chats");
            if seen_chats_dirs.insert(chats_dir.clone()) {
                collect_qwen_session_files(&chats_dir, &mut session_files);
            }
        }
    }

    let mut recent = session_files
        .into_iter()
        .filter_map(|(path, modified_at)| read_qwen_context_file(&path, modified_at))
        .collect::<Vec<_>>();
    recent.sort_by_key(|item| std::cmp::Reverse(item.updated_at));

    let mut seen = std::collections::HashSet::new();
    Ok(recent
        .into_iter()
        .filter(|item| seen.insert(item.id.clone()))
        .take(RECENT_LIMIT)
        .collect())
}

fn infer_wsl_home_root(markdown_path: &str) -> Option<PathBuf> {
    // The app runs on Windows while the user's CLIs live in WSL. When the
    // picked markdown file is a WSL UNC path, derive the Linux home from it:
    // \\server\distro\home\<user>\... -> \\server\distro\home\<user>
    let normalized = markdown_path.replace('/', "\\");
    let mut parts = normalized.split('\\').filter(|part| !part.is_empty());
    let server = parts.next()?;
    let distro = parts.next()?;
    if parts.next()? != "home" {
        return None;
    }
    let user = parts.next()?;
    if server.is_empty() || distro.is_empty() || user.is_empty() {
        return None;
    }
    Some(PathBuf::from(format!(
        "\\\\{server}\\{distro}\\home\\{user}"
    )))
}

fn muse_home_roots(markdown_path: &str) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    // Prefer the WSL home when the markdown file itself lives in WSL: that is
    // where the user's CLIs keep their state, invisible to USERPROFILE.
    if let Some(wsl_root) = infer_wsl_home_root(markdown_path) {
        push_unique_path(&mut roots, wsl_root);
    }
    if let Some(home_root) = infer_user_home_root(markdown_path) {
        push_unique_path(&mut roots, home_root);
    }
    roots
}

fn muse_auth_path(markdown_path: &str) -> Option<PathBuf> {
    muse_home_roots(markdown_path)
        .into_iter()
        .map(|home| home.join(".config").join("muse").join("auth.json"))
        .find(|candidate| candidate.is_file())
}

fn zcode_home_roots(markdown_path: &str) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    // ZCode can run natively on Windows and inside WSL; both installs keep
    // state under <home>/.zcode. Scan the native profile first, then the WSL
    // home implied by the markdown path, so both session stores are visible.
    if let Some(profile) = std::env::var_os("USERPROFILE") {
        let profile = PathBuf::from(profile);
        if !profile.as_os_str().is_empty() {
            push_unique_path(&mut roots, profile.join(".zcode"));
        }
    }
    if let Some(wsl_root) = infer_wsl_home_root(markdown_path) {
        push_unique_path(&mut roots, wsl_root.join(".zcode"));
    }
    if roots.is_empty() {
        if let Some(home_root) = infer_user_home_root(markdown_path) {
            push_unique_path(&mut roots, home_root.join(".zcode"));
        }
    }
    roots
}

fn zcode_db_path_for_root(root: &Path) -> PathBuf {
    root.join("cli").join("db").join("db.sqlite")
}

fn load_recent_zcode_contexts(markdown_path: &str) -> Result<Vec<RecentContext>> {
    let mut recent = Vec::<RecentContext>::new();
    for root in zcode_home_roots(markdown_path) {
        let db_path = zcode_db_path_for_root(&root);
        if !db_path.is_file() {
            continue;
        }
        let items = load_recent_zcode_database(&db_path)
            .with_context(|| format!("Failed to read ZCode sessions from {}", db_path.display()))?;
        recent.extend(items);
    }

    recent.sort_by_key(|item| std::cmp::Reverse(item.updated_at));
    let mut seen = std::collections::HashSet::new();
    Ok(recent
        .into_iter()
        .filter(|item| seen.insert(item.id.clone()))
        .take(RECENT_LIMIT)
        .collect())
}

fn load_recent_zcode_database(db_path: &PathBuf) -> Result<Vec<RecentContext>> {
    match query_recent_zcode_contexts(db_path) {
        Ok(items) => Ok(items),
        Err(error) if is_locked_sqlite_error(&error) => {
            let snapshot = snapshot_sqlite_database(db_path)?;
            let result = query_recent_zcode_contexts(&snapshot)
                .with_context(|| format!("Failed to read snapshot of {}", db_path.display()));
            let _ = remove_snapshot_database(&snapshot);
            result
        }
        Err(error) => Err(error).with_context(|| format!("Failed to read {}", db_path.display())),
    }
}

fn query_recent_zcode_contexts(db_path: &PathBuf) -> rusqlite::Result<Vec<RecentContext>> {
    let connection = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let _ = connection.busy_timeout(Duration::from_millis(250));
    let query = format!(
        "SELECT id, title, directory, time_updated
         FROM session
         WHERE time_archived IS NULL
           AND TRIM(COALESCE(parent_id, '')) = ''
           AND COALESCE(task_type, '') != 'subagent_child'
         ORDER BY time_updated DESC
         LIMIT {RECENT_CANDIDATE_LIMIT}"
    );
    let mut statement = connection.prepare(&query)?;

    let rows = statement.query_map([], |row| {
        let id: String = row.get(0)?;
        let title: String = row.get(1)?;
        let directory: Option<String> = row.get(2)?;
        Ok(RecentContext {
            provider: PROVIDER_ZCODE.to_owned(),
            id,
            title,
            updated_at: normalize_epoch_millis(row.get(3)?),
            forked_from_id: None,
            work_dir: directory
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty()),
        })
    })?;

    let mut items = Vec::new();
    for row in rows {
        items.push(row?);
    }
    Ok(items)
}

fn read_zcode_config_providers(root: &Path) -> Option<serde_json::Map<String, serde_json::Value>> {
    let config_path = root.join("v2").join("config.json");
    let bytes = fs::read(&config_path).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    value.get("provider")?.as_object().cloned()
}

fn read_zcode_provider_names(root: &Path, names: &mut std::collections::BTreeMap<String, String>) {
    let Some(providers) = read_zcode_config_providers(root) else {
        return;
    };
    for (provider_id, provider) in providers {
        let Some(name) = provider.get("name").and_then(|value| value.as_str()) else {
            continue;
        };
        let name = name.trim();
        if !name.is_empty() {
            names.insert(provider_id, name.to_owned());
        }
    }
}

fn read_zcode_enabled_providers(root: &Path, enabled: &mut Vec<String>) {
    let Some(providers) = read_zcode_config_providers(root) else {
        return;
    };
    for (provider_id, provider) in providers {
        if provider.get("enabled").and_then(|value| value.as_bool()) == Some(true) {
            enabled.push(provider_id);
        }
    }
}

fn zcode_provider_display_name(
    slot: &str,
    names: &std::collections::BTreeMap<String, String>,
) -> String {
    if let Some(name) = names.get(slot) {
        return name.clone();
    }
    let trimmed = slot.trim();
    for prefix in ["builtin:", "account:"] {
        if let Some(stripped) = trimmed.strip_prefix(prefix)
            && !stripped.is_empty()
        {
            return stripped.to_owned();
        }
    }
    if trimmed.is_empty() {
        "ZCode".to_owned()
    } else {
        trimmed.to_owned()
    }
}

fn zcode_unavailable_account(error: &str) -> ZcodeAccountMetadata {
    ZcodeAccountMetadata {
        slot: "default".to_owned(),
        name: "ZCode".to_owned(),
        updated_at: unix_epoch_millis().ok(),
        tier: None,
        used_percent: None,
        reset_at: None,
        window_seconds: None,
        zcode_error: Some(error.to_owned()),
    }
}

fn load_zcode_accounts_for_markdown(markdown_path: &str) -> Result<LoadedZcodeAccounts> {
    let roots = zcode_home_roots(markdown_path);
    if roots.is_empty() {
        return Ok(LoadedZcodeAccounts {
            accounts: vec![zcode_unavailable_account(ZCODE_STATE_NOT_FOUND_ERROR)],
        });
    }

    let mut provider_names = std::collections::BTreeMap::new();
    let mut enabled_providers = Vec::new();
    let mut found_any_state = false;
    for root in &roots {
        if root.join("v2").join("config.json").is_file() || zcode_db_path_for_root(root).is_file() {
            found_any_state = true;
        }
        read_zcode_provider_names(root, &mut provider_names);
        read_zcode_enabled_providers(root, &mut enabled_providers);
    }
    if !found_any_state {
        return Ok(LoadedZcodeAccounts {
            accounts: vec![zcode_unavailable_account(ZCODE_STATE_NOT_FOUND_ERROR)],
        });
    }

    let now_ms = unix_epoch_millis().unwrap_or_default();
    let since_ms = now_ms.saturating_sub(ZCODE_USAGE_LOOKBACK_MS);
    let mut rows: Vec<(i64, String)> = Vec::new();
    let mut latest_request: Option<(i64, String)> = None;
    for root in &roots {
        let db_path = zcode_db_path_for_root(root);
        if !db_path.is_file() {
            continue;
        }
        // An unreadable install (for example a locked database on a slow WSL
        // link) must not hide usage recorded by the other install.
        let Ok((db_rows, db_latest)) = load_zcode_usage_rows(&db_path, since_ms) else {
            continue;
        };
        if db_latest.is_some()
            && match &latest_request {
                Some((latest_at, _)) => db_latest.as_ref().is_some_and(|(at, _)| at > latest_at),
                None => true,
            }
        {
            latest_request = db_latest;
        }
        rows.extend(db_rows);
    }

    // Primary source: the provider's own quota endpoint (same data the ZCode
    // sidebar shows). Local request-log measurement is the offline fallback.
    let (used_percent, reset_at, window_seconds, zcode_error) = match zcode_quota_api_key(&roots) {
        Some(api_key) => match fetch_zcode_quota(&api_key) {
            Ok(usage) => (
                Some(usage.used_percent),
                Some(usage.reset_at_ms),
                Some(usage.window_seconds),
                None,
            ),
            Err(error) => {
                let fallback = compute_zcode_window_usage(&mut rows, now_ms);
                if fallback.0 > 0.0 {
                    (Some(fallback.0), Some(fallback.1), Some(fallback.2), None)
                } else {
                    (None, None, None, Some(error.message().to_owned()))
                }
            }
        },
        None => {
            let fallback = compute_zcode_window_usage(&mut rows, now_ms);
            if fallback.0 > 0.0 {
                (Some(fallback.0), Some(fallback.1), Some(fallback.2), None)
            } else {
                (
                    None,
                    None,
                    None,
                    Some("Usage unavailable: no ZCode API key in config.".to_owned()),
                )
            }
        }
    };

    let raw_slot = latest_request
        .map(|(_, provider_id)| provider_id)
        .or_else(|| enabled_providers.first().cloned())
        .unwrap_or_else(|| "default".to_owned());
    let name = zcode_provider_display_name(&raw_slot, &provider_names);
    let slot = zcode_provider_display_name(&raw_slot, &std::collections::BTreeMap::new());

    Ok(LoadedZcodeAccounts {
        accounts: vec![ZcodeAccountMetadata {
            tier: Some(raw_slot),
            slot,
            name,
            updated_at: unix_epoch_millis().ok(),
            used_percent,
            reset_at,
            window_seconds,
            zcode_error,
        }],
    })
}

/// Folds the request rows into the provider's window model: a window starts at
/// the first request after the previous window's five hours elapse, and every
/// request inside keeps it open. Returns the percent of the prompt quota used
/// in the active window plus its reset instant; an expired or empty history
/// reads as a fresh window.
fn compute_zcode_window_usage(rows: &mut [(i64, String)], now_ms: i64) -> (f64, i64, i64) {
    let window_ms = ZCODE_WINDOW_SECONDS * 1000;
    rows.sort_by_key(|(at, _)| *at);
    let Some(&oldest) = rows.first().map(|(at, _)| at) else {
        return (0.0, now_ms + window_ms, ZCODE_WINDOW_SECONDS);
    };
    let mut window_start = oldest;
    for &(at, _) in rows.iter() {
        if at >= window_start + window_ms {
            window_start = at;
        }
    }

    let window_end = window_start + window_ms;
    if now_ms >= window_end {
        return (0.0, now_ms + window_ms, ZCODE_WINDOW_SECONDS);
    }

    let mut prompts = std::collections::HashSet::new();
    for &(at, ref identity) in rows.iter() {
        if at >= window_start && at < window_end {
            prompts.insert(identity);
        }
    }
    let used_percent = (prompts.len() as f64 / ZCODE_PROMPT_QUOTA as f64 * 100.0).min(100.0);
    (used_percent, window_end, ZCODE_WINDOW_SECONDS)
}

/// Reads the coding-plan API key ZCode stores in plaintext in
/// ~/.zcode/v2/config.json. Prefers the enabled Z.ai coding-plan provider.
fn zcode_quota_api_key(roots: &[PathBuf]) -> Option<String> {
    fn priority(id: &str, enabled: bool) -> u8 {
        let base = if id == "builtin:zai-coding-plan" {
            0u8
        } else if id.contains("zai") && id.contains("coding-plan") {
            1
        } else if id.contains("coding-plan") {
            2
        } else {
            3
        };
        base * 2 + u8::from(!enabled)
    }

    for root in roots {
        let config_path = root.join("v2").join("config.json");
        let Ok(bytes) = fs::read(&config_path) else {
            continue;
        };
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            continue;
        };
        let Some(providers) = value.get("provider").and_then(|v| v.as_object()) else {
            continue;
        };
        let mut candidates: Vec<(u8, String, String)> = Vec::new();
        for (id, provider) in providers {
            let enabled = provider.get("enabled").and_then(|v| v.as_bool()) == Some(true);
            let Some(key) = provider
                .get("options")
                .and_then(|options| options.get("apiKey"))
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|key| !key.is_empty())
            else {
                continue;
            };
            candidates.push((priority(id, enabled), id.clone(), key.to_owned()));
        }
        candidates.sort_by(|left, right| left.0.cmp(&right.0).then_with(|| left.1.cmp(&right.1)));
        if let Some((_, _, key)) = candidates.into_iter().next() {
            return Some(key);
        }
    }
    None
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum ZcodeQuotaError {
    Unavailable,
    CredentialRejected,
}

impl ZcodeQuotaError {
    fn message(self) -> &'static str {
        match self {
            Self::Unavailable => ZCODE_QUOTA_ERROR,
            Self::CredentialRejected => ZCODE_QUOTA_CREDENTIAL_ERROR,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct ZcodeQuotaUsage {
    used_percent: f64,
    reset_at_ms: i64,
    window_seconds: i64,
}

#[derive(Clone, Debug, PartialEq)]
struct ZcodeQuotaLimit {
    percentage: f64,
    next_reset_time_ms: i64,
    window_seconds: i64,
}

#[derive(Debug, Deserialize)]
struct ZcodeQuotaEnvelope {
    #[serde(default)]
    data: Option<ZcodeQuotaData>,
}

#[derive(Debug, Deserialize)]
struct ZcodeQuotaData {
    #[serde(default)]
    limits: Vec<ZcodeQuotaRawLimit>,
}

#[derive(Debug, Deserialize)]
struct ZcodeQuotaRawLimit {
    #[serde(default)]
    number: Option<f64>,
    #[serde(default)]
    unit: Option<f64>,
    #[serde(default)]
    percentage: Option<f64>,
    #[serde(default, rename = "nextResetTime")]
    next_reset_time: Option<i64>,
}

/// The endpoint reports one limit per rolling window (5-hour and weekly for
/// coding plans). The weekly limit — the furthest reset — is the one ZCode's
/// sidebar displays, so prefer it; its length is derived from unit/number.
fn pick_zcode_quota_limit(limits: &[ZcodeQuotaRawLimit]) -> Option<ZcodeQuotaLimit> {
    fn normalize(limit: &ZcodeQuotaRawLimit) -> Option<ZcodeQuotaLimit> {
        let percentage = limit.percentage?;
        let next_reset_time_ms = limit.next_reset_time?;
        if !(0.0..=100.0).contains(&percentage) || next_reset_time_ms <= 0 {
            return None;
        }
        let unit_seconds = match limit.unit {
            Some(unit) if unit == 3.0 => 3_600.0,
            Some(unit) if unit == 4.0 => 86_400.0,
            Some(unit) if unit == 6.0 => 604_800.0,
            _ => 604_800.0,
        };
        let number = limit.number.filter(|value| *value > 0.0).unwrap_or(1.0);
        Some(ZcodeQuotaLimit {
            percentage,
            next_reset_time_ms,
            window_seconds: (unit_seconds * number) as i64,
        })
    }

    let normalized: Vec<ZcodeQuotaLimit> = limits.iter().filter_map(normalize).collect();
    normalized
        .iter()
        .max_by_key(|limit| limit.next_reset_time_ms)
        .cloned()
        .or_else(|| normalized.first().cloned())
}

fn fetch_zcode_quota(api_key: &str) -> std::result::Result<ZcodeQuotaUsage, ZcodeQuotaError> {
    let api_key = escape_curl_config_value(api_key).ok_or(ZcodeQuotaError::Unavailable)?;
    let curl_config = format!(
        "url = \"{ZCODE_QUOTA_URL}\"\nheader = \"Accept: application/json\"\nheader = \"Authorization: Bearer {api_key}\"\nconnect-timeout = {ZCODE_QUOTA_CONNECT_TIMEOUT_SECONDS}\nmax-time = {ZCODE_QUOTA_TIMEOUT_SECONDS}\n"
    );

    // The API key travels through curl's stdin config, never the argv list,
    // matching how the Codex and Muse usage fetches handle credentials.
    let mut command = Command::new("curl");
    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);
    let mut child = command
        .args([
            "-q",
            "--silent",
            "--proto",
            "=https",
            "--config",
            "-",
            "--output",
            "-",
            "--max-filesize",
            "524288",
            "--write-out",
            "\n%{http_code}",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| ZcodeQuotaError::Unavailable)?;
    let write_result = child
        .stdin
        .take()
        .ok_or(ZcodeQuotaError::Unavailable)
        .and_then(|mut stdin| {
            stdin
                .write_all(curl_config.as_bytes())
                .map_err(|_| ZcodeQuotaError::Unavailable)
        });
    if write_result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(ZcodeQuotaError::Unavailable);
    }
    let output = child
        .wait_with_output()
        .map_err(|_| ZcodeQuotaError::Unavailable)?;
    if !output.status.success() {
        return Err(ZcodeQuotaError::Unavailable);
    }
    let newline = output
        .stdout
        .iter()
        .rposition(|byte| *byte == b'\n')
        .ok_or(ZcodeQuotaError::Unavailable)?;
    let status = std::str::from_utf8(&output.stdout[newline + 1..])
        .map_err(|_| ZcodeQuotaError::Unavailable)?;
    if status.len() != 3 || !status.chars().all(|character| character.is_ascii_digit()) {
        return Err(ZcodeQuotaError::Unavailable);
    }
    let status = status
        .parse::<u16>()
        .map_err(|_| ZcodeQuotaError::Unavailable)?;
    if !(200..300).contains(&status) {
        return Err(if matches!(status, 401 | 403) {
            ZcodeQuotaError::CredentialRejected
        } else {
            ZcodeQuotaError::Unavailable
        });
    }
    let body = &output.stdout[..newline];
    if body.len() > ZCODE_QUOTA_MAX_BODY_BYTES {
        return Err(ZcodeQuotaError::Unavailable);
    }
    parse_zcode_quota_response(body).ok_or(ZcodeQuotaError::Unavailable)
}

fn parse_zcode_quota_response(body: &[u8]) -> Option<ZcodeQuotaUsage> {
    let envelope: ZcodeQuotaEnvelope = serde_json::from_slice(body).ok()?;
    let data = envelope.data?;
    let limit = pick_zcode_quota_limit(&data.limits)?;
    Some(ZcodeQuotaUsage {
        used_percent: limit.percentage,
        reset_at_ms: limit.next_reset_time_ms,
        window_seconds: limit.window_seconds,
    })
}

fn load_zcode_usage_rows(
    db_path: &PathBuf,
    since_ms: i64,
) -> Result<(Vec<(i64, String)>, Option<(i64, String)>)> {
    match query_zcode_usage_rows(db_path, since_ms) {
        Ok(value) => Ok(value),
        Err(error) if is_locked_sqlite_error(&error) => {
            let snapshot = snapshot_sqlite_database(db_path)?;
            let result = query_zcode_usage_rows(&snapshot, since_ms)
                .with_context(|| format!("Failed to read snapshot of {}", db_path.display()));
            let _ = remove_snapshot_database(&snapshot);
            result
        }
        Err(error) => Err(error).with_context(|| format!("Failed to read {}", db_path.display())),
    }
}

fn query_zcode_usage_rows(
    db_path: &PathBuf,
    since_ms: i64,
) -> rusqlite::Result<(Vec<(i64, String)>, Option<(i64, String)>)> {
    let connection = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let _ = connection.busy_timeout(Duration::from_millis(250));
    let has_prompt_id =
        sqlite_table_has_column(&connection, "model_usage", "parent_user_message_id")?;
    let has_turn_id = sqlite_table_has_column(&connection, "model_usage", "turn_id")?;
    let mut selected = String::from("started_at, COALESCE(provider_id, '')");
    if has_prompt_id {
        selected.push_str(", COALESCE(parent_user_message_id, '')");
    }
    if has_turn_id {
        selected.push_str(", COALESCE(turn_id, '')");
    }
    let prompt_index = if has_prompt_id { Some(2) } else { None };
    let turn_index = if has_turn_id {
        Some(if has_prompt_id { 3 } else { 2 })
    } else {
        None
    };
    let query = format!(
        "SELECT {selected}
         FROM model_usage
         WHERE started_at >= ?1
         ORDER BY started_at ASC
         LIMIT ?2"
    );
    let mut statement = connection.prepare(&query)?;
    let rows = statement.query_map(
        rusqlite::params![since_ms, ZCODE_USAGE_ROW_LIMIT as i64],
        |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                prompt_index
                    .map(|index| row.get::<_, String>(index))
                    .transpose()?,
                turn_index
                    .map(|index| row.get::<_, String>(index))
                    .transpose()?,
            ))
        },
    )?;

    let mut usage_rows = Vec::new();
    let mut latest_at: Option<i64> = None;
    let mut latest_provider: Option<String> = None;
    for row in rows {
        let (started_at, provider_id, prompt_id, turn_id) = row?;
        // Rows arrive ascending, so the last write wins with the newest
        // provider id, which identifies the account for the header.
        let provider_id = provider_id.trim();
        if !provider_id.is_empty() && latest_at.is_none_or(|at| started_at >= at) {
            latest_at = Some(started_at);
            latest_provider = Some(provider_id.to_owned());
        }
        // One prompt = one user message; fall back to the turn id and finally
        // to the row itself so internal retries of one prompt never multiply
        // the count.
        let identity = if let Some(prompt_id) = prompt_id
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty())
        {
            format!("p:{prompt_id}")
        } else if let Some(turn_id) = turn_id
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty())
        {
            format!("t:{turn_id}")
        } else {
            format!("r:{}", usage_rows.len())
        };
        usage_rows.push((started_at, identity));
    }
    let latest = match (latest_at, latest_provider) {
        (Some(at), Some(provider)) => Some((at, provider)),
        _ => None,
    };
    Ok((usage_rows, latest))
}

fn load_muse_accounts_for_markdown(markdown_path: &str) -> Result<LoadedMuseAccounts> {
    const MUSE_DEFAULT_SLOT: &str = "default";
    let Some(auth_path) = muse_auth_path(markdown_path) else {
        return Ok(LoadedMuseAccounts {
            accounts: vec![MuseAccountMetadata {
                slot: MUSE_DEFAULT_SLOT.to_owned(),
                name: "Muse".to_owned(),
                updated_at: unix_epoch_millis().ok(),
                tier: None,
                weekly_used_percent: None,
                weekly_reset_at: None,
                window_used_percent: None,
                window_reset_at: None,
                window_duration_mins: None,
                muse_error: Some("Muse is not logged in (auth.json not found).".to_owned()),
            }],
            active_slot: Some(MUSE_DEFAULT_SLOT.to_owned()),
        });
    };
    let auth_bytes = fs::read(&auth_path).map_err(|error| {
        anyhow!(
            "Could not read Muse auth file {}: {error}",
            auth_path.display()
        )
    })?;
    let name = muse_auth_user_email(&auth_bytes).unwrap_or_else(|| "Muse".to_owned());
    match fetch_muse_subscription_usage(&auth_bytes) {
        Ok(usage) => Ok(LoadedMuseAccounts {
            accounts: vec![MuseAccountMetadata {
                slot: MUSE_DEFAULT_SLOT.to_owned(),
                name,
                updated_at: unix_epoch_millis().ok(),
                tier: usage.tier,
                weekly_used_percent: usage.weekly_used_percent,
                weekly_reset_at: usage.weekly_reset_at_ms,
                window_used_percent: usage.window_used_percent,
                window_reset_at: usage.window_reset_at_ms,
                window_duration_mins: usage.window_duration_mins,
                muse_error: None,
            }],
            active_slot: Some(MUSE_DEFAULT_SLOT.to_owned()),
        }),
        Err(error) => Ok(LoadedMuseAccounts {
            accounts: vec![MuseAccountMetadata {
                slot: MUSE_DEFAULT_SLOT.to_owned(),
                name,
                updated_at: unix_epoch_millis().ok(),
                tier: None,
                weekly_used_percent: None,
                weekly_reset_at: None,
                window_used_percent: None,
                window_reset_at: None,
                window_duration_mins: None,
                muse_error: Some(error.message().to_owned()),
            }],
            active_slot: Some(MUSE_DEFAULT_SLOT.to_owned()),
        }),
    }
}

fn load_recent_muse_contexts(markdown_path: &str) -> Result<Vec<RecentContext>> {
    let mut session_files = Vec::<PathBuf>::new();
    for sessions_root in infer_muse_sessions_roots(markdown_path) {
        collect_muse_session_files(&sessions_root, &mut session_files);
    }

    // session.jsonl files can be megabytes; parsing every candidate over a
    // slow link (WSL UNC) stalls the refresh. Sort by mtime first and parse
    // only the newest candidates — mtime tracks content recency closely.
    session_files.sort_by_key(|path| std::cmp::Reverse(modified_at_ms(path)));
    session_files.truncate(RECENT_CANDIDATE_LIMIT);

    let mut recent = session_files
        .iter()
        .filter_map(|path| read_muse_context_file(path))
        .collect::<Vec<_>>();
    recent.sort_by_key(|item| std::cmp::Reverse(item.updated_at));

    let mut seen = std::collections::HashSet::new();
    Ok(recent
        .into_iter()
        .filter(|item| seen.insert(item.id.clone()))
        .take(RECENT_LIMIT)
        .collect())
}

fn infer_muse_sessions_roots(markdown_path: &str) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(value) = std::env::var_os("MUSE_HOME") {
        let base = PathBuf::from(value);
        push_unique_path(&mut candidates, base.join("sessions"));
        push_unique_path(&mut candidates, base.clone());
    }
    if let Some(value) = std::env::var_os("XDG_DATA_HOME") {
        let base = PathBuf::from(value);
        if !base.as_os_str().is_empty() {
            push_unique_path(&mut candidates, base.join("muse").join("sessions"));
        }
    }
    for home_root in muse_home_roots(markdown_path) {
        push_unique_path(
            &mut candidates,
            home_root
                .join(".local")
                .join("share")
                .join("muse")
                .join("sessions"),
        );
    }
    candidates
}

fn collect_muse_session_files(root: &Path, files: &mut Vec<PathBuf>) {
    if is_muse_subagent_path(root) {
        return;
    }
    if root.is_file() {
        if is_muse_session_file(root) {
            files.push(root.to_owned());
        }
        return;
    }
    if !root.is_dir() {
        return;
    }
    // Bound the walk so a huge sessions tree cannot stall the refresh task.
    let mut visited_dirs = 0usize;
    let mut stack = vec![root.to_owned()];
    while let Some(dir) = stack.pop() {
        visited_dirs += 1;
        if visited_dirs > 4000 {
            break;
        }
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        let mut entries: Vec<_> = entries.flatten().collect();
        // Ascending push order: the stack below is LIFO, so date/session
        // directories (which sort chronologically) are visited newest-first
        // and fresh sessions are reached before any cap cuts in.
        entries.sort_by_key(|entry| entry.path());
        for entry in entries.into_iter().take(2000) {
            let path = entry.path();
            if is_muse_subagent_path(&path) || is_muse_tool_outputs_dir(&path) {
                continue;
            }
            if path.is_dir() {
                stack.push(path);
            } else if is_muse_session_file(&path) {
                files.push(path);
                // Paths are cheap (no reads yet); the expensive parse step is
                // capped separately after an mtime sort.
                if files.len() >= RECENT_CANDIDATE_LIMIT * 64 {
                    return;
                }
            }
        }
    }
}

fn is_muse_subagent_path(path: &Path) -> bool {
    path.components().any(|component| {
        matches!(
            component
                .as_os_str()
                .to_str()
                .map(str::to_ascii_lowercase)
                .as_deref(),
            Some("subagent") | Some("subagents")
        )
    })
}

fn is_muse_tool_outputs_dir(path: &Path) -> bool {
    path.components().any(|component| {
        matches!(
            component
                .as_os_str()
                .to_str()
                .map(str::to_ascii_lowercase)
                .as_deref(),
            Some("tool-outputs") | Some("tool_outputs")
        )
    })
}

fn is_muse_session_file(path: &Path) -> bool {
    if path.file_name().and_then(|name| name.to_str()) != Some("session.jsonl") {
        return false;
    }
    // Top-level Muse sessions live under sessions/YYYY/MM/DD/<session-id>/session.jsonl.
    // Anything nested under a subagent directory is excluded above.
    matches!(
        path.parent()
            .and_then(|parent| parent.file_name())
            .and_then(|name| name.to_str())
            .map(|name| !name.trim().is_empty()),
        Some(true)
    )
}

fn read_muse_context_file(path: &Path) -> Option<RecentContext> {
    let id = path.parent()?.file_name()?.to_str()?.trim().to_owned();
    if id.is_empty() {
        return None;
    }
    let fallback_mtime = modified_at_ms(path);
    let file = fs::File::open(path).ok()?;
    let mut session_name: Option<String> = None;
    let mut first_prompt: Option<String> = None;
    let mut work_dir: Option<String> = None;
    let mut latest_recorded_ms: Option<i64> = None;

    for line in BufReader::new(file).lines().filter_map(|line| line.ok()) {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) else {
            continue;
        };
        if let Some(recorded) = value.get("recorded_at").and_then(|v| {
            v.as_i64()
                .or_else(|| v.as_u64().and_then(|n| i64::try_from(n).ok()))
        }) {
            let normalized = normalize_muse_epoch_millis(recorded);
            if latest_recorded_ms.map_or(true, |current| normalized > current) {
                latest_recorded_ms = Some(normalized);
            }
        }
        let payload_type = value
            .get("payload_type")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let payload = value.get("payload");
        if payload_type == "session.name.changed" {
            if let Some(name) = payload
                .and_then(|p| p.get("new_name"))
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|v| !v.is_empty())
            {
                session_name = Some(name.to_owned());
            }
            continue;
        }
        if work_dir.is_none() {
            // route_facts carries cwd; metadata carries workspace_root.
            let cwd = payload
                .and_then(|p| p.get("record"))
                .and_then(|r| r.get("cwd"))
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|v| !v.is_empty())
                .map(ToOwned::to_owned)
                .or_else(|| {
                    payload
                        .and_then(|p| p.get("record"))
                        .and_then(|r| r.get("workspace_root"))
                        .and_then(serde_json::Value::as_str)
                        .map(str::trim)
                        .filter(|v| !v.is_empty())
                        .map(ToOwned::to_owned)
                });
            if cwd.is_some() {
                work_dir = cwd;
            }
        }
        if first_prompt.is_none() {
            if let Some(prompt) = muse_prompt_from_value(&value) {
                first_prompt = Some(prompt);
            }
        }
    }

    let title = session_name
        .filter(|name| !name.trim().is_empty())
        .or(first_prompt)
        .unwrap_or_else(|| short_session_id(&id));
    let updated_at = latest_recorded_ms.unwrap_or(fallback_mtime);
    if updated_at <= 0 {
        return None;
    }
    Some(RecentContext {
        provider: PROVIDER_MUSE.to_owned(),
        id,
        title,
        updated_at,
        forked_from_id: None,
        work_dir,
    })
}

fn normalize_muse_epoch_millis(value: i64) -> i64 {
    // Muse session.jsonl uses microseconds since the Unix epoch.
    if value >= 100_000_000_000_000 {
        value / 1_000
    } else if value >= 100_000_000_000 {
        value
    } else if value >= 1_000_000_000 {
        value.saturating_mul(1_000)
    } else {
        value
    }
}

fn muse_prompt_from_value(value: &serde_json::Value) -> Option<String> {
    let payload = value.get("payload")?;
    // Newest schema: runtime.user_intent.accepted with model_messages/refill_blocks.
    for key in ["model_messages", "refill_blocks"] {
        if let Some(text) = payload
            .get(key)
            .and_then(serde_json::Value::as_array)
            .and_then(|items| muse_first_text_in_messages(items))
        {
            return Some(text);
        }
    }
    // Run-level prompt echoes.
    for key in ["prompt"] {
        if let Some(text) = payload
            .get("record")
            .and_then(|record| record.get(key))
            .and_then(serde_json::Value::as_str)
            .map(muse_single_line_title)
            .filter(|text| !text.is_empty())
        {
            return Some(text);
        }
        if let Some(text) = payload
            .get("event")
            .and_then(|event| event.get(key))
            .and_then(serde_json::Value::as_str)
            .map(muse_single_line_title)
            .filter(|text| !text.is_empty())
        {
            return Some(text);
        }
    }
    None
}

fn muse_first_text_in_messages(items: &[serde_json::Value]) -> Option<String> {
    for item in items {
        if let Some(content) = item.get("content").and_then(serde_json::Value::as_array) {
            for block in content {
                let kind = block
                    .get("kind")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("");
                if kind != "text" {
                    continue;
                }
                if let Some(text) = block
                    .get("text")
                    .and_then(serde_json::Value::as_str)
                    .map(muse_single_line_title)
                    .filter(|text| !text.is_empty())
                {
                    return Some(text);
                }
            }
        }
        if let Some(text) = item
            .get("text")
            .and_then(serde_json::Value::as_str)
            .map(muse_single_line_title)
            .filter(|text| !text.is_empty())
        {
            return Some(text);
        }
    }
    None
}

fn muse_single_line_title(raw: &str) -> String {
    let single_line = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    const MAX_CHARS: usize = 80;
    let mut out = String::new();
    for ch in single_line.chars().take(MAX_CHARS) {
        out.push(ch);
    }
    out.trim().to_owned()
}

fn infer_qwen_runtime_bases(markdown_path: &str) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(value) = std::env::var_os("QWEN_RUNTIME_DIR") {
        push_unique_path(
            &mut candidates,
            expand_qwen_path(&value.to_string_lossy(), markdown_path),
        );
    }
    if let Some(value) = std::env::var_os("QWEN_HOME") {
        push_unique_path(
            &mut candidates,
            expand_qwen_path(&value.to_string_lossy(), markdown_path),
        );
    }
    if let Some(home_root) = infer_user_home_root(markdown_path) {
        push_unique_path(&mut candidates, home_root.join(".qwen"));
    }
    candidates
}

fn push_unique_path(paths: &mut Vec<PathBuf>, path: PathBuf) {
    if !path.as_os_str().is_empty() && !paths.iter().any(|candidate| candidate == &path) {
        paths.push(path);
    }
}

fn expand_qwen_path(raw_path: &str, markdown_path: &str) -> PathBuf {
    let trimmed = raw_path.trim();
    let Some(home_root) = infer_user_home_root(markdown_path) else {
        return PathBuf::from(trimmed);
    };
    if trimmed == "~" {
        return home_root;
    }
    if let Some(relative) = trimmed
        .strip_prefix("~/")
        .or_else(|| trimmed.strip_prefix("~\\"))
    {
        return home_root.join(relative);
    }
    PathBuf::from(trimmed)
}

fn collect_qwen_session_files(chats_dir: &Path, files: &mut Vec<(PathBuf, i64)>) {
    let Ok(entries) = fs::read_dir(chats_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() || qwen_session_id_from_path(&path).is_none() {
            continue;
        }
        files.push((path.clone(), modified_at_ms(&path)));
    }
}

fn qwen_session_id_from_path(path: &Path) -> Option<String> {
    if path.extension().and_then(|value| value.to_str()) != Some("jsonl") {
        return None;
    }
    let value = path.file_stem()?.to_str()?.trim();
    if !(32..=36).contains(&value.len())
        || !value.chars().all(|ch| ch.is_ascii_hexdigit() || ch == '-')
    {
        return None;
    }
    Some(value.to_owned())
}

fn read_qwen_context_file(path: &Path, modified_at: i64) -> Option<RecentContext> {
    let file_id = qwen_session_id_from_path(path)?;
    let file = fs::File::open(path).ok()?;
    let mut session_id = None;
    let mut title = None;
    let mut prompt = None;
    let mut updated_at = None;
    let mut forked_from_id = None;
    let mut work_dir = None;

    for line in BufReader::new(file).lines().filter_map(|line| line.ok()) {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) else {
            continue;
        };

        if session_id.is_none() {
            session_id = qwen_string(&value, &["sessionId", "session_id"]);
        }
        if work_dir.is_none() {
            work_dir = qwen_string(&value, &["cwd", "workDir", "work_dir"]);
        }
        if let Some(timestamp) = value.get("timestamp").and_then(parse_json_timestamp)
            && updated_at.map_or(true, |current| timestamp > current)
        {
            updated_at = Some(timestamp);
        }

        if value.get("type").and_then(serde_json::Value::as_str) == Some("system")
            && value.get("subtype").and_then(serde_json::Value::as_str) == Some("custom_title")
        {
            title = value
                .get("systemPayload")
                .and_then(|payload| qwen_string(payload, &["customTitle", "title"]));
        }
        if prompt.is_none() && value.get("type").and_then(serde_json::Value::as_str) == Some("user")
        {
            prompt = qwen_prompt_text(&value);
        }
        if forked_from_id.is_none() {
            forked_from_id = qwen_parent_session_id(&value);
        }
    }

    let session_id = session_id.filter(|value| !value.is_empty())?;
    if session_id != file_id {
        return None;
    }

    let runtime_status_path = path.with_file_name(format!("{file_id}.runtime.json"));
    let runtime_status = read_qwen_runtime_status(&runtime_status_path);
    let work_dir = work_dir.or_else(|| {
        runtime_status
            .as_ref()
            .and_then(|value| qwen_string(value, &["work_dir", "workDir", "cwd"]))
    });
    let updated_at = updated_at
        .or_else(|| runtime_status.as_ref().and_then(qwen_started_at))
        .unwrap_or(modified_at);
    let title = title
        .or(prompt)
        .map(|value| normalize_qwen_title(&value))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| short_session_id(&session_id));

    Some(RecentContext {
        provider: PROVIDER_QWEN.to_owned(),
        id: session_id,
        title,
        updated_at,
        forked_from_id: forked_from_id.filter(|value| !value.is_empty()),
        work_dir: work_dir.filter(|value| !value.is_empty()),
    })
}

fn qwen_string(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn qwen_prompt_text(value: &serde_json::Value) -> Option<String> {
    value
        .get("message")
        .and_then(|message| message.get("parts"))
        .and_then(serde_json::Value::as_array)
        .and_then(|parts| {
            parts.iter().find_map(|part| {
                part.get("text")
                    .and_then(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(ToOwned::to_owned)
            })
        })
}

fn qwen_parent_session_id(value: &serde_json::Value) -> Option<String> {
    let payload = value.get("systemPayload");
    for object in [Some(value), payload] {
        let Some(object) = object else {
            continue;
        };
        if let Some(parent) = qwen_string(
            object,
            &[
                "parentSessionId",
                "parent_session_id",
                "forkedFromId",
                "forked_from_id",
            ],
        ) {
            return Some(parent);
        }
        if let Some(parent) = object.get("forkedFrom") {
            if let Some(parent) = parent
                .as_str()
                .map(str::trim)
                .filter(|value| !value.is_empty())
            {
                return Some(parent.to_owned());
            }
            if let Some(parent) = qwen_string(parent, &["sessionId", "session_id", "id"]) {
                return Some(parent);
            }
        }
    }
    None
}

fn read_qwen_runtime_status(path: &Path) -> Option<serde_json::Value> {
    let text = fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

fn qwen_started_at(value: &serde_json::Value) -> Option<i64> {
    value
        .get("started_at")
        .and_then(parse_qwen_runtime_timestamp)
        .or_else(|| {
            value
                .get("startedAt")
                .and_then(parse_qwen_runtime_timestamp)
        })
}

fn parse_qwen_runtime_timestamp(value: &serde_json::Value) -> Option<i64> {
    if let Some(number) = value.as_f64()
        && number.is_finite()
    {
        let millis = if number.abs() < 100_000_000_000.0 {
            number * 1_000.0
        } else {
            number
        };
        if millis >= i64::MIN as f64 && millis <= i64::MAX as f64 {
            return Some(millis.round() as i64);
        }
    }
    parse_json_timestamp(value)
}

fn normalize_qwen_title(value: &str) -> String {
    const TITLE_LIMIT: usize = 200;
    let compact = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= TITLE_LIMIT {
        return compact;
    }
    let mut title = compact.chars().take(TITLE_LIMIT).collect::<String>();
    title.push_str("...");
    title
}

fn load_recent_opencode_contexts(markdown_path: &str) -> Result<Vec<RecentContext>> {
    if let Some(db_path) = infer_opencode_db_path(markdown_path)
        && db_path.is_file()
    {
        return load_recent_opencode_database(&db_path);
    }

    let args = vec![
        "session".to_owned(),
        "list".to_owned(),
        "--max-count".to_owned(),
        RECENT_CANDIDATE_LIMIT.to_string(),
        "--format".to_owned(),
        "json".to_owned(),
    ];
    let output = run_opencode_command(&args, markdown_path)
        .with_context(|| "Failed to run opencode session list")?;

    if !output.status.success() {
        let status = output.status.code().map_or_else(
            || "terminated by signal".to_owned(),
            |code| format!("exit status {code}"),
        );
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        if stderr.is_empty() {
            return Err(anyhow!("opencode session list failed ({status})"));
        }
        return Err(anyhow!("opencode session list failed ({status}): {stderr}"));
    }

    let stdout = String::from_utf8(output.stdout)
        .context("opencode session list returned non-UTF-8 output")?;
    parse_opencode_session_list(&stdout)
}

fn load_recent_opencode_database(db_path: &PathBuf) -> Result<Vec<RecentContext>> {
    match query_recent_opencode_contexts(db_path) {
        Ok(items) => Ok(items),
        Err(error) if is_locked_sqlite_error(&error) => {
            let snapshot = snapshot_sqlite_database(db_path)?;
            let result = query_recent_opencode_contexts(&snapshot)
                .with_context(|| format!("Failed to read snapshot of {}", db_path.display()));
            let _ = remove_snapshot_database(&snapshot);
            result
        }
        Err(error) => Err(error).with_context(|| format!("Failed to read {}", db_path.display())),
    }
}

fn query_recent_opencode_contexts(db_path: &PathBuf) -> rusqlite::Result<Vec<RecentContext>> {
    let connection = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    let _ = connection.busy_timeout(Duration::from_millis(250));
    let query = format!(
        "SELECT id, title, parent_id, time_updated, directory
         FROM session
         WHERE time_archived IS NULL
           AND TRIM(COALESCE(parent_id, '')) = ''
         ORDER BY time_updated DESC
         LIMIT {}",
        RECENT_CANDIDATE_LIMIT
    );
    let mut statement = connection.prepare(&query)?;

    let rows = statement.query_map([], |row| {
        let id: String = row.get(0)?;
        let title: String = row.get(1)?;
        let parent_id: Option<String> = row.get(2)?;
        let directory: String = row.get(4)?;
        Ok(RecentContext {
            provider: PROVIDER_OPENCODE.to_owned(),
            id,
            title,
            updated_at: normalize_epoch_millis(row.get(3)?),
            forked_from_id: parent_id
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty()),
            work_dir: Some(directory.trim().to_owned()).filter(|value| !value.is_empty()),
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

#[cfg(not(target_os = "windows"))]
fn run_opencode_command(args: &[String], _: &str) -> Result<Output> {
    Command::new(PROVIDER_OPENCODE)
        .args(args)
        .output()
        .map_err(anyhow::Error::from)
}

#[cfg(target_os = "windows")]
fn run_opencode_command(args: &[String], markdown_path: &str) -> Result<Output> {
    let native = Command::new(PROVIDER_OPENCODE)
        .creation_flags(CREATE_NO_WINDOW)
        .args(args)
        .output();
    if let Ok(output) = &native
        && output.status.success()
    {
        return Ok(native.expect("checked native OpenCode output"));
    }

    match run_wsl_opencode_command(args, markdown_path) {
        Ok(output) => Ok(output),
        Err(wsl_error) => match native {
            Ok(output) => Ok(output),
            Err(native_error) => Err(anyhow!(
                "native OpenCode failed: {native_error}; WSL OpenCode failed: {wsl_error}"
            )),
        },
    }
}

#[cfg(target_os = "windows")]
fn run_wsl_opencode_command(args: &[String], markdown_path: &str) -> Result<Output> {
    let distro = infer_wsl_distro(markdown_path);

    if let Some(executable) = infer_wsl_opencode_path(markdown_path) {
        let mut configured = Command::new("wsl.exe");
        configured.creation_flags(CREATE_NO_WINDOW);
        if let Some(distro) = distro.as_deref() {
            configured.args(["-d", distro]);
        }
        let configured = configured.arg("--").arg(executable).args(args).output();
        if let Ok(output) = &configured
            && output.status.success()
        {
            return Ok(configured.expect("checked configured WSL OpenCode output"));
        }
    }

    let mut direct = Command::new("wsl.exe");
    direct.creation_flags(CREATE_NO_WINDOW);
    if let Some(distro) = distro.as_deref() {
        direct.args(["-d", distro]);
    }
    let direct = direct.arg("--").arg(PROVIDER_OPENCODE).args(args).output();
    if let Ok(output) = &direct
        && output.status.success()
    {
        return Ok(direct.expect("checked direct WSL OpenCode output"));
    }

    let shell_command = format!(
        "opencode {}",
        args.iter()
            .map(|value| value.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    );
    let mut shell = Command::new("wsl.exe");
    shell.creation_flags(CREATE_NO_WINDOW);
    if let Some(distro) = distro.as_deref() {
        shell.args(["-d", distro]);
    }
    let shell = shell
        .args(["--", "bash", "-lc", shell_command.as_str()])
        .output()
        .with_context(|| "Failed to start wsl.exe for OpenCode")?;
    if shell.status.success() {
        return Ok(shell);
    }

    let status = shell.status.code().map_or_else(
        || "terminated by signal".to_owned(),
        |code| format!("exit status {code}"),
    );
    let stderr = String::from_utf8_lossy(&shell.stderr).trim().to_owned();
    if stderr.is_empty() {
        Err(anyhow!("wsl OpenCode failed ({status})"))
    } else {
        Err(anyhow!("wsl OpenCode failed ({status}): {stderr}"))
    }
}

#[cfg(target_os = "windows")]
fn infer_wsl_distro(markdown_path: &str) -> Option<String> {
    let normalized = markdown_path.replace('\\', "/");
    let path = normalized
        .strip_prefix("//wsl.localhost/")
        .or_else(|| normalized.strip_prefix("//wsl$/"))?;
    path.split('/')
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

#[cfg(target_os = "windows")]
fn infer_wsl_opencode_path(markdown_path: &str) -> Option<String> {
    let normalized = markdown_path.replace('\\', "/");
    let path = normalized
        .strip_prefix("//wsl.localhost/")
        .or_else(|| normalized.strip_prefix("//wsl$/"))?;
    let (_, home_path) = path.split_once('/')?;
    let home_path = home_path.strip_suffix("/codex-out/codex sessions.md")?;
    if home_path.is_empty() {
        return None;
    }
    Some(format!("{home_path}/.opencode/bin/opencode"))
}

fn parse_opencode_session_list(text: &str) -> Result<Vec<RecentContext>> {
    if text.trim().is_empty() {
        return Ok(Vec::new());
    }
    let value: serde_json::Value =
        serde_json::from_str(text.trim()).context("Failed to parse opencode session list JSON")?;
    let sessions = if let Some(sessions) = value.as_array() {
        sessions
    } else if let Some(object) = value.as_object() {
        ["sessions", "items", "data", "results"]
            .iter()
            .find_map(|key| object.get(*key).and_then(serde_json::Value::as_array))
            .ok_or_else(|| {
                anyhow!("opencode session list JSON must be an array or contain a session array")
            })?
    } else {
        return Err(anyhow!(
            "opencode session list JSON must be an array or object"
        ));
    };

    let mut recent = Vec::new();
    for session in sessions {
        let Some(item) = parse_opencode_session(session) else {
            continue;
        };
        if item.forked_from_id.is_some() {
            continue;
        }
        recent.push(item);
    }

    recent.sort_by_key(|item| std::cmp::Reverse(item.updated_at));
    let mut seen = std::collections::HashSet::new();
    Ok(recent
        .into_iter()
        .filter(|item| seen.insert(item.id.clone()))
        .take(RECENT_LIMIT)
        .collect())
}

fn parse_opencode_session(value: &serde_json::Value) -> Option<RecentContext> {
    let object = value.as_object()?;
    let id = first_nonempty_string(object, &["id", "sessionID", "sessionId"])?;
    let title =
        first_nonempty_string(object, &["title", "name"]).unwrap_or_else(|| short_session_id(&id));
    let updated_at = ["updated_at", "updatedAt", "updated", "lastUpdatedAt"]
        .iter()
        .find_map(|key| object.get(*key).and_then(parse_json_timestamp))
        .or_else(|| {
            object
                .get("time")
                .and_then(serde_json::Value::as_object)
                .and_then(|time| {
                    ["updated", "updated_at", "updatedAt"]
                        .iter()
                        .find_map(|key| time.get(*key).and_then(parse_json_timestamp))
                })
        })?;
    let forked_from_id = first_nonempty_string(
        object,
        &[
            "forked_from_id",
            "forkedFromId",
            "forkedFrom",
            "parent_id",
            "parentId",
            "parentID",
        ],
    );
    let work_dir = first_nonempty_string(object, &["work_dir", "workDir", "cwd", "directory"]);

    Some(RecentContext {
        provider: PROVIDER_OPENCODE.to_owned(),
        id,
        title,
        updated_at,
        forked_from_id,
        work_dir,
    })
}

fn first_nonempty_string(
    object: &serde_json::Map<String, serde_json::Value>,
    keys: &[&str],
) -> Option<String> {
    keys.iter().find_map(|key| {
        object
            .get(*key)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn parse_json_timestamp(value: &serde_json::Value) -> Option<i64> {
    if let Some(number) = value.as_i64() {
        return Some(normalize_epoch_millis(number));
    }
    if let Some(number) = value.as_u64() {
        return i64::try_from(number).ok().map(normalize_epoch_millis);
    }
    if let Some(number) = value.as_f64()
        && number.is_finite()
        && number.fract() == 0.0
        && number >= i64::MIN as f64
        && number <= i64::MAX as f64
    {
        return Some(normalize_epoch_millis(number as i64));
    }
    value.as_str().and_then(|value| {
        let value = value.trim();
        value
            .parse::<i64>()
            .ok()
            .map(normalize_epoch_millis)
            .or_else(|| parse_iso8601_utc_ms(value))
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
    let has_thread_source = sqlite_table_has_column(&connection, "threads", "thread_source")?;
    let mut selected_columns = String::from("id, title, updated_at, rollout_path");
    let cwd_index = if has_cwd {
        selected_columns.push_str(", cwd");
        Some(4)
    } else {
        None
    };
    let thread_source_index = if has_thread_source {
        let index = selected_columns.split(',').count();
        selected_columns.push_str(", thread_source");
        Some(index)
    } else {
        None
    };
    let query = format!(
        "SELECT {selected_columns}
         FROM threads
         WHERE archived = 0
         ORDER BY updated_at DESC"
    );
    let mut statement = connection.prepare(&query)?;

    let rows = statement.query_map([], |row| {
        let rollout_path = row.get::<_, String>(3)?;
        let resolved_rollout = resolve_codex_rollout_path(codex_home, &rollout_path);
        let thread_source = thread_source_index
            .map(|index| row.get::<_, Option<String>>(index))
            .transpose()?
            .flatten();
        if thread_source
            .as_deref()
            .is_some_and(is_codex_subagent_thread_source)
            || read_codex_rollout_is_subagent(&resolved_rollout)
        {
            return Ok(None);
        }

        Ok(Some(RecentContext {
            provider: PROVIDER_CODEX.to_owned(),
            id: row.get::<_, String>(0)?,
            title: row.get::<_, String>(1)?,
            updated_at: normalize_epoch_millis(row.get::<_, i64>(2)?),
            forked_from_id: read_forked_from_id(&resolved_rollout).ok().flatten(),
            work_dir: cwd_index
                .map(|index| row.get::<_, Option<String>>(index))
                .transpose()?
                .flatten(),
        }))
    })?;

    let mut seen = std::collections::HashSet::new();
    let mut items = Vec::new();
    for row in rows {
        let Some(item) = row? else {
            continue;
        };
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

fn is_codex_subagent_thread_source(value: &str) -> bool {
    value.trim().eq_ignore_ascii_case("subagent")
}

fn read_codex_rollout_is_subagent(rollout_path: &Path) -> bool {
    let Ok(file) = fs::File::open(rollout_path) else {
        return false;
    };
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let Ok(read) = reader.read_line(&mut line) else {
        return false;
    };
    if read == 0 {
        return false;
    }

    let Ok(value) = serde_json::from_str::<serde_json::Value>(line.trim_end()) else {
        return false;
    };
    value
        .get("payload")
        .and_then(|payload| payload.get("thread_source"))
        .and_then(serde_json::Value::as_str)
        .is_some_and(is_codex_subagent_thread_source)
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

fn infer_opencode_db_path(markdown_path: &str) -> Option<PathBuf> {
    let home_root = infer_user_home_root(markdown_path)?;
    Some(
        home_root
            .join(".local")
            .join("share")
            .join("opencode")
            .join("opencode.db"),
    )
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

    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

fn validate_codex_account_slot(value: &str) -> Result<String> {
    let slot = value.trim();
    if slot.is_empty()
        || slot == "0"
        || !slot.chars().all(|character| character.is_ascii_digit())
        || (slot.len() > 1 && slot.starts_with('0'))
    {
        return Err(anyhow!(
            "Codex account slot must be a positive numeric value such as 1 or 2."
        ));
    }
    Ok(slot.to_owned())
}

fn normalize_codex_account_display_name(value: &str) -> Result<String> {
    let display_name = value.trim();
    if display_name.is_empty() || display_name.chars().any(|character| character.is_control()) {
        return Err(anyhow!(
            "Codex account display name must be non-empty text."
        ));
    }
    let bounded = display_name
        .chars()
        .take(MAX_CODEX_ACCOUNT_DISPLAY_NAME_CHARS)
        .collect::<String>();
    if bounded.is_empty() {
        return Err(anyhow!(
            "Codex account display name must be non-empty text."
        ));
    }
    Ok(bounded)
}

fn infer_codex_account_paths(markdown_path: &str) -> Result<CodexAccountPaths> {
    let home_root = infer_user_home_root(markdown_path)
        .ok_or_else(|| anyhow!("Pick a sessions markdown file before using Codex accounts."))?;
    let codex_dir = home_root.join(".codex");
    Ok(CodexAccountPaths {
        auth_path: codex_dir.join(CODEX_AUTH_FILE),
        accounts_dir: codex_dir.join(CODEX_ACCOUNTS_DIR),
    })
}

fn account_snapshot_path(accounts_dir: &Path, slot: &str) -> Result<PathBuf> {
    let slot = validate_codex_account_slot(slot)?;
    Ok(accounts_dir.join(format!("{slot}.json")))
}

fn account_metadata_path(accounts_dir: &Path) -> PathBuf {
    accounts_dir.join(CODEX_ACCOUNT_METADATA_FILE)
}

fn infer_codex_live_auth_path(accounts_dir: &Path) -> Option<PathBuf> {
    accounts_dir
        .parent()
        .map(|codex_dir| codex_dir.join(CODEX_AUTH_FILE))
}

const CODEX_ACTIVE_ACCOUNT_OWNERSHIP_ERROR: &str = "Save current Codex credentials once because the live account's saved-slot ownership cannot be determined uniquely.";

fn codex_active_account_ownership_error() -> anyhow::Error {
    anyhow!(CODEX_ACTIVE_ACCOUNT_OWNERSHIP_ERROR)
}

fn resolve_codex_active_account_slot(
    paths: &CodexAccountPaths,
    _current_slot_hint: &str,
) -> Result<String> {
    // The persisted Dart hint is advisory and may be empty or stale.
    let live_auth_bytes = read_json_object_bytes(
        &paths.auth_path,
        CODEX_ACTIVE_ACCOUNT_OWNERSHIP_ERROR,
        CODEX_ACTIVE_ACCOUNT_OWNERSHIP_ERROR,
    )?;
    let live_identity = codex_auth_account_id(&live_auth_bytes);
    let mut identity_matches = Vec::new();
    let mut byte_matches = Vec::new();

    for (slot, path) in list_codex_account_snapshot_paths(&paths.accounts_dir)? {
        let Ok(snapshot_bytes) = read_codex_snapshot_bytes_for_usage(&path) else {
            continue;
        };
        if live_identity.as_deref().is_some_and(|live_identity| {
            codex_auth_account_id(&snapshot_bytes).as_deref() == Some(live_identity)
        }) {
            identity_matches.push(slot.clone());
        }
        if snapshot_bytes == live_auth_bytes {
            byte_matches.push(slot);
        }
    }

    if identity_matches.len() == 1 {
        return Ok(identity_matches.remove(0));
    }
    if identity_matches.len() > 1 {
        return Err(codex_active_account_ownership_error());
    }
    if byte_matches.len() == 1 {
        return Ok(byte_matches.remove(0));
    }
    Err(codex_active_account_ownership_error())
}

fn unix_epoch_millis() -> Result<i64> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| anyhow!("System clock is before the Unix epoch."))?;
    i64::try_from(duration.as_millis())
        .map_err(|_| anyhow!("System clock is outside the supported range."))
}

fn validate_codex_manual_reset_at(manual_reset_at: i64) -> Result<()> {
    if manual_reset_at <= unix_epoch_millis()? {
        return Err(anyhow!(
            "Codex manual reset timestamp must be in the future."
        ));
    }
    Ok(())
}

fn effective_codex_manual_reset_at(
    accounts_dir: &Path,
    labels: &mut CodexAccountLabels,
) -> Result<Option<i64>> {
    let Some(manual_reset_at) = labels.manual_reset_at else {
        return Ok(None);
    };
    if manual_reset_at > unix_epoch_millis()? {
        return Ok(Some(manual_reset_at));
    }

    labels.manual_reset_at = None;
    write_codex_account_labels(accounts_dir, labels)?;
    Ok(None)
}

fn apply_codex_weekly_usage_history(
    slot: &str,
    account_key: Option<&str>,
    mut usage: WeeklyUsage,
    account_reset_at: Option<i64>,
    states: &mut std::collections::BTreeMap<String, CodexWeeklyUsageState>,
) -> (WeeklyUsage, bool) {
    usage.reset_at_ms = account_reset_at;
    usage.reset_after_seconds = None;
    let Some(account_key) = account_key.filter(|key| is_valid_codex_account_key(key)) else {
        return (usage, states.remove(slot).is_some());
    };
    let Some(previous) = states.get(slot) else {
        return (usage, false);
    };
    if previous.account_key != account_key {
        return (usage, states.remove(slot).is_some());
    }
    if usage.used_percent == 0.0
        && previous.used_percent > 0.0
        && Some(previous.reset_at) == account_reset_at
    {
        usage.used_percent = previous.used_percent;
        usage.window_seconds = previous.window_seconds;
    }
    (usage, false)
}

fn remember_codex_weekly_usage(
    slot: &str,
    account_key: Option<&str>,
    usage: &WeeklyUsage,
    reset_at: Option<i64>,
    response_received_at_ms: i64,
    states: &mut std::collections::BTreeMap<String, CodexWeeklyUsageState>,
) -> bool {
    let Some(account_key) = account_key.filter(|key| is_valid_codex_account_key(key)) else {
        return states.remove(slot).is_some();
    };
    let Some(reset_at) = reset_at.filter(|reset_at| *reset_at > response_received_at_ms) else {
        return states.remove(slot).is_some();
    };
    let state = CodexWeeklyUsageState {
        account_key: account_key.to_owned(),
        used_percent: usage.used_percent,
        reset_at,
        window_seconds: usage.window_seconds,
    };
    states.insert(slot.to_owned(), state.clone()).as_ref() != Some(&state)
}

fn load_codex_accounts_for_markdown(
    markdown_path: &str,
    current_slot_hint: &str,
) -> Result<LoadedCodexAccounts> {
    if markdown_path.trim().is_empty() {
        return Ok(LoadedCodexAccounts {
            accounts: Vec::new(),
            active_slot: None,
            active_slot_error: None,
        });
    }
    let paths = infer_codex_account_paths(markdown_path)?;
    let accounts = list_codex_account_metadata(&paths.accounts_dir)?;
    let (active_slot, active_slot_error) = if accounts.is_empty() {
        (None, None)
    } else {
        match resolve_codex_active_account_slot(&paths, current_slot_hint) {
            Ok(slot) => (Some(slot), None),
            Err(error) => (None, Some(error.to_string())),
        }
    };
    Ok(LoadedCodexAccounts {
        accounts,
        active_slot,
        active_slot_error,
    })
}

fn list_codex_account_snapshot_paths(accounts_dir: &Path) -> Result<Vec<(String, PathBuf)>> {
    if !accounts_dir.is_dir() {
        return Ok(Vec::new());
    }

    let entries =
        fs::read_dir(accounts_dir).map_err(|_| anyhow!("Could not list saved Codex accounts."))?;
    let mut snapshots = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file()
            || !path
                .extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("json"))
        {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|value| value.to_str()) else {
            continue;
        };
        let Ok(slot) = validate_codex_account_slot(stem) else {
            continue;
        };
        snapshots.push((slot, path));
    }
    snapshots.sort_by(|(left, _), (right, _)| compare_codex_account_slots(left, right));
    Ok(snapshots)
}

fn list_codex_account_metadata(accounts_dir: &Path) -> Result<Vec<CodexAccountMetadata>> {
    list_codex_account_metadata_with(
        accounts_dir,
        |slot, snapshot_bytes, live_auth_bytes, now_ms| {
            prepare_codex_account_auth(accounts_dir, slot, snapshot_bytes, live_auth_bytes, now_ms)
        },
        fetch_codex_weekly_usage,
    )
}

fn list_codex_account_metadata_with<P, F>(
    accounts_dir: &Path,
    mut prepare: P,
    fetch: F,
) -> Result<Vec<CodexAccountMetadata>>
where
    P: FnMut(&str, &[u8], Option<&[u8]>, i64) -> std::result::Result<Vec<u8>, CodexUsageError>,
    F: Fn(&[u8]) -> std::result::Result<CodexUsageQuery, CodexUsageError> + Sync,
{
    if !accounts_dir.is_dir() {
        return Ok(Vec::new());
    }

    let live_auth_bytes =
        infer_codex_live_auth_path(accounts_dir).and_then(|path| fs::read(path).ok());
    let now_ms = unix_epoch_millis()?;
    // Mirroring live credentials and renewing saved tokens can write snapshots.
    // Finish those operations serially before starting any read-only usage calls.
    let mut prepared_accounts = Vec::new();
    for (slot, path) in list_codex_account_snapshot_paths(accounts_dir)? {
        let (auth, account_key) = match read_codex_snapshot_bytes_for_usage(&path) {
            Ok(snapshot_bytes) => {
                let original_auth_bytes =
                    prefer_live_codex_auth(&snapshot_bytes, live_auth_bytes.as_deref());
                let account_key = codex_auth_account_key(original_auth_bytes);
                let auth = prepare(&slot, &snapshot_bytes, live_auth_bytes.as_deref(), now_ms);
                (auth, account_key)
            }
            Err(()) => (Err(CodexUsageError::Unavailable), None),
        };
        let updated_at = fs::metadata(&path)
            .ok()
            .and_then(|metadata| metadata.modified().ok())
            .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
            .and_then(|duration| i64::try_from(duration.as_millis()).ok());
        prepared_accounts.push((slot, updated_at, account_key, auth));
    }

    let worker_count = prepared_accounts
        .len()
        .min(CODEX_USAGE_MAX_CONCURRENT_READS);
    let queue = Mutex::new(prepared_accounts.into_iter());
    let mut fetched_accounts = std::thread::scope(|scope| -> Result<Vec<_>> {
        let mut workers = Vec::with_capacity(worker_count);
        for index in 0..worker_count {
            let queue = &queue;
            let fetch = &fetch;
            workers.push(
                std::thread::Builder::new()
                    .name(format!("codex-usage-{index}"))
                    .spawn_scoped(scope, move || -> Result<Vec<_>> {
                        let mut results = Vec::new();
                        loop {
                            let next = queue
                                .lock()
                                .map_err(|_| anyhow!("Could not read Codex usage queue."))?
                                .next();
                            let Some((slot, updated_at, account_key, auth)) = next else {
                                break;
                            };
                            let usage = auth.and_then(|bytes| fetch(&bytes));
                            results.push((slot, updated_at, account_key, usage));
                        }
                        Ok(results)
                    })
                    .map_err(|_| anyhow!("Could not start Codex usage reader."))?,
            );
        }
        let mut results = Vec::new();
        for worker in workers {
            results.extend(
                worker
                    .join()
                    .map_err(|_| anyhow!("Codex usage reader stopped unexpectedly."))??,
            );
        }
        Ok(results)
    })?;
    fetched_accounts.sort_by(|left, right| compare_codex_account_slots(&left.0, &right.0));

    // Merge usage into the latest labels only after network work. A local reset edit
    // must neither wait for the API nor be overwritten by this refresh.
    let _metadata_guard = lock_codex_metadata()?;
    let mut labels = read_codex_account_labels(accounts_dir)?;
    let mut labels_changed = labels.legacy_weekly_reset_at.take().is_some();
    let manual_reset_at = effective_codex_manual_reset_at(accounts_dir, &mut labels)?;
    let mut accounts = Vec::with_capacity(fetched_accounts.len());
    for (slot, updated_at, account_key, usage) in fetched_accounts {
        let name = labels
            .labels
            .get(&slot)
            .cloned()
            .unwrap_or_else(|| slot.clone());
        let (weekly_used_percent, weekly_reset_at, weekly_window_seconds, weekly_error) =
            match usage {
                Ok(query) => {
                    let timing = query.timing;
                    let account_reset_at = query.usage.reset_at_ms;
                    let (usage, history_changed) = apply_codex_weekly_usage_history(
                        &slot,
                        account_key.as_deref(),
                        query.usage,
                        account_reset_at,
                        &mut labels.weekly_usage_state,
                    );
                    let usage_changed = remember_codex_weekly_usage(
                        &slot,
                        account_key.as_deref(),
                        &usage,
                        account_reset_at,
                        timing.response_received_at_ms,
                        &mut labels.weekly_usage_state,
                    );
                    labels_changed |= history_changed || usage_changed;
                    (
                        Some(usage.used_percent),
                        account_reset_at,
                        Some(usage.window_seconds),
                        None,
                    )
                }
                Err(error) => (None, None, None, Some(error.message().to_owned())),
            };
        accounts.push(CodexAccountMetadata {
            slot,
            name,
            updated_at,
            weekly_used_percent,
            weekly_reset_at,
            manual_reset_at,
            weekly_window_seconds,
            weekly_error,
        });
    }
    if labels_changed {
        write_codex_account_labels(accounts_dir, &labels)?;
    }
    Ok(accounts)
}

fn codex_usage_error_for_refresh(error: codex_refresh::RefreshError) -> CodexUsageError {
    match error {
        codex_refresh::RefreshError::CredentialRejected => CodexUsageError::CredentialRejected,
        _ => CodexUsageError::Unavailable,
    }
}

fn prepare_codex_account_auth_with<F>(
    accounts_dir: &Path,
    slot: &str,
    snapshot_bytes: &[u8],
    live_auth_bytes: Option<&[u8]>,
    now_ms: i64,
    refresh: F,
) -> std::result::Result<Vec<u8>, CodexUsageError>
where
    F: FnOnce(&[u8], i64) -> std::result::Result<Vec<u8>, codex_refresh::RefreshError>,
{
    if let Some(live_auth_bytes) = live_auth_bytes {
        let identities_match = match (
            codex_refresh::account_identity(snapshot_bytes),
            codex_refresh::account_identity(live_auth_bytes),
        ) {
            (Some(snapshot_identity), Some(live_identity)) => snapshot_identity == live_identity,
            _ => false,
        };
        if identities_match {
            if snapshot_bytes != live_auth_bytes {
                save_snapshot_bytes(accounts_dir, slot, live_auth_bytes)
                    .map_err(|_| CodexUsageError::Unavailable)?;
            }
            return Ok(live_auth_bytes.to_vec());
        }
    }

    let should_refresh = codex_refresh::needs_refresh(snapshot_bytes, now_ms)
        .map_err(|_| CodexUsageError::Unavailable)?;
    if !should_refresh {
        return Ok(snapshot_bytes.to_vec());
    }

    let refreshed_bytes = refresh(snapshot_bytes, now_ms).map_err(codex_usage_error_for_refresh)?;
    save_snapshot_bytes(accounts_dir, slot, &refreshed_bytes)
        .map_err(|_| CodexUsageError::Unavailable)?;
    Ok(refreshed_bytes)
}

fn prepare_codex_account_auth(
    accounts_dir: &Path,
    slot: &str,
    snapshot_bytes: &[u8],
    live_auth_bytes: Option<&[u8]>,
    now_ms: i64,
) -> std::result::Result<Vec<u8>, CodexUsageError> {
    prepare_codex_account_auth_with(
        accounts_dir,
        slot,
        snapshot_bytes,
        live_auth_bytes,
        now_ms,
        codex_refresh::refresh_via_curl,
    )
}

fn compare_codex_account_slots(left: &str, right: &str) -> std::cmp::Ordering {
    left.len().cmp(&right.len()).then_with(|| left.cmp(right))
}

fn read_codex_account_labels(accounts_dir: &Path) -> Result<CodexAccountLabels> {
    let path = account_metadata_path(accounts_dir);
    if !path.is_file() {
        return Ok(CodexAccountLabels::default());
    }
    let bytes = fs::read(path).map_err(|_| anyhow!("Could not read Codex account metadata."))?;
    let mut stored_value = serde_json::from_slice::<serde_json::Value>(&bytes)
        .map_err(|_| anyhow!("Could not read Codex account metadata."))?;
    if let Some(object) = stored_value.as_object_mut() {
        // Discard the retired global API reset anchor instead of treating it as a label.
        object.remove("weekly_cycle_reset_at");
        object.remove("weekly_reset_at_confirmed");
    }
    let stored = serde_json::from_value::<CodexAccountLabels>(stored_value)
        .map_err(|_| anyhow!("Could not read Codex account metadata."))?;
    let labels = stored
        .labels
        .into_iter()
        .filter_map(|(slot, label)| {
            let slot = validate_codex_account_slot(&slot).ok()?;
            let label = normalize_codex_account_display_name(&label).ok()?;
            Some((slot, label))
        })
        .collect();
    let weekly_usage_state = stored
        .weekly_usage_state
        .into_iter()
        .filter_map(|(slot, state)| {
            let slot = validate_codex_account_slot(&slot).ok()?;
            let valid_account_key = is_valid_codex_account_key(&state.account_key);
            (valid_account_key
                && state.used_percent.is_finite()
                && (0.0..=100.0).contains(&state.used_percent)
                && state.reset_at > 0
                && state.window_seconds >= CODEX_WEEKLY_WINDOW_MIN_SECONDS)
                .then_some((slot, state))
        })
        .collect();
    Ok(CodexAccountLabels {
        labels,
        manual_reset_at: stored.manual_reset_at,
        legacy_weekly_reset_at: stored.legacy_weekly_reset_at,
        weekly_usage_state,
    })
}

fn write_codex_account_labels(accounts_dir: &Path, labels: &CodexAccountLabels) -> Result<()> {
    ensure_codex_accounts_dir(accounts_dir)?;
    let path = account_metadata_path(accounts_dir);
    if labels.labels.is_empty()
        && labels.manual_reset_at.is_none()
        && labels.weekly_usage_state.is_empty()
    {
        if path.is_file() {
            fs::remove_file(path)
                .map_err(|_| anyhow!("Could not replace Codex account metadata."))?;
        }
        return Ok(());
    }
    let bytes = serde_json::to_vec_pretty(labels)
        .map_err(|_| anyhow!("Could not prepare Codex account metadata."))?;
    let temp_path = write_temp_bytes(accounts_dir, "account-metadata", &bytes)?;
    if let Err(error) = replace_file_from_temp(&temp_path, &path) {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    Ok(())
}

fn lock_codex_metadata() -> Result<std::sync::MutexGuard<'static, ()>> {
    CODEX_METADATA_LOCK
        .lock()
        .map_err(|_| anyhow!("Could not lock Codex account metadata."))
}

fn set_codex_manual_reset_at(accounts_dir: &Path, manual_reset_at: i64) -> Result<()> {
    validate_codex_manual_reset_at(manual_reset_at)?;
    let _metadata_guard = lock_codex_metadata()?;
    let mut labels = read_codex_account_labels(accounts_dir)?;
    labels.manual_reset_at = Some(manual_reset_at);
    write_codex_account_labels(accounts_dir, &labels)
}

fn clear_codex_manual_reset_at(accounts_dir: &Path) -> Result<()> {
    let _metadata_guard = lock_codex_metadata()?;
    if !accounts_dir.is_dir() {
        return Ok(());
    }
    let mut labels = read_codex_account_labels(accounts_dir)?;
    if labels.manual_reset_at.is_none() {
        return Ok(());
    }
    labels.manual_reset_at = None;
    write_codex_account_labels(accounts_dir, &labels)
}

fn set_codex_account_label(accounts_dir: &Path, slot: &str, label: &str) -> Result<()> {
    let slot = validate_codex_account_slot(slot)?;
    let label = normalize_codex_account_display_name(label)?;
    let _metadata_guard = lock_codex_metadata()?;
    let mut labels = read_codex_account_labels(accounts_dir)?;
    labels.labels.insert(slot, label);
    write_codex_account_labels(accounts_dir, &labels)
}

fn remove_codex_account_label(accounts_dir: &Path, slot: &str) -> Result<()> {
    let slot = validate_codex_account_slot(slot)?;
    let _metadata_guard = lock_codex_metadata()?;
    let mut labels = read_codex_account_labels(accounts_dir)?;
    labels.labels.remove(&slot);
    labels.weekly_usage_state.remove(&slot);
    write_codex_account_labels(accounts_dir, &labels)
}

fn codex_snapshot_identity_matches(existing_bytes: &[u8], new_bytes: &[u8]) -> bool {
    let Some(existing_identity) = codex_auth_account_id(existing_bytes) else {
        return false;
    };
    let Some(new_identity) = codex_auth_account_id(new_bytes) else {
        return false;
    };
    existing_identity == new_identity
}

fn read_codex_snapshot_bytes_for_usage(path: &Path) -> std::result::Result<Vec<u8>, ()> {
    let bytes = fs::read(path).map_err(|_| ())?;
    let value = serde_json::from_slice::<serde_json::Value>(&bytes).map_err(|_| ())?;
    if !value.is_object() {
        return Err(());
    }
    Ok(bytes)
}

fn codex_auth_account_id(auth_bytes: &[u8]) -> Option<String> {
    let value = serde_json::from_slice::<serde_json::Value>(auth_bytes).ok()?;
    let account_id = value
        .get("tokens")
        .and_then(serde_json::Value::as_object)
        .and_then(|tokens| tokens.get("account_id"))
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| {
            !value.is_empty()
                && !value
                    .chars()
                    .any(|character| character == '\0' || character == '\r' || character == '\n')
        })?;
    Some(account_id.to_owned())
}

fn codex_auth_account_key(auth_bytes: &[u8]) -> Option<String> {
    let account_id = codex_auth_account_id(auth_bytes)?;
    let mut fingerprint = FNV1A_64_OFFSET_BASIS;
    for byte in account_id.as_bytes() {
        fingerprint ^= u64::from(*byte);
        fingerprint = fingerprint.wrapping_mul(FNV1A_64_PRIME);
    }
    // The prefix is part of the persisted format. Any future algorithm change must use a new
    // version so history produced by a different fingerprint cannot be attributed to an account.
    Some(format!("{CODEX_ACCOUNT_KEY_PREFIX}{fingerprint:016x}"))
}

fn is_valid_codex_account_key(account_key: &str) -> bool {
    let Some(payload) = account_key.strip_prefix(CODEX_ACCOUNT_KEY_PREFIX) else {
        return false;
    };
    payload.len() == CODEX_ACCOUNT_KEY_PAYLOAD_LEN
        && payload
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn prefer_live_codex_auth<'a>(
    snapshot_bytes: &'a [u8],
    live_auth_bytes: Option<&'a [u8]>,
) -> &'a [u8] {
    let Some(live_auth_bytes) = live_auth_bytes else {
        return snapshot_bytes;
    };
    let Some(snapshot_account_id) = codex_auth_account_id(snapshot_bytes) else {
        return snapshot_bytes;
    };
    let Some(live_account_id) = codex_auth_account_id(live_auth_bytes) else {
        return snapshot_bytes;
    };
    if snapshot_account_id == live_account_id {
        live_auth_bytes
    } else {
        snapshot_bytes
    }
}

fn codex_auth_tokens(auth_bytes: &[u8]) -> std::result::Result<(String, Option<String>), ()> {
    let value = serde_json::from_slice::<serde_json::Value>(auth_bytes).map_err(|_| ())?;
    let tokens = value
        .get("tokens")
        .and_then(serde_json::Value::as_object)
        .ok_or(())?;
    let access_token = tokens
        .get("access_token")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or(())?
        .to_owned();
    let account_id = tokens
        .get("account_id")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    if access_token
        .chars()
        .any(|character| character == '\0' || character == '\r' || character == '\n')
        || account_id.as_deref().is_some_and(|value| {
            value
                .chars()
                .any(|character| character == '\0' || character == '\r' || character == '\n')
        })
    {
        return Err(());
    }
    Ok((access_token, account_id))
}

fn escape_curl_config_value(value: &str) -> Option<String> {
    if value
        .chars()
        .any(|character| character == '\0' || character == '\r' || character == '\n')
    {
        return None;
    }
    Some(value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn codex_usage_error_for_http_status(status: u16) -> CodexUsageError {
    if matches!(status, 401 | 403) {
        CodexUsageError::CredentialRejected
    } else {
        CodexUsageError::Unavailable
    }
}

fn fetch_codex_weekly_usage(
    auth_bytes: &[u8],
) -> std::result::Result<CodexUsageQuery, CodexUsageError> {
    let (access_token, account_id) =
        codex_auth_tokens(auth_bytes).map_err(|_| CodexUsageError::Unavailable)?;
    let access_token =
        escape_curl_config_value(&access_token).ok_or(CodexUsageError::Unavailable)?;
    let account_id = match account_id.as_deref() {
        Some(account_id) => {
            Some(escape_curl_config_value(account_id).ok_or(CodexUsageError::Unavailable)?)
        }
        None => None,
    };
    let mut curl_config = format!(
        "url = \"{CODEX_USAGE_URL}\"\nheader = \"Accept: application/json\"\nheader = \"Authorization: Bearer {access_token}\"\nconnect-timeout = {CODEX_USAGE_CONNECT_TIMEOUT_SECONDS}\nmax-time = {CODEX_USAGE_TIMEOUT_SECONDS}\n"
    );
    if let Some(account_id) = account_id {
        curl_config.push_str(&format!("header = \"ChatGPT-Account-Id: {account_id}\"\n"));
    }

    // codex-cli 0.147.0 uses this endpoint; feed the bearer header through curl's
    // stdin config so the token is not placed in the child process argument list.
    let request_started_at_ms = unix_epoch_millis().map_err(|_| CodexUsageError::Unavailable)?;
    let mut command = Command::new("curl");
    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);
    let mut child = command
        .args([
            "-q",
            "--silent",
            "--proto",
            "=https",
            "--config",
            "-",
            "--output",
            "-",
            "--max-filesize",
            "524288",
            "--write-out",
            "\n%{http_code}",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| CodexUsageError::Unavailable)?;
    let write_result = child
        .stdin
        .take()
        .ok_or(CodexUsageError::Unavailable)
        .and_then(|mut stdin| {
            stdin
                .write_all(curl_config.as_bytes())
                .map_err(|_| CodexUsageError::Unavailable)
        });
    if write_result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(CodexUsageError::Unavailable);
    }
    let output = child
        .wait_with_output()
        .map_err(|_| CodexUsageError::Unavailable)?;
    let response_received_at_ms = unix_epoch_millis().map_err(|_| CodexUsageError::Unavailable)?;
    if !output.status.success() {
        return Err(CodexUsageError::Unavailable);
    }
    let newline = output
        .stdout
        .iter()
        .rposition(|byte| *byte == b'\n')
        .ok_or(CodexUsageError::Unavailable)?;
    let status = std::str::from_utf8(&output.stdout[newline + 1..])
        .map_err(|_| CodexUsageError::Unavailable)?;
    if status.len() != 3 || !status.chars().all(|character| character.is_ascii_digit()) {
        return Err(CodexUsageError::Unavailable);
    }
    let status = status
        .parse::<u16>()
        .map_err(|_| CodexUsageError::Unavailable)?;
    if !(200..300).contains(&status) {
        return Err(codex_usage_error_for_http_status(status));
    }
    let body = &output.stdout[..newline];
    if body.len() > CODEX_USAGE_MAX_BODY_BYTES {
        return Err(CodexUsageError::Unavailable);
    }
    let usage = parse_weekly_usage_response(body, response_received_at_ms)
        .map_err(|_| CodexUsageError::Unavailable)?;
    Ok(CodexUsageQuery {
        usage,
        timing: CodexUsageRequestTiming {
            request_started_at_ms,
            response_received_at_ms,
        },
    })
}

fn parse_usage_window(value: &serde_json::Value, now_ms: i64) -> Option<WeeklyUsage> {
    let used_percent = value
        .get("used_percent")
        .and_then(serde_json::Value::as_f64)?;
    if !used_percent.is_finite() || !(0.0..=100.0).contains(&used_percent) {
        return None;
    }
    let window_seconds = value.get("limit_window_seconds").and_then(|value| {
        value.as_i64().or_else(|| {
            value
                .as_u64()
                .and_then(|seconds| i64::try_from(seconds).ok())
        })
    })?;
    if window_seconds <= 0 {
        return None;
    }
    let reset_after_seconds = value
        .get("reset_after_seconds")
        .and_then(|value| {
            value.as_i64().or_else(|| {
                value
                    .as_u64()
                    .and_then(|seconds| i64::try_from(seconds).ok())
            })
        })
        .filter(|seconds| *seconds >= 0);
    let reset_at_ms = value
        .get("reset_at")
        .and_then(serde_json::Value::as_i64)
        .and_then(|seconds| seconds.checked_mul(1_000))
        .or_else(|| {
            reset_after_seconds
                .and_then(|seconds| seconds.checked_mul(1_000))
                .and_then(|milliseconds| now_ms.checked_add(milliseconds))
        });
    Some(WeeklyUsage {
        used_percent,
        reset_at_ms,
        reset_after_seconds,
        window_seconds,
    })
}

fn parse_weekly_usage_response(body: &[u8], now_ms: i64) -> std::result::Result<WeeklyUsage, ()> {
    let value = serde_json::from_slice::<serde_json::Value>(body).map_err(|_| ())?;
    let rate_limit = value
        .get("rate_limit")
        .and_then(serde_json::Value::as_object)
        .ok_or(())?;
    let primary = rate_limit
        .get("primary_window")
        .and_then(|value| parse_usage_window(value, now_ms));
    if let Some(primary) = primary.as_ref()
        && primary.window_seconds >= CODEX_WEEKLY_WINDOW_MIN_SECONDS
    {
        return Ok(primary.clone());
    }

    if let Some(secondary) = rate_limit
        .get("secondary_window")
        .and_then(|value| parse_usage_window(value, now_ms))
        .filter(|window| window.window_seconds >= CODEX_WEEKLY_WINDOW_MIN_SECONDS)
    {
        return Ok(secondary);
    }

    Err(())
}

#[derive(Clone, Debug, PartialEq)]
struct MuseUsage {
    tier: Option<String>,
    weekly_used_percent: Option<f64>,
    weekly_reset_at_ms: Option<i64>,
    window_used_percent: Option<f64>,
    window_reset_at_ms: Option<i64>,
    window_duration_mins: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MuseUsageError {
    Unavailable,
    CredentialRejected,
}

impl MuseUsageError {
    fn message(self) -> &'static str {
        match self {
            Self::Unavailable => MUSE_USAGE_ERROR,
            Self::CredentialRejected => MUSE_USAGE_CREDENTIAL_ERROR,
        }
    }
}

fn muse_usage_error_for_http_status(status: u16) -> MuseUsageError {
    if status == 401 || status == 403 {
        MuseUsageError::CredentialRejected
    } else {
        MuseUsageError::Unavailable
    }
}

fn muse_auth_api_key(auth_bytes: &[u8]) -> Option<(String, String)> {
    let value: serde_json::Value = serde_json::from_slice(auth_bytes).ok()?;
    let meta = value.get("providers")?.get("meta")?;
    let api_key = meta.get("api_key")?.as_str()?.trim();
    if api_key.is_empty() {
        return None;
    }
    let base_url = meta
        .get("api_base_url")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|url| !url.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| "https://api.meta.ai/v1".to_owned());
    Some((base_url, api_key.to_owned()))
}

fn muse_auth_user_email(auth_bytes: &[u8]) -> Option<String> {
    let value: serde_json::Value = serde_json::from_slice(auth_bytes).ok()?;
    value
        .get("providers")?
        .get("meta")?
        .get("user_email")?
        .as_str()
        .map(str::trim)
        .filter(|email| !email.is_empty())
        .map(ToOwned::to_owned)
}

fn fetch_muse_subscription_usage(
    auth_bytes: &[u8],
) -> std::result::Result<MuseUsage, MuseUsageError> {
    let (base_url, api_key) = muse_auth_api_key(auth_bytes).ok_or(MuseUsageError::Unavailable)?;
    let api_key = escape_curl_config_value(&api_key).ok_or(MuseUsageError::Unavailable)?;
    let url = format!("{}{MUSE_USAGE_URL_PATH}", base_url.trim_end_matches('/'));
    let request_body = format!(
        "{{\"model\":\"{MUSE_USAGE_MODEL}\",\"input\":\"{MUSE_USAGE_PROMPT}\",\"stream\":true}}"
    );
    let curl_config = format!(
        "url = \"{url}\"\nheader = \"Accept: text/event-stream\"\nheader = \"Content-Type: application/json\"\nheader = \"Authorization: Bearer {api_key}\"\nconnect-timeout = {MUSE_USAGE_CONNECT_TIMEOUT_SECONDS}\nmax-time = {MUSE_USAGE_TIMEOUT_SECONDS}\n"
    );

    // The refresh burns a few tokens on a minimal completion; the
    // subscription_usage SSE event rides the response. The POST body carries
    // no secrets, so it travels via argv while the key uses stdin config.
    let mut command = Command::new("curl");
    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);
    let mut child = command
        .args([
            "-q",
            "--silent",
            "--proto",
            "=https",
            "--config",
            "-",
            "--output",
            "-",
            "--max-filesize",
            "524288",
            "--write-out",
            "\n%{http_code}",
            "-X",
            "POST",
            "-d",
            &request_body,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| MuseUsageError::Unavailable)?;
    let write_result = child
        .stdin
        .take()
        .ok_or(MuseUsageError::Unavailable)
        .and_then(|mut stdin| {
            stdin
                .write_all(curl_config.as_bytes())
                .map_err(|_| MuseUsageError::Unavailable)
        });
    if write_result.is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return Err(MuseUsageError::Unavailable);
    }
    let output = child
        .wait_with_output()
        .map_err(|_| MuseUsageError::Unavailable)?;
    if !output.status.success() {
        return Err(MuseUsageError::Unavailable);
    }
    let newline = output
        .stdout
        .iter()
        .rposition(|byte| *byte == b'\n')
        .ok_or(MuseUsageError::Unavailable)?;
    let status = std::str::from_utf8(&output.stdout[newline + 1..])
        .map_err(|_| MuseUsageError::Unavailable)?;
    if status.len() != 3 || !status.chars().all(|character| character.is_ascii_digit()) {
        return Err(MuseUsageError::Unavailable);
    }
    let status = status
        .parse::<u16>()
        .map_err(|_| MuseUsageError::Unavailable)?;
    if !(200..300).contains(&status) {
        return Err(muse_usage_error_for_http_status(status));
    }
    let body = &output.stdout[..newline];
    if body.len() > MUSE_USAGE_MAX_BODY_BYTES {
        return Err(MuseUsageError::Unavailable);
    }
    parse_muse_subscription_sse(body).ok_or(MuseUsageError::Unavailable)
}

fn muse_percent(value: &serde_json::Value) -> Option<f64> {
    let percent = value.get("used_percent")?.as_f64()?;
    if !percent.is_finite() || !(0.0..=100.0).contains(&percent) {
        return None;
    }
    Some(percent)
}

fn muse_reset_at_ms(value: &serde_json::Value) -> Option<i64> {
    let seconds = value
        .get("resets_at")?
        .as_i64()
        .or_else(|| {
            value
                .get("resets_at")?
                .as_u64()
                .and_then(|seconds| i64::try_from(seconds).ok())
        })
        .filter(|seconds| *seconds > 0)?;
    seconds.checked_mul(1_000)
}

fn parse_muse_subscription_sse(body: &[u8]) -> Option<MuseUsage> {
    let text = std::str::from_utf8(body).ok()?;
    for line in text.lines() {
        let Some(data) = line.trim().strip_prefix("data:") else {
            continue;
        };
        let data = data.trim();
        if data.is_empty() || data.trim_matches('"') == "[DONE]" {
            continue;
        }
        let Ok(value) = serde_json::from_str::<serde_json::Value>(data) else {
            continue;
        };
        if value.get("type").and_then(serde_json::Value::as_str)
            != Some("response.subscription_usage")
        {
            continue;
        }
        let subscription = value.get("subscription")?;
        let tier = subscription
            .get("tier")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|tier| !tier.is_empty())
            .map(ToOwned::to_owned);
        let weekly = subscription.get("weekly");
        let window = subscription.get("window");
        let weekly_used_percent = weekly.and_then(muse_percent);
        let weekly_reset_at_ms = weekly.and_then(muse_reset_at_ms);
        let window_used_percent = window.and_then(muse_percent);
        let window_reset_at_ms = window.and_then(muse_reset_at_ms);
        let window_duration_mins = window
            .and_then(|window| window.get("window_duration_mins"))
            .and_then(|value| {
                value
                    .as_i64()
                    .or_else(|| value.as_u64().and_then(|mins| i64::try_from(mins).ok()))
            })
            .filter(|mins| *mins > 0);
        if weekly_used_percent.is_none() && window_used_percent.is_none() {
            continue;
        }
        return Some(MuseUsage {
            tier,
            weekly_used_percent,
            weekly_reset_at_ms,
            window_used_percent,
            window_reset_at_ms,
            window_duration_mins,
        });
    }
    None
}

fn read_json_object_bytes(
    path: &Path,
    missing_message: &str,
    invalid_message: &str,
) -> Result<Vec<u8>> {
    let bytes = fs::read(path).map_err(|_| anyhow!("{}", missing_message))?;
    let value: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| anyhow!("{}", invalid_message))?;
    if !value.is_object() {
        return Err(anyhow!("{}", invalid_message));
    }
    Ok(bytes)
}

fn ensure_codex_accounts_dir(accounts_dir: &Path) -> Result<()> {
    fs::create_dir_all(accounts_dir)
        .map_err(|_| anyhow!("Could not create Codex account storage."))?;
    #[cfg(unix)]
    fs::set_permissions(accounts_dir, fs::Permissions::from_mode(0o700))
        .map_err(|_| anyhow!("Could not secure Codex account storage."))?;
    Ok(())
}

fn write_temp_bytes(parent: &Path, prefix: &str, bytes: &[u8]) -> Result<PathBuf> {
    for attempt in 0..16_u32 {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let temp_path = parent.join(format!(
            ".context-{prefix}-{}-{stamp}-{attempt}.tmp",
            std::process::id()
        ));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file = match options.open(&temp_path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return Err(anyhow!("Could not prepare Codex account data.")),
        };
        if file.write_all(bytes).is_err() || file.sync_all().is_err() {
            let _ = fs::remove_file(&temp_path);
            return Err(anyhow!("Could not prepare Codex account data."));
        }
        return Ok(temp_path);
    }
    Err(anyhow!("Could not prepare Codex account data."))
}

#[cfg(target_os = "windows")]
fn replace_file_from_temp(temp_path: &Path, target_path: &Path) -> Result<()> {
    use std::os::windows::ffi::OsStrExt;

    const MOVEFILE_REPLACE_EXISTING: u32 = 0x0000_0001;
    const MOVEFILE_WRITE_THROUGH: u32 = 0x0000_0008;

    unsafe extern "system" {
        fn MoveFileExW(
            existing_file_name: *const u16,
            new_file_name: *const u16,
            flags: u32,
        ) -> i32;
    }

    let temp_wide = temp_path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let target_wide = target_path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let replaced = unsafe {
        MoveFileExW(
            temp_wide.as_ptr(),
            target_wide.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if replaced == 0 {
        return Err(anyhow!("Could not replace Codex account data."));
    }
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn replace_file_from_temp(temp_path: &Path, target_path: &Path) -> Result<()> {
    fs::rename(temp_path, target_path).map_err(|_| anyhow!("Could not replace Codex account data."))
}

fn save_snapshot_bytes(accounts_dir: &Path, slot: &str, bytes: &[u8]) -> Result<()> {
    ensure_codex_accounts_dir(accounts_dir)?;
    let target_path = account_snapshot_path(accounts_dir, slot)?;
    let temp_path = write_temp_bytes(accounts_dir, "account", bytes)?;
    if let Err(error) = replace_file_from_temp(&temp_path, &target_path) {
        let _ = fs::remove_file(&temp_path);
        return Err(error);
    }
    Ok(())
}

fn set_codex_manual_reset_file(markdown_path: &str, manual_reset_at: i64) -> Result<()> {
    let paths = infer_codex_account_paths(markdown_path)?;
    set_codex_manual_reset_at(&paths.accounts_dir, manual_reset_at)
}

fn clear_codex_manual_reset_file(markdown_path: &str) -> Result<()> {
    let paths = infer_codex_account_paths(markdown_path)?;
    clear_codex_manual_reset_at(&paths.accounts_dir)
}

fn save_codex_account_file(
    markdown_path: &str,
    slot: &str,
    display_name: &str,
) -> Result<Vec<CodexAccountMetadata>> {
    let slot = validate_codex_account_slot(slot)?;
    let display_name = normalize_codex_account_display_name(display_name)?;
    let paths = infer_codex_account_paths(markdown_path)?;
    let bytes = read_json_object_bytes(
        &paths.auth_path,
        "Current Codex credentials are unavailable.",
        "Current Codex credentials are invalid.",
    )?;
    let snapshot_path = account_snapshot_path(&paths.accounts_dir, &slot)?;
    let preserve_weekly_usage = fs::read(snapshot_path)
        .ok()
        .is_some_and(|existing_bytes| codex_snapshot_identity_matches(&existing_bytes, &bytes));
    save_snapshot_bytes(&paths.accounts_dir, &slot, &bytes)?;
    let metadata_guard = lock_codex_metadata()?;
    let mut labels = read_codex_account_labels(&paths.accounts_dir)?;
    if !preserve_weekly_usage {
        labels.weekly_usage_state.remove(&slot);
    }
    labels.labels.insert(slot, display_name);
    write_codex_account_labels(&paths.accounts_dir, &labels)?;
    drop(metadata_guard);
    list_codex_account_metadata(&paths.accounts_dir)
}

fn replace_live_auth_with_rollback<F>(
    auth_path: &Path,
    target_bytes: &[u8],
    mut replace: F,
) -> Result<()>
where
    F: FnMut(&Path, &Path) -> Result<()>,
{
    let parent = auth_path
        .parent()
        .ok_or_else(|| anyhow!("Could not switch Codex account."))?;
    let backup_path = parent.join(format!(
        ".context-auth-backup-{}-{}.tmp",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    if fs::copy(auth_path, &backup_path).is_err() {
        return Err(anyhow!("Could not back up current Codex credentials."));
    }
    #[cfg(unix)]
    let _ = fs::set_permissions(&backup_path, fs::Permissions::from_mode(0o600));

    let target_temp = match write_temp_bytes(parent, "live-auth", target_bytes) {
        Ok(path) => path,
        Err(error) => {
            let _ = fs::remove_file(&backup_path);
            return Err(error);
        }
    };
    if replace(&target_temp, auth_path).is_ok() {
        let _ = fs::remove_file(&backup_path);
        return Ok(());
    }
    let _ = fs::remove_file(&target_temp);

    let original_bytes = match fs::read(&backup_path) {
        Ok(bytes) => bytes,
        Err(_) => {
            let _ = fs::remove_file(&backup_path);
            return Err(anyhow!(
                "Could not switch Codex account; original credentials could not be restored."
            ));
        }
    };
    let restore_temp = match write_temp_bytes(parent, "restore-auth", &original_bytes) {
        Ok(path) => path,
        Err(_) => {
            let _ = fs::remove_file(&backup_path);
            return Err(anyhow!(
                "Could not switch Codex account; original credentials could not be restored."
            ));
        }
    };
    let restored = replace(&restore_temp, auth_path).is_ok();
    if !restored {
        let _ = fs::remove_file(&restore_temp);
    }
    let _ = fs::remove_file(&backup_path);
    if restored {
        Err(anyhow!(
            "Could not switch Codex account; original credentials were restored."
        ))
    } else {
        Err(anyhow!(
            "Could not switch Codex account; original credentials could not be restored."
        ))
    }
}

fn switch_codex_account_file(
    markdown_path: &str,
    current_slot_hint: &str,
    target_slot: &str,
) -> Result<Vec<CodexAccountMetadata>> {
    let target_slot = validate_codex_account_slot(target_slot)?;
    ensure_codex_not_running(markdown_path)?;
    let paths = infer_codex_account_paths(markdown_path)?;
    let current_bytes = read_json_object_bytes(
        &paths.auth_path,
        "Current Codex credentials are unavailable.",
        "Current Codex credentials are invalid.",
    )?;
    let current_slot = resolve_codex_active_account_slot(&paths, current_slot_hint)?;
    let target_bytes = if current_slot == target_slot {
        current_bytes.clone()
    } else {
        let target_path = account_snapshot_path(&paths.accounts_dir, &target_slot)?;
        read_json_object_bytes(
            &target_path,
            "Selected Codex account is unavailable.",
            "Selected Codex account is invalid.",
        )?
    };

    save_snapshot_bytes(&paths.accounts_dir, &current_slot, &current_bytes)?;
    replace_live_auth_with_rollback(&paths.auth_path, &target_bytes, replace_file_from_temp)?;
    list_codex_account_metadata(&paths.accounts_dir)
}

fn rename_codex_account_file(
    markdown_path: &str,
    slot: &str,
    display_name: &str,
) -> Result<Vec<CodexAccountMetadata>> {
    let slot = validate_codex_account_slot(slot)?;
    let display_name = normalize_codex_account_display_name(display_name)?;
    let paths = infer_codex_account_paths(markdown_path)?;
    let snapshot_path = account_snapshot_path(&paths.accounts_dir, &slot)?;
    if !snapshot_path.is_file() {
        return Err(anyhow!("Selected Codex account is unavailable."));
    }
    set_codex_account_label(&paths.accounts_dir, &slot, &display_name)?;
    list_codex_account_metadata(&paths.accounts_dir)
}

fn delete_codex_account_file(markdown_path: &str, slot: &str) -> Result<Vec<CodexAccountMetadata>> {
    let slot = validate_codex_account_slot(slot)?;
    let paths = infer_codex_account_paths(markdown_path)?;
    let snapshot_path = account_snapshot_path(&paths.accounts_dir, &slot)?;
    if !snapshot_path.is_file() {
        return Err(anyhow!("Selected Codex account is unavailable."));
    }
    let _ = read_codex_account_labels(&paths.accounts_dir)?;
    let snapshot_bytes =
        fs::read(&snapshot_path).map_err(|_| anyhow!("Could not delete saved Codex account."))?;
    fs::remove_file(&snapshot_path)
        .map_err(|_| anyhow!("Could not delete saved Codex account."))?;
    if let Err(error) = remove_codex_account_label(&paths.accounts_dir, &slot) {
        if save_snapshot_bytes(&paths.accounts_dir, &slot, &snapshot_bytes).is_err() {
            return Err(anyhow!("Could not delete saved Codex account."));
        }
        return Err(error);
    }
    list_codex_account_metadata(&paths.accounts_dir)
}

fn process_listing_has_codex(text: &str) -> bool {
    text.lines().any(|line| {
        line.split_whitespace().any(|token| {
            let token = token
                .trim_matches(['"', '\'', '(', ')', '[', ']', ','])
                .rsplit(['/', '\\'])
                .next()
                .unwrap_or_default()
                .to_ascii_lowercase();
            matches!(
                token.strip_suffix(".exe").unwrap_or(&token),
                "codex" | "codex-cli"
            )
        })
    })
}

#[cfg(target_os = "windows")]
fn ensure_codex_not_running(markdown_path: &str) -> Result<()> {
    if let Some(distro) = infer_wsl_distro(markdown_path) {
        let mut command = Command::new("wsl.exe");
        command.creation_flags(CREATE_NO_WINDOW);
        let output = command
            .args(["-d", distro.as_str(), "--", "ps", "-eo", "comm=,args="])
            .output()
            .map_err(|_| anyhow!("Could not verify whether Codex is running."))?;
        if !output.status.success() {
            return Err(anyhow!("Could not verify whether Codex is running."));
        }
        if process_listing_has_codex(&String::from_utf8_lossy(&output.stdout)) {
            return Err(anyhow!("Close Codex before switching accounts."));
        }
    }

    let script = r#"$processes = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -notmatch '^powershell(\.exe)?$' -and (($_.Name -match '^(codex|codex-cli)(\.exe)?$') -or ($_.CommandLine -and $_.CommandLine -match '(?i)(^|[\\/ ])codex(-cli)?(\.cmd|\.exe)?($|[ \\"/])')) }; if ($processes) { 'codex' }"#;
    let mut command = Command::new("powershell.exe");
    command.creation_flags(CREATE_NO_WINDOW);
    let output = command
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .output()
        .map_err(|_| anyhow!("Could not verify whether Codex is running."))?;
    if !output.status.success() {
        return Err(anyhow!("Could not verify whether Codex is running."));
    }
    if process_listing_has_codex(&String::from_utf8_lossy(&output.stdout)) {
        return Err(anyhow!("Close Codex before switching accounts."));
    }
    Ok(())
}

#[cfg(not(target_os = "windows"))]
fn ensure_codex_not_running(_: &str) -> Result<()> {
    let output = Command::new("ps")
        .args(["-eo", "comm=,args="])
        .output()
        .map_err(|_| anyhow!("Could not verify whether Codex is running."))?;
    if !output.status.success() {
        return Err(anyhow!("Could not verify whether Codex is running."));
    }
    if process_listing_has_codex(&String::from_utf8_lossy(&output.stdout)) {
        return Err(anyhow!("Close Codex before switching accounts."));
    }
    Ok(())
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
}

fn parse_session_command(line: &str) -> Option<ParsedSessionCommand> {
    let command = line.rsplit("&&").next()?.trim();
    let tokens = command.split_whitespace().collect::<Vec<_>>();
    let executable = normalize_executable(tokens.first()?);

    if executable == PROVIDER_CODEX {
        if tokens.len() < 3 || !matches!(tokens[1].to_ascii_lowercase().as_str(), "resume" | "fork")
        {
            return None;
        }
        let command_id = normalize_session_id(tokens[2], PROVIDER_CODEX)?;
        return Some(ParsedSessionCommand {
            provider: PROVIDER_CODEX.to_owned(),
            command_id,
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
                });
            }
            if matches!(normalized.as_str(), "--session" | "--resume" | "-s" | "-r") {
                let command_id = normalize_session_id(tokens.get(index + 1)?, PROVIDER_KIMI)?;
                return Some(ParsedSessionCommand {
                    provider: PROVIDER_KIMI.to_owned(),
                    command_id,
                });
            }
        }
    }

    if executable == PROVIDER_OPENCODE {
        for (index, token) in tokens.iter().enumerate().skip(1) {
            if let Some((flag, value)) = token.split_once('=')
                && matches!(flag.to_ascii_lowercase().as_str(), "--session" | "-s")
            {
                let command_id = normalize_session_id(value, PROVIDER_OPENCODE)?;
                return Some(ParsedSessionCommand {
                    provider: PROVIDER_OPENCODE.to_owned(),
                    command_id,
                });
            }
            if matches!(token.to_ascii_lowercase().as_str(), "--session" | "-s") {
                let command_id = normalize_session_id(tokens.get(index + 1)?, PROVIDER_OPENCODE)?;
                return Some(ParsedSessionCommand {
                    provider: PROVIDER_OPENCODE.to_owned(),
                    command_id,
                });
            }
        }
    }

    if executable == PROVIDER_QWEN {
        for (index, token) in tokens.iter().enumerate().skip(1) {
            if let Some((flag, value)) = token.split_once('=')
                && matches!(flag.to_ascii_lowercase().as_str(), "--resume" | "-r")
            {
                let command_id = normalize_session_id(value, PROVIDER_QWEN)?;
                return Some(ParsedSessionCommand {
                    provider: PROVIDER_QWEN.to_owned(),
                    command_id,
                });
            }
            if matches!(token.to_ascii_lowercase().as_str(), "--resume" | "-r") {
                let command_id = normalize_session_id(tokens.get(index + 1)?, PROVIDER_QWEN)?;
                return Some(ParsedSessionCommand {
                    provider: PROVIDER_QWEN.to_owned(),
                    command_id,
                });
            }
        }
    }

    if executable == PROVIDER_MUSE {
        for (index, token) in tokens.iter().enumerate().skip(1) {
            if let Some((flag, value)) = token.split_once('=')
                && matches!(
                    flag.to_ascii_lowercase().as_str(),
                    "--resume" | "--session-id" | "--session" | "-r" | "-s"
                )
            {
                let command_id = normalize_session_id(value, PROVIDER_MUSE)?;
                return Some(ParsedSessionCommand {
                    provider: PROVIDER_MUSE.to_owned(),
                    command_id,
                });
            }
            if matches!(
                token.to_ascii_lowercase().as_str(),
                "--resume" | "--session-id" | "--session" | "-r" | "-s" | "resume"
            ) {
                let command_id = normalize_session_id(tokens.get(index + 1)?, PROVIDER_MUSE)?;
                return Some(ParsedSessionCommand {
                    provider: PROVIDER_MUSE.to_owned(),
                    command_id,
                });
            }
        }
    }

    None
}

fn normalize_executable(value: &str) -> String {
    let trimmed = value.trim().trim_matches(['\'', '"']);
    let basename = trimmed.rsplit(['/', '\\']).next().unwrap_or(trimmed);
    let lowercase = basename.to_ascii_lowercase();
    lowercase
        .strip_suffix(".exe")
        .or_else(|| lowercase.strip_suffix(".cmd"))
        .unwrap_or(&lowercase)
        .to_owned()
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
    let normalized = value.trim().to_ascii_lowercase();
    if normalized == PROVIDER_KIMI {
        PROVIDER_KIMI.to_owned()
    } else if normalized == PROVIDER_OPENCODE {
        PROVIDER_OPENCODE.to_owned()
    } else if normalized == PROVIDER_QWEN || normalized == "qwen-code" || normalized == "qwen code"
    {
        PROVIDER_QWEN.to_owned()
    } else if normalized == PROVIDER_MUSE || normalized == "muse-code" || normalized == "muse code"
    {
        PROVIDER_MUSE.to_owned()
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
            } else if provider == PROVIDER_OPENCODE {
                out.push_str("opencode --session ");
                out.push_str(&command_id);
            } else if provider == PROVIDER_QWEN {
                out.push_str("qwen --resume ");
                out.push_str(&command_id);
            } else if provider == PROVIDER_MUSE {
                out.push_str("muse resume ");
                out.push_str(&command_id);
                out.push_str(" --yolo");
            } else {
                out.push_str("codex resume ");
                out.push_str(&command_id);
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
        } else if item.provider == PROVIDER_QWEN {
            item.command_id.trim().to_owned()
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
        } else if item.is_group_end() {
            item.kind = "group_end".to_owned();
            item.id = normalize_group_id(&item.id);
            item.name.clear();
            item.command_id.clear();
            item.color_hex.clear();
            item.provider.clear();
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
    let value = id.trim();
    const VISIBLE_LENGTH: usize = 4;
    let character_count = value.chars().count();
    if character_count <= VISIBLE_LENGTH {
        return value.to_owned();
    }
    value
        .chars()
        .skip(character_count - VISIBLE_LENGTH)
        .collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn zcode_quota_response_picks_weekly_limit() {
        let body = br#"{"code":200,"msg":"Operation successful","success":true,"data":{
            "level":"lite",
            "limits":[
                {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":1060,"remaining":939,"percentage":53,"nextResetTime":1789698221644},
                {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":2923,"remaining":7076,"percentage":29,"nextResetTime":1790265030984}
            ]
        }}"#;
        let usage = parse_zcode_quota_response(body).expect("parse quota response");
        assert!((usage.used_percent - 29.0).abs() < f64::EPSILON);
        assert_eq!(usage.reset_at_ms, 1_790_265_030_984);
        assert_eq!(usage.window_seconds, 604_800);
    }

    #[test]
    fn zcode_quota_response_rejects_garbage() {
        assert!(parse_zcode_quota_response(b"not json").is_none());
        assert!(parse_zcode_quota_response(br#"{"code":500}"#).is_none());
        assert!(parse_zcode_quota_response(br#"{"data":{"limits":[]}}"#).is_none());
        assert!(
            parse_zcode_quota_response(
                br#"{"data":{"limits":[{"percentage":150,"nextResetTime":123}]}}"#
            )
            .is_none()
        );
    }

    use std::cell::Cell;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    use rusqlite::Connection;

    use super::codex_refresh::RefreshError;
    use super::{
        CODEX_ACTIVE_ACCOUNT_OWNERSHIP_ERROR, CodexAccountPaths, CodexUsageError,
        CodexWeeklyUsageState, ConfigItem, MUSE_USAGE_CREDENTIAL_ERROR, MuseUsageError,
        PROVIDER_CODEX, PROVIDER_KIMI, PROVIDER_OPENCODE, PROVIDER_QWEN, WeeklyUsage,
        apply_codex_weekly_usage_history, codex_auth_account_key,
        codex_usage_error_for_http_status, delete_codex_account_file, deserialize_items,
        infer_wsl_home_root, is_muse_subagent_path, is_muse_tool_outputs_dir,
        is_valid_codex_account_key, list_codex_account_metadata, load_recent_kimi_contexts,
        load_recent_opencode_contexts, load_recent_qwen_contexts, muse_auth_api_key,
        muse_auth_user_email, muse_usage_error_for_http_status, parse_iso8601_utc_ms,
        parse_markdown_items, parse_muse_subscription_sse, parse_opencode_session_list,
        parse_session_command, parse_weekly_usage_response, parse_zcode_quota_response,
        prefer_live_codex_auth, prepare_codex_account_auth_with, process_listing_has_codex,
        query_recent_codex_contexts, read_codex_account_labels, remember_codex_weekly_usage,
        remove_codex_account_label, rename_codex_account_file, render_markdown_items,
        replace_file_from_temp, replace_live_auth_with_rollback, resolve_codex_active_account_slot,
        save_codex_account_file, save_snapshot_bytes, set_codex_account_label,
        set_codex_manual_reset_at, validate_codex_account_slot, write_codex_account_labels,
    };

    const CODEX_REFRESH_TEST_NOW_MS: i64 = 1_704_067_200_000;

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
        assert_eq!(items[3].kind, "group_end");
    }

    #[test]
    fn strips_legacy_codex_fast_flags() {
        let text = "# Codex Work\ncodex resume 11111111-1111-1111-1111-111111111111 --full-auto\n";
        let (items, warnings) = parse_markdown_items(text);

        assert!(warnings.is_empty());
        assert_eq!(items.len(), 1);
        assert_eq!(
            render_markdown_items(&items),
            "# Codex Work\ncodex resume 11111111-1111-1111-1111-111111111111\n"
        );
    }

    #[test]
    fn accepts_only_canonical_numeric_codex_account_slots() {
        assert_eq!(validate_codex_account_slot("1").ok().as_deref(), Some("1"));
        assert_eq!(
            validate_codex_account_slot(" 2 ").ok().as_deref(),
            Some("2")
        );
        for value in ["", "0", "0x1", "01", "one", "1/2", "../1"] {
            assert!(
                validate_codex_account_slot(value).is_err(),
                "accepted {value:?}"
            );
        }
    }

    #[test]
    fn codex_account_key_has_a_pinned_stable_fingerprint() {
        let auth = br#"{"tokens":{"account_id":"fixture-account-id"}}"#;

        assert_eq!(
            codex_auth_account_key(auth).as_deref(),
            Some("fnv1a64-v1:43598759838d7e36")
        );
    }

    #[test]
    fn rejects_legacy_unversioned_and_malformed_persisted_account_keys() -> anyhow::Result<()> {
        let valid_key = "fnv1a64-v1:0123456789abcdef";
        for invalid_key in [
            "0123456789abcdef",
            "fnv1a64-v0:0123456789abcdef",
            "fnv1a64-v1:0123456789abcde",
            "fnv1a64-v1:0123456789abcdef0",
            "fnv1a64-v1:0123456789abcdeg",
            "fnv1a64-v1:0123456789abcdeF",
        ] {
            assert!(!is_valid_codex_account_key(invalid_key));
        }
        assert!(is_valid_codex_account_key(valid_key));

        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-key-migration-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        let state = |account_key: &str| {
            serde_json::json!({
                "account_key": account_key,
                "used_percent": 75.0,
                "reset_at": 1_700_604_800_000_i64,
                "window_seconds": 604_800,
            })
        };
        fs::write(
            root.join("metadata.json"),
            serde_json::to_vec(&serde_json::json!({
                "weekly_usage_state": {
                    "1": state("0123456789abcdef"),
                    "2": state("fnv1a64-v1:0123456789abcdeg"),
                    "3": state(valid_key),
                }
            }))?,
        )?;

        let labels = read_codex_account_labels(&root)?;
        assert_eq!(
            labels
                .weekly_usage_state
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["3"]
        );
        write_codex_account_labels(&root, &labels)?;
        let persisted =
            serde_json::from_slice::<serde_json::Value>(&fs::read(root.join("metadata.json"))?)?;
        let persisted_states = persisted
            .get("weekly_usage_state")
            .and_then(serde_json::Value::as_object)
            .ok_or_else(|| anyhow::anyhow!("missing weekly usage state"))?;
        assert_eq!(persisted_states.len(), 1);
        assert!(persisted_states.contains_key("3"));
        let round_tripped = read_codex_account_labels(&root)?;
        assert_eq!(round_tripped.weekly_usage_state, labels.weekly_usage_state);

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn lists_only_numeric_codex_account_metadata() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-list-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        fs::write(root.join("1.json"), b"{}")?;
        fs::write(root.join("12.json"), b"{}")?;
        fs::write(root.join("2.json"), b"{}")?;
        fs::write(root.join("01.json"), b"{}")?;
        fs::write(root.join("notes.json"), b"{}")?;
        fs::write(root.join("3.txt"), b"{}")?;

        let accounts = list_codex_account_metadata(&root)?;
        assert_eq!(
            accounts
                .iter()
                .map(|account| account.name.as_str())
                .collect::<Vec<_>>(),
            ["1", "2", "12"]
        );
        assert_eq!(
            accounts
                .iter()
                .map(|account| account.slot.as_str())
                .collect::<Vec<_>>(),
            ["1", "2", "12"]
        );
        assert!(accounts.iter().all(|account| account.updated_at.is_some()));

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn applies_and_expires_global_codex_manual_reset_override() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-manual-reset-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        fs::write(root.join("1.json"), b"{}")?;
        fs::write(root.join("2.json"), b"{}")?;
        set_codex_account_label(&root, "1", "one")?;

        assert!(set_codex_manual_reset_at(&root, 0).is_err());
        let future =
            i64::try_from(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())? + 60_000;
        set_codex_manual_reset_at(&root, future)?;
        let accounts = list_codex_account_metadata(&root)?;
        assert_eq!(accounts.len(), 2);
        assert!(
            accounts
                .iter()
                .all(|account| account.manual_reset_at == Some(future))
        );
        assert_eq!(read_codex_account_labels(&root)?.labels["1"], "one");

        fs::write(
            root.join("metadata.json"),
            br#"{"1":"one","manual_reset_at":0}"#,
        )?;
        let accounts = list_codex_account_metadata(&root)?;
        assert!(
            accounts
                .iter()
                .all(|account| account.manual_reset_at.is_none())
        );
        let labels = read_codex_account_labels(&root)?;
        assert_eq!(labels.labels.get("1").map(String::as_str), Some("one"));
        assert!(labels.manual_reset_at.is_none());

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn round_trips_bounded_codex_account_labels_in_sidecar() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-label-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;

        set_codex_account_label(&root, "1", "  one@example.com  ")?;
        let labels = read_codex_account_labels(&root)?;
        assert_eq!(
            labels.labels.get("1").map(|value| value.as_str()),
            Some("one@example.com")
        );
        assert!(root.join("metadata.json").is_file());

        let long_label = "é".repeat(400);
        set_codex_account_label(&root, "2", &long_label)?;
        let labels = read_codex_account_labels(&root)?;
        assert_eq!(labels.labels["2"].chars().count(), 256);
        assert!(!root.join("1.json").exists());

        remove_codex_account_label(&root, "1")?;
        let labels = read_codex_account_labels(&root)?;
        assert!(!labels.labels.contains_key("1"));

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn each_account_keeps_its_own_api_reset() {
        let first_reset = Some(1_788_136_886_000);
        let second_reset = Some(1_788_212_374_000);
        let first = WeeklyUsage {
            used_percent: 8.0,
            reset_at_ms: first_reset,
            reset_after_seconds: Some(536_886),
            window_seconds: 604_800,
        };
        let second = WeeklyUsage {
            used_percent: 0.0,
            reset_at_ms: second_reset,
            reset_after_seconds: Some(604_800),
            window_seconds: 604_800,
        };
        let mut states = std::collections::BTreeMap::new();

        let first = apply_codex_weekly_usage_history("1", None, first, first_reset, &mut states).0;
        let second =
            apply_codex_weekly_usage_history("2", None, second, second_reset, &mut states).0;

        assert_eq!(first.reset_at_ms, first_reset);
        assert_eq!(second.reset_at_ms, second_reset);
        assert_ne!(first.reset_at_ms, second.reset_at_ms);
    }

    #[test]
    fn metadata_migration_removes_slot_pins_and_preserves_other_fields() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-global-reset-metadata-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        fs::write(
            root.join("metadata.json"),
            br#"{"1":"one","manual_reset_at":1700000000000,"weekly_cycle_reset_at":1700606706000,"weekly_reset_at":{"1":1700604800000},"weekly_reset_at_confirmed":{"1":true}}"#,
        )?;

        let labels = read_codex_account_labels(&root)?;
        assert_eq!(labels.labels.get("1").map(String::as_str), Some("one"));
        assert_eq!(labels.manual_reset_at, Some(1_700_000_000_000));
        assert!(labels.legacy_weekly_reset_at.is_some());

        write_codex_account_labels(&root, &labels)?;
        let stored =
            serde_json::from_slice::<serde_json::Value>(&fs::read(root.join("metadata.json"))?)?;
        assert_eq!(
            stored.get("1").and_then(serde_json::Value::as_str),
            Some("one")
        );
        assert_eq!(
            stored
                .get("manual_reset_at")
                .and_then(serde_json::Value::as_i64),
            Some(1_700_000_000_000)
        );
        assert!(stored.get("weekly_cycle_reset_at").is_none());
        assert!(stored.get("weekly_reset_at").is_none());
        assert!(stored.get("weekly_reset_at_confirmed").is_none());

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn renaming_and_deleting_account_never_touch_live_auth() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-rename-delete-test-{}-{stamp}",
            std::process::id()
        ));
        let home = root.join("home");
        let markdown = home.join("codex-out").join("codex sessions.md");
        let codex_dir = home.join(".codex");
        fs::create_dir_all(
            markdown
                .parent()
                .ok_or_else(|| anyhow::anyhow!("missing parent"))?,
        )?;
        fs::create_dir_all(&codex_dir)?;
        let live_auth = br#"{"live":"untouched"}"#;
        fs::write(codex_dir.join("auth.json"), live_auth)?;

        let markdown_text = markdown.to_string_lossy();
        save_codex_account_file(&markdown_text, "1", "first")?;
        let accounts_dir = codex_dir.join("context-accounts");
        save_snapshot_bytes(&accounts_dir, "2", br#"{"saved":"second"}"#)?;
        set_codex_account_label(&accounts_dir, "2", "second")?;
        let mut labels = read_codex_account_labels(&accounts_dir)?;
        labels.weekly_usage_state.insert(
            "1".to_owned(),
            CodexWeeklyUsageState {
                account_key: "fnv1a64-v1:0123456789abcdef".to_owned(),
                used_percent: 75.0,
                reset_at: 1_800_000_000_000,
                window_seconds: 604_800,
            },
        );
        write_codex_account_labels(&accounts_dir, &labels)?;

        rename_codex_account_file(&markdown_text, "1", "renamed")?;
        let accounts = list_codex_account_metadata(&accounts_dir)?;
        assert_eq!(accounts[0].slot, "1");
        assert_eq!(accounts[0].name, "renamed");

        delete_codex_account_file(&markdown_text, "1")?;
        assert!(!accounts_dir.join("1.json").exists());
        assert_eq!(fs::read(codex_dir.join("auth.json"))?, live_auth);
        let labels = read_codex_account_labels(&accounts_dir)?;
        assert!(!labels.labels.contains_key("1"));
        assert!(!labels.weekly_usage_state.contains_key("1"));
        assert!(labels.labels.contains_key("2"));

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn deleting_account_without_identity_clears_weekly_usage_history() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-delete-history-test-{}-{stamp}",
            std::process::id()
        ));
        let home = root.join("home");
        let markdown = home.join("codex-out").join("codex sessions.md");
        let codex_dir = home.join(".codex");
        let accounts_dir = codex_dir.join("context-accounts");
        fs::create_dir_all(
            markdown
                .parent()
                .ok_or_else(|| anyhow::anyhow!("missing parent"))?,
        )?;
        fs::create_dir_all(&codex_dir)?;
        fs::write(codex_dir.join("auth.json"), br#"{"tokens":{}}"#)?;

        let markdown_text = markdown.to_string_lossy();
        save_codex_account_file(&markdown_text, "1", "missing-identity")?;
        let mut labels = read_codex_account_labels(&accounts_dir)?;
        labels.weekly_usage_state.insert(
            "1".to_owned(),
            CodexWeeklyUsageState {
                account_key: "fnv1a64-v1:0123456789abcdef".to_owned(),
                used_percent: 75.0,
                reset_at: 1_700_604_800_000,
                window_seconds: 604_800,
            },
        );
        write_codex_account_labels(&accounts_dir, &labels)?;

        delete_codex_account_file(&markdown_text, "1")?;
        assert!(
            !read_codex_account_labels(&accounts_dir)?
                .weekly_usage_state
                .contains_key("1")
        );

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn weekly_parser_uses_only_root_primary_then_root_secondary() -> anyhow::Result<()> {
        let body = br#"{
            "rate_limit": {
                "primary_window": {
                    "used_percent": 42.5,
                    "limit_window_seconds": 3600,
                    "reset_after_seconds": 900
                },
                "secondary_window": {
                    "used_percent": 63,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 654
                }
            },
            "additional_rate_limits": [
                {
                    "rate_limit": {
                        "primary_window": {
                            "used_percent": 99,
                            "limit_window_seconds": 604800,
                            "reset_after_seconds": 321
                        }
                    }
                }
            ]
        }"#;
        let usage = parse_weekly_usage_response(body, 1_700_000_000_000)
            .map_err(|_| anyhow::anyhow!("weekly usage did not parse"))?;
        assert_eq!(usage.used_percent, 63.0);
        assert_eq!(usage.window_seconds, 604800);
        assert_eq!(usage.reset_at_ms, Some(1_700_000_654_000));
        assert_eq!(usage.reset_after_seconds, Some(654));

        let primary_body = br#"{
            "rate_limit": {
                "primary_window": {
                    "used_percent": 12,
                    "limit_window_seconds": 604800,
                    "reset_at": 1700000000,
                    "reset_after_seconds": 1
                },
                "secondary_window": null
            }
        }"#;
        let usage = parse_weekly_usage_response(primary_body, 0)
            .map_err(|_| anyhow::anyhow!("primary weekly usage did not parse"))?;
        assert_eq!(usage.used_percent, 12.0);
        assert_eq!(usage.reset_at_ms, Some(1_700_000_000_000));
        assert_eq!(usage.reset_after_seconds, Some(1));

        let invalid_body = br#"{
            "rate_limit": {
                "primary_window": {
                    "used_percent": 101,
                    "limit_window_seconds": 604800
                }
            }
        }"#;
        assert!(parse_weekly_usage_response(invalid_body, 0).is_err());
        Ok(())
    }

    #[test]
    fn canonical_weekly_secondary_beats_additional_sliding_zero() -> anyhow::Result<()> {
        let body = br#"{
            "rate_limit": {
                "primary_window": {
                    "used_percent": 90,
                    "limit_window_seconds": 18000,
                    "reset_after_seconds": 900
                },
                "secondary_window": {
                    "used_percent": 100,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 3600
                }
            },
            "additional_rate_limits": [{
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 0,
                        "limit_window_seconds": 604800,
                        "reset_after_seconds": 604800
                    }
                }
            }]
        }"#;

        let usage = parse_weekly_usage_response(body, 1_700_000_000_000)
            .map_err(|_| anyhow::anyhow!("canonical weekly usage did not parse"))?;
        assert_eq!(usage.used_percent, 100.0);
        assert_eq!(usage.window_seconds, 604_800);
        assert_eq!(usage.reset_after_seconds, Some(3_600));
        Ok(())
    }

    #[test]
    fn conflicting_additional_weekly_windows_fail_independent_of_order() {
        let first_order = br#"{
            "rate_limit": {"primary_window": null, "secondary_window": null},
            "additional_rate_limits": [
                {"rate_limit": {"primary_window": {
                    "used_percent": 20,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 300
                }}},
                {"rate_limit": {"primary_window": {
                    "used_percent": 30,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 300
                }}}
            ]
        }"#;
        let reverse_order = br#"{
            "rate_limit": {"primary_window": null, "secondary_window": null},
            "additional_rate_limits": [
                {"rate_limit": {"primary_window": {
                    "used_percent": 30,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 300
                }}},
                {"rate_limit": {"primary_window": {
                    "used_percent": 20,
                    "limit_window_seconds": 604800,
                    "reset_after_seconds": 300
                }}}
            ]
        }"#;

        assert!(parse_weekly_usage_response(first_order, 0).is_err());
        assert!(parse_weekly_usage_response(reverse_order, 0).is_err());
    }

    #[test]
    fn parses_muse_subscription_usage_sse_event() {
        let body = br#"event: response.created
data: {"type":"response.created","response":{"id":"resp_1"}}

event: response.subscription_usage
data: {"subscription":{"tier":"27681527378179523","weekly":{"resets_at":1789948800,"used_percent":61},"window":{"resets_at":1789421006,"used_percent":93,"window_duration_mins":300}},"type":"response.subscription_usage"}

event: response.completed
data: "[DONE]"
"#;
        let usage =
            parse_muse_subscription_sse(body).expect("muse subscription usage did not parse");
        assert_eq!(usage.tier.as_deref(), Some("27681527378179523"));
        assert_eq!(usage.weekly_used_percent, Some(61.0));
        assert_eq!(usage.weekly_reset_at_ms, Some(1_789_948_800_000));
        assert_eq!(usage.window_used_percent, Some(93.0));
        assert_eq!(usage.window_reset_at_ms, Some(1_789_421_006_000));
        assert_eq!(usage.window_duration_mins, Some(300));
    }

    #[test]
    fn rejects_muse_subscription_usage_without_any_percent() {
        let missing_windows =
            br#"data: {"subscription":{"tier":"t"},"type":"response.subscription_usage"}
"#;
        assert!(parse_muse_subscription_sse(missing_windows).is_none());

        let out_of_range = br#"data: {"subscription":{"weekly":{"resets_at":1789948800,"used_percent":101}},"type":"response.subscription_usage"}
"#;
        assert!(parse_muse_subscription_sse(out_of_range).is_none());

        let wrong_type = br#"data: {"subscription":{"weekly":{"resets_at":1789948800,"used_percent":61}},"type":"response.completed"}
"#;
        assert!(parse_muse_subscription_sse(wrong_type).is_none());

        let not_json = b"data: not json\n";
        assert!(parse_muse_subscription_sse(not_json).is_none());
    }

    #[test]
    fn extracts_muse_api_key_and_email_without_values() {
        let auth = br#"{"schema_version":1,"providers":{"meta":{"api_key":"  key ","api_base_url":"https://example.invalid/v1/","user_email":" me@example.invalid "}}}"#;
        let (base_url, api_key) = muse_auth_api_key(auth).expect("muse api key did not parse");
        assert_eq!(base_url, "https://example.invalid/v1/");
        assert_eq!(api_key, "key");
        assert_eq!(
            muse_auth_user_email(auth).as_deref(),
            Some("me@example.invalid")
        );

        let missing_key = br#"{"providers":{"meta":{"api_base_url":"https://example.invalid"}}}"#;
        assert!(muse_auth_api_key(missing_key).is_none());

        let fallback_base = br#"{"providers":{"meta":{"api_key":"key"}}}"#;
        let (base_url, _) =
            muse_auth_api_key(fallback_base).expect("muse base fallback did not parse");
        assert_eq!(base_url, "https://api.meta.ai/v1");
    }

    #[test]
    fn skips_muse_tool_outputs_and_subagent_paths() {
        assert!(is_muse_tool_outputs_dir(Path::new(
            "/home/u/.local/share/muse/sessions/2026/09/14/id/tool-outputs/x.txt"
        )));
        assert!(!is_muse_tool_outputs_dir(Path::new(
            "/home/u/.local/share/muse/sessions/2026/09/14/id/session.jsonl"
        )));
        assert!(is_muse_subagent_path(Path::new(
            "/home/u/.local/share/muse/sessions/subagent/id/session.jsonl"
        )));
        assert!(!is_muse_subagent_path(Path::new(
            "/home/u/.local/share/muse/sessions/2026/09/14/id/session.jsonl"
        )));
    }

    #[test]
    fn derives_wsl_home_from_unc_markdown_paths() {
        let root = infer_wsl_home_root(
            "\\\\wsl.localhost\\Ubuntu-24.04\\home\\luka\\codex-out\\codex sessions.md",
        )
        .expect("wsl home did not parse");
        assert_eq!(
            root,
            PathBuf::from("\\\\wsl.localhost\\Ubuntu-24.04\\home\\luka")
        );
        let legacy =
            infer_wsl_home_root("//wsl$/Ubuntu-24.04/home/luka/codex-out/codex sessions.md")
                .expect("legacy wsl home did not parse");
        assert_eq!(legacy, PathBuf::from("\\\\wsl$\\Ubuntu-24.04\\home\\luka"));
        assert!(infer_wsl_home_root("C:\\Users\\luka\\codex sessions.md").is_none());
        assert!(infer_wsl_home_root("").is_none());
    }

    #[test]
    fn maps_muse_http_status_to_credential_errors() {
        assert_eq!(
            muse_usage_error_for_http_status(401),
            MuseUsageError::CredentialRejected
        );
        assert_eq!(
            muse_usage_error_for_http_status(403),
            MuseUsageError::CredentialRejected
        );
        assert_eq!(
            muse_usage_error_for_http_status(500),
            MuseUsageError::Unavailable
        );
        assert_eq!(
            MuseUsageError::CredentialRejected.message(),
            MUSE_USAGE_CREDENTIAL_ERROR
        );
    }

    #[test]
    fn same_cycle_zero_usage_regression_keeps_previous_usage() {
        let now_ms = 1_700_000_000_000_i64;
        let previous_reset = now_ms + 86_400_000;
        let account_key = "fnv1a64-v1:0123456789abcdef";
        let mut states = std::collections::BTreeMap::from([(
            "2".to_owned(),
            CodexWeeklyUsageState {
                account_key: account_key.to_owned(),
                used_percent: 100.0,
                reset_at: previous_reset,
                window_seconds: 604_800,
            },
        )]);
        let incoming = WeeklyUsage {
            used_percent: 0.0,
            reset_at_ms: Some(now_ms + 604_800_000),
            reset_after_seconds: Some(604_800),
            window_seconds: 604_800,
        };

        let (guarded, changed) = apply_codex_weekly_usage_history(
            "2",
            Some(account_key),
            incoming,
            Some(previous_reset),
            &mut states,
        );

        assert!(!changed);
        assert_eq!(guarded.used_percent, 100.0);
        assert_eq!(guarded.reset_at_ms, Some(previous_reset));
        assert_eq!(states.get("2").map(|state| state.used_percent), Some(100.0));
    }

    #[test]
    fn post_reset_zero_usage_is_accepted_when_account_reset_advances() {
        let previous_reset = 1_700_000_000_000_i64;
        let now_ms = previous_reset + 1;
        let next_reset = now_ms + 604_800_000;
        let account_key = "fnv1a64-v1:0123456789abcdef";
        let mut states = std::collections::BTreeMap::from([(
            "2".to_owned(),
            CodexWeeklyUsageState {
                account_key: account_key.to_owned(),
                used_percent: 100.0,
                reset_at: previous_reset,
                window_seconds: 604_800,
            },
        )]);
        let incoming = WeeklyUsage {
            used_percent: 0.0,
            reset_at_ms: Some(next_reset),
            reset_after_seconds: Some(604_800),
            window_seconds: 604_800,
        };

        let (accepted, changed) = apply_codex_weekly_usage_history(
            "2",
            Some(account_key),
            incoming,
            Some(next_reset),
            &mut states,
        );
        assert!(!changed);
        assert_eq!(accepted.used_percent, 0.0);
        assert!(remember_codex_weekly_usage(
            "2",
            Some(account_key),
            &accepted,
            Some(next_reset),
            now_ms,
            &mut states,
        ));
        assert_eq!(states.get("2").map(|state| state.used_percent), Some(0.0));
        assert_eq!(
            states.get("2").map(|state| state.reset_at),
            Some(next_reset)
        );
    }

    #[test]
    fn prefers_live_codex_auth_only_for_matching_account() {
        let snapshot: &[u8] = br#"{"tokens":{"account_id":"account-1","access_token":"saved"}}"#;
        let live: &[u8] = br#"{"tokens":{"account_id":"account-1","access_token":"fresh"}}"#;
        let other: &[u8] = br#"{"tokens":{"account_id":"account-2","access_token":"other"}}"#;
        let invalid_live: &[u8] = br#"{}"#;

        assert_eq!(prefer_live_codex_auth(snapshot, Some(live)), live);
        assert_eq!(prefer_live_codex_auth(snapshot, Some(other)), snapshot);
        assert_eq!(prefer_live_codex_auth(snapshot, None), snapshot);
        assert_eq!(
            prefer_live_codex_auth(snapshot, Some(invalid_live)),
            snapshot
        );
    }

    #[test]
    fn matching_live_auth_is_mirrored_without_refresh() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-refresh-live-match-test-{}-{stamp}",
            std::process::id()
        ));
        let snapshot = br#"{"tokens":{"account_id":"account-1","access_token":"saved"}}"#;
        let live = br#"{"tokens":{"account_id":"account-1","access_token":"fresh"}}"#;
        save_snapshot_bytes(&root, "1", snapshot)?;

        let refresh_calls = Cell::new(0);
        let prepared = match prepare_codex_account_auth_with(
            &root,
            "1",
            snapshot,
            Some(live),
            CODEX_REFRESH_TEST_NOW_MS,
            |_, _| {
                refresh_calls.set(refresh_calls.get() + 1);
                Err(RefreshError::RequestFailed)
            },
        ) {
            Ok(prepared) => prepared,
            Err(_) => panic!("matching live auth preparation failed"),
        };

        assert_eq!(prepared.as_slice(), live);
        assert_eq!(refresh_calls.get(), 0);
        assert_eq!(fs::read(root.join("1.json"))?, live);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn fresh_inactive_snapshot_skips_refresh() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-refresh-fresh-test-{}-{stamp}",
            std::process::id()
        ));
        let snapshot =
            br#"{"tokens":{"account_id":"account-1","access_token":"a.eyJleHAiOjE3MDQwNjc1MDF9.b"}}"#;
        save_snapshot_bytes(&root, "1", snapshot)?;

        let refresh_calls = Cell::new(0);
        let prepared = match prepare_codex_account_auth_with(
            &root,
            "1",
            snapshot,
            None,
            CODEX_REFRESH_TEST_NOW_MS,
            |_, _| {
                refresh_calls.set(refresh_calls.get() + 1);
                Err(RefreshError::RequestFailed)
            },
        ) {
            Ok(prepared) => prepared,
            Err(_) => panic!("fresh inactive auth preparation failed"),
        };

        assert_eq!(prepared.as_slice(), snapshot);
        assert_eq!(refresh_calls.get(), 0);
        assert_eq!(fs::read(root.join("1.json"))?, snapshot);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn expired_inactive_snapshot_refreshes_once_and_persists() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-refresh-expired-test-{}-{stamp}",
            std::process::id()
        ));
        let snapshot =
            br#"{"tokens":{"account_id":"account-1","access_token":"a.eyJleHAiOjE3MDQwNjc0OTl9.b"}}"#;
        let refreshed = br#"{"tokens":{"account_id":"account-1","access_token":"new-access"}}"#;
        save_snapshot_bytes(&root, "1", snapshot)?;

        let refresh_calls = Cell::new(0);
        let prepared = match prepare_codex_account_auth_with(
            &root,
            "1",
            snapshot,
            None,
            CODEX_REFRESH_TEST_NOW_MS,
            |_, _| {
                refresh_calls.set(refresh_calls.get() + 1);
                Ok(refreshed.to_vec())
            },
        ) {
            Ok(prepared) => prepared,
            Err(_) => panic!("expired inactive auth preparation failed"),
        };

        assert_eq!(prepared.as_slice(), refreshed);
        assert_eq!(refresh_calls.get(), 1);
        assert_eq!(fs::read(root.join("1.json"))?, refreshed);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn refresh_failure_leaves_snapshot_unchanged() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-refresh-failure-test-{}-{stamp}",
            std::process::id()
        ));
        let snapshot =
            br#"{"tokens":{"account_id":"account-1","access_token":"a.eyJleHAiOjE3MDQwNjc0OTl9.b"}}"#;
        save_snapshot_bytes(&root, "1", snapshot)?;

        let refresh_calls = Cell::new(0);
        let result = prepare_codex_account_auth_with(
            &root,
            "1",
            snapshot,
            None,
            CODEX_REFRESH_TEST_NOW_MS,
            |_, _| {
                refresh_calls.set(refresh_calls.get() + 1);
                Err(RefreshError::RequestFailed)
            },
        );

        assert_eq!(result, Err(CodexUsageError::Unavailable));
        assert_eq!(refresh_calls.get(), 1);
        assert_eq!(fs::read(root.join("1.json"))?, snapshot);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn failed_slot_preparation_does_not_block_another_slot() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-refresh-independent-slots-test-{}-{stamp}",
            std::process::id()
        ));
        let first_snapshot =
            br#"{"tokens":{"account_id":"account-1","access_token":"a.eyJleHAiOjE3MDQwNjc0OTl9.b"}}"#;
        let second_snapshot =
            br#"{"tokens":{"account_id":"account-2","access_token":"a.eyJleHAiOjE3MDQwNjc0OTl9.b"}}"#;
        let second_refreshed =
            br#"{"tokens":{"account_id":"account-2","access_token":"new-access"}}"#;
        save_snapshot_bytes(&root, "1", first_snapshot)?;
        save_snapshot_bytes(&root, "2", second_snapshot)?;

        let first_calls = Cell::new(0);
        let first_result = prepare_codex_account_auth_with(
            &root,
            "1",
            first_snapshot,
            None,
            CODEX_REFRESH_TEST_NOW_MS,
            |_, _| {
                first_calls.set(first_calls.get() + 1);
                Err(RefreshError::RequestFailed)
            },
        );
        assert_eq!(first_result, Err(CodexUsageError::Unavailable));
        assert_eq!(first_calls.get(), 1);

        let second_calls = Cell::new(0);
        let second_result = match prepare_codex_account_auth_with(
            &root,
            "2",
            second_snapshot,
            None,
            CODEX_REFRESH_TEST_NOW_MS,
            |_, _| {
                second_calls.set(second_calls.get() + 1);
                Ok(second_refreshed.to_vec())
            },
        ) {
            Ok(prepared) => prepared,
            Err(_) => panic!("second slot auth preparation failed"),
        };
        assert_eq!(second_result.as_slice(), second_refreshed);
        assert_eq!(second_calls.get(), 1);
        assert_eq!(fs::read(root.join("2.json"))?, second_refreshed);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn resolves_unique_codex_account_identity_before_byte_fallback() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-resolve-identity-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        let paths = CodexAccountPaths {
            auth_path: root.join("auth.json"),
            accounts_dir: root.clone(),
        };
        let live_auth = br#"{"tokens":{"account_id":" account-live "}}"#;
        fs::write(&paths.auth_path, live_auth)?;
        save_snapshot_bytes(
            &paths.accounts_dir,
            "1",
            br#"{"tokens":{"account_id":"account-other"}}"#,
        )?;
        save_snapshot_bytes(
            &paths.accounts_dir,
            "2",
            br#"{"tokens":{"account_id":"account-live"}}"#,
        )?;

        assert_eq!(resolve_codex_active_account_slot(&paths, "")?, "2");

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn recovers_codex_active_slot_from_empty_or_stale_hint() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-resolve-hint-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        let paths = CodexAccountPaths {
            auth_path: root.join("auth.json"),
            accounts_dir: root.clone(),
        };
        fs::write(
            &paths.auth_path,
            br#"{"tokens":{"account_id":"account-live"}}"#,
        )?;
        save_snapshot_bytes(
            &paths.accounts_dir,
            "3",
            br#"{"tokens":{"account_id":"account-live"}}"#,
        )?;

        assert_eq!(resolve_codex_active_account_slot(&paths, "")?, "3");
        assert_eq!(resolve_codex_active_account_slot(&paths, "99")?, "3");

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn refuses_ambiguous_or_unmatched_codex_account_ownership() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-resolve-fail-closed-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        let paths = CodexAccountPaths {
            auth_path: root.join("auth.json"),
            accounts_dir: root.clone(),
        };
        fs::write(
            &paths.auth_path,
            br#"{"tokens":{"account_id":"account-live"}}"#,
        )?;
        save_snapshot_bytes(
            &paths.accounts_dir,
            "1",
            br#"{"tokens":{"account_id":"account-live"}}"#,
        )?;
        save_snapshot_bytes(
            &paths.accounts_dir,
            "2",
            br#"{"tokens":{"account_id":"account-live"}}"#,
        )?;

        let error = resolve_codex_active_account_slot(&paths, "1")
            .expect_err("duplicate identities must not choose a slot");
        assert_eq!(error.to_string(), CODEX_ACTIVE_ACCOUNT_OWNERSHIP_ERROR);

        save_snapshot_bytes(
            &paths.accounts_dir,
            "1",
            br#"{"tokens":{"account_id":"account-other"}}"#,
        )?;
        save_snapshot_bytes(
            &paths.accounts_dir,
            "2",
            br#"{"tokens":{"account_id":"account-other-2"}}"#,
        )?;
        let error = resolve_codex_active_account_slot(&paths, "1")
            .expect_err("unmatched identity must not choose a slot");
        assert_eq!(error.to_string(), CODEX_ACTIVE_ACCOUNT_OWNERSHIP_ERROR);

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn classifies_codex_usage_credential_rejections_without_response_details() {
        assert_eq!(
            codex_usage_error_for_http_status(401),
            CodexUsageError::CredentialRejected
        );
        assert_eq!(
            codex_usage_error_for_http_status(403),
            CodexUsageError::CredentialRejected
        );
        assert_eq!(
            codex_usage_error_for_http_status(500),
            CodexUsageError::Unavailable
        );
        assert_eq!(
            CodexUsageError::CredentialRejected.message(),
            "Weekly usage unavailable: API rejected Codex credentials (HTTP 401/403)."
        );
        assert_eq!(
            CodexUsageError::Unavailable.message(),
            "Weekly usage unavailable (network or parse failure)."
        );
    }

    #[test]
    fn saves_and_replaces_codex_account_snapshot() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-save-test-{}-{stamp}",
            std::process::id()
        ));
        let home = root.join("home");
        let markdown = home.join("codex-out").join("codex sessions.md");
        let codex_dir = home.join(".codex");
        fs::create_dir_all(
            markdown
                .parent()
                .ok_or_else(|| anyhow::anyhow!("missing parent"))?,
        )?;
        fs::create_dir_all(&codex_dir)?;
        fs::write(codex_dir.join("auth.json"), br#"{"token":"first"}"#)?;

        let markdown_text = markdown.to_string_lossy();
        let accounts = save_codex_account_file(&markdown_text, "1", "first@example.com")?;
        assert_eq!(accounts.len(), 1);
        assert!(codex_dir.join("context-accounts").join("1.json").is_file());

        fs::write(codex_dir.join("auth.json"), br#"{"token":"second"}"#)?;
        save_codex_account_file(&markdown_text, "1", "second")?;
        assert!(codex_dir.join("context-accounts").join("1.json").is_file());

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn replacing_account_without_identity_clears_weekly_usage_history() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-replace-history-test-{}-{stamp}",
            std::process::id()
        ));
        let home = root.join("home");
        let markdown = home.join("codex-out").join("codex sessions.md");
        let codex_dir = home.join(".codex");
        let accounts_dir = codex_dir.join("context-accounts");
        fs::create_dir_all(
            markdown
                .parent()
                .ok_or_else(|| anyhow::anyhow!("missing parent"))?,
        )?;
        fs::create_dir_all(&codex_dir)?;
        fs::write(
            codex_dir.join("auth.json"),
            br#"{"tokens":{"account_id":"account-1"}}"#,
        )?;

        let markdown_text = markdown.to_string_lossy();
        save_codex_account_file(&markdown_text, "1", "with-identity")?;
        let mut labels = read_codex_account_labels(&accounts_dir)?;
        labels.weekly_usage_state.insert(
            "1".to_owned(),
            CodexWeeklyUsageState {
                account_key: "fnv1a64-v1:0123456789abcdef".to_owned(),
                used_percent: 75.0,
                reset_at: 1_700_604_800_000,
                window_seconds: 604_800,
            },
        );
        write_codex_account_labels(&accounts_dir, &labels)?;

        fs::write(codex_dir.join("auth.json"), br#"{"tokens":{}}"#)?;
        save_codex_account_file(&markdown_text, "1", "missing-identity")?;
        assert!(
            !read_codex_account_labels(&accounts_dir)?
                .weekly_usage_state
                .contains_key("1")
        );

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn save_codex_account_preserves_only_matching_history() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-pin-identity-test-{}-{stamp}",
            std::process::id()
        ));
        let home = root.join("home");
        let markdown = home.join("codex-out").join("codex sessions.md");
        let codex_dir = home.join(".codex");
        let accounts_dir = codex_dir.join("context-accounts");
        fs::create_dir_all(
            markdown
                .parent()
                .ok_or_else(|| anyhow::anyhow!("missing parent"))?,
        )?;
        fs::create_dir_all(&codex_dir)?;
        let markdown_text = markdown.to_string_lossy();
        fs::write(
            codex_dir.join("auth.json"),
            br#"{"tokens":{"account_id":"account-1"}}"#,
        )?;
        save_codex_account_file(&markdown_text, "1", "first")?;
        let mut labels = read_codex_account_labels(&accounts_dir)?;
        labels.weekly_usage_state.insert(
            "1".to_owned(),
            CodexWeeklyUsageState {
                account_key: "fnv1a64-v1:0123456789abcdef".to_owned(),
                used_percent: 80.0,
                reset_at: 1_800_000_000_000,
                window_seconds: 604_800,
            },
        );
        write_codex_account_labels(&accounts_dir, &labels)?;

        fs::write(
            codex_dir.join("auth.json"),
            br#"{"tokens":{"account_id":"account-1","session":"new"}}"#,
        )?;
        save_codex_account_file(&markdown_text, "1", "same-account")?;
        assert!(
            read_codex_account_labels(&accounts_dir)?
                .weekly_usage_state
                .contains_key("1")
        );

        fs::write(
            codex_dir.join("auth.json"),
            br#"{"tokens":{"account_id":"account-2"}}"#,
        )?;
        save_codex_account_file(&markdown_text, "1", "different-account")?;
        assert!(
            !read_codex_account_labels(&accounts_dir)?
                .weekly_usage_state
                .contains_key("1")
        );

        let mut labels = read_codex_account_labels(&accounts_dir)?;
        labels.weekly_usage_state.insert(
            "1".to_owned(),
            CodexWeeklyUsageState {
                account_key: "fnv1a64-v1:0123456789abcdef".to_owned(),
                used_percent: 80.0,
                reset_at: 1_800_000_000_000,
                window_seconds: 604_800,
            },
        );
        write_codex_account_labels(&accounts_dir, &labels)?;
        fs::write(
            codex_dir.join("auth.json"),
            br#"{"tokens":{"session":"unknown-account"}}"#,
        )?;
        save_codex_account_file(&markdown_text, "1", "unknown-account")?;
        assert!(
            !read_codex_account_labels(&accounts_dir)?
                .weekly_usage_state
                .contains_key("1")
        );

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn refuses_invalid_codex_auth_json() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-invalid-test-{}-{stamp}",
            std::process::id()
        ));
        let home = root.join("home");
        let markdown = home.join("codex-out").join("codex sessions.md");
        let codex_dir = home.join(".codex");
        fs::create_dir_all(
            markdown
                .parent()
                .ok_or_else(|| anyhow::anyhow!("missing parent"))?,
        )?;
        fs::create_dir_all(&codex_dir)?;
        fs::write(codex_dir.join("auth.json"), b"[]")?;

        let error = save_codex_account_file(&markdown.to_string_lossy(), "1", "invalid")
            .expect_err("array auth should be rejected");
        assert_eq!(error.to_string(), "Current Codex credentials are invalid.");
        assert!(!codex_dir.join("context-accounts").join("1.json").exists());

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn restores_live_auth_when_atomic_switch_replacement_fails() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-account-rollback-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        let auth_path = root.join("auth.json");
        fs::write(&auth_path, b"original")?;
        let mut fail_once = true;
        let result = replace_live_auth_with_rollback(&auth_path, b"replacement", |temp, target| {
            if fail_once {
                fail_once = false;
                Err(anyhow::anyhow!("test replacement failure"))
            } else {
                replace_file_from_temp(temp, target)
            }
        });
        assert!(result.is_err());
        assert_eq!(fs::read(&auth_path)?, b"original");

        assert!(process_listing_has_codex("node codex-cli --resume 1"));
        assert!(process_listing_has_codex("/usr/local/bin/codex"));
        assert!(!process_listing_has_codex("node worker --resume 1"));

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn filters_codex_subagent_threads_using_database_thread_source() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-thread-source-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        let db_path = root.join("state_5.sqlite");
        let connection = Connection::open(&db_path)?;
        connection.execute_batch(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                archived INTEGER NOT NULL,
                cwd TEXT,
                thread_source TEXT
            );
            INSERT INTO threads (id, rollout_path, updated_at, title, archived, cwd, thread_source)
            VALUES
                ('codex_subagent_1', '/missing/subagent-1.jsonl', 7000, 'Subagent', 0, '/work', 'subagent'),
                ('codex_subagent_2', '/missing/subagent-2.jsonl', 6000, 'Subagent', 0, '/work', 'subagent'),
                ('codex_subagent_3', '/missing/subagent-3.jsonl', 5000, 'Subagent', 0, '/work', 'subagent'),
                ('codex_subagent_4', '/missing/subagent-4.jsonl', 4000, 'Subagent', 0, '/work', 'subagent'),
                ('codex_subagent_5', '/missing/subagent-5.jsonl', 3000, 'Subagent', 0, '/work', 'subagent'),
                ('codex_subagent_6', '/missing/subagent-6.jsonl', 2000, 'Subagent', 0, '/work', 'subagent'),
                ('codex_legacy', '/missing/legacy.jsonl', 1000, 'Legacy', 0, '/work', NULL),
                ('codex_top_level', '/missing/top-level.jsonl', 900, 'Top level', 0, '/work', 'user');",
        )?;
        drop(connection);

        let recent = query_recent_codex_contexts(&db_path, Some(&root))?;
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].id, "codex_legacy");
        assert_eq!(recent[1].id, "codex_top_level");
        assert!(
            !recent
                .iter()
                .any(|item| item.id.starts_with("codex_subagent"))
        );

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn filters_codex_subagent_threads_using_rollout_metadata_fallback() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-codex-rollout-source-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        let db_path = root.join("state_5.sqlite");
        let top_rollout = root.join("top-level.jsonl");
        let subagent_rollout = root.join("subagent.jsonl");
        fs::write(
            &top_rollout,
            "{\"type\":\"session_meta\",\"payload\":{\"thread_source\":\"user\"}}\n",
        )?;
        fs::write(
            &subagent_rollout,
            "{\"type\":\"session_meta\",\"payload\":{\"thread_source\":\"subagent\"}}\n",
        )?;

        let connection = Connection::open(&db_path)?;
        connection.execute_batch(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                archived INTEGER NOT NULL,
                cwd TEXT
            );",
        )?;
        let mut insert = connection.prepare(
            "INSERT INTO threads (id, rollout_path, updated_at, title, archived, cwd)
             VALUES (?1, ?2, ?3, ?4, 0, ?5)",
        )?;
        insert.execute(rusqlite::params![
            "codex_subagent",
            subagent_rollout.to_string_lossy().to_string(),
            2000_i64,
            "Subagent",
            "/work",
        ])?;
        insert.execute(rusqlite::params![
            "codex_top_level",
            top_rollout.to_string_lossy().to_string(),
            1000_i64,
            "Top level",
            "/work",
        ])?;
        drop(insert);
        drop(connection);

        let recent = query_recent_codex_contexts(&db_path, Some(&root))?;
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].id, "codex_top_level");
        assert!(!recent.iter().any(|item| item.id == "codex_subagent"));

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn parses_kimi_permission_flags_without_changing_resume_command() {
        let parsed = match parse_session_command(
            "cd /home/luka/codex-out && kimi --auto --resume session_1234",
        ) {
            Some(parsed) => parsed,
            None => panic!("Kimi command should parse"),
        };

        assert_eq!(parsed.provider, PROVIDER_KIMI);
        assert_eq!(parsed.command_id, "session_1234");
    }

    #[test]
    fn parses_and_renders_qwen_resume_without_inventing_fork_command() -> anyhow::Result<()> {
        let session_id = "11111111-1111-4111-8111-111111111111";
        for command in [
            format!("cd /home/luka && qwen --resume {session_id}"),
            format!("qwen -r={session_id}"),
            format!(r#""C:\\Users\\tester\\qwen.cmd" --resume {session_id}"#),
        ] {
            let parsed = parse_session_command(&command)
                .ok_or_else(|| anyhow::anyhow!("Qwen resume command should parse: {command}"))?;
            assert_eq!(parsed.provider, PROVIDER_QWEN);
            assert_eq!(parsed.command_id, session_id);
        }
        assert!(parse_session_command(&format!("qwen --fork {session_id}")).is_none());

        let items = deserialize_items(&format!(
            r#"[{{"kind":"session","id":"{session_id}","name":"Qwen","command_id":"{session_id}","color_hex":"","provider":"QWEN"}}]"#
        ))?;
        assert_eq!(items[0].provider, PROVIDER_QWEN);
        assert_eq!(
            render_markdown_items(&items),
            format!("# Qwen\nqwen --resume {session_id}\n")
        );
        let (parsed, warnings) = parse_markdown_items(&render_markdown_items(&items));
        assert!(warnings.is_empty());
        assert_eq!(parsed[0].provider, PROVIDER_QWEN);
        assert_eq!(parsed[0].command_id, session_id);
        Ok(())
    }

    #[test]
    fn parses_opencode_recent_sessions_without_downgrading_provider() -> anyhow::Result<()> {
        let recent = parse_opencode_session_list(
            r#"{
                "sessions": [
                    {
                        "id": "ses_old",
                        "title": "Old",
                        "time": {"updated": 1785096000000},
                        "directory": "/work/old"
                    },
                    {
                        "id": "ses_new",
                        "title": "New",
                        "updatedAt": "2026-07-26T20:00:01.250Z",
                        "directory": "/work/new",
                        "provider": "codex"
                    },
                    {
                        "id": "ses_child",
                        "title": "Subagent",
                        "updatedAt": "2026-07-26T20:00:02.250Z",
                        "parentID": "ses_new",
                        "directory": "/work/new"
                    },
                    {
                        "id": "ses_fallback",
                        "time": {"updated": 1785095999000}
                    },
                    {"id": "ses_invalid"}
                ]
            }"#,
        )?;

        assert_eq!(recent.len(), 3);
        assert_eq!(recent[0].provider, PROVIDER_OPENCODE);
        assert_eq!(recent[0].id, "ses_new");
        assert_eq!(recent[0].title, "New");
        assert_eq!(recent[0].updated_at, 1_785_096_001_250);
        assert_eq!(recent[0].forked_from_id, None);
        assert_eq!(recent[0].work_dir.as_deref(), Some("/work/new"));
        assert_eq!(recent[2].title, "back");
        assert!(!recent.iter().any(|item| item.id == "ses_child"));
        assert!(!recent.iter().any(|item| item.id == "ses_invalid"));
        Ok(())
    }

    #[test]
    fn treats_empty_opencode_session_output_as_no_sessions() -> anyhow::Result<()> {
        assert!(parse_opencode_session_list("\n").is_ok_and(|items| items.is_empty()));
        Ok(())
    }

    #[test]
    fn loads_only_top_level_opencode_sessions_from_database() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-opencode-test-{}-{stamp}",
            std::process::id()
        ));
        let home = root.join("home").join("tester");
        let markdown_path = home.join("codex-out").join("codex sessions.md");
        let db_path = home
            .join(".local")
            .join("share")
            .join("opencode")
            .join("opencode.db");
        fs::create_dir_all(db_path.parent().expect("database parent"))?;
        let connection = Connection::open(&db_path)?;
        connection.execute_batch(
            "CREATE TABLE session (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                parent_id TEXT,
                directory TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                time_archived INTEGER
            );
            INSERT INTO session
                (id, title, parent_id, directory, time_created, time_updated, time_archived)
            VALUES
                ('ses_child', 'Subagent session', 'ses_parent', '/home/tester', 1000, 3000, NULL),
                ('ses_latest', 'Latest root session', NULL, '/home/tester', 950, 2000, NULL),
                ('ses_parent', 'Parent session', NULL, '/home/tester', 900, 1900, NULL),
                ('ses_archived', 'Archived session', NULL, '/home/tester', 800, 4000, 1);",
        )?;
        drop(connection);

        let markdown_path = markdown_path.to_string_lossy().into_owned();
        let recent = load_recent_opencode_contexts(&markdown_path)?;
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].id, "ses_latest");
        assert_eq!(recent[0].title, "Latest root session");
        assert_eq!(recent[0].provider, PROVIDER_OPENCODE);
        assert_eq!(recent[0].forked_from_id, None);
        assert_eq!(recent[0].work_dir.as_deref(), Some("/home/tester"));
        assert_eq!(recent[0].updated_at, 2_000_000);
        assert_eq!(recent[1].id, "ses_parent");
        assert_eq!(recent[1].provider, PROVIDER_OPENCODE);
        assert!(!recent.iter().any(|item| item.id == "ses_child"));

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn preserves_opencode_config_items_and_renders_resume_command() -> anyhow::Result<()> {
        let items = deserialize_items(
            r#"[{"kind":"session","id":"ses_AbC","name":"Open","command_id":"ses_AbC","color_hex":"","provider":"OpenCode","fast":true}]"#,
        )?;

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].provider, PROVIDER_OPENCODE);
        assert_eq!(items[0].id, "ses_AbC");
        assert_eq!(items[0].command_id, "ses_AbC");
        assert_eq!(
            render_markdown_items(&items),
            "# Open\nopencode --session ses_AbC\n"
        );

        let (parsed, warnings) = parse_markdown_items("# Open\nopencode --session ses_AbC\n");
        assert!(warnings.is_empty());
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].provider, PROVIDER_OPENCODE);
        assert_eq!(parsed[0].command_id, "ses_AbC");
        Ok(())
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
            },
            ConfigItem {
                kind: "session".to_owned(),
                id: "11111111-1111-1111-1111-111111111111".to_owned(),
                name: "First".to_owned(),
                command_id: "11111111-1111-1111-1111-111111111111".to_owned(),
                color_hex: String::new(),
                provider: PROVIDER_CODEX.to_owned(),
            },
            ConfigItem {
                kind: "session".to_owned(),
                id: "session_22222222-2222-2222-2222-222222222222".to_owned(),
                name: "Kimi".to_owned(),
                command_id: "session_22222222-2222-2222-2222-222222222222".to_owned(),
                color_hex: String::new(),
                provider: PROVIDER_KIMI.to_owned(),
            },
            ConfigItem {
                kind: "group_end".to_owned(),
                id: "work".to_owned(),
                name: String::new(),
                command_id: String::new(),
                color_hex: String::new(),
                provider: String::new(),
            },
        ]);

        assert_eq!(
            text,
            "<!-- context-group: work|Work|#FB4934 -->\n\n# First\ncodex resume 11111111-1111-1111-1111-111111111111\n\n# Kimi\nkimi --session session_22222222-2222-2222-2222-222222222222\n\n<!-- /context-group -->\n"
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

    #[test]
    fn loads_qwen_jsonl_sessions_from_all_inferred_projects() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root =
            std::env::temp_dir().join(format!("context-qwen-test-{}-{stamp}", std::process::id()));
        let home = root.join("home").join("tester");
        let codex_out = home.join("codex-out");
        let markdown = codex_out.join("codex sessions.md");
        let project_key = home
            .to_string_lossy()
            .chars()
            .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '-' })
            .collect::<String>();
        let home_text = home.to_string_lossy().replace('\\', "/");
        let chats_dir = home
            .join(".qwen")
            .join("projects")
            .join(project_key)
            .join("chats");
        let child_id = "22222222-2222-4222-8222-222222222222";
        let parent_id = "33333333-3333-4333-8333-333333333333";
        let fallback_id = "44444444-4444-4444-8444-444444444444";

        fs::create_dir_all(&chats_dir)?;
        fs::create_dir_all(&codex_out)?;
        fs::write(&markdown, "")?;
        fs::write(
            chats_dir.join(format!("{child_id}.jsonl")),
            format!(
                concat!(
                    "{{\"uuid\":\"u1\",\"parentUuid\":null,\"sessionId\":\"{child_id}\",",
                    "\"timestamp\":\"2026-07-26T19:00:00.000Z\",\"type\":\"user\",",
                    "\"cwd\":\"{home}\",\"message\":{{\"role\":\"user\",",
                    "\"parts\":[{{\"text\":\"ignored prompt\"}}]}}}}\n",
                    "{{\"uuid\":\"u2\",\"parentUuid\":\"u1\",\"sessionId\":\"{child_id}\",",
                    "\"timestamp\":\"2026-07-26T20:00:01.250Z\",\"type\":\"system\",",
                    "\"subtype\":\"parent_session\",\"cwd\":\"{home}\",",
                    "\"systemPayload\":{{\"parentSessionId\":\"{parent_id}\"}}}}\n",
                    "{{\"uuid\":\"u3\",\"parentUuid\":\"u2\",\"sessionId\":\"{child_id}\",",
                    "\"timestamp\":\"2026-07-26T20:00:01.250Z\",\"type\":\"system\",",
                    "\"subtype\":\"custom_title\",\"cwd\":\"{home}\",",
                    "\"systemPayload\":{{\"customTitle\":\"Qwen child\",\"titleSource\":\"manual\"}}}}\n"
                ),
                child_id = child_id,
                home = home_text,
                parent_id = parent_id,
            ),
        )?;
        fs::write(
            chats_dir.join(format!("{fallback_id}.jsonl")),
            format!(
                concat!(
                    "{{\"uuid\":\"f1\",\"parentUuid\":null,\"sessionId\":\"{fallback_id}\",",
                    "\"timestamp\":\"2026-07-26T21:00:00.000Z\",\"type\":\"user\",",
                    "\"cwd\":\"{home}\",\"message\":{{\"role\":\"user\",",
                    "\"parts\":[{{\"text\":\"Qwen prompt fallback\"}}]}}}}\n"
                ),
                fallback_id = fallback_id,
                home = home_text,
            ),
        )?;

        let recent = load_recent_qwen_contexts(&markdown.to_string_lossy())?;
        assert_eq!(recent.len(), 2);
        let child = recent
            .iter()
            .find(|item| item.id == child_id)
            .ok_or_else(|| anyhow::anyhow!("Qwen child fixture was not loaded"))?;
        assert_eq!(child.provider, PROVIDER_QWEN);
        assert_eq!(child.title, "Qwen child");
        assert_eq!(child.updated_at, 1_785_096_001_250);
        assert_eq!(child.forked_from_id.as_deref(), Some(parent_id));
        assert_eq!(child.work_dir.as_deref(), Some(home_text.as_str()));

        let fallback = recent
            .iter()
            .find(|item| item.id == fallback_id)
            .ok_or_else(|| anyhow::anyhow!("Qwen fallback fixture was not loaded"))?;
        assert_eq!(fallback.title, "Qwen prompt fallback");
        assert_eq!(fallback.forked_from_id, None);

        fs::remove_dir_all(root)?;
        Ok(())
    }
}
