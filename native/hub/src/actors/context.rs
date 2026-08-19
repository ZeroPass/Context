use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
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
    ClearCodexManualReset, DeleteCodexAccount, InitApp, LoadCodexAccounts, LoadConfig, OpFinished,
    RefreshRecent, RenameCodexAccount, SaveCodexAccount, SaveConfig, SetCodexManualReset,
    SetThemeSeed, SwitchCodexAccount, UiState,
};

const PROVIDER_CODEX: &str = "codex";
const PROVIDER_KIMI: &str = "kimi";
const PROVIDER_OPENCODE: &str = "opencode";
const PROVIDER_QWEN: &str = "qwen";
const RECENT_LIMIT: usize = 3;
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
const CODEX_WEEKLY_WINDOW_MIN_SECONDS: i64 = 6 * 24 * 60 * 60;
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
}

#[derive(Clone, Debug, PartialEq)]
struct WeeklyUsage {
    used_percent: f64,
    reset_at_ms: Option<i64>,
    window_seconds: i64,
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
    status: String,
}

#[derive(Debug)]
struct LoadedCodexAccounts {
    accounts: Vec<CodexAccountMetadata>,
    active_slot: Option<String>,
    active_slot_error: Option<String>,
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
    recent_opencode: Vec<RecentContext>,
    recent_qwen: Vec<RecentContext>,
    recent_busy: bool,
    recent_status: Option<String>,
    codex_accounts: Vec<CodexAccountMetadata>,
    codex_active_account: Option<String>,
    codex_account_busy: bool,
    codex_account_status: Option<String>,
    codex_account_error: Option<String>,
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
            recent_opencode: Vec::new(),
            recent_qwen: Vec::new(),
            recent_busy: false,
            recent_status: Some("Recent sessions not loaded.".to_owned()),
            codex_accounts: Vec::new(),
            codex_active_account: None,
            codex_account_busy: false,
            codex_account_status: Some("Codex accounts not loaded.".to_owned()),
            codex_account_error: None,
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
        let codex_accounts_json =
            serde_json::to_string(&self.codex_accounts).unwrap_or_else(|_| "[]".to_owned());

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
            recent_busy: self.recent_busy,
            recent_status: self.recent_status.clone(),
            codex_accounts_json,
            codex_active_account: self.codex_active_account.clone(),
            codex_account_busy: self.codex_account_busy,
            codex_account_status: self.codex_account_status.clone(),
            codex_account_error: self.codex_account_error.clone(),
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
            self.recent_codex.clear();
            self.recent_kimi.clear();
            self.recent_opencode.clear();
            self.recent_qwen.clear();
            self.recent_status = Some("Recent sessions not loaded.".to_owned());
            self.codex_accounts.clear();
            self.codex_active_account = None;
            self.codex_account_status = Some("Codex accounts not loaded.".to_owned());
            self.codex_account_error = None;
        }
        self.sessions_markdown_path = next_path;
        changed
    }

    async fn load_codex_accounts(&mut self, path_override: Option<String>) -> Result<()> {
        if self.codex_account_busy {
            return Err(anyhow!("Codex account operation is already in progress."));
        }

        if let Some(path) = path_override {
            self.set_sessions_markdown_path(path);
        }

        self.codex_account_busy = true;
        self.codex_account_error = None;
        self.codex_account_status = Some("Loading Codex accounts...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let current_slot_hint = self.codex_active_account.clone().unwrap_or_default();
        let result = spawn_blocking(move || {
            load_codex_accounts_for_markdown(&path, &current_slot_hint)
        })
        .await;
        let outcome = match result {
            Ok(Ok(loaded)) => {
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
            Ok(Err(error)) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not load Codex accounts.".to_owned());
                Err(error)
            }
            Err(_) => {
                let error = anyhow!("Could not load Codex accounts.");
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some(error.to_string());
                Err(error)
            }
        };

        self.codex_account_busy = false;
        self.emit_state();
        outcome
    }

    async fn set_codex_manual_reset(&mut self, path: String, manual_reset_at: i64) -> Result<()> {
        if self.codex_account_busy {
            return Err(anyhow!("Codex account operation is already in progress."));
        }
        if let Err(error) = validate_codex_manual_reset_at(manual_reset_at) {
            self.codex_account_error = Some(error.to_string());
            self.codex_account_status = Some("Could not set Codex manual reset.".to_owned());
            self.emit_state();
            return Err(error);
        }
        self.set_sessions_markdown_path(path);
        self.codex_account_busy = true;
        self.codex_account_error = None;
        self.codex_account_status = Some("Setting Codex manual reset...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let result = spawn_blocking(move || set_codex_manual_reset_file(&path, manual_reset_at))
            .await;
        let outcome = match result {
            Ok(Ok(accounts)) => {
                self.codex_accounts = accounts;
                self.codex_account_status = Some("Set Codex manual reset.".to_owned());
                Ok(())
            }
            Ok(Err(error)) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not set Codex manual reset.".to_owned());
                Err(error)
            }
            Err(_) => {
                let error = anyhow!("Could not set Codex manual reset.");
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some(error.to_string());
                Err(error)
            }
        };

        self.codex_account_busy = false;
        self.emit_state();
        outcome
    }

    async fn clear_codex_manual_reset(&mut self, path: String) -> Result<()> {
        if self.codex_account_busy {
            return Err(anyhow!("Codex account operation is already in progress."));
        }
        self.set_sessions_markdown_path(path);
        self.codex_account_busy = true;
        self.codex_account_error = None;
        self.codex_account_status = Some("Clearing Codex manual reset...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let result = spawn_blocking(move || clear_codex_manual_reset_file(&path)).await;
        let outcome = match result {
            Ok(Ok(accounts)) => {
                self.codex_accounts = accounts;
                self.codex_account_status = Some("Cleared Codex manual reset.".to_owned());
                Ok(())
            }
            Ok(Err(error)) => {
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some("Could not clear Codex manual reset.".to_owned());
                Err(error)
            }
            Err(_) => {
                let error = anyhow!("Could not clear Codex manual reset.");
                self.codex_account_error = Some(error.to_string());
                self.codex_account_status = Some(error.to_string());
                Err(error)
            }
        };

        self.codex_account_busy = false;
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
        let _ = self.load_codex_accounts(None).await;
        ok
    }

    async fn refresh_recent(&mut self, path_override: Option<String>) -> Result<()> {
        if self.recent_busy || self.busy || !self.initialized {
            return Ok(());
        }

        let path_changed = path_override
            .map(|path| self.set_sessions_markdown_path(path))
            .unwrap_or(false);

        self.recent_busy = true;
        self.recent_status = Some("Refreshing recent sessions...".to_owned());
        self.emit_state();

        let path = self.sessions_markdown_path.clone();
        let result = spawn_blocking(move || load_recent_file(&path)).await;

        let outcome = match result {
            Ok(Ok(loaded)) => {
                self.recent_codex = loaded.codex;
                self.recent_kimi = loaded.kimi;
                self.recent_opencode = loaded.opencode;
                self.recent_qwen = loaded.qwen;
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
        if path_changed {
            let _ = self.load_codex_accounts(None).await;
        }
        outcome
    }

    async fn save_config(&mut self, path: String, items_json: String) -> Result<()> {
        let path = path.trim().to_owned();
        let items = deserialize_items(&items_json)?;

        self.set_sessions_markdown_path(path.clone());
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
        let _ = self.load_codex_accounts(None).await;
        outcome
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
impl Notifiable<LoadCodexAccounts> for ContextActor {
    async fn notify(&mut self, msg: LoadCodexAccounts, _: &Context<Self>) {
        match self
            .load_codex_accounts(Some(msg.sessions_markdown_path))
            .await
        {
            Ok(()) => self.finish_op(msg.request_id, true, None),
            Err(error) => self.finish_op(msg.request_id, false, Some(error.to_string())),
        }
    }
}

#[async_trait]
impl Notifiable<SetCodexManualReset> for ContextActor {
    async fn notify(&mut self, msg: SetCodexManualReset, _: &Context<Self>) {
        match self
            .set_codex_manual_reset(msg.sessions_markdown_path, msg.manual_reset_at)
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
            .clear_codex_manual_reset(msg.sessions_markdown_path)
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

    Ok(LoadedRecent {
        codex,
        kimi,
        opencode,
        qwen,
        status: format!("{codex_status}  /  {kimi_status}  /  {opencode_status}  /  {qwen_status}"),
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
        RECENT_LIMIT.to_string(),
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
         ORDER BY time_updated DESC
         LIMIT {}",
        RECENT_LIMIT * 4
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

const CODEX_ACTIVE_ACCOUNT_OWNERSHIP_ERROR: &str =
    "Save current Codex credentials once because the live account's saved-slot ownership cannot be determined uniquely.";

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
    if !accounts_dir.is_dir() {
        return Ok(Vec::new());
    }

    let mut labels = read_codex_account_labels(accounts_dir)?;
    let manual_reset_at = effective_codex_manual_reset_at(accounts_dir, &mut labels)?;
    let live_auth_bytes =
        infer_codex_live_auth_path(accounts_dir).and_then(|path| fs::read(path).ok());
    let mut accounts = Vec::new();
    for (slot, path) in list_codex_account_snapshot_paths(accounts_dir)? {
        let updated_at = fs::metadata(&path)
            .ok()
            .and_then(|metadata| metadata.modified().ok())
            .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
            .and_then(|duration| i64::try_from(duration.as_millis()).ok());
        let name = labels
            .labels
            .get(&slot)
            .and_then(|label| normalize_codex_account_display_name(label).ok())
            .unwrap_or_else(|| slot.clone());
        let usage = match read_codex_snapshot_bytes_for_usage(&path) {
            Ok(snapshot_bytes) => fetch_codex_weekly_usage(prefer_live_codex_auth(
                &snapshot_bytes,
                live_auth_bytes.as_deref(),
            )),
            Err(()) => Err(CodexUsageError::Unavailable),
        };
        let (weekly_used_percent, weekly_reset_at, weekly_window_seconds, weekly_error) =
            match usage {
                Ok(usage) => (
                    Some(usage.used_percent),
                    usage.reset_at_ms,
                    Some(usage.window_seconds),
                    None,
                ),
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
    Ok(accounts)
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
    let stored = serde_json::from_slice::<CodexAccountLabels>(&bytes)
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
    Ok(CodexAccountLabels {
        labels,
        manual_reset_at: stored.manual_reset_at,
    })
}

fn write_codex_account_labels(accounts_dir: &Path, labels: &CodexAccountLabels) -> Result<()> {
    ensure_codex_accounts_dir(accounts_dir)?;
    let path = account_metadata_path(accounts_dir);
    if labels.labels.is_empty() && labels.manual_reset_at.is_none() {
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

fn set_codex_manual_reset_at(accounts_dir: &Path, manual_reset_at: i64) -> Result<()> {
    validate_codex_manual_reset_at(manual_reset_at)?;
    let mut labels = read_codex_account_labels(accounts_dir)?;
    labels.manual_reset_at = Some(manual_reset_at);
    write_codex_account_labels(accounts_dir, &labels)
}

fn clear_codex_manual_reset_at(accounts_dir: &Path) -> Result<()> {
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
    let mut labels = read_codex_account_labels(accounts_dir)?;
    labels.labels.insert(slot, label);
    write_codex_account_labels(accounts_dir, &labels)
}

fn remove_codex_account_label(accounts_dir: &Path, slot: &str) -> Result<()> {
    let slot = validate_codex_account_slot(slot)?;
    let mut labels = read_codex_account_labels(accounts_dir)?;
    labels.labels.remove(&slot);
    write_codex_account_labels(accounts_dir, &labels)
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
) -> std::result::Result<WeeklyUsage, CodexUsageError> {
    let (access_token, account_id) =
        codex_auth_tokens(auth_bytes).map_err(|_| CodexUsageError::Unavailable)?;
    let access_token =
        escape_curl_config_value(&access_token).ok_or(CodexUsageError::Unavailable)?;
    let account_id = match account_id.as_deref() {
        Some(account_id) => Some(
            escape_curl_config_value(account_id).ok_or(CodexUsageError::Unavailable)?,
        ),
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
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| i64::try_from(duration.as_millis()).ok())
        .ok_or(CodexUsageError::Unavailable)?;
    parse_weekly_usage_response(body, now_ms).map_err(|_| CodexUsageError::Unavailable)
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
    let reset_at_ms = value
        .get("reset_at")
        .and_then(serde_json::Value::as_i64)
        .and_then(|seconds| seconds.checked_mul(1_000))
        .or_else(|| {
            value
                .get("reset_after_seconds")
                .and_then(serde_json::Value::as_i64)
                .filter(|seconds| *seconds >= 0)
                .and_then(|seconds| seconds.checked_mul(1_000))
                .and_then(|milliseconds| now_ms.checked_add(milliseconds))
        });
    Some(WeeklyUsage {
        used_percent,
        reset_at_ms,
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

    let mut weekly_candidates = Vec::new();
    if let Some(secondary) = rate_limit
        .get("secondary_window")
        .and_then(|value| parse_usage_window(value, now_ms))
        .filter(|window| window.window_seconds >= CODEX_WEEKLY_WINDOW_MIN_SECONDS)
    {
        weekly_candidates.push(secondary);
    }
    if let Some(additional_rate_limits) = value
        .get("additional_rate_limits")
        .and_then(serde_json::Value::as_array)
    {
        for additional in additional_rate_limits {
            let additional_rate_limit = additional
                .get("rate_limit")
                .and_then(serde_json::Value::as_object)
                .or_else(|| additional.as_object());
            let Some(additional_rate_limit) = additional_rate_limit else {
                continue;
            };
            for window_name in ["primary_window", "secondary_window"] {
                if let Some(window) = additional_rate_limit
                    .get(window_name)
                    .and_then(|value| parse_usage_window(value, now_ms))
                    .filter(|window| window.window_seconds >= CODEX_WEEKLY_WINDOW_MIN_SECONDS)
                {
                    weekly_candidates.push(window);
                }
            }
        }
    }
    weekly_candidates
        .into_iter()
        .max_by_key(|window| window.window_seconds)
        .ok_or(())
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

fn set_codex_manual_reset_file(
    markdown_path: &str,
    manual_reset_at: i64,
) -> Result<Vec<CodexAccountMetadata>> {
    let paths = infer_codex_account_paths(markdown_path)?;
    set_codex_manual_reset_at(&paths.accounts_dir, manual_reset_at)?;
    list_codex_account_metadata(&paths.accounts_dir)
}

fn clear_codex_manual_reset_file(markdown_path: &str) -> Result<Vec<CodexAccountMetadata>> {
    let paths = infer_codex_account_paths(markdown_path)?;
    clear_codex_manual_reset_at(&paths.accounts_dir)?;
    list_codex_account_metadata(&paths.accounts_dir)
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
    save_snapshot_bytes(&paths.accounts_dir, &slot, &bytes)?;
    set_codex_account_label(&paths.accounts_dir, &slot, &display_name)?;
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
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use rusqlite::Connection;

    use super::{
        ConfigItem, CodexAccountPaths, CODEX_ACTIVE_ACCOUNT_OWNERSHIP_ERROR, PROVIDER_CODEX,
        PROVIDER_KIMI, PROVIDER_OPENCODE, PROVIDER_QWEN, CodexUsageError,
        codex_usage_error_for_http_status,
        delete_codex_account_file, deserialize_items, list_codex_account_metadata,
        load_recent_kimi_contexts, load_recent_qwen_contexts, parse_iso8601_utc_ms,
        parse_markdown_items, parse_opencode_session_list, parse_session_command,
        parse_weekly_usage_response, process_listing_has_codex, query_recent_codex_contexts,
        prefer_live_codex_auth, query_recent_opencode_contexts, read_codex_account_labels,
        remove_codex_account_label, rename_codex_account_file, render_markdown_items,
        replace_file_from_temp, replace_live_auth_with_rollback, resolve_codex_active_account_slot,
        save_codex_account_file, save_snapshot_bytes, set_codex_account_label,
        set_codex_manual_reset_at, validate_codex_account_slot,
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
        let future = i64::try_from(SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis())?
            + 60_000;
        set_codex_manual_reset_at(&root, future)?;
        let accounts = list_codex_account_metadata(&root)?;
        assert_eq!(accounts.len(), 2);
        assert!(accounts
            .iter()
            .all(|account| account.manual_reset_at == Some(future)));
        assert_eq!(read_codex_account_labels(&root)?.labels["1"], "one");

        fs::write(
            root.join("metadata.json"),
            br#"{"1":"one","manual_reset_at":0}"#,
        )?;
        let accounts = list_codex_account_metadata(&root)?;
        assert!(accounts
            .iter()
            .all(|account| account.manual_reset_at.is_none()));
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

        rename_codex_account_file(&markdown_text, "1", "renamed")?;
        let accounts = list_codex_account_metadata(&accounts_dir)?;
        assert_eq!(accounts[0].slot, "1");
        assert_eq!(accounts[0].name, "renamed");

        delete_codex_account_file(&markdown_text, "1")?;
        assert!(!accounts_dir.join("1.json").exists());
        assert_eq!(fs::read(codex_dir.join("auth.json"))?, live_auth);
        let labels = read_codex_account_labels(&accounts_dir)?;
        assert!(!labels.labels.contains_key("1"));
        assert!(labels.labels.contains_key("2"));

        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn parses_weekly_codex_usage_and_reset_pacing_inputs() -> anyhow::Result<()> {
        let body = br#"{
            "rate_limit": {
                "primary_window": {
                    "used_percent": 42.5,
                    "limit_window_seconds": 3600,
                    "reset_after_seconds": 900
                },
                "secondary_window": null
            },
            "additional_rate_limits": [
                {
                    "rate_limit": {
                        "primary_window": {
                            "used_percent": 77,
                            "limit_window_seconds": 604800,
                            "reset_after_seconds": 321
                        }
                    }
                }
            ]
        }"#;
        let usage = parse_weekly_usage_response(body, 1_700_000_000_000)
            .map_err(|_| anyhow::anyhow!("weekly usage did not parse"))?;
        assert_eq!(usage.used_percent, 77.0);
        assert_eq!(usage.window_seconds, 604800);
        assert_eq!(usage.reset_at_ms, Some(1_700_000_321_000));

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
    fn prefers_live_codex_auth_only_for_matching_account() {
        let snapshot: &[u8] =
            br#"{"tokens":{"account_id":"account-1","access_token":"saved"}}"#;
        let live: &[u8] =
            br#"{"tokens":{"account_id":"account-1","access_token":"fresh"}}"#;
        let other: &[u8] =
            br#"{"tokens":{"account_id":"account-2","access_token":"other"}}"#;
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
                        "parentID": "ses_parent",
                        "directory": "/work/new",
                        "provider": "codex"
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
        assert_eq!(recent[0].forked_from_id.as_deref(), Some("ses_parent"));
        assert_eq!(recent[0].work_dir.as_deref(), Some("/work/new"));
        assert_eq!(recent[2].title, "back");
        assert!(!recent.iter().any(|item| item.id == "ses_invalid"));
        Ok(())
    }

    #[test]
    fn treats_empty_opencode_session_output_as_no_sessions() -> anyhow::Result<()> {
        assert!(parse_opencode_session_list("\n").is_ok_and(|items| items.is_empty()));
        Ok(())
    }

    #[test]
    fn loads_opencode_child_sessions_from_database() -> anyhow::Result<()> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-opencode-test-{}-{stamp}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        let db_path = root.join("opencode.db");
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
                ('ses_child', 'Child session', 'ses_parent', '/home/tester', 1000, 2000, NULL),
                ('ses_parent', 'Parent session', NULL, '/home/tester', 900, 1900, NULL),
                ('ses_archived', 'Archived session', NULL, '/home/tester', 800, 3000, 1);",
        )?;
        drop(connection);

        let recent = query_recent_opencode_contexts(&db_path)?;
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].id, "ses_child");
        assert_eq!(recent[0].title, "Child session");
        assert_eq!(recent[0].provider, PROVIDER_OPENCODE);
        assert_eq!(recent[0].forked_from_id.as_deref(), Some("ses_parent"));
        assert_eq!(recent[0].work_dir.as_deref(), Some("/home/tester"));
        assert_eq!(recent[0].updated_at, 2_000_000);
        assert_eq!(recent[1].id, "ses_parent");

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
