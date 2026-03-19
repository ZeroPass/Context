param(
  # Working copy location on a real NTFS path (avoid WSL/UNC/reparse-point folders).
  # Default (if not set): %TEMP%\\context-win
  [string]$WorkDir = "",

  # Where to install Flutter if it isn't found on PATH.
  # Default (if not set): shared deps under the shared appx folder (<APPX_ROOT>\\deps\\flutter).
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
function Resolve-AppxRoot {
  param([string]$ProjectRoot)

  $envRoot = $env:APPX_ROOT
  if ($envRoot) { $envRoot = $envRoot.Trim() } else { $envRoot = "" }
  if ($envRoot.Length -gt 0) {
    if (Test-Path (Join-Path $envRoot "scripts\\windows_build_appx_local.ps1")) {
      return $envRoot
    }
  }

  $dir = $ProjectRoot
  for ($i = 0; $i -lt 6; $i++) {
    foreach ($cand in @(
      (Join-Path $dir "appx"),
      (Join-Path (Split-Path -Parent $dir) "appx")
    )) {
      if ([string]::IsNullOrWhiteSpace($cand)) { continue }
      if (Test-Path (Join-Path $cand "scripts\\windows_build_appx_local.ps1")) {
        return $cand
      }
    }

    $parent = Split-Path -Parent $dir
    if ([string]::IsNullOrWhiteSpace($parent) -or ($parent -eq $dir)) { break }
    $dir = $parent
  }

  return $null
}

$appxRoot = Resolve-AppxRoot -ProjectRoot $projectRoot
if (-not $appxRoot) {
  throw @"
Shared APPX folder not found.

Expected either:
- A sibling folder: ..\\appx  (next to this repo folder), OR
- APPX_ROOT environment variable pointing to the shared appx folder.
"@
}

$shared = Join-Path $appxRoot "scripts\\windows_build_appx_local.ps1"

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
