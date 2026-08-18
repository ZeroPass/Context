param(
  # Path to the signed APPX (defaults to .\Context.appx in the project root)
  [string]$AppxPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$shared = Join-Path (Join-Path $projectRoot "appx") "scripts\\trust_appx_cert.ps1"
if (-not (Test-Path -LiteralPath $shared -PathType Leaf)) {
  throw "Repository-local APPX kit is missing. Expected: $shared"
}

if ([string]::IsNullOrWhiteSpace($AppxPath)) {
  & $shared -ProjectRoot $projectRoot -AppName "Context"
} else {
  & $shared -AppxPath $AppxPath
}
