param(
  # App display name (also used to derive output names: <AppName>.appx, <AppName>-portable).
  [Parameter(Mandatory = $true)]
  [string]$AppName = "",

  # Root folder of the source project (the folder containing pubspec.yaml).
  [Parameter(Mandatory = $true)]
  [string]$SourceRoot = "",

  # Shared dependency root (Flutter SDK + PUB_CACHE) so multiple apps can reuse the same downloads.
  # Default (if not set): <codex-out>\\appx\\deps
  [string]$DepsRoot = "",

  # Working copy location on a real NTFS path (avoid WSL/UNC/reparse-point folders).
  # Default (if not set): %TEMP%\\<app>-win
  [string]$WorkDir = "",

  # Where to install Flutter if it isn't found on PATH.
  # Default (if not set): <DepsRoot>\\flutter
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
  [switch]$KeepWorkDir,

  # Extra paths to exclude when copying to WorkDir. Relative paths are resolved under SourceRoot.
  [string[]]$ExtraExcludeDirs = @()
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
  param([string]$Text)
  Write-Host ""
  Write-Host "==> $Text" -ForegroundColor Cyan
}

function Normalize-Path {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  $p = $Path.Trim()
  try { return [IO.Path]::GetFullPath($p) } catch { return $p }
}

function Is-UncPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $p = $Path.Trim()
  return ($p.StartsWith("\\\\") -or $p.StartsWith("//"))
}

function Get-LocalDepsRoot {
  $r = $env:APPX_DEPS_ROOT_LOCAL
  if ($r) { $r = $r.Trim() } else { $r = "" }
  if ($r.Length -gt 0) { return $r }

  $base = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
  if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TMP }
  if ([string]::IsNullOrWhiteSpace($base)) { $base = "C:\\Temp" }
  return (Join-Path $base "AppxKit\\deps")
}

$AppName = $AppName.Trim()
$SourceRoot = $SourceRoot.Trim()
if ([string]::IsNullOrWhiteSpace($AppName)) { throw "AppName is required." }
if ([string]::IsNullOrWhiteSpace($SourceRoot)) { throw "SourceRoot is required." }
if (-not (Test-Path $SourceRoot)) { throw "SourceRoot not found: $SourceRoot" }

$src = $SourceRoot
$WorkDir = $WorkDir.Trim()
if ([string]::IsNullOrWhiteSpace($WorkDir)) {
  $base = $env:TEMP
  if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TMP }
  if ([string]::IsNullOrWhiteSpace($base)) { $base = "C:\\Temp" }
  $safe = $AppName.ToLowerInvariant()
  $WorkDir = Join-Path $base ($safe + "-win")
}

$DepsRoot = $DepsRoot.Trim()
$depsRootSource = "param"
if ([string]::IsNullOrWhiteSpace($DepsRoot)) {
  $depsRootSource = ""
  $envDeps = $env:APPX_DEPS_ROOT
  if ($envDeps) { $envDeps = $envDeps.Trim() } else { $envDeps = "" }
  if ($envDeps.Length -gt 0) {
    $DepsRoot = $envDeps
    $depsRootSource = "env"
  } else {
    # Default to a local NTFS deps cache (Flutter/Dart break on \\wsl.localhost UNC paths).
    $DepsRoot = Get-LocalDepsRoot
    $depsRootSource = "local_default"
  }
}

if (Is-UncPath $DepsRoot) {
  Write-Host "WARNING: DepsRoot is a UNC path ($DepsRoot)." -ForegroundColor Yellow
  Write-Host "Flutter/Dart may fail on UNC paths. Recommended local cache:" -ForegroundColor Yellow
  Write-Host ("  " + (Get-LocalDepsRoot)) -ForegroundColor Yellow
}
try { New-Item -ItemType Directory -Force -Path $DepsRoot | Out-Null } catch { }

$FlutterInstallDir = $FlutterInstallDir.Trim()
if ([string]::IsNullOrWhiteSpace($FlutterInstallDir)) {
  $FlutterInstallDir = Join-Path $DepsRoot "flutter"
}

$dst = $WorkDir

Write-Step "$AppName local Windows APPX build"
Write-Host "Source: $src"
Write-Host "Work:   $dst"

$srcFull = Normalize-Path $src
$dstFull = Normalize-Path $dst
if ($srcFull -and $dstFull -and ($srcFull -ieq $dstFull)) {
  throw @"
WorkDir is the same as the source folder:
  $dst

This script is meant to copy the project into a separate working folder.

Fix:
  1) cd to your original repo folder (example):
       cd C:\path\to\project
  2) Re-run with a different -WorkDir (example):
       powershell -ExecutionPolicy Bypass -File .\scripts\windows_build_appx_local.ps1 -WorkDir "$env:TEMP\\app-win" -CleanWorkDir
"@
}

if ($srcFull -and $dstFull -and $dstFull.StartsWith($srcFull, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw @"
WorkDir is inside the source folder:
  Source: $srcFull
  WorkDir: $dstFull

This script copies the project into WorkDir. If WorkDir is inside the source tree, it can end up copying into itself.

Fix:
- If you want everything to stay in this project folder, use the in-place builder:
    powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap_windows_appx.ps1
- Or choose a WorkDir outside the repo (recommended):
    powershell -ExecutionPolicy Bypass -File .\scripts\windows_build_appx_local.ps1 -WorkDir "$env:TEMP\\app-win" -CleanWorkDir
"@
}

$effectiveInstallBuildTools = $InstallBuildTools -and (-not $SkipInstallBuildTools)

if ($CleanWorkDir -and (Test-Path $dst)) {
  Write-Step "Cleaning work dir"
  # If we're currently inside the work dir, move out so Remove-Item doesn't fail with "in use".
  try {
    $cur = Normalize-Path (Get-Location).ProviderPath
    if ($cur -and $dstFull -and $cur.StartsWith($dstFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      Set-Location (Split-Path -Parent $dstFull)
    }
  } catch {
    # ignore
  }
  try {
    Remove-Item -Recurse -Force -Path $dst -ErrorAction Stop
  } catch {
    Write-Host "WARNING: Failed to delete work dir (it may be in use by another process):" -ForegroundColor Yellow
    Write-Host ("  " + $dst) -ForegroundColor Yellow
    Write-Host ("  " + $_.Exception.Message) -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "Continuing with a new work dir to avoid blocking the build." -ForegroundColor Yellow

    $tag = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + $PID
    $dst = $dst.TrimEnd("\\") + "-inuse-" + $tag
    $dstFull = Normalize-Path $dst
    Write-Host "New WorkDir: $dst" -ForegroundColor DarkGray
  }
}

Write-Step "Copying project into work dir"
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$marker = Join-Path $dst ".appx_workdir.txt"
try {
  Set-Content -Path $marker -Encoding ASCII -Value @(
    "app=$AppName",
    "source=$src",
    ("created_utc=" + [DateTime]::UtcNow.ToString("o"))
  )
} catch {
  # ignore
}

$excludeDirs = @(
  (Join-Path $src "build"),
  (Join-Path $src ".dart_tool"),
  (Join-Path $src ".git"),
  "ephemeral",
  ".plugin_symlinks"
)

foreach ($d in $ExtraExcludeDirs) {
  if ([string]::IsNullOrWhiteSpace($d)) { continue }
  $t = $d.Trim()
  try {
    if ([IO.Path]::IsPathRooted($t)) {
      $excludeDirs += $t
    } else {
      $excludeDirs += (Join-Path $src $t)
    }
  } catch {
    $excludeDirs += $t
  }
}

$rcArgs = @($src, $dst, "/E", "/XJ", "/R:2", "/W:1", "/NP", "/XD") + $excludeDirs

& robocopy @rcArgs | Out-Host
$robocopyExit = $LASTEXITCODE

# Robocopy: 0-7 are success; 8+ are failures.
if ($robocopyExit -ge 8) {
  throw "Robocopy failed with exit code $robocopyExit"
}

$bootstrap = Join-Path $PSScriptRoot "bootstrap_windows_appx.ps1"
if (-not (Test-Path $bootstrap)) {
  throw "Missing bootstrap script at: $bootstrap"
}

Write-Step "Running bootstrap/build in work dir"
if ($FlutterVersion -and $FlutterVersion.Trim().Length -gt 0) {
  & $bootstrap `
    -ProjectRoot $dst `
    -AppName $AppName `
    -DepsRoot $DepsRoot `
    -FlutterInstallDir $FlutterInstallDir `
    -FlutterVersion $FlutterVersion `
    -InstallBuildTools:$effectiveInstallBuildTools `
    -Build:$Build `
    -PortableOnly:$PortableOnly
} else {
  & $bootstrap `
    -ProjectRoot $dst `
    -AppName $AppName `
    -DepsRoot $DepsRoot `
    -FlutterInstallDir $FlutterInstallDir `
    -InstallBuildTools:$effectiveInstallBuildTools `
    -Build:$Build `
    -PortableOnly:$PortableOnly
}

if ($Build) {
  if (-not $PortableOnly) {
    $appxCandidates = @(
      (Join-Path $dst ($AppName + ".appx")),
      (Join-Path $dst ("build\\windows\\x64\\runner\\Release\\" + $AppName + ".appx")),
      (Join-Path $dst ("build\\windows\\runner\\Release\\" + $AppName + ".appx"))
    )
    $appx = $appxCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($appx) {
      $out = Join-Path $src ($AppName + ".appx")
      Copy-Item -Force -Path $appx -Destination $out
      Write-Host ""
      Write-Host "Copied latest APPX to: $out" -ForegroundColor Green
    } else {
      Write-Host ""
      Write-Host "WARNING: APPX not found in work dir; nothing copied back to source." -ForegroundColor Yellow
    }
  }

  if ($PortableOnly) {
    $portable = Join-Path $dst ($AppName + "-portable")
    if (Test-Path $portable) {
      $out = Join-Path $src ($AppName + "-portable")
      if (Test-Path $out) { Remove-Item -Recurse -Force -Path $out }
      & robocopy $portable $out "/E" "/XJ" "/R:2" "/W:1" "/NP" | Out-Host
      $robocopyExit = $LASTEXITCODE
      if ($robocopyExit -ge 8) {
        throw "Robocopy (portable copy-back) failed with exit code $robocopyExit"
      }
      Write-Host "Copied portable folder to: $out" -ForegroundColor Green
    } else {
      Write-Host "WARNING: Portable folder not found in work dir; nothing copied back to source." -ForegroundColor Yellow
    }
  }
}

if (-not $KeepWorkDir) {
  Write-Step "Cleaning work dir (success)"
  try {
    $cur = Normalize-Path (Get-Location).ProviderPath
    if ($cur -and $dstFull -and $cur.StartsWith($dstFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      Set-Location (Split-Path -Parent $dstFull)
    }
  } catch {
    # ignore
  }
  try {
    Remove-Item -Recurse -Force -Path $dst -ErrorAction Stop
    Write-Host "Removed: $dst" -ForegroundColor DarkGray
  } catch {
    Write-Host "WARNING: Failed to delete work dir: $dst" -ForegroundColor Yellow
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
  }
} else {
  Write-Host ""
  Write-Host "Keeping work dir: $dst" -ForegroundColor Yellow
}
