use crate::signals::{ReadTerminalTabs, TerminalTabsResult};
use anyhow::{Result, anyhow};
use rinf::{DartSignal, RustSignal};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub(super) const PROCESS_SCRIPT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../scripts/probe-terminal-sessions.py"
));
#[cfg(target_os = "windows")]
const TAB_SCRIPT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../scripts/probe-terminal-tabs.ps1"
));
const MAX_OUTPUT: usize = 256 * 1024;

pub(super) async fn listen() {
    let receiver = ReadTerminalTabs::get_dart_signal_receiver();
    while let Some(pack) = receiver.recv().await {
        let id = pack.message.request_id;
        let result =
            tokio::task::spawn_blocking(move || read(&pack.message.sessions_markdown_path)).await;
        let (payload_json, error) = match result {
            Ok(Ok(value)) => (value.to_string(), None),
            Ok(Err(e)) => ("{}".into(), Some(e.to_string())),
            Err(e) => ("{}".into(), Some(e.to_string())),
        };
        TerminalTabsResult {
            request_id: id,
            payload_json,
            error,
        }
        .send_signal_to_dart();
    }
}

pub(super) fn wsl_target(path: &str) -> Result<Option<(String, String)>> {
    let normalized = path.replace('\\', "/");
    if !normalized.starts_with("//") {
        return Ok(None);
    }
    let parts: Vec<_> = normalized.trim_start_matches('/').split('/').collect();
    if parts.len() < 4
        || !matches!(parts[0].to_lowercase().as_str(), "wsl.localhost" | "wsl$")
        || parts[2] != "home"
    {
        return Err(anyhow!(
            "Select a WSL home-based sessions file for Terminal discovery."
        ));
    }
    if [parts[1], parts[3]].iter().any(|s| {
        s.is_empty() || s.len() > 128 || s.starts_with('-') || s.chars().any(char::is_control)
    }) {
        return Err(anyhow!("Invalid WSL distribution/user."));
    }
    Ok(Some((parts[1].into(), parts[3].into())))
}

fn read(path: &str) -> Result<serde_json::Value> {
    let target = wsl_target(path)?;
    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("wsl.exe");
        if let Some((distro, user)) = target {
            command.args(["-d", &distro, "-u", &user]);
        }
        command.args(["--exec", "python3", "-", "--processes-json"]);
        command
    };
    #[cfg(not(target_os = "windows"))]
    let mut command = {
        let _ = target;
        let mut command = Command::new("python3");
        command.args(["-", "--processes-json"]);
        command
    };
    let mut payload: serde_json::Value = serde_json::from_slice(&bounded_output(
        &mut command,
        Some(PROCESS_SCRIPT.as_bytes().to_vec()),
    )?)?;
    // Enrich only providers actually running. Cached metadata reads share the
    // normal recent-session loader; no credentials or transcript bodies leave it.
    if let Some(sessions) = payload.get_mut("sessions").and_then(|v| v.as_array_mut()) {
        let providers: std::collections::BTreeSet<String> = sessions
            .iter()
            .filter_map(|s| s["provider"].as_str().map(str::to_owned))
            .collect();
        for provider in providers {
            if provider == "codex" {
                continue;
            }
            let Ok(recent) = super::recent_cache::load(path, &provider, 10) else {
                continue;
            };
            for session in sessions.iter_mut().filter(|s| s["provider"] == provider) {
                let Some(id) = session["launch_session_id"].as_str() else {
                    continue;
                };
                if let Some(item) = recent["sessions"]
                    .as_array()
                    .and_then(|items| items.iter().find(|item| item["id"].as_str() == Some(id)))
                {
                    session["name"] = item["title"].clone();
                }
            }
        }
    }
    #[cfg(target_os = "windows")]
    {
        let mut command = Command::new("powershell.exe");
        command.args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            TAB_SCRIPT,
        ]);
        match bounded_output(&mut command, None)
            .and_then(|bytes| Ok(serde_json::from_slice::<serde_json::Value>(&bytes)?))
        {
            Ok(windows) => payload["windows"] = windows,
            Err(error) => {
                payload["windows"] = serde_json::json!([]);
                payload["tab_error"] =
                    serde_json::json!(format!("Tab selection unavailable: {error}"));
            }
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        payload["windows"] = serde_json::json!([]);
    }
    Ok(payload)
}

pub(super) fn bounded_output(command: &mut Command, input: Option<Vec<u8>>) -> Result<Vec<u8>> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let mut child = command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    if let Some(input) = input {
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("No process input."))?;
        std::thread::spawn(move || {
            let _ = stdin.write_all(&input);
        });
    }
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("No process output."))?;
    let (send, recv) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.take((MAX_OUTPUT + 1) as u64).read_to_end(&mut bytes);
        let _ = send.send(result.map(|_| bytes));
    });
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut captured = None;
    loop {
        if let Ok(result) = recv.try_recv() {
            match result {
                Ok(bytes) if bytes.len() <= MAX_OUTPUT => captured = Some(bytes),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(anyhow!(
                        "Terminal discovery output exceeded its limit or failed."
                    ));
                }
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    return Err(anyhow!(
                        "Terminal discovery failed; check WSL/Python access."
                    ));
                }
                return match captured {
                    Some(bytes) => Ok(bytes),
                    None => {
                        let bytes =
                            recv.recv_timeout(deadline.saturating_duration_since(Instant::now()))??;
                        if bytes.len() > MAX_OUTPUT {
                            return Err(anyhow!("Terminal output exceeds limit."));
                        }
                        Ok(bytes)
                    }
                };
            }
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(anyhow!("Terminal discovery timed out."));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn terminal_target_validation() {
        assert_eq!(
            wsl_target(r"\\wsl.localhost\Ubuntu-24.04\home\luka\Context\sessions.md").unwrap(),
            Some(("Ubuntu-24.04".into(), "luka".into()))
        );
        assert!(wsl_target(r"\\other\share\sessions.md").is_err());
        assert!(wsl_target(r"\\wsl.localhost\--bad\home\luka\a.md").is_err());
        assert!(wsl_target("/home/luka/a.md").unwrap().is_none());
    }
    #[test]
    #[ignore = "Explicit read-only local WSL smoke"]
    fn terminal_live_snapshot() {
        let path = std::env::var("CONTEXT_TERMINAL_PROBE_PATH").unwrap();
        println!("{}", read(&path).unwrap());
    }
}
