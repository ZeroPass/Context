param(
  # Working copy location on a real NTFS path (avoid WSL/UNC/reparse-point folders).
  # Default (if not set): %TEMP%\\context-win
  [string]$WorkDir = "",

  # Where to install Flutter if it isn't found on PATH.
  # Default (if not set): the external local AppxKit deps cache.
  [string]$FlutterInstallDir = "",

  # If empty, downloads the current stable Flutter from Google's release manifest.
  # Example: "3.38.6"
  [string]$FlutterVersion = "",

  # Installs Visual Studio Build Tools (Desktop C++) if missing.
  [bool]$InstallBuildTools = $true,

  # Convenience switch to disable toolchain install checks.
  [switch]$SkipInstallBuildTools,

  # Builds the APPX at the end.
  [bool]$Build = $true,

  # If set, builds a portable folder (no APPX packaging).
  [switch]$PortableOnly,

  # If set, deletes WorkDir before copying.
  [switch]$CleanWorkDir,

  # If set, keeps the WorkDir around after a successful build (useful for debugging).
  [switch]$KeepWorkDir
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$shared = Join-Path (Join-Path $projectRoot "appx") "scripts\\windows_build_appx_local.ps1"
if (-not (Test-Path -LiteralPath $shared -PathType Leaf)) {
  throw "Repository-local APPX kit is missing. Expected: $shared"
}

& $shared `
  -AppName "Context" `
  -SourceRoot $projectRoot `
  -WorkDir $WorkDir `
  -FlutterInstallDir $FlutterInstallDir `
  -FlutterVersion $FlutterVersion `
  -InstallBuildTools:$InstallBuildTools `
  -SkipInstallBuildTools:$SkipInstallBuildTools `
  -Build:$Build `
  -PortableOnly:$PortableOnly `
  -CleanWorkDir:$CleanWorkDir `
  -KeepWorkDir:$KeepWorkDir `
  -ExtraExcludeDirs @(
    "backend\\.venv",
    "backend\\build",
    "backend\\dist",
    "flash image",
    "_legacy_pyappx",
    ".cargo",
    "target",
    "native\\target"
  )
