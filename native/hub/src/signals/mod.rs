use rinf::{DartSignal, RustSignal};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, DartSignal)]
pub struct InitApp {
    pub theme_seed_color_value: i64,
    pub sessions_markdown_path: String,
}

#[derive(Deserialize, DartSignal)]
pub struct LoadConfig {
    pub request_id: u64,
    pub sessions_markdown_path: String,
}

#[derive(Deserialize, DartSignal)]
pub struct RefreshRecent {
    pub request_id: u64,
    pub sessions_markdown_path: String,
}

#[derive(Deserialize, DartSignal)]
pub struct SaveConfig {
    pub request_id: u64,
    pub sessions_markdown_path: String,
    pub items_json: String,
}

#[derive(Deserialize, DartSignal)]
pub struct LoadCodexAccounts {
    pub request_id: u64,
    pub sessions_markdown_path: String,
}

#[derive(Deserialize, DartSignal)]
pub struct SaveCodexAccount {
    pub request_id: u64,
    pub sessions_markdown_path: String,
    pub slot: String,
    pub display_name: String,
}

#[derive(Deserialize, DartSignal)]
pub struct SwitchCodexAccount {
    pub request_id: u64,
    pub sessions_markdown_path: String,
    pub current_slot: String,
    pub target_slot: String,
}

#[derive(Deserialize, DartSignal)]
pub struct RenameCodexAccount {
    pub request_id: u64,
    pub sessions_markdown_path: String,
    pub slot: String,
    pub display_name: String,
}

#[derive(Deserialize, DartSignal)]
pub struct DeleteCodexAccount {
    pub request_id: u64,
    pub sessions_markdown_path: String,
    pub slot: String,
}

#[derive(Deserialize, DartSignal)]
pub struct SetThemeSeed {
    pub value: i64,
}

#[derive(Serialize, RustSignal)]
pub struct UiState {
    pub theme_seed_color_value: i64,
    pub busy: bool,
    pub status: Option<String>,
    pub last_error: Option<String>,
    pub sessions_markdown_path: String,
    pub items_json: String,
    pub warnings_json: String,
    pub recent_codex_json: String,
    pub recent_kimi_json: String,
    pub recent_opencode_json: String,
    pub recent_qwen_json: String,
    pub recent_busy: bool,
    pub recent_status: Option<String>,
    pub codex_accounts_json: String,
    pub codex_active_account: Option<String>,
    pub codex_account_busy: bool,
    pub codex_account_status: Option<String>,
    pub codex_account_error: Option<String>,
}

#[derive(Serialize, RustSignal)]
pub struct OpFinished {
    pub request_id: u64,
    pub ok: bool,
    pub error: Option<String>,
}
