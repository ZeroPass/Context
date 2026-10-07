use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_BYTES: u64 = 8 * 1024 * 1024;
const START: &str = "<!-- context:whiteboard:entry ";
const HEADER_START: &str = "<!-- context:whiteboard:instructions:v1";
const HEADER_END: &str = "<!-- context:whiteboard:header-end -->";
const TEMPLATE: &str = include_str!("../../../assets/templates/whiteboard.instructions.md");

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Metadata {
    id: String,
    published_at_ms: u64,
    title: String,
    provider: String,
    cwd: String,
    body_bytes: usize,
    body_chars: usize,
}

#[derive(Clone, Debug)]
struct Post {
    metadata: Metadata,
    body: String,
}

fn parse(text: &str) -> Vec<Post> {
    let mut posts = Vec::new();
    let mut remaining = text;
    while let Some(start) = remaining.find(START) {
        remaining = &remaining[start + START.len()..];
        let Some(line_end) = remaining.find('\n') else {
            break;
        };
        let line = &remaining[..line_end];
        remaining = &remaining[line_end + 1..];
        if line.len() > 131072 {
            continue;
        }
        let Some(json) = line.strip_suffix(" -->") else {
            continue;
        };
        let Ok(metadata) = serde_json::from_str::<Metadata>(json) else {
            continue;
        };
        if metadata.id.is_empty()
            || metadata.id.len() > 80
            || !metadata
                .id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        {
            continue;
        }
        let body = remaining;
        let end = format!("\n<!-- context:whiteboard:end {} -->", metadata.id);
        let end_at = metadata.body_bytes;
        if end_at > MAX_BYTES as usize
            || !body.is_char_boundary(end_at)
            || !body
                .get(end_at..)
                .is_some_and(|tail| tail.starts_with(&end))
        {
            continue;
        }
        posts.retain(|p: &Post| p.metadata.id != metadata.id);
        posts.push(Post {
            metadata,
            body: body[..end_at].to_owned(),
        });
        remaining = &body[end_at + end.len()..];
    }
    posts
}

fn header(text: &str, path: &Path) -> String {
    if let Some(start) = text.find(HEADER_START)
        && let Some(end) = text[start..].find(HEADER_END)
    {
        return format!("{}\n", &text[start..start + end + HEADER_END.len()]);
    }
    let root = path.parent().unwrap_or_else(|| Path::new("."));
    let helper = if cfg!(windows) {
        "publish-whiteboard.ps1"
    } else {
        "publish-whiteboard"
    };
    TEMPLATE
        .replace("{{WHITEBOARD_PATH}}", &path.display().to_string())
        .replace(
            "{{PUBLISH_COMMAND}}",
            &root.join("scripts").join(helper).display().to_string(),
        )
}

fn bounded_read(path: &Path) -> io::Result<String> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(String::new()),
        Err(error) => return Err(error),
    };
    if file.metadata()?.len() > MAX_BYTES {
        return Err(io::Error::other(
            "Whiteboard exceeds the 8 MiB safety limit.",
        ));
    }
    let mut text = String::new();
    file.take(MAX_BYTES + 1).read_to_string(&mut text)?;
    if text.len() as u64 > MAX_BYTES {
        return Err(io::Error::other("Whiteboard grew beyond the safety limit."));
    }
    Ok(text)
}

fn write_board(path: &Path, post: Option<Post>, init: bool) -> io::Result<usize> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("Whiteboard needs a parent folder."))?;
    fs::create_dir_all(parent)?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path.with_file_name("whiteboard.md.lock"))?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match lock.try_lock() {
            Ok(()) => break,
            Err(std::fs::TryLockError::WouldBlock) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(error) => {
                return Err(io::Error::other(format!(
                    "Could not lock Whiteboard: {error}"
                )));
            }
        }
    }
    let text = bounded_read(path)?;
    if init && path.exists() {
        return Ok(parse(&text).len());
    }
    let mut posts = parse(&text);
    if let Some(post) = post {
        posts.push(post);
    }
    if posts.len() > 3 {
        posts.drain(..posts.len() - 3);
    }
    let mut output = header(&text, path);
    for post in &posts {
        let metadata = serde_json::to_string(&post.metadata).map_err(io::Error::other)?;
        output.push_str(&format!(
            "\n{START}{metadata} -->\n{}\n<!-- context:whiteboard:end {} -->\n",
            post.body, post.metadata.id
        ));
    }
    if output.len() as u64 > MAX_BYTES {
        return Err(io::Error::other("Published Whiteboard exceeds 8 MiB."));
    }
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let temp = parent.join(format!(".whiteboard.{}.{nonce}.tmp", std::process::id()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(output.as_bytes())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result?;
    drop(lock);
    Ok(posts.len())
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let mut path = None;
    let mut title = String::new();
    let mut provider = String::new();
    let mut init = false;
    let mut prune = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--file" => path = Some(PathBuf::from(args.next().ok_or("Missing --file value")?)),
            "--title" => title = args.next().ok_or("Missing --title value")?,
            "--provider" => provider = args.next().ok_or("Missing --provider value")?,
            "--init" => init = true,
            "--prune" => prune = true,
            _ => return Err(format!("Unknown argument: {arg}").into()),
        }
    }
    let path = path.ok_or("Pass --file /path/to/Context/whiteboard.md")?;
    let path = if path.is_absolute() {
        path
    } else {
        std::env::current_dir()?.join(path)
    };
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?;
    let post = if init || prune {
        None
    } else {
        let mut body = String::new();
        io::stdin().take(MAX_BYTES + 1).read_to_string(&mut body)?;
        if body.trim().is_empty() || body.len() as u64 > MAX_BYTES {
            return Err("Publish non-empty final Markdown output, at most 8 MiB.".into());
        }
        if title.trim().is_empty() {
            title = body
                .lines()
                .find(|line| !line.trim().is_empty())
                .unwrap_or("Published output")
                .trim_start_matches(['#', ' '])
                .chars()
                .take(160)
                .collect();
        }
        Some(Post {
            metadata: Metadata {
                id: format!("{:x}-{:x}", now.as_nanos(), std::process::id()),
                published_at_ms: now.as_millis().try_into()?,
                title: title.chars().take(160).collect(),
                provider,
                cwd: std::env::current_dir()?.to_string_lossy().into_owned(),
                body_bytes: body.len(),
                body_chars: body.encode_utf16().count(),
            },
            body,
        })
    };
    let count = write_board(&path, post, init)?;
    println!(
        "{}",
        serde_json::json!({"published": !init && !prune, "entries": count, "file": path})
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("Whiteboard: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn post(id: usize) -> Post {
        let body = format!("# Output {id}\n\n[file](a.md)\n");
        Post {
            metadata: Metadata {
                id: id.to_string(),
                published_at_ms: id as u64,
                title: format!("Post {id}"),
                provider: "codex".into(),
                cwd: "/work".into(),
                body_bytes: body.len(),
                body_chars: body.encode_utf16().count(),
            },
            body,
        }
    }
    #[test]
    fn append_cleans_all_surplus_debris_preserves_header_and_body() -> io::Result<()> {
        let root =
            std::env::temp_dir().join(format!("context-whiteboard-prune-{}", std::process::id()));
        fs::create_dir_all(&root)?;
        let path = root.join("whiteboard.md");
        let mut text = header("", &path).replace("Context Whiteboard -", "Custom instructions -");
        for id in 0..9 {
            let entry = post(id);
            text.push_str(&format!(
                "\n{START}{} -->\n{}\n<!-- context:whiteboard:end {id} -->\nTRASH\n",
                serde_json::to_string(&entry.metadata)?,
                entry.body
            ));
        }
        text.push_str("<!-- context:whiteboard:entry broken -->\nunfinished garbage");
        fs::write(&path, text)?;
        assert_eq!(write_board(&path, Some(post(9)), false)?, 3);
        let text = bounded_read(&path)?;
        let entries = parse(&text);
        assert_eq!(
            entries.iter().map(|p| &p.metadata.id).collect::<Vec<_>>(),
            ["7", "8", "9"]
        );
        assert_eq!(entries[2].body, post(9).body);
        assert!(text.contains("Custom instructions"));
        assert!(!text.contains("TRASH") && !text.contains("unfinished garbage"));
        fs::remove_dir_all(root)?;
        Ok(())
    }
    #[test]
    fn concurrent_writers_are_serialized() -> io::Result<()> {
        let root = std::env::temp_dir().join(format!(
            "context-whiteboard-concurrent-{}",
            std::process::id()
        ));
        fs::create_dir_all(&root)?;
        let path = root.join("whiteboard.md");
        let handles = (0..12)
            .map(|id| {
                let path = path.clone();
                std::thread::spawn(move || write_board(&path, Some(post(id)), false))
            })
            .collect::<Vec<_>>();
        for handle in handles {
            assert!((1..=3).contains(&handle.join().unwrap()?));
        }
        let entries = parse(&bounded_read(&path)?);
        assert_eq!(entries.len(), 3);
        assert!(
            entries
                .iter()
                .all(|p| p.body == post(p.metadata.id.parse().unwrap()).body)
        );
        fs::remove_dir_all(root)?;
        Ok(())
    }
}
