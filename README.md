# Context

**Manage your contexts**

A Windows desktop app for organizing coding-agent sessions, managing Codex
accounts, and sharing outputs and files through a local Whiteboard.

Supports **Codex, Claude Code, Kimi Code, OpenCode, Qwen Code, Muse, and ZCode**.
Session data comes from the agents' local stores. Terminal integration uses WSL.

![Context with grouped sessions, Codex account usage, and a Whiteboard preview](./Context%20app%20screenshoot.png)

## Sessions

Saved sessions have a name, provider, and session ID. They can be filtered,
reordered by dragging, and arranged in color groups. The list is stored in
Markdown, with autosave enabled by default.

- Click a session to copy its resume command, or enable opening it in Windows Terminal.
- Right-click for either action without changing the default.
- Add entries manually or save them from a provider's recent-session list.
- Fork controls are available for Codex and Claude Code. ZCode is copy-only.

UUIDs make lousy bookmarks.

## Terminal Tabs

Running coding agents are grouped by Windows Terminal window, using saved
session names where available. Groups are remembered locally and can be renamed.

Closing an individual tab updates the active group. Closing the whole window
preserves its last observed sessions. Restoring a group opens only missing
sessions, leaving already-open tabs alone.

Tabs open in WSL using the session's working directory. Context can request
administrator approval once for a small Terminal helper, while the UI stays at
normal rights so Explorer drag/drop works. The helper exits with Context; no
service is installed. Startup approval is configurable.

## Codex Accounts

Save the current Codex sign-in under a name, then switch between saved accounts
from their cards. Each card shows usage, reset time, and pace relative to the
time remaining before reset.

Each account uses its own API-reported reset. An optional manual reset override
can be edited or removed and expires automatically. Usage refreshes every 30 seconds.

The one-shot downgrade control applies a selected model and thinking level
after a quota reset or a delay in hours. Fast mode is turned off when it runs.
Account switching and pacing are Codex-specific.

## Whiteboard

Whiteboard is two-way: agents publish outputs, and you prepare input tabs with
files and notes for agents. The newest six entries appear in a tab strip.
Agents publish through a helper into `whiteboard.md`; Context
reads that file rather than pulling the full chat history.

- Images, videos, and Markdown files open in the built-in viewer.
- Attachments have previous/next navigation, image zoom, and app-wide expansion.
- Right-click previews to copy or save; videos also support copying a snapshot.
- File-location controls reveal files, with an option to open their default app.
- Relative paths are checked against the publication's working directory and configured locations.

Use **+** before the tabs to start an input. Dropping files appends to the active
input tab, or creates one when an output is selected. Each file has a note field,
a compact preview where supported, a folder control, and an optional copy-into-Context
button. Drops keep original paths by default; pasted files and images are stored
locally. Only Context-owned copies are removed when their input tab expires.

**Copy first prompt** gives an agent the active Whiteboard path and points it
to the publishing instructions in the file header. In a configured workspace,
`wb.md` refers to that file.

The Whiteboard pane can be shown or hidden beside the session list. Its divider
position is remembered. Light, dark, sepia, and dusk themes are available.

## Setup

Install and sign in to the provider CLIs separately in WSL. In Context's
Settings, select a sessions Markdown file or create an example. Add sessions
manually or from the recent-session list.

Enable **Open sessions in Terminal** for direct launching. Enable **Whiteboard**
in the header and use **Copy first prompt** to introduce it to an agent.

## Local Data

| File | Contents |
| --- | --- |
| `codex sessions.md` | Saved sessions and groups. |
| `whiteboard.md` | Published entries and agent instructions. |
| `whiteboard-drops/` | Temporary pasted attachments and handoff notes. |

These files and saved credentials are private local data, not repository assets.
Keep credential snapshots out of Git. Whiteboard does not upload attachments;
account features contact provider APIs.

See the [full guide](docs/GUIDE.md) for storage, cleanup, provider differences,
and the limits of Terminal discovery.

## Build

From PowerShell in the project folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_windows_appx.ps1
```

Or run **`Build_APPX.bat`**. The output is `Context.appx` in the project root.
The bootstrap can provision build dependencies and create a local signing
certificate. Self-signed packages require that certificate to be trusted on
each installation machine.

[Windows build guide](BUILD_WINDOWS_APPX_POWERSHELL.md): prerequisites,
portable output, WSL/UNC builds, and certificate troubleshooting.

Built with **Flutter, Rust, and [Rinf](https://pub.dev/packages/rinf)**.
Developer commands and regression checks are in the [full guide](docs/GUIDE.md).

## License

Dual-licensed under [LGPL v3](LICENSE.LGPL) and a
[commercial license](LICENSE.COMMERCIAL). Third-party components retain their own licenses.
