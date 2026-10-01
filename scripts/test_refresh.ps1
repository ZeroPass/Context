param(
  [string]$FlutterDir = (Join-Path $env:LOCALAPPDATA "AppxKit\deps\flutter"),
  [string]$EvidenceDir = ".buildlog\refresh-validation",
  [switch]$UiOnly
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$evidence = if ([IO.Path]::IsPathRooted($EvidenceDir)) { $EvidenceDir } else { Join-Path $root $EvidenceDir }
$work = Join-Path $env:TEMP ("context-refresh-check-" + [guid]::NewGuid().ToString("N"))
$dart = Join-Path $FlutterDir "bin\cache\dart-sdk\bin\dart.exe"
$flutter = Join-Path $FlutterDir "bin\flutter.bat"
if (-not (Test-Path -LiteralPath $dart)) { throw "Flutter SDK missing: $FlutterDir" }
if (-not (Test-Path -LiteralPath (Join-Path $root "lib\src\bindings\bindings.dart"))) {
  throw "Dart bindings missing. Run 'rinf gen' in the project folder first."
}
New-Item -ItemType Directory -Force -Path $evidence, $work | Out-Null
$reportPath = Join-Path $evidence "report.txt"
if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath -Force }
$inputs = @(
  "native\hub\src\actors\context.rs",
  "native\hub\src\actors\context_refresh_tests.rs",
  "native\hub\src\actors\codex_refresh.rs",
  "native\hub\src\signals\mod.rs", "native\hub\Cargo.toml",
  "lib\app\app_state.dart", "lib\app\models.dart", "lib\ui\home_screen.dart",
  "lib\main.dart", "test\app_state_refresh_test.dart", "scripts\test_refresh.ps1",
  "lib\ui\widgets\codex_account_card.dart", "test\codex_account_card_test.dart",
  "lib\ui\widgets\whiteboard_workspace.dart",
  "test\whiteboard_workspace_test.dart",
  "lib\ui\widgets\passive_tooltip.dart", "lib\ui\widgets\recent_sessions.dart",
  "lib\ui\widgets\whiteboard_pane.dart", "lib\app\whiteboard.dart",
  "lib\ui\widgets\file_preview.dart", "lib\ui\widgets\video_preview.dart",
  "test\file_preview_test.dart", "test\passive_tooltip_test.dart",
  "lib\ui\widgets\file_location_button.dart",
  "lib\app\file_references.dart", "test\whiteboard_test.dart",
  "native\hub\src\actors\whiteboard.rs",
  "Cargo.lock", "pubspec.yaml", "pubspec.lock", "analysis_options.yaml"
)
$inputHashes = @{}
$inputs += Get-ChildItem -LiteralPath (Join-Path $root "lib\src\bindings\signals") -File -Filter "*.dart" | ForEach-Object {
  "lib\src\bindings\signals\$($_.Name)"
}
foreach ($file in $inputs) {
  $inputHashes[$file] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)).Hash
}
$commands = [System.Collections.Generic.List[string]]::new()
$oldPubCache = $env:PUB_CACHE
$oldTarget = $env:CARGO_TARGET_DIR
$oldIncremental = $env:CARGO_INCREMENTAL
$oldUiEvidence = $env:CONTEXT_UI_EVIDENCE_DIR

function Run-Check([string]$Name, [string]$Exe, [string[]]$Arguments) {
  $commands.Add(("{0}: {1} {2}" -f $Name, $Exe, ($Arguments -join " ")))
  $log = Join-Path $evidence "$Name.log"
  # Native stderr is diagnostic output; the process exit code determines failure.
  $ErrorActionPreference = "Continue"
  & $Exe @Arguments 2>&1 | ForEach-Object { $_.ToString() } | Out-File -LiteralPath $log -Encoding utf8
  $code = $LASTEXITCODE
  Get-Content -LiteralPath $log -Tail 20
  if ($code -ne 0) { throw "$Name failed ($code). See $log" }
}

Push-Location $root
try {
  $env:CARGO_INCREMENTAL = "0"
  $env:CARGO_TARGET_DIR = Join-Path $env:TEMP "context-per-account-reset-tests"
  if (-not $UiOnly) {
    Run-Check "rust-format" "cargo" @("fmt", "--manifest-path", "native/hub/Cargo.toml", "--", "--check")
    Run-Check "rust-tests" "cargo" @("test", "--locked", "--manifest-path", "native/hub/Cargo.toml")
  }
  $formatFiles = if ($UiOnly) {
    @("lib/app/app_state.dart", "lib/ui/home_screen.dart", "lib/ui/widgets/whiteboard_workspace.dart", "test/whiteboard_workspace_test.dart", "lib/ui/widgets/passive_tooltip.dart", "lib/ui/widgets/recent_sessions.dart", "test/app_state_refresh_test.dart", "lib/ui/widgets/whiteboard_pane.dart", "lib/ui/widgets/file_preview.dart", "lib/ui/widgets/video_preview.dart", "lib/app/whiteboard.dart", "lib/app/file_references.dart", "lib/ui/widgets/file_location_button.dart", "test/whiteboard_test.dart", "test/file_preview_test.dart", "test/passive_tooltip_test.dart")
  } else {
    @("lib/main.dart", "lib/app/app_state.dart", "lib/ui/home_screen.dart", "lib/ui/widgets/codex_account_card.dart", "lib/ui/widgets/whiteboard_workspace.dart", "test/whiteboard_workspace_test.dart", "lib/ui/widgets/passive_tooltip.dart", "lib/ui/widgets/recent_sessions.dart", "test/app_state_refresh_test.dart", "test/codex_account_card_test.dart")
  }
  Run-Check "dart-format" $dart (@("format", "--output=none", "--set-exit-if-changed") + $formatFiles)

  # Flutter's batch launcher needs an NTFS working directory, not a WSL UNC path.
  foreach ($file in @("pubspec.yaml", "pubspec.lock", "analysis_options.yaml")) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $work
  }
  foreach ($dir in @("lib", "test", "assets\fonts", "assets\licenses")) {
    & robocopy (Join-Path $root $dir) (Join-Path $work $dir) /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Could not stage $dir for Flutter tests." }
  }
  $env:PUB_CACHE = Join-Path $env:LOCALAPPDATA "AppxKit\deps\pub-cache"
  $env:CONTEXT_UI_EVIDENCE_DIR = $evidence
  Push-Location $work
  try {
    Run-Check "flutter-pub" $flutter @("pub", "get", "--offline")
    Run-Check "flutter-analyze" $flutter @("analyze", "--no-pub")
    Run-Check "flutter-tests" $flutter @("test", "--no-pub", "--reporter=expanded", "test/app_state_refresh_test.dart", "test/codex_account_card_test.dart", "test/whiteboard_test.dart", "test/whiteboard_workspace_test.dart", "test/file_preview_test.dart", "test/passive_tooltip_test.dart", "test/ui_state_wire_order_test.dart")
  } finally { Pop-Location }

  $report = @("UTC: $([DateTime]::UtcNow.ToString('o'))", "Result: all checks completed", "Source: $root", "Flutter staging: $work", "CARGO_TARGET_DIR: $env:CARGO_TARGET_DIR", "CARGO_INCREMENTAL: $env:CARGO_INCREMENTAL", "PUB_CACHE: $env:PUB_CACHE", "", "Commands:") + $commands.ToArray()
  $report += @("", "SHA256:")
  foreach ($file in $inputs) {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)
    if ($hash.Hash -ne $inputHashes[$file]) { throw "Source changed during validation: $file" }
    $report += "$($hash.Hash)  $file"
  }
  foreach ($log in Get-ChildItem -LiteralPath $evidence -Filter "*.log" -File) {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $log.FullName
    $report += "$($hash.Hash)  $($log.FullName)"
  }
  foreach ($snapshot in Get-ChildItem -LiteralPath $evidence -File | Where-Object { $_.Name -match '^(accounts|whiteboard)-.*\.png$' }) {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $snapshot.FullName
    $report += "$($hash.Hash)  $($snapshot.FullName)"
  }
  $report | Set-Content -LiteralPath $reportPath -Encoding UTF8
  Write-Host "Evidence: $evidence\report.txt"
} finally {
  Pop-Location
  $env:PUB_CACHE = $oldPubCache
  $env:CARGO_TARGET_DIR = $oldTarget
  $env:CARGO_INCREMENTAL = $oldIncremental
  $env:CONTEXT_UI_EVIDENCE_DIR = $oldUiEvidence
  Remove-Item -LiteralPath $work -Recurse -Force
}
