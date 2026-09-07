# Context (Rust + Flutter)

Context session manager for Codex, Kimi Code, OpenCode, and Qwen Code. Offers account switching and pacing on Codex as well.

## Screenshot

![Context app screenshot](./Context%20app%20screenshoot.png)

- Flutter (UI)
- Rust (backend) via [Rinf](https://pub.dev/packages/rinf)
- Codex recent sessions from `~/.codex/state_5.sqlite`
- Kimi recent sessions from `~/.kimi-code/session_index.jsonl`

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
Flutter checks use a temporary NTFS directory so the command also works from a
WSL path. Logs, exact commands, and SHA256 evidence are written under
`.buildlog/refresh-validation/`. Use `-FlutterDir` if your Flutter SDK is elsewhere.
