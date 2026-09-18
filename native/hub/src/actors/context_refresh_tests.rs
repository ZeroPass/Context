use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Result, anyhow};
use async_trait::async_trait;
use messages::prelude::{Context, Handler};
use tokio::time::timeout;

use super::{
    CodexAccountMetadata, CodexAccountsRefreshed, CodexUsageError, CodexUsageQuery,
    CodexUsageRequestTiming, ContextActor, LoadedCodexAccounts, WeeklyUsage,
    clear_codex_manual_reset_at, list_codex_account_metadata_with, read_codex_account_labels,
    set_codex_account_label, set_codex_manual_reset_at, unix_epoch_millis,
};
use crate::signals::{ClearCodexManualReset, SetCodexManualReset};

struct Fixture {
    root: PathBuf,
    accounts: PathBuf,
    markdown: String,
}

impl Fixture {
    fn new() -> Result<Self> {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let root = std::env::temp_dir().join(format!(
            "context-refresh-test-{}-{stamp}",
            std::process::id()
        ));
        let accounts = root.join(".codex/context-accounts");
        let markdown = root.join("codex-out/codex sessions.md");
        fs::create_dir_all(&accounts)?;
        fs::create_dir_all(root.join("codex-out"))?;
        fs::write(&markdown, "")?;
        fs::write(
            accounts.join("1.json"),
            br#"{"tokens":{"account_id":"fake-account"}}"#,
        )?;
        Ok(Self {
            root,
            accounts,
            markdown: markdown.to_string_lossy().into_owned(),
        })
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn query(now: i64) -> CodexUsageQuery {
    CodexUsageQuery {
        usage: WeeklyUsage {
            used_percent: 31.0,
            reset_at_ms: Some(now + 604_800_000),
            reset_after_seconds: None,
            window_seconds: 604_800,
        },
        timing: CodexUsageRequestTiming {
            request_started_at_ms: now,
            response_received_at_ms: now,
        },
    }
}

#[test]
fn refresh_merges_a_reset_and_name_saved_during_network_work() -> Result<()> {
    let fixture = Fixture::new()?;
    let now = unix_epoch_millis()?;
    let manual = now + 86_400_000;
    let accounts = list_codex_account_metadata_with(
        &fixture.accounts,
        |_, snapshot, _, _| Ok(snapshot.to_vec()),
        |_: &[u8]| {
            // This runs inside the fetch, before its final metadata transaction.
            set_codex_manual_reset_at(&fixture.accounts, manual)
                .map_err(|_| CodexUsageError::Unavailable)?;
            set_codex_account_label(&fixture.accounts, "1", "renamed during refresh")
                .map_err(|_| CodexUsageError::Unavailable)?;
            Ok(query(now))
        },
    )?;
    assert_eq!(accounts[0].manual_reset_at, Some(manual));
    assert_eq!(accounts[0].name, "renamed during refresh");
    assert_eq!(accounts[0].weekly_reset_at, Some(now + 604_800_000));
    let labels = read_codex_account_labels(&fixture.accounts)?;
    assert_eq!(labels.manual_reset_at, Some(manual));
    assert_eq!(labels.weekly_usage_state["1"].used_percent, 31.0);
    Ok(())
}

#[test]
fn refresh_does_not_restore_a_removed_reset() -> Result<()> {
    let fixture = Fixture::new()?;
    let now = unix_epoch_millis()?;
    set_codex_manual_reset_at(&fixture.accounts, now + 86_400_000)?;
    let accounts = list_codex_account_metadata_with(
        &fixture.accounts,
        |_, snapshot, _, _| Ok(snapshot.to_vec()),
        |_: &[u8]| {
            clear_codex_manual_reset_at(&fixture.accounts)
                .map_err(|_| CodexUsageError::Unavailable)?;
            Ok(query(now))
        },
    )?;
    assert_eq!(accounts[0].manual_reset_at, None);
    let labels = read_codex_account_labels(&fixture.accounts)?;
    assert_eq!(labels.manual_reset_at, None);
    assert_eq!(labels.weekly_usage_state["1"].used_percent, 31.0);
    Ok(())
}

#[test]
fn usage_reads_overlap_with_a_bound_after_serial_credential_preparation() -> Result<()> {
    let fixture = Fixture::new()?;
    let slots = ["1", "2", "3", "10", "11", "12"];
    for slot in slots {
        fs::write(
            fixture.accounts.join(format!("{slot}.json")),
            serde_json::to_vec(&serde_json::json!({
                "tokens": { "account_id": format!("fake-account-{slot}") }
            }))?,
        )?;
    }
    let now = unix_epoch_millis()?;
    let prepared_count = AtomicUsize::new(0);
    let active = AtomicUsize::new(0);
    let peak = AtomicUsize::new(0);
    let (started, started_rx) = mpsc::channel();
    let mut prepared_slots = Vec::new();
    let accounts = std::thread::scope(|scope| -> Result<_> {
        let refresh = scope.spawn(|| {
            list_codex_account_metadata_with(
                &fixture.accounts,
                |slot, _, _, _| {
                    prepared_slots.push(slot.to_owned());
                    prepared_count.fetch_add(1, Ordering::SeqCst);
                    if slot == "12" {
                        Err(CodexUsageError::CredentialRejected)
                    } else {
                        Ok(slot.as_bytes().to_vec())
                    }
                },
                |auth| {
                    assert_eq!(prepared_count.load(Ordering::SeqCst), slots.len());
                    let slot = String::from_utf8(auth.to_vec())
                        .map_err(|_| CodexUsageError::Unavailable)?;
                    let concurrent = active.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(concurrent, Ordering::SeqCst);
                    let (release, blocked) = mpsc::channel();
                    let result = (|| {
                        started
                            .send((slot.clone(), release))
                            .map_err(|_| CodexUsageError::Unavailable)?;
                        blocked
                            .recv_timeout(Duration::from_secs(10))
                            .map_err(|_| CodexUsageError::Unavailable)?;
                        if slot == "10" {
                            return Err(CodexUsageError::Unavailable);
                        }
                        let mut value = query(now);
                        value.usage.used_percent =
                            slot.parse().map_err(|_| CodexUsageError::Unavailable)?;
                        Ok(value)
                    })();
                    active.fetch_sub(1, Ordering::SeqCst);
                    result
                },
            )
        });
        // No request is released until all three workers are simultaneously
        // waiting. Sequential fetching fails this check without timing a benchmark.
        let mut first_wave = Vec::new();
        for _ in 0..3 {
            first_wave.push(started_rx.recv_timeout(Duration::from_secs(3))?);
        }
        let mut requested_slots = first_wave
            .iter()
            .map(|(slot, _)| slot.clone())
            .collect::<Vec<_>>();
        for (_, release) in first_wave {
            release.send(())?;
        }
        for _ in 0..2 {
            let (slot, release) = started_rx.recv_timeout(Duration::from_secs(3))?;
            requested_slots.push(slot);
            release.send(())?;
        }
        let accounts = refresh
            .join()
            .map_err(|_| anyhow!("refresh test worker panicked"))??;
        requested_slots.sort_by(|a, b| super::compare_codex_account_slots(a, b));
        assert_eq!(requested_slots, ["1", "2", "3", "10", "11"]);
        Ok(accounts)
    })?;
    assert_eq!(prepared_slots, slots);
    assert_eq!(peak.load(Ordering::SeqCst), 3);
    assert_eq!(active.load(Ordering::SeqCst), 0);
    assert_eq!(
        accounts
            .iter()
            .map(|account| account.slot.as_str())
            .collect::<Vec<_>>(),
        slots
    );
    for account in accounts {
        if account.slot == "10" || account.slot == "12" {
            assert!(account.weekly_used_percent.is_none());
            assert!(account.weekly_error.is_some());
        } else {
            assert_eq!(
                account.weekly_used_percent,
                Some(account.slot.parse::<f64>()?)
            );
            assert_eq!(account.weekly_reset_at, Some(now + 604_800_000));
            assert!(account.weekly_error.is_none());
        }
    }
    Ok(())
}

#[test]
fn empty_and_unreadable_accounts_do_not_issue_usage_requests() -> Result<()> {
    let fixture = Fixture::new()?;
    fs::write(fixture.accounts.join("1.json"), b"not valid JSON")?;
    let accounts = list_codex_account_metadata_with(
        &fixture.accounts,
        |_, _, _, _| panic!("invalid snapshot must not be prepared"),
        |_| panic!("invalid snapshot must not be fetched"),
    )?;
    assert_eq!(accounts.len(), 1);
    assert!(accounts[0].weekly_error.is_some());
    fs::remove_file(fixture.accounts.join("1.json"))?;
    let accounts = list_codex_account_metadata_with(
        &fixture.accounts,
        |_, _, _, _| panic!("empty accounts must not be prepared"),
        |_| panic!("empty accounts must not be fetched"),
    )?;
    assert!(accounts.is_empty());
    Ok(())
}

fn loaded(manual: Option<i64>, api_reset: i64) -> LoadedCodexAccounts {
    LoadedCodexAccounts {
        accounts: vec![CodexAccountMetadata {
            slot: "1".to_owned(),
            name: "test".to_owned(),
            updated_at: None,
            weekly_used_percent: Some(31.0),
            weekly_reset_at: Some(api_reset),
            manual_reset_at: manual,
            weekly_window_seconds: Some(604_800),
            weekly_error: None,
        }],
        active_slot: Some("1".to_owned()),
        active_slot_error: None,
    }
}

struct Inspect;

#[async_trait]
impl Handler<Inspect> for ContextActor {
    type Result = (bool, Option<i64>, Vec<CodexAccountMetadata>);

    async fn handle(&mut self, _: Inspect, _: &Context<Self>) -> Self::Result {
        (
            self.codex_account_busy,
            self.codex_manual_reset_at,
            self.codex_accounts.clone(),
        )
    }
}

#[tokio::test]
async fn actor_handles_manual_reset_messages_while_refresh_is_blocked() -> Result<()> {
    let fixture = Fixture::new()?;
    let now = unix_epoch_millis()?;
    let first_reset = now + 86_400_000;
    let latest_reset = now + 172_800_000;
    let context = Context::new();
    let mut addr = context.address();
    let mut actor = ContextActor::new(addr.clone());
    actor.initialized = true;
    actor.set_sessions_markdown_path(fixture.markdown.clone());
    actor.codex_accounts = loaded(None, now + 604_800_000).accounts;
    let (release, blocked) = mpsc::channel();
    actor.load_codex_accounts_with(None, 0, move |_, _| {
        blocked.recv_timeout(Duration::from_secs(5))?;
        Ok(loaded(None, now + 604_800_000))
    })?;
    // Duplicate refreshes coalesce, without starting a second network operation.
    actor.load_codex_accounts_with(None, 0, |_, _| panic!("duplicate fetch"))?;
    let runner = tokio::spawn(context.run(actor));
    let result = timeout(Duration::from_secs(3), async {
        addr.notify(SetCodexManualReset {
            request_id: 0,
            sessions_markdown_path: fixture.markdown.clone(),
            manual_reset_at: first_reset,
        })
        .await?;
        let (busy, manual, accounts) = addr.send(Inspect).await?;
        assert!(busy);
        assert_eq!(manual, Some(first_reset));
        assert_eq!(accounts[0].manual_reset_at, Some(first_reset));
        assert_eq!(
            read_codex_account_labels(&fixture.accounts)?.manual_reset_at,
            Some(first_reset)
        );

        addr.notify(ClearCodexManualReset {
            request_id: 0,
            sessions_markdown_path: fixture.markdown.clone(),
        })
        .await?;
        let (busy, manual, accounts) = addr.send(Inspect).await?;
        assert!(busy);
        assert_eq!(manual, None);
        assert_eq!(accounts[0].manual_reset_at, None);

        addr.notify(SetCodexManualReset {
            request_id: 0,
            sessions_markdown_path: fixture.markdown.clone(),
            manual_reset_at: latest_reset,
        })
        .await?;
        assert_eq!(addr.send(Inspect).await?.1, Some(latest_reset));
        Ok::<_, anyhow::Error>(())
    })
    .await;
    let _ = release.send(());
    addr.stop().await;
    runner.await?;
    result??;
    Ok(())
}

#[tokio::test]
async fn stale_refresh_completion_keeps_newest_manual_reset_in_ui() -> Result<()> {
    let fixture = Fixture::new()?;
    let now = unix_epoch_millis()?;
    let context = Context::new();
    let mut actor = ContextActor::new(context.address());
    actor.set_sessions_markdown_path(fixture.markdown.clone());
    actor.codex_accounts = loaded(None, now + 604_800_000).accounts;
    for manual in [Some(now + 86_400_000), None] {
        let old_revision = actor.codex_manual_reset_revision;
        actor.codex_account_busy = true;
        actor.codex_account_refreshing = true;
        actor
            .update_codex_manual_reset(fixture.markdown.clone(), manual)
            .await?;
        actor.complete_codex_refresh(CodexAccountsRefreshed {
            generation: actor.path_generation,
            manual_reset_revision: old_revision,
            result: Ok(loaded(Some(now + 1000), now + 604_800_000)),
        });
        assert_eq!(actor.codex_accounts[0].manual_reset_at, manual);
        assert_eq!(actor.codex_accounts[0].weekly_used_percent, Some(31.0));
        assert_eq!(
            actor.codex_accounts[0].weekly_reset_at,
            Some(now + 604_800_000)
        );
        assert!(!actor.codex_account_busy);
    }
    Ok(())
}

#[tokio::test]
async fn failed_reset_does_not_change_persisted_or_visible_value() -> Result<()> {
    let fixture = Fixture::new()?;
    let future = unix_epoch_millis()? + 86_400_000;
    let context = Context::new();
    let mut actor = ContextActor::new(context.address());
    actor.set_sessions_markdown_path(fixture.markdown.clone());
    actor.codex_accounts = loaded(None, future).accounts;
    actor
        .update_codex_manual_reset(fixture.markdown.clone(), Some(future))
        .await?;
    assert!(
        actor
            .update_codex_manual_reset(fixture.markdown.clone(), Some(0))
            .await
            .is_err()
    );
    assert_eq!(actor.codex_accounts[0].manual_reset_at, Some(future));
    assert_eq!(
        read_codex_account_labels(&fixture.accounts)?.manual_reset_at,
        Some(future)
    );
    // A failed API response also leaves the saved reset intact.
    actor.complete_codex_refresh(CodexAccountsRefreshed {
        generation: actor.path_generation,
        manual_reset_revision: actor.codex_manual_reset_revision,
        result: Err(anyhow!("simulated network failure")),
    });
    assert_eq!(actor.codex_accounts[0].manual_reset_at, Some(future));
    Ok(())
}
