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
    pub recent_busy: bool,
    pub recent_status: Option<String>,
}

#[derive(Serialize, RustSignal)]
pub struct OpFinished {
    pub request_id: u64,
    pub ok: bool,
    pub error: Option<String>,
}
