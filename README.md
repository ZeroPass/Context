# Context (Rust + Flutter)

Context session manager for Codex, Claude Code, Kimi Code, OpenCode, Qwen Code, Muse, and ZCode. Offers account switching and pacing on Codex as well.

## Screenshot

![Context app screenshot](./Context%20app%20screenshoot.png)

- Flutter (UI)
- Rust (backend) via [Rinf](https://pub.dev/packages/rinf)
- Codex recent sessions from `~/.codex/state_5.sqlite`
- Kimi recent sessions from `~/.kimi-code/session_index.jsonl`

## Adding and Recent Sessions

**Add Entry** has a single-line coding-agent picker, with the name first and
session ID or command second. Adding from a recent card's **+** prefills its
agent, name, and ID; only that agent is shown, with **Change** available.

Recent sessions load for the selected Context provider, not all providers in
sequence. Other tabs keep their loaded cards and refresh when selected. Context
keeps provider-specific caches.
Automatic session checks run only while the window is focused and foregrounded,
pause when inactive, and check again on return. Checks run every two seconds,
but unchanged cards are not rebuilt and the loading indicator is reserved for
initial or manual loads. Failed refreshes retain the existing cards and back off
automatic retries for 30 seconds; manual refresh can retry immediately.

The Rust cache validates exact database/WAL, index, directory, and candidate-file
metadata rather than reparsing unchanged stores. It keeps at most eight provider
results and watches at most 256 exact paths per result, including at most 64
directories. A 30-second rediscovery covers changes outside that bounded set.
No background filesystem watcher or persistent CLI process is needed. Kimi index
reads reuse unchanged records and consume appended records, keeping incomplete
trailing records pending; truncated or replaced indices are reread. Qwen and Kimi
parse the newest candidates rather than every historical session. Account usage
refresh behavior is unchanged. The main local file is `Context/codex sessions.md`;
saved legacy default paths migrate when the relocated file exists. Provider homes
and credentials remain under the original user home. Create example uses the
selected folder/default Context folder, never the Windows launch directory.

## Copying

Clipboard actions verify that the copied text is actually on the clipboard
before showing a success message. Windows uses a native, checked Unicode-text
writer. Brief clipboard contention is retried at most three times; a persistent
failure shows an error rather than a false "copied" message. Rapid clicks are
serialized, with the latest queued request winning, and old copy messages are
replaced instead of building up in a queue. This applies to resume/fork commands
and Whiteboard response copying. To run the native clipboard checks without
changing your own clipboard, use
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test_clipboard.ps1`.

## Terminal Tabs

The **Terminal tabs** card above **Sessions** groups coding agents by Ubuntu
Terminal window. Compact items use saved Context names or the provider and last
four ID characters. Hover shows only the provider and full ID.

Window groups are remembered automatically in local app preferences. Closing
individual tabs updates the active group; closing the whole window preserves
its last observed tab set. A new window starts a new group, without replacing a
saved one. Double-click a group name to rename it. X closes a live window after
confirmation, using Terminal's normal close path; X on a closed group deletes
only that saved group.

Play restores missing sessions and skips those already open or starting. If
none are open, the restored group uses its own named Terminal window; otherwise
missing tabs append to the latest window. Clicking a single saved item also
opens only that item in the latest Terminal window. Failed launches stay in
the remembered group for retry. Existing tabs are never
moved by simulated keystrokes; the card follows the observed tab order when
titles can be matched uniquely. Unknown session IDs cannot be restored safely.

Discovery runs after Markdown loading, on app focus, every 30 seconds while
active, and on refresh. Group actions perform a fresh check plus two bounded
follow-ups. A short removal debounce preserves a window's snapshot while it
closes. Changes made entirely between snapshots cannot be reconstructed.

The native worker reads a bounded WSL process snapshot with Python 3 and uses
Windows UI Automation for tab labels and selection. Codex, Claude Code, Kimi,
OpenCode, Qwen Code, Muse and ZCode entrypoints are recognized. Session IDs come
from explicit launch arguments: new sessions and sessions changed inside a TUI
can remain unknown or retain their launch identity. Tab selection is shown only
for unique title matches. Access to elevated Terminal windows may require
Context to be elevated too; process discovery can still work without tab labels.

**Claude Code** is available in the Accounts provider tabs, including hide/show.
Its last three main sessions are read from local Claude project JSONL files,
with bounded header/tail reads and no subagent-directory traversal. It supports
saving entries, copying/resuming with `claude --resume <id>`, and forking with
`claude --resume <id> --fork-session`. Claude credentials, account switching and
usage are not read or managed. Install Claude separately in WSL and sign in there.

### Opening Sessions

Settings has an opt-in **Open sessions in Terminal** switch. On Windows, clicking
a saved or recent session then resumes it in a new tab of the most recently
used Windows Terminal window (`wt.exe -w 0`); if no eligible window exists,
Terminal creates one. The switch sets the normal-click default. Right-click any
saved or recent session for **Copy resume command** and **Open in Terminal**,
with whichever is not the default listed first. Choosing a menu action does not
change the default. Double-click-to-rename and the separate fork/delete controls
keep their existing behavior. ZCode remains copy-only because it has no
supported terminal resume command.

To reuse an administrator Terminal without a UAC prompt for every tab, Context
offers a one-time administrator restart when enabling this experimental mode.
It saves pending session-list edits before restarting; cancellation leaves the
current app open. No service, scheduled task, or background helper is installed.
Windows keeps administrator and ordinary Terminal windows separate, so this
mode targets administrator windows. If Context is started normally again,
it will ask before restarting as administrator. Turning the switch off restores
click-to-copy.

The sideloaded APPX declares `allowElevation` for this explicit administrator
restart. Context still starts normally; this capability does not install a
helper or remove Windows' approval prompt.

WSL session directories are passed to `wsl.exe` as Linux paths, with the
distribution taken from the session/config UNC path. Recently discovered
working directories take priority; saved sessions without one fall back to
the configured workspace. This mode always opens WSL, not PowerShell or CMD.
Windows drive paths are translated to their Linux mount (for example,
`C:\work` becomes `/mnt/c/work`). Without a distribution in the config path,
WSL uses its configured default distribution.
Commands and paths are passed as separate, escaped arguments rather than
interpolating a raw resume command into a shell.
Context explicitly selects the matching Ubuntu/WSL Terminal profile so its
icon, font, colors and other appearance settings are retained. It reads Terminal
settings only when launching a tab and never edits them. If no matching Linux
profile is available, it reports an error rather than using a CMD-looking tab.

## Whiteboard

Enable Whiteboard in the header to view it alongside Context; its on/off state
and divider position are remembered. Enabling it expands the window from 100%
to 300% of the Context-only width by default, leaving its height unchanged.
Hiding it restores the Context-only width. A divider-selected ratio controls
future expansion: for example, a 50/50 split opens at twice the Context-only
width. Growth stops at the monitor's work-area width and the displayed split
adjusts to fit; this temporary limit does not overwrite your preferred ratio.
Maximized/minimized windows are left alone. Resize completion is event-driven,
not background polling.

Drag the subtle divider to resize either pane. By default Context keeps
one-third of the expanded space and Whiteboard gets the other two-thirds.
Context keeps at least 400 px in the split layout. Below 678 px the panes become
full-width screens: swipe horizontally or use the compact Context/Whiteboard
navigation buttons. Pane state and scroll positions survive layout changes;
a manually adjusted divider stays adjusted when Whiteboard is reopened.

Whiteboard is a push feed in `whiteboard.md` beside the session file. `wb.md` is
an alias for that file and a request to publish, not another filename. Permanent
HTML comments at its beginning instruct agents. The local workspace `AGENTS.md`
points to it: `wb.md` alone means publish the preceding completed answer. Only
the requested final Markdown goes there, not thinking or tool traces.

The **Copy first prompt** icon beside **Published entries** copies a short first-contact prompt
with the full active Whiteboard path. WSL locations include both Linux and
Windows paths; the detailed publishing rules stay in the file's header.
Paste it to an agent the first time to introduce your Whiteboard.

Use the helper rather than editing message blocks by hand:

```bash
Context/scripts/publish-whiteboard --title "Report" --provider codex <<'OUTPUT'
# Final output
Publish the actual requested report here.
OUTPUT
```

Inside Context, use `scripts/publish-whiteboard`. It builds the small Rust helper
when needed (Rust 1.89+) and defaults to this project's `whiteboard.md`. Windows
agents can pipe output into `scripts/publish-whiteboard.ps1 -Title Report -Provider
codex`. The APPX also bundles `context-whiteboard.exe` for direct use with `--file`.
The helper records the time/working directory, serializes writers with an atomic
lock-directory claim (shared by Windows and WSL), and publishes the newest four entries. It removes **all**
surplus older entries and unframed debris, not merely the fifth entry. Surviving
output and the instruction header are preserved. `--init` creates the header if
missing; `--prune` cleans without adding output. Input/files are capped at 8 MiB;
oversized input fails without replacing the board. Live files and locks/temp
files are excluded from Git and Windows build staging.
Use the updated helper for all writers; the app bundles the same implementation.
If a publisher is forcibly killed, `.whiteboard-write.lock` may remain. The helper
fails closed rather than stealing it. Remove that empty directory only after
confirming no publisher is running. Normal completion and errors release it.

Whiteboard has one scroll area for previews, outputs, and published entries;
sections use their content height instead of fixed viewport fractions. Embedded
previews grow with their content, up to a square matching the pane's width.
Long Markdown documents scroll inside that cap; app-wide expansion is unchanged.
It shows at most four compact published entries and automatically opens the newest.
Selecting an older entry pins it while publications arrive; a pruned entry cannot
remain selected. The right pane has no provider tabs, session-log pulls, expansion
to ten, or per-session Last 3 control. Context's provider tabs and recents on the
left are unchanged.

Drag files, folders, or text onto the Whiteboard pane, or focus it and press
**Ctrl+V** to paste copied files, text, or an image. A pane-only **Drop here**
overlay marks the target. Each submission becomes a silent **Drop** entry;
clicking it opens the output and copies a minimal `Read <README path>` prompt
for your agent. A small copy icon also copies that prompt without changing views.
Existing files are referenced in place (no video copies or folder scans), so
keep them at that location. Clipboard images/text and a short README are stored
in private temporary `whiteboard-drops/` beside the active `whiteboard.md`. WSL agents get
Linux paths, including `/mnt/<drive>` for Windows files. After a successful
publication, the helper deletes Context-owned temporary folders for entries
older than the newest four. This also applies when an agent publishes while
Context is closed. Original referenced files are never deleted; staged/unpublished
drops, unmarked folders, and links are left alone. Locked temporary files are
retried on a later publish/prune, without an extra background timer. Prompts for
entries that have left the four slots expire with their temporary README.
These local drops never trigger a Windows notification. Typing fields keep
normal paste behavior. Windows may block Explorer drag/drop into an elevated
Context window; Ctrl+V is the alternative, without weakening UAC protections.

On Windows, new complete publications show a native **Whiteboard published**
notification with the entry title/provider. Alerts are on by default and can be
disabled in **Settings > Whiteboard notifications**. Context must be running,
but it can be minimized or have Whiteboard hidden. Startup entries, edits,
pruning and duplicate filesystem events do not repeat alerts. Only the newest
toast is retained, and answer bodies are not included.

The pane and notifications share one file watcher and bounded read cache.
Local paths use filesystem events; WSL/network shares retain a 250 ms fallback
that checks only this file's metadata, reading/parsing content only on change.
While idle there are no directory scans, session-log/API queries, helper processes or
additional notification polling timer.

Answers retain Markdown structure without thinking traces or tool output.
Named file links keep their real filename and extension visible; hover tips
distinguish Context previews and browser links. Only websites and files Context
can preview have clickable link styling. Other file references remain ordinary
text and never launch an external application on a normal click.
File references have a folder button to reveal their location. Right-click it
to open the file in its default app; the same menu is available in all previews.
Markdown files, raster images, and videos open in a full-width viewer
above the response, without replacing it. Markdown follows the same styling as
answers and resolves links relative to the opened document. Images support
zoom/pan after clicking inside the viewer; a subtle outline indicates selection.
Until selected, the wheel scrolls Whiteboard instead of zooming. Click outside
or press Escape in the embedded viewer to release selection. The live zoom
percentage resets to 100% when clicked. Previous/next buttons and a counter on
the toolbar browse existing image, video, and Markdown attachments in document
order, counting duplicate links/thumbnails only once. Left/right arrow keys work
throughout the active Whiteboard pane, not only the viewer. Before opening any
attachment, Right opens the first and Left opens the last. Navigation does not
activate image zoom, and text fields/dialogs retain their normal keyboard input.
Arrow keys also work in the expanded viewer. No next file is loaded until
navigated to. Double-click viewer content to **Expand to app**, keeping the
navigation and zoom/file controls at the top.
Every resolved local image uses a compact thumbnail, including image embeds,
ordinary links, bare paths, and paths in inline or fenced code. Labels and folder
controls remain available; missing or ambiguous paths retain their existing
location controls. Video has playback,
seeking, mute, and volume controls. **Expand to app**
covers the application's content area, not the monitor; the exit button or Escape
restores both panes. Video remains the same player when expanded and is released
when the preview is closed. To open any local file in its default application,
use the folder icon's right-click menu. Website links open in the browser.
Right-click an image, Markdown document, or video preview for **Copy** and
**Save as**. Images copy the full-resolution bitmap, Markdown copies its text,
and videos copy the file for pasting into Explorer or compatible apps.
Video's **Copy snapshot** copies the current frame. Images and video references
inside Markdown have their own menus; a snapshot opens a referenced video in
Context if necessary and captures its first frame. Save as preserves the original
file bytes. These menus also work when a preview is expanded to the full app.
Linux paths are translated to the WSL share indicated by the markdown location.
Standard Windows drive mounts such as `/mnt/c/...` use `C:\...` directly instead
of the inaccessible WSL-share mount path.
When a WSL path is unreadable because a Linux symlink crosses onto a Windows
drive, Context requests the real target from that distro and checks it directly.
These on-demand lookups are batched, cached and time-limited, without opening a
terminal or scanning directories.
Line-number suffixes are removed. Relative paths are checked against the publisher's
working directory, then the folders in **Settings > Whiteboard file locations**.
The default fallback stays `codex-out` when the session file is in its Context
subfolder; custom locations use the selected folder. Only exact
candidate paths are checked, never recursive searches; ambiguous matches offer
a chooser and missing files offer a link to add locations.

While visible and focused, Whiteboard watches its containing directory for file
replacement, with a 20 ms event debounce. WSL UNC shares also check one file's
metadata every 250 ms because Linux-side notifications may be absent; unchanged
files are not reread/reparsed. Checks never overlap. Watching/checking stops while
hidden or unfocused and refreshes on return. Event bursts coalesce without losing
the final update during an active read. No session database or answer-log scan is
used by the Whiteboard pane. Existing previews and the subtle arrival fade remain.
Nothing is uploaded.

Video uses [media_kit](https://github.com/media-kit/media-kit); the Windows APPX
bundles its native player dependencies, so a separate player installation is not
required. Third-party notices and LGPL texts are included under `assets/licenses/`.
Markdown previews are limited to 8 MiB and use asynchronous reads.

## Run (Linux dev)

```bash
flutter run -d linux
```

## Build `Context.appx` (Windows)

From a Windows machine (PowerShell), in this project folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_windows_appx.ps1
```

Or double-click:

- `Build_APPX.bat`

Docs:

- `BUILD_WINDOWS_APPX_POWERSHELL.md`

## APPX tooling

The APPX kit is included under `appx/scripts/`, so this clone is self-contained
for packaging scripts. The wrappers in `scripts/` invoke only this local kit;
no additional APPX kit checkout or environment override is needed.

The kit does not vendor Flutter, Rust, Visual Studio, certificates, generated
APPX files, or caches. By default, the scripts keep Flutter and Rust-related
dependencies in the external local `%LOCALAPPDATA%\\AppxKit\\deps` cache.
`APPX_DEPS_ROOT` and `APPX_DEPS_ROOT_LOCAL` can override the dependency roots;
see [the Windows APPX build guide](BUILD_WINDOWS_APPX_POWERSHELL.md) for the
cache and prerequisite details.

## Regenerate Dart bindings (Rinf)

Signals sent between Dart and Rust are implemented using signal attributes. If you modify Rust signal structs, regenerate bindings:

```bash
rinf gen
```

## Refresh and save behavior

Codex accounts and recent sessions refresh in the background. Setting, editing,
or removing a manual reset saves local metadata without waiting for the usage
API. Refresh responses preserve newer reset edits. Without a manual override,
each account uses its own API-reported reset.
The manual-reset picker uses the latest genuine seven-day reset still within
the coming week. Monthly allowances keep their real usage/reset but never move
that picker into the following month. If no usable weekly reset is available,
the picker starts seven days from now; its day/hour offsets remain unchanged.

Account usage reads run concurrently (up to three at a time), after serial
credential preparation and snapshot writes. The refresh interval remains 30
seconds. UI updates rebuild only the affected sections; unchanged account and
recent-session payloads are reused, and themes rebuild only when changed.

Account cards highlight on hover and keyboard focus. Pressing an inactive card
shows a subtle edge pulse while switching, followed by a short confirmation on
success. These effects preserve the usage chart and respect reduced-motion settings.

Session autosave waits 500 ms after an edit. Background refreshes do not replace
unsaved edits, and edits made during a save remain pending for the next save.
Saving the sessions markdown does not trigger an extra account refresh.

## Regression checks (Windows)

With the build prerequisites installed and Dart bindings generated (`rinf gen`):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_refresh.ps1
```

This runs Rust tests, Dart formatting checks, Flutter analysis, and refresh/save
UI tests using temporary fixtures, without live credentials or API requests.
Coverage includes bounded usage-read concurrency, isolated request failures,
and section rebuild isolation.
Flutter checks use a temporary NTFS directory so the command also works from a
WSL path. Logs, exact commands, and SHA256 evidence are written under
`.buildlog/refresh-validation/`. Use `-FlutterDir` if your Flutter SDK is elsewhere,
or `-EvidenceDir` to keep a separate validation report.
