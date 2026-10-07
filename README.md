# Context (Rust + Flutter)

Context session manager for Codex, Kimi Code, OpenCode, and Qwen Code. Offers account switching and pacing on Codex as well.

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

## Whiteboard

Enable Whiteboard in the header to view it alongside Context; its on/off state
is remembered across restarts. Drag the subtle
divider to resize either pane. By default Whiteboard gets two-thirds of the
available width, while
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
The helper records the time/working directory, serializes writers with a file
lock, and atomically publishes the newest three entries. It removes **all**
surplus older entries and unframed debris, not merely the fourth entry. Surviving
output and the instruction header are preserved. `--init` creates the header if
missing; `--prune` cleans without adding output. Input/files are capped at 8 MiB;
oversized input fails without replacing the board. Live files and locks/temp
files are excluded from Git and Windows build staging.

Whiteboard has one scroll area for previews, outputs, and published entries;
sections use their content height instead of fixed viewport fractions. Embedded
previews grow with their content, up to a square matching the pane's width.
Long Markdown documents scroll inside that cap; app-wide expansion is unchanged.
It shows at most three published entries and automatically opens the newest.
Selecting an older entry pins it while publications arrive; a pruned entry cannot
remain selected. The right pane has no provider tabs, session-log pulls, expansion
to ten, or per-session Last 3 control. Context's provider tabs and recents on the
left are unchanged.

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
zoom/pan, with a live zoom percentage in the toolbar that resets to 100% when
clicked. Inline response images use compact thumbnails. Video has playback,
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
Linux paths are translated to the WSL share indicated by the markdown location;
line-number suffixes are removed. Relative paths are checked against the publisher's
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
