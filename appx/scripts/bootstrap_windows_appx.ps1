param(
  # Root folder of the Flutter project to build (the folder containing pubspec.yaml).
  [Parameter(Mandatory = $true)]
  [string]$ProjectRoot = "",

  # Display name (also used to derive output names: <AppName>.appx, <AppName>-portable).
  [Parameter(Mandatory = $true)]
  [string]$AppName = "",

  # Shared dependency root (Flutter SDK + PUB_CACHE) so multiple apps can reuse the same downloads.
  # Default (if not set): <codex-out>\\appx\\deps
  [string]$DepsRoot = "",

  # Where to install Flutter if it isn't found on PATH.
  # Default (if not set): <DepsRoot>\\flutter
  [string]$FlutterInstallDir = "",

  # If empty, downloads the current stable Flutter from Google's release manifest.
  # Example: "3.38.6"
  [string]$FlutterVersion = "",

  # Installs Visual Studio Build Tools (Desktop C++) if missing.
  [bool]$InstallBuildTools = $true,

  # Builds the APPX at the end.
  [bool]$Build = $true,

  # If true, trusts the local dev signing certificate in LocalMachine stores (UAC prompt if needed).
  [bool]$InstallSigningCertificate = $true,

  # If set, builds a portable folder (no APPX packaging).
  [switch]$PortableOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
  param([string]$Text)
  Write-Host ""
  Write-Host "==> $Text" -ForegroundColor Cyan
}

function Ensure-Tls12 {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  } catch {
    # ignore
  }
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

function Copy-DirRobo {
  param(
    [Parameter(Mandatory = $true)][string]$Src,
    [Parameter(Mandatory = $true)][string]$Dst
  )

  if (-not (Test-Path $Src)) { throw "Copy source not found: $Src" }
  New-Item -ItemType Directory -Force -Path $Dst | Out-Null

  $args = @(
    $Src,
    $Dst,
    "/E",
    "/XJ",
    "/COPY:DAT",
    "/DCOPY:DA",
    "/R:2",
    "/W:1",
    "/NP"
  )

  & robocopy @args | Out-Host
  $rc = $LASTEXITCODE
  if ($rc -ge 8) { throw "Robocopy failed with exit code $rc" }
}

function Get-FlutterFromPath {
  $cmd = Get-Command flutter -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Get-FlutterBatInDir {
  param([string]$Dir)
  $bat = Join-Path $Dir "bin\\flutter.bat"
  if (Test-Path $bat) { return $bat }
  return $null
}

function Download-FlutterStableZip {
  param(
    [string]$OutFile,
    [string]$Version
  )

  Ensure-Tls12

  $manifestUrl = "https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json"
  $irmArgs = @{ Uri = $manifestUrl }
  if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey("UseBasicParsing")) {
    $irmArgs.UseBasicParsing = $true
  }
  $rel = Invoke-RestMethod @irmArgs

  if (-not $rel) { throw "Failed to load Flutter release manifest." }

  $hash = $rel.current_release.stable
  if ($Version -and $Version.Trim().Length -gt 0) {
    $match = $rel.releases | Where-Object { $_.version -eq $Version } | Select-Object -First 1
    if (-not $match) {
      throw "Flutter version '$Version' not found in manifest. Try leaving -FlutterVersion empty."
    }
    $hash = $match.hash
  }

  $release = $rel.releases | Where-Object { $_.hash -eq $hash } | Select-Object -First 1
  if (-not $release) { throw "Failed to resolve Flutter release from manifest." }

  $archive = $release.archive
  $uri = "$($rel.base_url)/$archive"

  Write-Host "Downloading Flutter: $uri"
  $iwrArgs = @{ Uri = $uri; OutFile = $OutFile }
  if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
    $iwrArgs.UseBasicParsing = $true
  }
  Invoke-WebRequest @iwrArgs
}

function Ensure-Flutter {
  param(
    [string]$InstallDir,
    [string]$Version
  )

  $fromPath = Get-FlutterFromPath
  if ($fromPath) {
    Write-Host "Flutter found on PATH: $fromPath"
    return $fromPath
  }

  $bat = Get-FlutterBatInDir -Dir $InstallDir
  if ($bat) {
    $env:Path = (Join-Path $InstallDir "bin") + ";" + $env:Path
    Write-Host "Flutter found at: $bat"
    return $bat
  }

  Write-Step "Installing Flutter (portable)"

  $parent = Split-Path -Parent $InstallDir
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

  $tempDir = $env:TEMP
  if ([string]::IsNullOrWhiteSpace($tempDir)) { $tempDir = $env:TMP }
  if ([string]::IsNullOrWhiteSpace($tempDir)) { $tempDir = [IO.Path]::GetTempPath() }

  $tag = "stable"
  if ($Version -and $Version.Trim().Length -gt 0) { $tag = $Version.Trim() }
  $tag = ($tag -replace '[^0-9A-Za-z._-]', '_')

  $tmpZip = Join-Path $tempDir ("flutter_windows_" + $tag + "_" + $PID + ".zip")
  if (Test-Path $tmpZip) { Remove-Item -Force -Path $tmpZip -ErrorAction SilentlyContinue }

  try {
    Download-FlutterStableZip -OutFile $tmpZip -Version $Version

    if (Test-Path $InstallDir) {
      throw "Target FlutterInstallDir already exists but flutter.bat not found: $InstallDir"
    }

    Expand-Archive -Path $tmpZip -DestinationPath $parent -Force
  } finally {
    if (Test-Path $tmpZip) { Remove-Item -Force -Path $tmpZip -ErrorAction SilentlyContinue }
  }

  $bat = Get-FlutterBatInDir -Dir $InstallDir
  if (-not $bat) { throw "Flutter install failed, missing: $InstallDir\\bin\\flutter.bat" }

  $env:Path = (Join-Path $InstallDir "bin") + ";" + $env:Path
  Write-Host "Installed Flutter at: $bat"
  return $bat
}

function Resolve-Dart {
  param([string]$FlutterBat)

  $cmd = Get-Command dart -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  $flutterBin = Split-Path -Parent $FlutterBat
  $dart = Join-Path $flutterBin "cache\\dart-sdk\\bin\\dart.exe"
  if (Test-Path $dart) { return $dart }

  # Force Flutter to populate the cache/dart-sdk.
  & $FlutterBat --version | Out-Host
  if (Test-Path $dart) { return $dart }

  throw "Dart not found. Flutter may not be installed correctly."
}

function Get-CargoFromPath {
  $cmd = Get-Command cargo -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Needs-RustToolchain {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return $false }
  return (Test-Path (Join-Path $ProjectRoot "native\\hub\\Cargo.toml"))
}

function Ensure-RustToolchain {
  param([string]$DepsRoot)

  $cargoFromPath = Get-CargoFromPath
  if ($cargoFromPath) {
    Write-Host "Rust (cargo) found on PATH: $cargoFromPath"
    return $cargoFromPath
  }

  Write-Step "Installing Rust toolchain (portable rustup)"

  if ([string]::IsNullOrWhiteSpace($DepsRoot)) {
    throw "DepsRoot is required to install Rust toolchain."
  }

  $rustupHome = Join-Path $DepsRoot "rustup"
  $cargoHome = Join-Path $DepsRoot "cargo"
  $cargoBin = Join-Path $cargoHome "bin"
  $cargoExe = Join-Path $cargoBin "cargo.exe"

  $env:RUSTUP_HOME = $rustupHome
  $env:CARGO_HOME = $cargoHome

  try { New-Item -ItemType Directory -Force -Path $rustupHome | Out-Null } catch { }
  try { New-Item -ItemType Directory -Force -Path $cargoHome | Out-Null } catch { }

  if (Test-Path $cargoExe) {
    $env:Path = $cargoBin + ";" + $env:Path
    Write-Host "Rust (cargo) found at: $cargoExe"
    return $cargoExe
  }

  Ensure-Tls12

  $tempDir = $env:TEMP
  if ([string]::IsNullOrWhiteSpace($tempDir)) { $tempDir = $env:TMP }
  if ([string]::IsNullOrWhiteSpace($tempDir)) { $tempDir = [IO.Path]::GetTempPath() }

  $tmpExe = Join-Path $tempDir ("rustup-init_" + $PID + ".exe")
  if (Test-Path $tmpExe) { Remove-Item -Force -Path $tmpExe -ErrorAction SilentlyContinue }

  try {
    $uri = "https://win.rustup.rs/x86_64"
    Write-Host "Downloading rustup-init: $uri"
    $iwrArgs = @{ Uri = $uri; OutFile = $tmpExe }
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
      $iwrArgs.UseBasicParsing = $true
    }
    Invoke-WebRequest @iwrArgs

    & $tmpExe -y --profile minimal --default-toolchain stable | Out-Host
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "rustup-init failed with exit code $code" }
  } finally {
    if (Test-Path $tmpExe) { Remove-Item -Force -Path $tmpExe -ErrorAction SilentlyContinue }
  }

  if (-not (Test-Path $cargoExe)) {
    throw "Rust toolchain install completed but cargo.exe was not found at: $cargoExe"
  }

  $env:Path = $cargoBin + ";" + $env:Path
  Write-Host "Installed Rust (cargo) at: $cargoExe"
  return $cargoExe
}

function DartCliWorks {
  param([string]$FlutterRoot)
  if ([string]::IsNullOrWhiteSpace($FlutterRoot)) { return $true }

  $dart = Join-Path $FlutterRoot "bin\\cache\\dart-sdk\\bin\\dart.exe"
  if (-not (Test-Path $dart)) { return $true } # let Flutter populate later if needed

  $out = $null
  try { $out = & $dart --help 2>&1 } catch { $out = $null }
  $text = ($out | Out-String)

  if ($text -match "\\\\\\?\\\\ prefix is not supported") { return $false }
  if ($LASTEXITCODE -ne 0) { return $false }
  return $true
}

function Get-FlutterRootFromFlutterBat {
  param([string]$FlutterBat)
  if ([string]::IsNullOrWhiteSpace($FlutterBat)) { return $null }
  try {
    $bin = Split-Path -Parent $FlutterBat
    if ([string]::IsNullOrWhiteSpace($bin)) { return $null }
    return (Split-Path -Parent $bin)
  } catch {
    return $null
  }
}

function Normalize-GitPathForSafeDirectory {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  $p = $Path.Trim()

  # Convert Windows-style UNC paths to the POSIX-ish form Git for Windows uses:
  #   \\wsl.localhost\Ubuntu-24.04\home\... -> //wsl.localhost/Ubuntu-24.04/home/...
  if ($p.StartsWith("\\\\")) {
    $p = $p -replace '^\\\\\\\\', '//'
    $p = $p -replace '\\\\', '/'
    return $p
  }

  # Convert normal Windows paths to forward slashes.
  if ($p -match '^[A-Za-z]:\\') {
    return ($p -replace '\\\\', '/')
  }

  return $p
}

function Get-GitExeForFlutterRoot {
  param([string]$FlutterRoot)

  if (-not [string]::IsNullOrWhiteSpace($FlutterRoot)) {
    $mingit = Join-Path $FlutterRoot "bin\\mingit\\cmd\\git.exe"
    if (Test-Path $mingit) { return $mingit }
  }

  $cmd = Get-Command git -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Ensure-GitSafeDirectory {
  param([string]$RepoRoot)

  $root = Normalize-GitPathForSafeDirectory -Path $RepoRoot
  if ([string]::IsNullOrWhiteSpace($root)) { return }

  # Only needed for UNC-style repos (common with \\wsl.localhost).
  if (-not $root.StartsWith("//")) { return }

  $gitExe = Get-GitExeForFlutterRoot -FlutterRoot $RepoRoot
  if (-not $gitExe) {
    Write-Host "WARNING: git.exe not found; Flutter may fail to determine its engine version." -ForegroundColor Yellow
    return
  }

  $existing = @()
  try { $existing = & $gitExe config --global --get-all safe.directory 2>$null } catch { $existing = @() }
  if ($existing -isnot [System.Array]) { $existing = @($existing) }
  $existing = $existing | ForEach-Object { ($_ | Out-String).Trim() } | Where-Object { $_ }

  $candidates = @(
    # Git for Windows typically prints this exact suggestion for UNC paths.
    ("%(prefix)/" + $root),
    # Also add the plain path in case the prefix variant doesn't match.
    $root
  ) | Where-Object { $_ } | Select-Object -Unique

  # NOTE: safe.directory is a protected config; environment overrides are intentionally ignored.
  # We must write to git's global config for this to take effect.
  Write-Host "Ensuring git safe.directory for Flutter repo: $root" -ForegroundColor DarkGray
  Write-Host "Using git: $gitExe" -ForegroundColor DarkGray

  foreach ($c in $candidates) {
    if ($existing -contains $c) { continue }
    try {
      & $gitExe config --global --add safe.directory $c | Out-Null
      Write-Host "Git safe.directory added (global): $c" -ForegroundColor DarkGray
    } catch {
      Write-Host "WARNING: Failed to add git safe.directory '$c': $($_.Exception.Message)" -ForegroundColor Yellow
    }
  }

  # Verify we can access the repo without triggering the safety check.
  try {
    $probe = & $gitExe -C $RepoRoot rev-parse --is-inside-work-tree 2>&1
    if ($LASTEXITCODE -ne 0 -and ($probe | Out-String) -match "dubious ownership") {
      Write-Host "WARNING: git still reports 'dubious ownership' for: $RepoRoot" -ForegroundColor Yellow
      Write-Host "Tried safe.directory values:" -ForegroundColor Yellow
      foreach ($c in $candidates) { Write-Host "  $c" -ForegroundColor Yellow }
      Write-Host "Fix: run the suggested 'git config --global --add safe.directory ...' command from the error output." -ForegroundColor Yellow
    }
  } catch {
    # ignore (repo probe is best-effort)
  }
}

function Get-VsWhere {
  $p = "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"
  if (Test-Path $p) { return $p }
  return $null
}

function Get-KitsRoot10 {
  $regPaths = @(
    "HKLM:\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots",
    "HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows Kits\\Installed Roots"
  )

  foreach ($rp in $regPaths) {
    try {
      $v = (Get-ItemProperty -Path $rp -Name "KitsRoot10" -ErrorAction Stop).KitsRoot10
      if (-not [string]::IsNullOrWhiteSpace($v)) {
        $v = $v.Trim()
        # Guard against a common quoting mistake:
        #   reg add ... /d "C:\Program Files (x86)\Windows Kits\10\" /f
        # which can result in KitsRoot10 being set to: C:\...\10" /f
        if ($v.Contains('"')) {
          $san = ($v.Split('"')[0]).Trim()
          if (-not [string]::IsNullOrWhiteSpace($san)) { $v = $san }
        }
        return $v
      }
    } catch {
      # ignore
    }
  }

  return $null
}

function Get-KitsRoot10Candidates {
  $candidates = @()

  $reg = Get-KitsRoot10
  if ($reg) { $candidates += $reg }

  $pf86 = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\\10"
  # Note: In PowerShell, "\" is not an escape character (backtick is).
  # Keep paths normalized to a single "\".
  $pf86 = $pf86 -replace '\\{2,}', '\'
  if (Test-Path $pf86) { $candidates += $pf86 }

  $pf = Join-Path $env:ProgramFiles "Windows Kits\\10"
  $pf = $pf -replace '\\{2,}', '\'
  if (Test-Path $pf) { $candidates += $pf }

  $candidates |
    Where-Object { $_ -and $_.Trim().Length -gt 0 } |
    Where-Object { $_.IndexOfAny([IO.Path]::GetInvalidPathChars()) -lt 0 } |
    ForEach-Object { ($_.Trim().TrimEnd("\") + "\") } |
    Select-Object -Unique
}

function Find-UcrtdLib {
  $kitsRoots = @(Get-KitsRoot10Candidates)
  if (-not $kitsRoots -or $kitsRoots.Count -eq 0) { return $null }

  foreach ($kitsRoot in $kitsRoots) {
    $libRoot = Join-Path $kitsRoot "Lib"
    try {
      if (-not (Test-Path $libRoot)) { continue }
    } catch {
      continue
    }

    $verDirs = Get-ChildItem -Path $libRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' } |
      Sort-Object -Property Name -Descending

    foreach ($d in $verDirs) {
      $p = Join-Path $d.FullName "ucrt\\x64\\ucrtd.lib"
      $p = $p -replace '\\{2,}', '\'
      if (Test-Path $p) { return $p }
    }

    # Fallback: glob for any SDK version folder (in case version directory names are unexpected).
    try {
      $glob = (Join-Path $libRoot "*\\ucrt\\x64\\ucrtd.lib") -replace '\\{2,}', '\'
      $m = Get-ChildItem -Path $glob -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
      if ($m) { return $m.FullName }
    } catch {
      # ignore
    }

    # Last resort: recursive search (slow, but robust against odd directory layouts/provider quirks).
    try {
      $m = Get-ChildItem -Path $libRoot -Recurse -Filter "ucrtd.lib" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\ucrt\\x64\\ucrtd\.lib$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
      if ($m) { return $m.FullName }
    } catch {
      # ignore
    }
  }

  return $null
}

function Get-VsInstallPath {
  $vswhere = Get-VsWhere
  if (-not $vswhere) { return $null }

  $json = & $vswhere -all -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  if ([string]::IsNullOrWhiteSpace($json)) { return $null }

  try {
    $instances = $json | ConvertFrom-Json
  } catch {
    return $null
  }
  if (-not $instances) { return $null }
  if ($instances -isnot [System.Array]) { $instances = @($instances) }

  $candidates = @()
  foreach ($i in $instances) {
    $p = $i.installationPath
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $p = $p.Trim()

    $ver = [Version]"0.0.0.0"
    try { $ver = [Version]$i.installationVersion } catch { }

    $candidates += [PSCustomObject]@{ Path = $p; Ver = $ver }
  }

  # Fallback common install paths (vswhere sometimes returns a broken "C:\Program" instance).
  foreach ($p in @(
    "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools",
    "C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools"
  )) {
    if (Test-Path $p) { $candidates += [PSCustomObject]@{ Path = $p; Ver = [Version]"0.0.0.0" } }
  }

  $candidates = $candidates | Group-Object Path | ForEach-Object { $_.Group | Sort-Object Ver -Descending | Select-Object -First 1 }

  $scored = foreach ($c in $candidates) {
    $p = $c.Path
    $ver = $c.Ver
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $p = $p.Trim()

    $hasVcVars = Test-Path (Join-Path $p "VC\\Auxiliary\\Build\\vcvars64.bat")
    $hasVsDevCmd = Test-Path (Join-Path $p "Common7\\Tools\\VsDevCmd.bat")
    if (-not $hasVcVars -and -not $hasVsDevCmd) { continue }

    $score = 0
    if ($p -ieq "C:\\Program") { $score -= 1000 } # common broken path if installer args weren't quoted
    if ($p -match "Microsoft Visual Studio\\2022\\BuildTools$") { $score += 100 }
    elseif ($p -match "Microsoft Visual Studio\\2022\\") { $score += 80 }
    elseif ($p -match "Microsoft Visual Studio\\") { $score += 60 }

    if ($hasVcVars) { $score += 20 }
    if ($hasVsDevCmd) { $score += 20 }

    [PSCustomObject]@{ Path = $p; Ver = $ver; Score = $score }
  }

  $best = $scored | Sort-Object -Property Score, Ver -Descending | Select-Object -First 1
  if (-not $best) { return $null }
  return $best.Path
}

function Get-VsWhereLatestFlutterInstallPath {
  # Flutter uses vswhere; in practice the most reliable signal for "MSVC is installed"
  # is the VC tools component.
  $vswhere = Get-VsWhere
  if (-not $vswhere) { return $null }

  $json = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -format json 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  if ([string]::IsNullOrWhiteSpace($json)) { return $null }

  try {
    $instances = $json | ConvertFrom-Json
  } catch {
    return $null
  }
  if (-not $instances) { return $null }
  if ($instances -is [System.Array]) { $instances = $instances | Select-Object -First 1 }

  $p = $instances.installationPath
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }
  return $p.Trim()
}

function Has-FlutterVsWhereInstance {
  $p = Get-VsWhereLatestFlutterInstallPath
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }
  if ($p -ieq "C:\\Program") { return $false }

  $hasVcVars = Test-Path (Join-Path $p "VC\\Auxiliary\\Build\\vcvars64.bat")
  $hasVsDevCmd = Test-Path (Join-Path $p "Common7\\Tools\\VsDevCmd.bat")
  return ($hasVcVars -or $hasVsDevCmd)
}

function Get-VsDevCmd {
  $path = Get-VsInstallPath
  if (-not $path) { return $null }

  $vsDevCmd = Join-Path $path "Common7\\Tools\\VsDevCmd.bat"
  if (Test-Path $vsDevCmd) { return $vsDevCmd }
  return $null
}

function Has-VcBuildTools {
  $path = Get-VsInstallPath
  return -not [string]::IsNullOrWhiteSpace($path)
}

function Has-ClCompiler {
  $vsDevCmd = Get-VsDevCmd
  if (-not $vsDevCmd) { return $false }

  try {
    $out = & cmd.exe /c "call `"$vsDevCmd`" -arch=amd64 -host_arch=amd64 >nul 2>nul && where cl" 2>$null
  } catch {
    return $false
  }
  if ($LASTEXITCODE -ne 0) { return $false }

  if (-not $out) { return $false }
  $first = ($out | Select-Object -First 1)

  # Require an x64-targeting MSVC compiler path.
  if ($first -match "\\VC\\Tools\\MSVC\\" -and $first -match "\\x64\\cl\.exe$") {
    return $true
  }

  return $false
}

function Has-MsvcToolset {
  $installPath = Get-VsInstallPath
  if (-not $installPath) { return $false }

  $msvcRoot = Join-Path $installPath "VC\\Tools\\MSVC"
  if (-not (Test-Path $msvcRoot)) { return $false }

  $verDir = Get-ChildItem -Path $msvcRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $verDir) { return $false }

  # Flutter's Windows build targets x64; require an x64 compiler.
  $candidates = @(
    (Join-Path $verDir.FullName "bin\\Hostx64\\x64\\cl.exe"),
    (Join-Path $verDir.FullName "bin\\Hostx86\\x64\\cl.exe")
  )

  foreach ($c in $candidates) {
    if (Test-Path $c) { return $true }
  }

  return $false
}

function Install-VcBuildTools {
  Write-Step "Installing Visual Studio Build Tools (Desktop C++)"

  $vs = Join-Path $env:TEMP "vs_BuildTools.exe"
  if (Test-Path $vs) { Remove-Item -Force $vs }

  Ensure-Tls12
  $iwrArgs = @{ Uri = "https://aka.ms/vs/17/release/vs_BuildTools.exe"; OutFile = $vs }
  if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
    $iwrArgs.UseBasicParsing = $true
  }
  Invoke-WebRequest @iwrArgs

  $defaultInstallPath = "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools"
  $installPath = $defaultInstallPath
  $existing = Get-VsInstallPath
  if ($existing -and $existing -ine "C:\\Program") { $installPath = $existing }

  function Quote-Arg {
    param([string]$Arg)
    if ($null -eq $Arg) { return '""' }
    if ($Arg -match '[\s"]') {
      $escaped = $Arg -replace '"', '\\"'
      return '"' + $escaped + '"'
    }
    return $Arg
  }

  $installerArgs = @(
    "--quiet",
    "--wait",
    "--norestart",
    "--nocache",
    "--installPath", $installPath,
    # Flutter's toolchain detection commonly requires the "Desktop development with C++" workload.
    "--add", "Microsoft.VisualStudio.Workload.NativeDesktop",
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "--add", "Microsoft.VisualStudio.Component.VC.CMake.Project",
    "--includeRecommended",
    "--includeOptional"
  )

  $argLine = ($installerArgs | ForEach-Object { Quote-Arg $_ }) -join " "
  $proc = Start-Process -FilePath $vs -ArgumentList $argLine -Verb RunAs -Wait -PassThru
  $code = $proc.ExitCode

  Remove-Item -Force $vs -ErrorAction SilentlyContinue

  if ($code -eq 0) { return }
  if ($code -eq 3010) {
    Write-Host "Build Tools installed, but a reboot is required (exit code 3010)." -ForegroundColor Yellow
    Write-Host "Reboot Windows, then re-run this script." -ForegroundColor Yellow
    exit 3010
  }

  Write-Host "Build Tools installer failed (exit code $code)." -ForegroundColor Red
  Write-Host "Latest Visual Studio setup logs (from %TEMP%):" -ForegroundColor Yellow
  $patterns = @("dd_setup_*.log", "dd_bootstrapper_*.log", "dd_installer_*.log")
  foreach ($pat in $patterns) {
    $latest = Get-ChildItem -Path $env:TEMP -Filter $pat -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
      Write-Host "  $($latest.FullName)" -ForegroundColor DarkGray
      try {
        Get-Content -Tail 80 $latest.FullName | Out-Host
      } catch {
        # ignore
      }
    }
  }
  throw "Build Tools installer failed with exit code $code"
}

function Run-Command {
  param(
    [string]$Title,
    [string]$Exe,
    [string[]]$Arguments
  )
  Write-Step $Title
  if (-not [string]::IsNullOrWhiteSpace($Exe)) {
    $exeText = $Exe.Trim()
    if (($exeText -match '^[A-Za-z]:') -or $exeText.Contains("\\") -or $exeText.Contains("/")) {
      if (-not (Test-Path $exeText)) { throw "Executable not found: $exeText" }
    }
  }
  # flutter sometimes prints warnings/progress to stderr; don't treat as terminating errors.
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $Exe @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldEap
  }
  if ($exitCode -ne 0) { throw "$Title failed with exit code $exitCode" }
}

$root = $ProjectRoot.Trim()
$AppName = $AppName.Trim()
if ([string]::IsNullOrWhiteSpace($root)) { throw "ProjectRoot is required." }
if ([string]::IsNullOrWhiteSpace($AppName)) { throw "AppName is required." }
if (-not (Test-Path $root)) { throw "ProjectRoot not found: $root" }
Set-Location $root

Write-Step "$AppName Windows APPX bootstrap"
Write-Host "Project: $root"

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

try { New-Item -ItemType Directory -Force -Path $DepsRoot | Out-Null } catch { }
Write-Host "Deps:    $DepsRoot" -ForegroundColor DarkGray

if ([string]::IsNullOrWhiteSpace($env:PUB_CACHE)) {
  $pubCache = Join-Path $DepsRoot "pub-cache"
  try { New-Item -ItemType Directory -Force -Path $pubCache | Out-Null } catch { }
  $env:PUB_CACHE = $pubCache
}
Write-Host "Pub:     $env:PUB_CACHE" -ForegroundColor DarkGray

$FlutterInstallDir = $FlutterInstallDir.Trim()
if ([string]::IsNullOrWhiteSpace($FlutterInstallDir)) {
  $FlutterInstallDir = Join-Path $DepsRoot "flutter"
}

$flutter = Ensure-Flutter -InstallDir $FlutterInstallDir -Version $FlutterVersion
$flutterRoot = Get-FlutterRootFromFlutterBat -FlutterBat $flutter

# WSL UNC paths (\\wsl.localhost\...) behave like "network" paths. The Dart CLI (dart.exe)
# fails on these paths with: "\\?\\ prefix is not supported ...", which breaks Flutter.
# If we detect this, fall back to a local NTFS deps cache for Flutter/Dart only.
if ($flutterRoot -and (Is-UncPath $flutterRoot) -and (-not (DartCliWorks -FlutterRoot $flutterRoot))) {
  $localDeps = Get-LocalDepsRoot
  $localFlutter = Join-Path $localDeps "flutter"

  Write-Host ""
  Write-Host "WARNING: Dart CLI cannot run from the WSL UNC Flutter install:" -ForegroundColor Yellow
  Write-Host "  $flutterRoot" -ForegroundColor Yellow
  Write-Host "Falling back to a local deps cache for Flutter/Dart:" -ForegroundColor Yellow
  Write-Host "  $localDeps" -ForegroundColor Yellow
  Write-Host "Override with APPX_DEPS_ROOT (or set APPX_DEPS_ROOT_LOCAL)." -ForegroundColor Yellow

  if (-not (Test-Path (Join-Path $localFlutter "bin\\flutter.bat"))) {
    Write-Step "Copying Flutter SDK to local deps cache (one-time)"
    Copy-DirRobo -Src $flutterRoot -Dst $localFlutter
  }

  $DepsRoot = $localDeps
  $FlutterInstallDir = $localFlutter
  $env:PUB_CACHE = Join-Path $DepsRoot "pub-cache"
  try { New-Item -ItemType Directory -Force -Path $env:PUB_CACHE | Out-Null } catch { }
  Write-Host "Deps:    $DepsRoot" -ForegroundColor DarkGray
  Write-Host "Pub:     $env:PUB_CACHE" -ForegroundColor DarkGray

  $flutter = Ensure-Flutter -InstallDir $FlutterInstallDir -Version $FlutterVersion
  $flutterRoot = Get-FlutterRootFromFlutterBat -FlutterBat $flutter
}

Ensure-GitSafeDirectory -RepoRoot $flutterRoot
$dart = Resolve-Dart -FlutterBat $flutter

Run-Command -Title "Flutter doctor" -Exe $flutter -Arguments @("doctor", "-v")
Run-Command -Title "Enable Windows desktop (safe if already enabled)" -Exe $flutter -Arguments @("config", "--enable-windows-desktop")

$vsLatest = Get-VsWhereLatestFlutterInstallPath
if ($vsLatest) {
  Write-Host "Visual Studio picked by Flutter (vswhere -latest): $vsLatest"
  if ($vsLatest -ieq "C:\\Program") {
    Write-Host "WARNING: vswhere returned installPath 'C:\\Program'. This is usually a broken Visual Studio install record caused by unquoted installer args." -ForegroundColor Yellow
    Write-Host "This can break Flutter's CMake/MSVC wiring and show up as paths like: C:/Program/Common7/IDE/CommonExtensions/Microsoft/CMake/..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Fix (recommended): open Visual Studio Installer and uninstall/repair the Build Tools instance so vswhere returns the real path under Program Files (x86)." -ForegroundColor Yellow
    Write-Host "Quick check (copy/paste):" -ForegroundColor Yellow
    Write-Host "  & `"${env:ProgramFiles(x86)}\\Microsoft Visual Studio\\Installer\\vswhere.exe`" -all -products * -property installationPath" -ForegroundColor Yellow
  }
} else {
  Write-Host "Visual Studio picked by Flutter (vswhere -latest): <none>" -ForegroundColor Yellow
  Write-Host "This usually means the required C++ workloads are not installed (or VS is broken)." -ForegroundColor Yellow
}

$kitsRoot = Get-KitsRoot10
$kitsCandidates = @(Get-KitsRoot10Candidates)
if ($kitsRoot) {
  Write-Host "Windows Kits root (KitsRoot10): $kitsRoot"
  if ($kitsRoot -match "^C:\\Program Files\\Windows Kits\\10") {
    Write-Host "WARNING: KitsRoot10 points to Program Files (missing '(x86)'). This often causes LNK1104 ucrtd.lib." -ForegroundColor Yellow
    Write-Host "Fix (run in *elevated* PowerShell):" -ForegroundColor Yellow
    Write-Host "  reg add `"HKLM\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots`" /v KitsRoot10 /t REG_SZ /d `"C:\\Program Files (x86)\\Windows Kits\\10`" /f" -ForegroundColor Yellow
    Write-Host "  reg add `"HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows Kits\\Installed Roots`" /v KitsRoot10 /t REG_SZ /d `"C:\\Program Files (x86)\\Windows Kits\\10`" /f" -ForegroundColor Yellow
  }
} else {
  Write-Host "Windows Kits root (KitsRoot10): <not found in registry>" -ForegroundColor Yellow
}
if ($kitsCandidates -and $kitsCandidates.Count -gt 0) {
  Write-Host "Windows Kits search roots:"
  $kitsCandidates | ForEach-Object { Write-Host "  - $_" }
}

$ucrtd = Find-UcrtdLib
if ($ucrtd) {
  Write-Host "Found ucrtd.lib: $ucrtd"
} else {
  Write-Host "WARNING: ucrtd.lib not found. Windows SDK debug UCRT libs appear missing (or KitsRoot10 points to the wrong folder)." -ForegroundColor Yellow
}

if ($InstallBuildTools) {
  $installedOrRepaired = $false
  if (-not (Has-FlutterVsWhereInstance)) {
    Write-Host "Flutter's vswhere query did not find a usable Visual Studio instance. Installing/repairing Build Tools workloads..." -ForegroundColor Yellow
    Install-VcBuildTools
    $installedOrRepaired = $true
  } elseif (-not (Has-VcBuildTools)) {
    Install-VcBuildTools
    $installedOrRepaired = $true
  } elseif (-not (Has-MsvcToolset)) {
    Write-Host "Visual Studio detected, but the MSVC toolset (cl.exe) is missing. Repairing/adding C++ components..." -ForegroundColor Yellow
    Install-VcBuildTools
    $installedOrRepaired = $true
  } elseif (-not $ucrtd) {
    Write-Host "ucrtd.lib is missing; repairing/adding Windows UCRT SDK components..." -ForegroundColor Yellow
    Install-VcBuildTools
    $installedOrRepaired = $true
  } elseif (-not (Has-ClCompiler)) {
    Write-Host "MSVC toolset is installed, but cl.exe isn't on PATH in a VS dev prompt." -ForegroundColor Yellow
    Write-Host "Continuing anyway (the build uses vcvars/vsdevcmd explicitly)." -ForegroundColor Yellow
    Write-Host "If the build fails, re-run this script from an elevated PowerShell to repair Build Tools." -ForegroundColor Yellow
  } else {
    Write-Host "Visual Studio C++ build tools detected."
  }

  # Always refresh SDK detection after any install/repair.
  if ($installedOrRepaired) {
    $ucrtd = Find-UcrtdLib
    if ($ucrtd) {
      Write-Host "Found ucrtd.lib after install: $ucrtd"
    } else {
      Write-Host "WARNING: ucrtd.lib still not found after Build Tools install/repair." -ForegroundColor Yellow
    }
  }
} else {
  Write-Host "Skipping Build Tools install/check (InstallBuildTools was not set)." -ForegroundColor Yellow
}

if (-not $ucrtd) {
  Write-Host ""
  Write-Host "ERROR: ucrtd.lib is still missing." -ForegroundColor Red
  Write-Host "This will cause: LINK : fatal error LNK1104: cannot open file 'ucrtd.lib'." -ForegroundColor Red
  Write-Host ""
  Write-Host "Run this in an *elevated* PowerShell to confirm:" -ForegroundColor Yellow
  Write-Host "  reg query `"HKLM\\SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots`" /v KitsRoot10" -ForegroundColor Yellow
  Write-Host "  reg query `"HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows Kits\\Installed Roots`" /v KitsRoot10" -ForegroundColor Yellow
  Write-Host "  Get-ChildItem `"${env:ProgramFiles(x86)}\\Windows Kits\\10\\Lib`" -Recurse -Filter ucrtd.lib -ErrorAction SilentlyContinue | Select-Object -First 5 -Expand FullName" -ForegroundColor Yellow
  throw "Missing ucrtd.lib (Windows UCRT debug import library)."
}

if (Needs-RustToolchain -ProjectRoot $root) {
  Ensure-RustToolchain -DepsRoot $DepsRoot | Out-Null
}

Run-Command -Title "Flutter doctor (post-toolchain)" -Exe $flutter -Arguments @("doctor", "-v")

if ($Build) {
  $title = "Build APPX"
  if ($PortableOnly) { $title = "Build portable folder" }
  $buildScript = Join-Path $PSScriptRoot "build_appx.ps1"
  Write-Step $title

  # IMPORTANT: Don't spawn a nested `powershell.exe -File <wsl-path> ...`.
  # Windows PowerShell has a bug binding boolean parameters when the script lives on the
  # WSL UNC filesystem (\\wsl.localhost\...). Running in-process avoids it.
  & $buildScript `
    -ProjectRoot $root `
    -AppName $AppName `
    -FlutterPath $flutter `
    -DartPath $dart `
    -InstallSigningCertificate:$InstallSigningCertificate `
    -PortableOnly:$PortableOnly

  Write-Step "Done"
  if ($PortableOnly) {
    Write-Host "Portable: $(Join-Path $root ($AppName + '-portable'))"
  } else {
    $outAppx = Join-Path $root ($AppName + ".appx")
    Write-Host "APPX: $outAppx"
  }
} else {
  Write-Host "Build skipped (Build was not set)." -ForegroundColor Yellow
}
