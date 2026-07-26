# Context (Rust + Flutter)

Desktop UI for organizing local Codex and Kimi sessions in a markdown file. Context copies provider-correct resume commands, supports Codex fork and Fast commands, and lists the three most recent sessions from each provider.

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

## Shared APPX tooling

This project expects a shared `appx/` folder **next to** the project folder (so multiple apps can share Flutter + pub cache):

```text
<workspace>\
  appx\
  Context\
```

You can also set `APPX_ROOT` to point at your shared `appx` folder.

To get the shared `appx/` folder, clone it as a sibling folder named `appx`:

```bash
git clone git@github.com:ZeroPass/appx-kit.git appx
```

If `appx/` is not a sibling folder, set `APPX_ROOT` (PowerShell example):

```powershell
$env:APPX_ROOT = "D:\\path\\to\\appx"
```

## Regenerate Dart bindings (Rinf)

Signals sent between Dart and Rust are implemented using signal attributes. If you modify Rust signal structs, regenerate bindings:

```bash
rinf gen
```
