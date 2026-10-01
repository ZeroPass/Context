# Context (Rust + Flutter)

Context session manager for Codex, Kimi Code, OpenCode, and Qwen Code. Offers account switching and pacing on Codex as well.

## Screenshot

![Context app screenshot](./Context%20app%20screenshoot.png)

- Flutter (UI)
- Rust (backend) via [Rinf](https://pub.dev/packages/rinf)
- Codex recent sessions from `~/.codex/state_5.sqlite`
- Kimi recent sessions from `~/.kimi-code/session_index.jsonl`

## Whiteboard

Enable Whiteboard in the header to view it alongside Context; its on/off state
is remembered across restarts. Drag the subtle
divider to resize either pane. By default Whiteboard gets two-thirds of the
available width, while
Context keeps at least 400 px in the split layout. Below 678 px the panes become
full-width screens: swipe horizontally or use the compact Context/Whiteboard
navigation buttons. Pane state and scroll positions survive layout changes;
a manually adjusted divider stays adjusted when Whiteboard is reopened.

Whiteboard has one scroll area for previews, answers, and recent sessions;
sections use their content height instead of fixed viewport fractions. Embedded
previews grow with their content, up to a square matching the pane's width.
Long Markdown documents scroll inside that cap; app-wide expansion is unchanged.
Its Codex tab shows the three most recent
top-level sessions, with an on-demand expansion to ten. Selecting a row shows
the latest completed answer directly above the recent list, not a resume command.
The latest session opens automatically when Whiteboard is enabled; selecting
another row replaces the response. Expand **Last 3** beside the
copy button to load
the previous two completed answers. Other Whiteboard provider tabs remain hidden
until their response readers are implemented; the Context provider tabs are unchanged.

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
Linux paths are translated to the WSL share indicated by the markdown location;
line-number suffixes are removed. Relative paths are checked against the session
working directory, then the folders in **Settings > Whiteboard file locations**.
The default fallback is the folder containing the sessions markdown. Only exact
candidate paths are checked, never recursive searches; ambiguous matches offer
a chooser and missing files offer a link to add locations.

While visible, the Whiteboard refreshes every 30 seconds. Reads are independent
of account refreshes, use read-only SQLite access, and cache unchanged response
logs. Log reads are bounded to the most recent 32 MiB; history outside that window
is explicitly identified as unavailable. Responses are not saved into the
sessions markdown or uploaded. Generated signal bindings must be regenerated
after updating to this source version (`rinf gen`).

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
