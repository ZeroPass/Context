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
const DROP_ROOT: &str = "whiteboard-drops";
const DROP_MARKER: &str = ".context-drop.json";
const DROP_SCHEMA: &str = "context.whiteboard.drop.v1";

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Metadata {
    id: String,
    published_at_ms: u64,
    title: String,
    provider: String,
    cwd: String,
    body_bytes: usize,
    body_chars: usize,
    #[serde(default)]
    local_drop: bool,
    #[serde(default)]
    agent_prompt: String,
    #[serde(default)]
    drop_folder: String,
}

#[derive(Serialize, Deserialize)]
struct DropOwner {
    schema: String,
    folder: String,
    retired: bool,
}

fn valid_drop_folder(folder: &str) -> bool {
    !folder.is_empty()
        && folder.len() <= 100
        && folder
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}

fn is_link(metadata: &fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        metadata.file_type().is_symlink()
    }
}

fn drop_owner(parent: &Path, folder: &str) -> io::Result<(PathBuf, DropOwner)> {
    if !valid_drop_folder(folder) {
        return Err(io::Error::other("Invalid drop folder"));
    }
    let root = parent.join(DROP_ROOT);
    let path = root.join(folder);
    for directory in [&root, &path] {
        let metadata = fs::symlink_metadata(directory)?;
        if !metadata.is_dir() || is_link(&metadata) {
            return Err(io::Error::other("Drop folders must not be links"));
        }
    }
    let marker = path.join(DROP_MARKER);
    let metadata = fs::symlink_metadata(&marker)?;
    if !metadata.is_file() || is_link(&metadata) || metadata.len() > 2048 {
        return Err(io::Error::other("Invalid drop ownership marker"));
    }
    let mut text = String::new();
    File::open(marker)?.take(2049).read_to_string(&mut text)?;
    let owner: DropOwner = serde_json::from_str(&text).map_err(io::Error::other)?;
    if owner.schema != DROP_SCHEMA || owner.folder != folder || text.len() > 2048 {
        return Err(io::Error::other("Drop ownership mismatch"));
    }
    Ok((path, owner))
}

fn remove_owned_drop(path: &Path) -> io::Result<()> {
    // Never recurse into a folder or follow a link. Originals are only listed
    // inside README.md, and are never deletion targets.
    const FILES: [&str; 5] = [
        DROP_MARKER,
        "README.md",
        "message.md",
        "clipboard.png",
        "clipboard.bmp",
    ];
    let mut files = Vec::new();
    for entry in fs::read_dir(path)?.take(FILES.len() + 1) {
        let entry = entry?;
        let name = entry.file_name();
        let metadata = fs::symlink_metadata(entry.path())?;
        if !FILES.iter().any(|allowed| name == *allowed)
            || !metadata.is_file()
            || is_link(&metadata)
        {
            return Err(io::Error::other(
                "Unknown files in temporary drop; keeping it intact",
            ));
        }
        if name != DROP_MARKER {
            files.push(entry.path());
        }
    }
    for file in files {
        fs::remove_file(file)?;
    }
    fs::remove_file(path.join(DROP_MARKER))?;
    fs::remove_dir(path)
}

fn cleanup_drops(parent: &Path, retained: &[Post], removed: &[Post]) {
    let retained_folder = |folder: &str| {
        retained
            .iter()
            .any(|post| post.metadata.drop_folder.eq_ignore_ascii_case(folder))
    };
    for post in removed.iter().filter(|post| post.metadata.local_drop) {
        let folder = &post.metadata.drop_folder;
        if retained_folder(folder) {
            continue;
        }
        if let Ok((path, mut owner)) = drop_owner(parent, folder) {
            owner.retired = true;
            // Record retirement before deleting anything. A locked video can be
            // retried by the next publisher without guessing that a staging drop
            // was abandoned or deleting another concurrent drop's files.
            if let Ok(bytes) = serde_json::to_vec(&owner) {
                if fs::write(path.join(DROP_MARKER), bytes).is_ok() {
                    // Exact expired IDs are handled even if an unusually large
                    // staging pool exceeds the bounded retry scan below.
                    let _ = remove_owned_drop(&path);
                }
            }
        }
    }
    let root = parent.join(DROP_ROOT);
    let Ok(metadata) = fs::symlink_metadata(&root) else {
        return;
    };
    if !metadata.is_dir() || is_link(&metadata) {
        return;
    }
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    // Bounded, nonrecursive inspection of this app's dedicated temporary pool;
    // only happens after a successful publish/prune, never on an idle timer.
    for entry in entries.take(256).flatten() {
        let Some(folder) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if retained_folder(&folder) {
            continue;
        }
        if let Ok((path, owner)) = drop_owner(parent, &folder)
            && owner.retired
        {
            let _ = remove_owned_drop(&path);
        }
    }
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
        return format!("{}\n", &text[start..start + end + HEADER_END.len()])
            .replace("than the newest three,", "than the newest four,");
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

// Windows byte-range locks are not implemented by the WSL UNC file server.
// Atomic directory creation is shared by both access paths. Never steal a stale
// claim: a forced-kill claim must be removed only after confirming writers stopped.
struct BoardLock(PathBuf);

impl BoardLock {
    fn acquire(parent: &Path, timeout: Duration) -> io::Result<Self> {
        let path = parent.join(".whiteboard-write.lock");
        let deadline = Instant::now() + timeout;
        loop {
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    if Instant::now() >= deadline {
                        return Err(io::Error::other(format!(
                            "Whiteboard is busy. If a writer was forcibly stopped, confirm no publisher is running before removing {}",
                            path.display()
                        )));
                    }
                    std::thread::sleep(Duration::from_millis(25));
                }
                Err(error) => return Err(error),
            }
        }
    }
}

impl Drop for BoardLock {
    fn drop(&mut self) {
        // The claim is empty and exclusively ours. Never recursively delete it.
        let _ = fs::remove_dir(&self.0);
    }
}

fn write_board(path: &Path, post: Option<Post>, init: bool) -> io::Result<usize> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("Whiteboard needs a parent folder."))?;
    fs::create_dir_all(parent)?;
    let lock = BoardLock::acquire(parent, Duration::from_secs(5))?;
    let text = bounded_read(path)?;
    if init && path.exists() {
        return Ok(parse(&text).len());
    }
    let mut posts = parse(&text);
    if let Some(post) = post {
        posts.push(post);
    }
    let removed = if posts.len() > 4 {
        posts.drain(..posts.len() - 4).collect::<Vec<_>>()
    } else {
        Vec::new()
    };
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
    cleanup_drops(parent, &posts, &removed);
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
    let mut agent_prompt = String::new();
    let mut local_drop = false;
    let mut drop_folder = String::new();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--file" => path = Some(PathBuf::from(args.next().ok_or("Missing --file value")?)),
            "--title" => title = args.next().ok_or("Missing --title value")?,
            "--provider" => provider = args.next().ok_or("Missing --provider value")?,
            "--init" => init = true,
            "--prune" => prune = true,
            "--local-drop" => local_drop = true,
            "--drop-folder" => drop_folder = args.next().ok_or("Missing --drop-folder value")?,
            "--agent-prompt" => agent_prompt = args.next().ok_or("Missing --agent-prompt value")?,
            _ => return Err(format!("Unknown argument: {arg}").into()),
        }
    }
    let path = path.ok_or("Pass --file /path/to/Context/whiteboard.md")?;
    let path = if path.is_absolute() {
        path
    } else {
        std::env::current_dir()?.join(path)
    };
    if !drop_folder.is_empty() {
        if !local_drop {
            return Err("--drop-folder requires --local-drop".into());
        }
        drop_owner(path.parent().ok_or("Missing board folder")?, &drop_folder)?;
    }
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
                local_drop,
                agent_prompt,
                drop_folder,
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
                local_drop: false,
                agent_prompt: String::new(),
                drop_folder: String::new(),
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
        assert_eq!(write_board(&path, Some(post(9)), false)?, 4);
        let text = bounded_read(&path)?;
        let entries = parse(&text);
        assert_eq!(
            entries.iter().map(|p| &p.metadata.id).collect::<Vec<_>>(),
            ["6", "7", "8", "9"]
        );
        assert_eq!(entries[3].body, post(9).body);
        assert!(text.contains("Custom instructions"));
        assert!(!text.contains("TRASH") && !text.contains("unfinished garbage"));
        fs::remove_dir_all(root)?;
        Ok(())
    }
    #[test]
    fn drop_metadata_roundtrips_and_old_entries_remain_readable() {
        let mut entry = post(1);
        entry.metadata.local_drop = true;
        entry.metadata.agent_prompt = "Read `/drop/README.md`.".into();
        let json = serde_json::to_string(&entry.metadata).unwrap();
        let block = format!(
            "{START}{json} -->\n{}\n<!-- context:whiteboard:end 1 -->",
            entry.body
        );
        let entries = parse(&block);
        assert!(entries[0].metadata.local_drop);
        assert_eq!(entries[0].metadata.agent_prompt, "Read `/drop/README.md`.");
        let mut old = serde_json::to_value(&entry.metadata).unwrap();
        old.as_object_mut().unwrap().remove("local_drop");
        old.as_object_mut().unwrap().remove("agent_prompt");
        let restored: Metadata = serde_json::from_value(old).unwrap();
        assert!(!restored.local_drop && restored.agent_prompt.is_empty());
    }
    #[test]
    fn lock_contention_never_steals_or_deletes_another_claim() -> io::Result<()> {
        let root = std::env::temp_dir().join(format!("context-lock-{}", std::process::id()));
        fs::create_dir_all(&root)?;
        let claim = BoardLock::acquire(&root, Duration::ZERO)?;
        assert!(BoardLock::acquire(&root, Duration::from_millis(30)).is_err());
        assert!(root.join(".whiteboard-write.lock").is_dir());
        drop(claim);
        assert!(!root.join(".whiteboard-write.lock").exists());
        drop(BoardLock::acquire(&root, Duration::ZERO)?);
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
            assert!((1..=4).contains(&handle.join().unwrap()?));
        }
        let entries = parse(&bounded_read(&path)?);
        assert_eq!(entries.len(), 4);
        assert!(
            entries
                .iter()
                .all(|p| p.body == post(p.metadata.id.parse().unwrap()).body)
        );
        fs::remove_dir_all(root)?;
        Ok(())
    }

    fn owned_drop(parent: &Path, id: &str) -> io::Result<PathBuf> {
        let path = parent.join(DROP_ROOT).join(id);
        fs::create_dir_all(&path)?;
        fs::write(
            path.join(DROP_MARKER),
            serde_json::to_vec(&DropOwner {
                schema: DROP_SCHEMA.into(),
                folder: id.into(),
                retired: false,
            })?,
        )?;
        fs::write(path.join("README.md"), "Original: /keep/me.png")?;
        fs::write(path.join("clipboard.png"), [1, 2, 3])?;
        Ok(path)
    }

    #[test]
    fn fifth_entry_removes_only_expired_drop_not_original_or_staging() -> io::Result<()> {
        let root =
            std::env::temp_dir().join(format!("context-drop-retention-{}", std::process::id()));
        fs::create_dir_all(&root)?;
        let board = root.join("whiteboard.md");
        let original = root.join("original.png");
        fs::write(&original, b"original")?;
        let staging = owned_drop(&root, "staging")?;
        let mut folders = Vec::new();
        for id in 0..4 {
            let folder = format!("drop-{id}");
            folders.push(owned_drop(&root, &folder)?);
            let mut entry = post(id);
            entry.metadata.local_drop = true;
            entry.metadata.drop_folder = folder;
            write_board(&board, Some(entry), false)?;
        }
        assert!(folders.iter().all(|path| path.is_dir()));
        write_board(&board, Some(post(4)), false)?;
        assert!(!folders[0].exists());
        assert!(folders[1..].iter().all(|path| path.is_dir()));
        assert!(staging.join("clipboard.png").exists());
        assert_eq!(fs::read(original)?, b"original");
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn cleanup_is_committed_only_after_publish_and_retries_retired_folders() -> io::Result<()> {
        let root = std::env::temp_dir().join(format!("context-drop-retry-{}", std::process::id()));
        fs::create_dir_all(&root)?;
        let board = root.join("whiteboard.md");
        let folder = owned_drop(&root, "drop-0")?;
        let mut entry = post(0);
        entry.metadata.local_drop = true;
        entry.metadata.drop_folder = "drop-0".into();
        write_board(&board, Some(entry), false)?;
        for id in 1..4 {
            write_board(&board, Some(post(id)), false)?;
        }
        let before = fs::read(&board)?;
        let mut oversized = post(4);
        oversized.body = "x".repeat(MAX_BYTES as usize);
        assert!(write_board(&board, Some(oversized), false).is_err());
        assert_eq!(fs::read(&board)?, before);
        assert!(folder.join("clipboard.png").exists());
        // Unknown files are never deleted. Once the owner removes that file,
        // a later prune retries the retired folder even though its entry is gone.
        fs::write(folder.join("not-ours.txt"), "keep")?;
        write_board(&board, Some(post(4)), false)?;
        assert!(folder.join("README.md").exists());
        fs::remove_file(folder.join("not-ours.txt"))?;
        write_board(&board, None, false)?;
        assert!(!folder.exists());
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn cleanup_rejects_unowned_paths_and_retains_shared_drop_references() -> io::Result<()> {
        let root = std::env::temp_dir().join(format!("context-drop-safety-{}", std::process::id()));
        fs::create_dir_all(&root)?;
        let folder = owned_drop(&root, "drop-0")?;
        let mut entry = post(0);
        entry.metadata.local_drop = true;
        entry.metadata.drop_folder = "drop-0".into();
        cleanup_drops(&root, &[entry.clone()], &[entry.clone()]);
        assert!(folder.join("clipboard.png").exists());
        for name in ["../escape", "/tmp", "", "C:\\temp", "a/b"] {
            assert!(drop_owner(&root, name).is_err());
        }
        fs::remove_file(folder.join(DROP_MARKER))?;
        cleanup_drops(&root, &[], &[entry]);
        assert!(folder.join("clipboard.png").exists());
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn cleanup_never_follows_folder_or_file_links() -> io::Result<()> {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("context-drop-links-{}", std::process::id()));
        fs::create_dir_all(&root)?;
        let original = root.join("original.txt");
        fs::write(&original, "original")?;
        let folder = owned_drop(&root, "drop-0")?;
        fs::remove_file(folder.join("clipboard.png"))?;
        symlink(&original, folder.join("clipboard.png"))?;
        let mut entry = post(0);
        entry.metadata.local_drop = true;
        entry.metadata.drop_folder = "drop-0".into();
        cleanup_drops(&root, &[], &[entry]);
        assert_eq!(fs::read_to_string(&original)?, "original");
        assert!(folder.join("README.md").exists());
        symlink(&folder, root.join(DROP_ROOT).join("linked-drop"))?;
        assert!(drop_owner(&root, "linked-drop").is_err());
        fs::remove_dir_all(root)?;
        Ok(())
    }
}
