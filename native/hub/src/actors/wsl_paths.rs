use anyhow::{Result, anyhow};
use serde_json::Value;

const MAX_PATHS: usize = 16;
const MAX_INPUT_BYTES: usize = 12 * 1024;
#[cfg(any(target_os = "windows", test))]
const MAX_OUTPUT_BYTES: usize = 64 * 1024;
#[cfg(any(target_os = "windows", test))]
const SCRIPT: &str = r#"for path do resolved=$(readlink -e -- "$path" 2>/dev/null) || resolved=; printf '%s\0' "$resolved"; done"#;

fn validate(distro: &str, paths: &[String]) -> Result<()> {
    if distro.is_empty()
        || distro.len() > 128
        || distro.starts_with('-')
        || distro
            .chars()
            .any(|c| c.is_control() || c == '/' || c == '\\')
        || paths.is_empty()
        || paths.len() > MAX_PATHS
        || paths.iter().map(String::len).sum::<usize>() > MAX_INPUT_BYTES
        || paths.iter().any(|path| {
            !path.starts_with('/') || path.len() > 4096 || path.chars().any(char::is_control)
        })
    {
        return Err(anyhow!("Invalid WSL path lookup."));
    }
    Ok(())
}

#[cfg(any(target_os = "windows", test))]
fn decode(paths: &[String], output: &[u8]) -> Result<Value> {
    if output.len() > MAX_OUTPUT_BYTES || !output.ends_with(&[0]) {
        return Err(anyhow!("Invalid WSL path output."));
    }
    let targets: Vec<&[u8]> = output[..output.len() - 1]
        .split(|byte| *byte == 0)
        .collect();
    if targets.len() != paths.len() {
        return Err(anyhow!("Mismatched WSL path output."));
    }
    let mut resolved = serde_json::Map::new();
    for (source, target) in paths.iter().zip(targets) {
        let target = std::str::from_utf8(target)?;
        if target.starts_with('/') && target.len() <= 4096 && !target.chars().any(char::is_control)
        {
            resolved.insert(source.clone(), Value::String(target.to_owned()));
        }
    }
    Ok(Value::Object(resolved))
}

pub(super) fn resolve(distro: &str, paths: &[String]) -> Result<Value> {
    validate(distro, paths)?;
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        let mut command = std::process::Command::new("wsl.exe");
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        command.args(["-d", distro, "--exec", "sh", "-c", SCRIPT, "context-paths"]);
        command.args(paths);
        let output = bounded_output(command)?;
        decode(paths, &output)
    }
    #[cfg(not(target_os = "windows"))]
    {
        Err(anyhow!("WSL path translation is only needed on Windows."))
    }
}

#[cfg(any(target_os = "windows", test))]
fn bounded_output(mut command: std::process::Command) -> Result<Vec<u8>> {
    use std::io::Read;
    use std::process::Stdio;
    use std::time::{Duration, Instant};
    let mut child = command
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::piped())
        .spawn()?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("No WSL output."))?;
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout
            .take((MAX_OUTPUT_BYTES + 1) as u64)
            .read_to_end(&mut bytes);
        let _ = sender.send(result.map(|_| bytes));
    });
    let deadline = Instant::now() + Duration::from_secs(4);
    let mut captured = None;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    return Err(anyhow!("WSL path lookup failed."));
                }
                let bytes = match captured {
                    Some(bytes) => bytes,
                    None => receiver
                        .recv_timeout(deadline.saturating_duration_since(Instant::now()))??,
                };
                if bytes.len() > MAX_OUTPUT_BYTES {
                    return Err(anyhow!("WSL path output exceeds limit."));
                }
                return Ok(bytes);
            }
            Ok(None) if Instant::now() < deadline => {
                if captured.is_none()
                    && let Ok(result) = receiver.try_recv()
                {
                    let bytes = match result {
                        Ok(bytes) => bytes,
                        Err(error) => {
                            let _ = child.kill();
                            let _ = child.wait();
                            return Err(error.into());
                        }
                    };
                    if bytes.len() > MAX_OUTPUT_BYTES {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err(anyhow!("WSL path output exceeds limit."));
                    }
                    captured = Some(bytes);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(anyhow!("WSL path lookup timed out."));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "windows")]
    #[test]
    #[ignore = "Requires an explicit local WSL path fixture"]
    fn actual_wsl_symlink_lookup() {
        let path = std::env::var("CONTEXT_WSL_SYMLINK_PROBE").unwrap();
        let distro = std::env::var("CONTEXT_WSL_DISTRO_PROBE").unwrap();
        let expected = std::env::var("CONTEXT_WSL_TARGET_PROBE").unwrap();
        let resolved = resolve(&distro, std::slice::from_ref(&path)).unwrap();
        println!("WSL canonical targets: {resolved}");
        assert_eq!(resolved[&path].as_str(), Some(expected.as_str()));
    }

    #[test]
    fn rejects_invalid_requests_and_mismatched_output() {
        assert!(validate("--bad", &["/ok".into()]).is_err());
        assert!(validate("Ubuntu", &["relative".into()]).is_err());
        assert!(validate("Ubuntu", &["/bad\npath".into()]).is_err());
        assert!(validate("Ubuntu", &vec!["/ok".into(); 17]).is_err());
        assert!(decode(&["/ok".into()], b"/target").is_err());
        assert!(decode(&["/ok".into()], b"/one\0/two\0").is_err());
        assert_eq!(
            decode(&["/one".into(), "/missing".into()], b"/mnt/c/one\0\0").unwrap(),
            serde_json::json!({"/one":"/mnt/c/one"})
        );
    }

    #[cfg(unix)]
    #[test]
    fn resolves_symlinks_without_interpreting_path_text_as_shell_code() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("context-wsl-paths-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("clip ' $(not-a-command).mp4");
        std::fs::write(&file, b"fixture").unwrap();
        let link = root.join("published");
        symlink(&root, &link).unwrap();
        let paths = vec![
            link.join(file.file_name().unwrap())
                .to_str()
                .unwrap()
                .to_owned(),
            root.join("missing").to_str().unwrap().to_owned(),
        ];
        let mut command = std::process::Command::new("sh");
        command.args(["-c", SCRIPT, "context-paths"]).args(&paths);
        let output = bounded_output(command).unwrap();
        assert_eq!(
            decode(&paths, &output).unwrap(),
            serde_json::json!({paths[0].clone():file.to_str().unwrap()})
        );
        std::fs::remove_file(link).unwrap();
        std::fs::remove_file(file).unwrap();
        std::fs::remove_dir(root).unwrap();
    }
}
