use super::terminal_tabs::{bounded_output, wsl_target};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::process::Command;

const SCRIPT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../scripts/claude-account.py"
));

fn payload(value: &Value) -> Result<Value> {
    match value["action"].as_str() {
        Some(action @ ("account" | "models")) => Ok(json!({"action": action})),
        Some("apply") => {
            let model = value["model"].as_str().unwrap_or_default();
            let effort = value["effort"].as_str().unwrap_or_default();
            let key = value["account_key"].as_str().unwrap_or_default();
            if !["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"].contains(&model)
                || !["low", "medium", "high", "xhigh"].contains(&effort)
                || key.len() != 64
                || !key.bytes().all(|c| c.is_ascii_hexdigit())
            {
                return Err(anyhow!("Invalid Claude downgrade selection."));
            }
            Ok(json!({"action":"apply", "model":model, "effort":effort, "account_key":key}))
        }
        _ => Err(anyhow!("Unsupported Claude account action.")),
    }
}

pub(super) fn execute(path: &str, request: &Value) -> Result<Value> {
    let payload = payload(request)?.to_string();
    let target = wsl_target(path)?;
    #[cfg(target_os = "windows")]
    let mut command = {
        let (distro, user) = target
            .ok_or_else(|| anyhow!("Claude accounts require a WSL home-based sessions path."))?;
        let mut command = Command::new("wsl.exe");
        command.args([
            "-d", &distro, "-u", &user, "--exec", "python3", "-", &payload,
        ]);
        command
    };
    #[cfg(not(target_os = "windows"))]
    let mut command = {
        let _ = target;
        let mut command = Command::new("python3");
        command.args(["-", &payload]);
        command
    };
    let output = bounded_output(&mut command, Some(SCRIPT.as_bytes().to_vec()))?;
    let value: Value = serde_json::from_slice(&output)?;
    if let Some(error) = value["error"].as_str() {
        return Err(anyhow!("{error}"));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn claude_control_is_metadata_or_validated_defaults_only() {
        assert!(payload(&json!({"action":"account"})).is_ok());
        assert!(payload(&json!({"action":"models"})).is_ok());
        assert!(payload(&json!({"action":"apply","model":"claude-sonnet-5-5","effort":"high","account_key":"a".repeat(64)})).is_ok());
        assert!(payload(&json!({"action":"apply","model":"x;cmd","effort":"high","account_key":"a".repeat(64)})).is_err());
        assert!(
            payload(&json!({"action":"apply","model":"sonnet","effort":"high","account_key":""}))
                .is_err()
        );
        assert!(payload(&json!({"action":"prompt","text":"run this"})).is_err());
    }
}
