use super::*;
use std::cell::RefCell;
use std::collections::VecDeque;
use std::time::Instant;

const MAX_WATCHED_PATHS: usize = 256;
const REDISCOVERY_INTERVAL: Duration = Duration::from_secs(30);
thread_local! {
    static TRACKED: RefCell<Option<Vec<Stamp>>> = const { RefCell::new(None) };
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Stamp {
    path: PathBuf,
    state: Option<(u64, Option<SystemTime>, Option<SystemTime>)>,
    directory: bool,
}

impl Stamp {
    fn read(path: PathBuf) -> Self {
        let metadata = fs::metadata(&path).ok();
        let directory = metadata.as_ref().is_some_and(|m| m.is_dir());
        let state = metadata.map(|m| (m.len(), m.modified().ok(), m.created().ok()));
        Self {
            path,
            state,
            directory,
        }
    }
}

struct CachedRecent {
    markdown: String,
    provider: String,
    stamps: Vec<Stamp>,
    items: Vec<RecentContext>,
    scanned: Instant,
}

static CACHE: Mutex<VecDeque<CachedRecent>> = Mutex::new(VecDeque::new());

// Observe exact sources used by the loader, not a recursive filesystem watch.
pub(super) fn track(path: &Path) {
    TRACKED.with(|tracked| {
        if let Some(paths) = tracked.borrow_mut().as_mut() {
            if paths.len() < MAX_WATCHED_PATHS && !paths.iter().any(|p| p.path == path) {
                // Reserve most of the budget for session files, not directories.
                let stamp = Stamp::read(path.into());
                if stamp.directory && paths.iter().filter(|p| p.directory).count() >= 64 {
                    return;
                }
                paths.push(stamp);
            }
        }
    });
}

pub(super) fn track_database(path: &Path) {
    track(path);
    track(&PathBuf::from(format!("{}-wal", path.display())));
    if let Some(parent) = path.parent() {
        track(parent);
    }
}

pub(super) fn load(markdown: &str, provider: &str, limit: usize) -> Result<serde_json::Value> {
    let mut cache = CACHE
        .lock()
        .map_err(|_| anyhow!("Session cache unavailable."))?;
    if let Some(index) = cache
        .iter()
        .position(|c| c.markdown == markdown && c.provider == provider)
    {
        let valid = {
            let entry = &cache[index];
            entry.scanned.elapsed() < REDISCOVERY_INTERVAL
                && entry
                    .stamps
                    .iter()
                    .all(|s| Stamp::read(s.path.clone()) == *s)
        };
        if valid {
            let entry = cache
                .remove(index)
                .ok_or_else(|| anyhow!("Session cache changed."))?;
            let result =
                serde_json::json!({"sessions": entry.items.iter().take(limit).collect::<Vec<_>>()});
            cache.push_back(entry);
            return Ok(result);
        }
        cache.remove(index);
    }
    TRACKED.with(|paths| *paths.borrow_mut() = Some(Vec::new()));
    let result = match provider {
        PROVIDER_CODEX => whiteboard::load_recent_codex(markdown),
        PROVIDER_KIMI => load_recent_kimi_contexts(markdown),
        PROVIDER_OPENCODE => load_recent_opencode_contexts(markdown),
        PROVIDER_QWEN => load_recent_qwen_contexts(markdown),
        PROVIDER_MUSE => load_recent_muse_contexts(markdown),
        PROVIDER_ZCODE => load_recent_zcode_contexts(markdown),
        _ => Err(anyhow!("Unknown session provider.")),
    };
    let paths = TRACKED.with(|paths| paths.borrow_mut().take().unwrap_or_default());
    let items = result?;
    let payload = serde_json::json!({"sessions": items.iter().take(limit).collect::<Vec<_>>()});
    // Never associate data with a newer source stamp observed after its read.
    // Sources changing during the read force another load on the next check.
    let stable = paths.iter().all(|s| Stamp::read(s.path.clone()) == *s);
    cache.push_back(CachedRecent {
        markdown: markdown.into(),
        provider: provider.into(),
        stamps: paths,
        items,
        scanned: if stable {
            Instant::now()
        } else {
            Instant::now() - REDISCOVERY_INTERVAL
        },
    });
    while cache.len() > 8 {
        cache.pop_front();
    }
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamps_notice_append_creation_deletion_and_replacement() -> Result<()> {
        let root = std::env::temp_dir().join(format!("context-stamp-{}", std::process::id()));
        fs::create_dir_all(&root)?;
        let file = root.join("state.json");
        let missing = Stamp::read(file.clone());
        fs::write(&file, "a")?;
        let created = Stamp::read(file.clone());
        assert_ne!(missing, created);
        fs::write(&file, "ab")?;
        assert_ne!(created, Stamp::read(file.clone()));
        fs::remove_file(&file)?;
        assert_eq!(missing, Stamp::read(file));
        fs::remove_dir(root)?;
        Ok(())
    }

    #[test]
    fn provider_cache_reuses_unchanged_sources_and_invalidates_wal() -> Result<()> {
        let root =
            std::env::temp_dir().join(format!("context-recent-cache-{}", std::process::id()));
        let store = root.join(".local/share/opencode");
        fs::create_dir_all(&store)?;
        let db = store.join("opencode.db");
        let connection = Connection::open(&db)?;
        connection.execute_batch("PRAGMA journal_mode=WAL;
            CREATE TABLE session(id TEXT, title TEXT, parent_id TEXT, time_updated INTEGER, directory TEXT, time_archived INTEGER);
            INSERT INTO session VALUES('a', 'A', NULL, 100, '/work', NULL);")?;
        let markdown = root
            .join("codex-out/codex sessions.md")
            .to_string_lossy()
            .into_owned();
        let first = load(&markdown, PROVIDER_OPENCODE, 3)?;
        let scanned = CACHE
            .lock()
            .unwrap()
            .iter()
            .find(|entry| entry.markdown == markdown)
            .unwrap()
            .scanned;
        assert_eq!(first, load(&markdown, PROVIDER_OPENCODE, 3)?);
        assert_eq!(
            scanned,
            CACHE
                .lock()
                .unwrap()
                .iter()
                .find(|entry| entry.markdown == markdown)
                .unwrap()
                .scanned
        );
        connection.execute("UPDATE session SET title = 'Changed' WHERE id = 'a'", [])?;
        let updated = load(&markdown, PROVIDER_OPENCODE, 3)?;
        assert_eq!(updated["sessions"][0]["title"], "Changed");
        connection.execute(
            "INSERT INTO session VALUES('child', 'Child', 'a', 200, '/work', NULL)",
            [],
        )?;
        assert_eq!(
            load(&markdown, PROVIDER_OPENCODE, 3)?["sessions"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        drop(connection);
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    #[ignore = "requires CONTEXT_WHITEBOARD_MARKDOWN; same-session ABBA metadata-cache diagnostic"]
    fn compare_recent_cache() -> Result<()> {
        let markdown = std::env::var("CONTEXT_WHITEBOARD_MARKDOWN")?;
        let expected = load(&markdown, PROVIDER_CODEX, 3)?;
        for mode in ["read", "cache", "cache", "read"] {
            let started = Instant::now();
            let payload = if mode == "read" {
                serde_json::json!({"sessions": whiteboard::load_recent_codex(&markdown)?.into_iter().take(3).collect::<Vec<_>>()})
            } else {
                load(&markdown, PROVIDER_CODEX, 3)?
            };
            println!(
                "{}",
                serde_json::json!({"mode":mode,"elapsed_us":started.elapsed().as_micros(),"count":payload["sessions"].as_array().map(Vec::len)})
            );
            assert_eq!(
                payload, expected,
                "Recent session data changed during comparison."
            );
        }
        Ok(())
    }
}
