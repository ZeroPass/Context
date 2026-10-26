use super::terminal_tabs::{PROCESS_SCRIPT, bounded_output, wsl_target};
use crate::signals::{CodexSessionControl, CodexSessionControlResult};
use anyhow::{Result, anyhow};
use rinf::{DartSignal, RustSignal};
use serde_json::{Value, json};
use std::process::Command;

const SCRIPT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../scripts/codex-session-control.py"
));

pub(super) async fn listen() {
    let receiver = CodexSessionControl::get_dart_signal_receiver();
    while let Some(pack) = receiver.recv().await {
        let request = pack.message;
        let id = request.request_id;
        let result = tokio::task::spawn_blocking(move || execute(request)).await;
        let (payload_json, error) = match result {
            Ok(Ok(payload)) => (payload.to_string(), None),
            Ok(Err(error)) => ("{}".into(), Some(error.to_string())),
            Err(_) => ("{}".into(), Some("Codex control worker stopped.".into())),
        };
        CodexSessionControlResult {
            request_id: id,
            payload_json,
            error,
        }
        .send_signal_to_dart();
    }
}

fn validated_payload(source: &str) -> Result<Value> {
    if source.len() > 32768 {
        return Err(anyhow!("Codex control request is too large."));
    }
    let value: Value = serde_json::from_str(source)?;
    match value["action"].as_str() {
        Some("models") => Ok(json!({"action":"models"})),
        Some(action @ ("status" | "recover")) => {
            let targets = value["targets"]
                .as_array()
                .ok_or_else(|| anyhow!("Missing targets."))?;
            if targets.is_empty()
                || targets.len() > 64
                || (action == "recover" && targets.len() != 1)
            {
                return Err(anyhow!("Invalid recovery target count."));
            }
            let mut cleaned = Vec::new();
            for target in targets {
                let mut entry = serde_json::Map::new();
                for field in ["id", "pid", "start"] {
                    let text = target[field]
                        .as_str()
                        .ok_or_else(|| anyhow!("Missing {field}."))?;
                    if text.is_empty()
                        || text.len() > 200
                        || !text.bytes().all(|b| {
                            if field == "id" {
                                b.is_ascii_alphanumeric() || b"-_.".contains(&b)
                            } else {
                                b.is_ascii_digit()
                            }
                        })
                    {
                        return Err(anyhow!("Invalid recovery {field}."));
                    }
                    entry.insert(field.into(), json!(text));
                }
                if action == "recover" {
                    let turn = target["turn_id"]
                        .as_str()
                        .ok_or_else(|| anyhow!("Missing turn ID."))?;
                    if turn.is_empty()
                        || turn.len() > 200
                        || !turn
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
                    {
                        return Err(anyhow!("Invalid turn ID."));
                    }
                    entry.insert("turn_id".into(), json!(turn));
                }
                cleaned.push(Value::Object(entry));
            }
            Ok(json!({"action":action,"targets":cleaned}))
        }
        Some("apply") => {
            for field in ["model", "effort"] {
                let text = value[field]
                    .as_str()
                    .ok_or_else(|| anyhow!("Missing {field}."))?;
                if text.is_empty()
                    || text.len() > 100
                    || !text
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
                {
                    return Err(anyhow!("Invalid Codex {field}."));
                }
            }
            Ok(json!({"action":"apply","model":value["model"],"effort":value["effort"]}))
        }
        _ => Err(anyhow!("Unsupported Codex control action.")),
    }
}

fn execute(request: CodexSessionControl) -> Result<Value> {
    let payload = validated_payload(&request.payload_json)?.to_string();
    let target = wsl_target(&request.sessions_markdown_path)?;
    #[cfg(target_os = "windows")]
    let mut command = {
        let (distro, user) =
            target.ok_or_else(|| anyhow!("Live Codex control requires a WSL sessions path."))?;
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
    let source = format!(
        "PROBE_SOURCE = {}\n{}",
        serde_json::to_string(PROCESS_SCRIPT)?,
        SCRIPT
    );
    let output = bounded_output(&mut command, Some(source.into_bytes()))?;
    let result: Value = serde_json::from_slice(&output)?;
    if let Some(error) = result["error"].as_str() {
        return Err(anyhow!("{error}"));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn control_payload_is_narrow_and_never_accepts_shell_input() {
        assert!(
            validated_payload(r#"{"action":"apply","model":"gpt-6.1-sol","effort":"high"}"#)
                .is_ok()
        );
        assert!(validated_payload(r#"{"action":"models"}"#).is_ok());
        assert!(validated_payload(r#"{"action":"turn/start"}"#).is_err());
        assert!(
            validated_payload(r#"{"action":"apply","model":"x;touch /tmp/x","effort":"high"}"#)
                .is_err()
        );
        assert!(validated_payload(r#"{"action":"apply","model":"x","effort":""}"#).is_err());
        assert!(
            validated_payload(
                r#"{"action":"status","targets":[{"id":"a","pid":"123","start":"456"}]}"#
            )
            .is_ok()
        );
        assert!(validated_payload(r#"{"action":"recover","targets":[{"id":"a","pid":"123","start":"456","turn_id":"t-1"}]}"#).is_ok());
        assert!(
            validated_payload(
                r#"{"action":"recover","targets":[{"id":"a","pid":"123","start":"456"}]}"#
            )
            .is_err()
        );
        assert!(
            validated_payload(
                r#"{"action":"status","targets":[{"id":"a;rm","pid":"123","start":"456"}]}"#
            )
            .is_err()
        );
        assert!(validated_payload(r#"{"action":"status","targets":[]}"#).is_err());
    }
}
