param(
  # Where to install Flutter if it isn't found on PATH.
  # Default (if not set): the external local AppxKit deps cache.
  [string]$FlutterInstallDir = "",

  # If empty, downloads the current stable Flutter from Google's release manifest.
  # Example: "3.38.6"
  [string]$FlutterVersion = "",

  # Installs Visual Studio Build Tools (Desktop C++) if missing.
  [bool]$InstallBuildTools = $true,

  # Builds the APPX at the end.
  [bool]$Build = $true,

  # If set, builds a portable folder (no APPX packaging).
  [switch]$PortableOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$shared = Join-Path (Join-Path $projectRoot "appx") "scripts\\bootstrap_windows_appx.ps1"
if (-not (Test-Path -LiteralPath $shared -PathType Leaf)) {
  throw "Repository-local APPX kit is missing. Expected: $shared"
}

& $shared `
  -ProjectRoot $projectRoot `
  -AppName "Context" `
  -FlutterInstallDir $FlutterInstallDir `
  -FlutterVersion $FlutterVersion `
  -InstallBuildTools:$InstallBuildTools `
  -Build:$Build `
  -PortableOnly:$PortableOnly
