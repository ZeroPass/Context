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
pub struct LoadMuseAccounts {
    pub request_id: u64,
    pub sessions_markdown_path: String,
}

#[derive(Deserialize, DartSignal)]
pub struct LoadZcodeAccounts {
    pub request_id: u64,
    pub sessions_markdown_path: String,
}

#[derive(Deserialize, DartSignal)]
pub struct SetCodexManualReset {
    pub request_id: u64,
    pub sessions_markdown_path: String,
    pub manual_reset_at: i64,
}

#[derive(Deserialize, DartSignal)]
pub struct ClearCodexManualReset {
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
    pub recent_muse_json: String,
    // Keep this field's position in sync with the hand-maintained Dart binding
    // in lib/src/bindings/signals/ui_state.dart: bincode is order-sensitive.
    pub recent_zcode_json: String,
    pub recent_busy: bool,
    pub recent_status: Option<String>,
    pub codex_accounts_json: String,
    pub codex_active_account: Option<String>,
    pub codex_account_busy: bool,
    pub codex_account_status: Option<String>,
    pub codex_account_error: Option<String>,
    pub muse_accounts_json: String,
    pub muse_active_account: Option<String>,
    pub muse_account_busy: bool,
    pub muse_account_status: Option<String>,
    pub muse_account_error: Option<String>,
    // Keep these fields' positions in sync with the hand-maintained Dart
    // binding in lib/src/bindings/signals/ui_state.dart: bincode is
    // order-sensitive.
    pub zcode_accounts_json: String,
    pub zcode_account_busy: bool,
    pub zcode_account_status: Option<String>,
    pub zcode_account_error: Option<String>,
}

#[derive(Serialize, RustSignal)]
pub struct OpFinished {
    pub request_id: u64,
    pub ok: bool,
    pub error: Option<String>,
}

#[cfg(test)]
mod wire_order_tests {
    use super::*;

    // Bincode serializes struct fields in definition order, and the Dart
    // binding for UiState is hand-maintained in
    // lib/src/bindings/signals/ui_state.dart. A field inserted in only one of
    // the two desynchronizes the whole stream: Dart misreads every following
    // field, the UiState listener dies, and the app silently stops loading
    // the markdown path, accounts, and recents. These sentinel tests pin the
    // wire layout on both sides; update the hex in both when adding fields.
    const UI_STATE_WIRE_HEX: &str = "341200000000000001010100000000000000730001000000000000007001000000000000006901000000000000007701000000000000006301000000000000006b01000000000000006f01000000000000007101000000000000006d01000000000000007a000101000000000000007202000000000000006361000101020000000000000063730002000000000000006d610102000000000000006d6f00000102000000000000006d6502000000000000007a61010102000000000000007a7300";

    fn sentinel_state() -> UiState {
        UiState {
            theme_seed_color_value: 0x1234,
            busy: true,
            status: Some("s".to_owned()),
            last_error: None,
            sessions_markdown_path: "p".to_owned(),
            items_json: "i".to_owned(),
            warnings_json: "w".to_owned(),
            recent_codex_json: "c".to_owned(),
            recent_kimi_json: "k".to_owned(),
            recent_opencode_json: "o".to_owned(),
            recent_qwen_json: "q".to_owned(),
            recent_muse_json: "m".to_owned(),
            recent_zcode_json: "z".to_owned(),
            recent_busy: false,
            recent_status: Some("r".to_owned()),
            codex_accounts_json: "ca".to_owned(),
            codex_active_account: None,
            codex_account_busy: true,
            codex_account_status: Some("cs".to_owned()),
            codex_account_error: None,
            muse_accounts_json: "ma".to_owned(),
            muse_active_account: Some("mo".to_owned()),
            muse_account_busy: false,
            muse_account_status: None,
            muse_account_error: Some("me".to_owned()),
            zcode_accounts_json: "za".to_owned(),
            zcode_account_busy: true,
            zcode_account_status: Some("zs".to_owned()),
            zcode_account_error: None,
        }
    }

    #[test]
    fn ui_state_wire_order_matches_dart_binding() {
        let bytes = bincode::serialize(&sentinel_state()).expect("serialize UiState");
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        assert_eq!(hex, UI_STATE_WIRE_HEX);
    }
}
