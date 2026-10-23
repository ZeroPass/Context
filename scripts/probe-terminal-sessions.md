# Read-only Terminal session prototype

Run from the Context project in Ubuntu/WSL:

    python3 scripts/probe-terminal-sessions.py

For structured results:

    python3 scripts/probe-terminal-sessions.py --json

The companion PowerShell script reads Windows Terminal's tab labels and selected
state through Windows UI Automation. Python inventories this Linux user's
terminal-attached coding-agent processes, reads explicit resume arguments, and
looks up Codex names in a bounded tail of session_index.jsonl. Unique title/directory
matches associate the two inventories. Duplicate names remain ambiguous.

This is separate from Context: no APPX rebuild or installation is needed.
The result is a single snapshot, not a resident watcher. Nothing switches tabs,
sends keys, changes files in Codex, or reads credentials or terminal transcripts.
Only WT_SESSION, WSL_DISTRO_NAME and CODEX_HOME environment fields are retained.
It does not scan session rollouts or query the usage API/database.

## Limits

- Codex, Claude Code, Kimi, OpenCode, Qwen Code, Muse and ZCode entrypoints in
  the WSL distribution running the script are recognized. Unknown launch IDs
  stay unknown. The standalone script resolves names for Codex; Context's
  native bridge can additionally use cached recent-provider metadata.
- Session IDs describe the explicit launch/resume command, not an in-TUI session
  change or fork after startup. Fresh sessions and resume pickers remain unknown.
- Matching is name-based, not an authoritative Windows tab-to-Linux-process API.
  Manually renamed tabs or missing session-name metadata may not match.
- Selected means selected in that Terminal window, not necessarily the foreground
  Windows application. Split panes are not mapped independently.
- A Terminal tab switch or process exit between reads can race the snapshot.
- UI Automation may require matching elevation when Terminal runs as admin.
- The probe caps UI nodes/depth, process count and metadata bytes; it times out
  PowerShell after 15 seconds. It installs no helper/service and starts no timer.

Regression checks:

    python3 -B test/terminal_probe_test.py -v

Keep captured JSON reports local: they contain private session names and IDs.
