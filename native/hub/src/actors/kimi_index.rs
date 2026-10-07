use super::*;
use std::collections::{HashMap, HashSet};
use std::io::{Read, Seek, SeekFrom};

const MAX_INDEX_BYTES: u64 = 16 * 1024 * 1024;
type IndexRows = (HashMap<String, KimiIndexEntry>, HashSet<String>);

struct IndexCache {
    path: PathBuf,
    created: Option<SystemTime>,
    modified: Option<SystemTime>,
    size: u64,
    offset: u64,
    prefix: Vec<u8>,
    boundary: Vec<u8>,
    rows: IndexRows,
}
static CACHE: Mutex<Option<IndexCache>> = Mutex::new(None);

pub(super) fn read(home: &Path) -> Result<IndexRows> {
    let path = home.join("session_index.jsonl");
    recent_cache::track(&path);
    let metadata = match fs::metadata(&path) {
        Ok(m) => m,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Default::default()),
        Err(error) => return Err(error.into()),
    };
    if metadata.len() > MAX_INDEX_BYTES {
        return Err(anyhow!("Kimi index exceeds the 16 MiB safety limit."));
    }
    let mut cache = CACHE
        .lock()
        .map_err(|_| anyhow!("Kimi index cache unavailable."))?;
    if let Some(c) = cache.as_ref() {
        if c.path == path
            && c.size == metadata.len()
            && c.created == metadata.created().ok()
            && c.modified == metadata.modified().ok()
        {
            return Ok(c.rows.clone());
        }
    }
    let mut file = fs::File::open(&path)?;
    let append = if let Some(c) = cache.as_ref() {
        if c.path == path && c.created == metadata.created().ok() && metadata.len() > c.size {
            let mut prefix = vec![0; c.prefix.len()];
            file.read_exact(&mut prefix)?;
            file.seek(SeekFrom::Start(
                c.offset.saturating_sub(c.boundary.len() as u64),
            ))?;
            let mut boundary = vec![0; c.boundary.len()];
            file.read_exact(&mut boundary)?;
            prefix == c.prefix && boundary == c.boundary
        } else {
            false
        }
    } else {
        false
    };
    let (start, mut rows) = if append {
        let c = cache
            .as_ref()
            .ok_or_else(|| anyhow!("Kimi index cache changed."))?;
        (c.offset, c.rows.clone())
    } else {
        (0, IndexRows::default())
    };
    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_INDEX_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_INDEX_BYTES {
        return Err(anyhow!("Kimi index grew beyond the safety limit."));
    }
    let complete = bytes
        .iter()
        .rposition(|b| *b == b'\n')
        .map(|i| i + 1)
        .unwrap_or(0);
    // A valid last record without a newline may already be visible; do not
    // advance the append cursor past it until its terminating newline arrives.
    for line in bytes.split(|b| *b == b'\n') {
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(line) else {
            continue;
        };
        let Some(id) = value
            .get("sessionId")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|id| !id.is_empty())
        else {
            continue;
        };
        if value.get("deleted").and_then(serde_json::Value::as_bool) == Some(true) {
            rows.0.remove(id);
            rows.1.insert(id.into());
            continue;
        }
        let Some(raw) = value
            .get("sessionDir")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|dir| !dir.is_empty())
        else {
            continue;
        };
        rows.1.remove(id);
        rows.0.insert(
            id.into(),
            KimiIndexEntry {
                id: id.into(),
                session_dir: resolve_kimi_session_dir(home, raw),
                work_dir: value
                    .get("workDir")
                    .and_then(serde_json::Value::as_str)
                    .map(str::trim)
                    .filter(|cwd| !cwd.is_empty())
                    .map(ToOwned::to_owned),
            },
        );
    }
    let offset = start + complete as u64;
    file.seek(SeekFrom::Start(0))?;
    let mut prefix = vec![0; offset.min(4096) as usize];
    file.read_exact(&mut prefix)?;
    let mut boundary = vec![0; offset.min(64) as usize];
    file.seek(SeekFrom::Start(offset - boundary.len() as u64))?;
    file.read_exact(&mut boundary)?;
    *cache = Some(IndexCache {
        path,
        created: metadata.created().ok(),
        modified: metadata.modified().ok(),
        size: metadata.len(),
        offset,
        prefix,
        boundary,
        rows: rows.clone(),
    });
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn appends_partial_records_deletes_and_replacement() -> Result<()> {
        let root = std::env::temp_dir().join(format!("context-kimi-index-{}", std::process::id()));
        fs::create_dir_all(&root)?;
        let path = root.join("session_index.jsonl");
        fs::write(
            &path,
            "{\"sessionId\":\"a\",\"sessionDir\":\"/sessions/a\"}\n",
        )?;
        assert!(read(&root)?.0.contains_key("a"));
        let mut file = OpenOptions::new().append(true).open(&path)?;
        write!(file, "{{\"sessionId\":\"b\",\"sessionDir\":\"/sessions/b\"")?;
        file.flush()?;
        assert!(!read(&root)?.0.contains_key("b"));
        writeln!(file, "}}")?;
        writeln!(file, "{{\"sessionId\":\"a\",\"deleted\":true}}")?;
        file.flush()?;
        let (entries, deleted) = read(&root)?;
        assert!(entries.contains_key("b"));
        assert!(deleted.contains("a"));
        drop(file);
        fs::write(
            &path,
            "{\"sessionId\":\"c\",\"sessionDir\":\"/sessions/c\"}\n",
        )?;
        let (entries, _) = read(&root)?;
        assert_eq!(entries.len(), 1);
        assert!(entries.contains_key("c"));
        fs::remove_dir_all(root)?;
        Ok(())
    }
}
