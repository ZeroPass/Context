param(
  [string]$FlutterPath = "",
  [string]$DartPath = "",
  [bool]$InstallSigningCertificate = $true,
  [switch]$PortableOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$shared = Join-Path (Join-Path $projectRoot "appx") "scripts\\build_appx.ps1"
if (-not (Test-Path -LiteralPath $shared -PathType Leaf)) {
  throw "Repository-local APPX kit is missing. Expected: $shared"
}

& $shared `
  -ProjectRoot $projectRoot `
  -AppName "Context" `
  -FlutterPath $FlutterPath `
  -DartPath $DartPath `
  -InstallSigningCertificate:$InstallSigningCertificate `
  -PortableOnly:$PortableOnly
