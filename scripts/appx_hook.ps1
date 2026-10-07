param(
  [Parameter(Mandatory = $true)]
  [string]$Stage = "",

  [string]$ProjectRoot = "",
  [string]$AppName = "",
  [string]$FlutterPath = "",
  [string]$DartPath = "",
  [string]$BuildDir = "",
  [string]$PortableDir = "",
  [string]$AppxPath = "",
  [switch]$PortableOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

switch ($Stage) {
  "after_windows_build" {
    $target = Join-Path $env:LOCALAPPDATA "AppxKit\deps\context-whiteboard-target"
    $savedPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      & cargo build --locked --release --manifest-path (Join-Path $ProjectRoot "native\whiteboard_writer\Cargo.toml") --target-dir $target
      $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($code -ne 0) { throw "Whiteboard publisher build failed ($code)." }
    Copy-Item -LiteralPath (Join-Path $target "release\context-whiteboard.exe") -Destination $BuildDir -Force
  }
  default {
    # no-op
  }
}
