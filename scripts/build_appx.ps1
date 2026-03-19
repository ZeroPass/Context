param(
  [string]$FlutterPath = "",
  [string]$DartPath = "",
  [bool]$InstallSigningCertificate = $true,
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
    if (Test-Path (Join-Path $envRoot "scripts\\build_appx.ps1")) {
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
      if (Test-Path (Join-Path $cand "scripts\\build_appx.ps1")) {
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

To get it:
  git clone git@github.com:ZeroPass/appx-kit.git appx
"@
}

$shared = Join-Path $appxRoot "scripts\\build_appx.ps1"

& $shared `
  -ProjectRoot $projectRoot `
  -AppName "Context" `
  -FlutterPath $FlutterPath `
  -DartPath $DartPath `
  -InstallSigningCertificate:$InstallSigningCertificate `
  -PortableOnly:$PortableOnly
