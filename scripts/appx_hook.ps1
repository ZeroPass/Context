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
  "after_windows_build" { }
  default {
    # no-op
  }
}
