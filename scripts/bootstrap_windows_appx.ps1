param(
  # Where to install Flutter if it isn't found on PATH.
  # Default (if not set): shared deps under the shared appx folder (<APPX_ROOT>\\deps\\flutter).
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

function Resolve-AppxRoot {
  param([string]$ProjectRoot)

  $envRoot = $env:APPX_ROOT
  if ($envRoot) { $envRoot = $envRoot.Trim() } else { $envRoot = "" }
  if ($envRoot.Length -gt 0) {
    if (Test-Path (Join-Path $envRoot "scripts\\bootstrap_windows_appx.ps1")) {
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
      if (Test-Path (Join-Path $cand "scripts\\bootstrap_windows_appx.ps1")) {
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

Example:
  setx APPX_ROOT C:\\path\\to\\appx
"@
}

$shared = Join-Path $appxRoot "scripts\\bootstrap_windows_appx.ps1"

& $shared `
  -ProjectRoot $projectRoot `
  -AppName "Context" `
  -FlutterInstallDir $FlutterInstallDir `
  -FlutterVersion $FlutterVersion `
  -InstallBuildTools:$InstallBuildTools `
  -Build:$Build `
  -PortableOnly:$PortableOnly
