param(
  # Root folder of the Flutter project to build (the folder containing pubspec.yaml).
  [Parameter(Mandatory = $true)]
  [string]$ProjectRoot = "",

  # Display name (also used to derive output names: <AppName>.appx, <AppName>-portable).
  [Parameter(Mandatory = $true)]
  [string]$AppName = "",

  # Optional explicit flutter.bat path; otherwise uses flutter on PATH.
  [string]$FlutterPath = "",

  # Optional explicit dart.exe path; otherwise uses dart on PATH (or via Flutter's dart-sdk).
  [string]$DartPath = "",

  # If true, trusts the local dev signing certificate in LocalMachine stores (UAC prompt if needed).
  [bool]$InstallSigningCertificate = $true,

  # If set, builds a portable folder (no APPX packaging).
  [switch]$PortableOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Run-Command {
  param(
    [string]$Title,
    [string]$Exe,
    [string[]]$Arguments
  )
  Write-Host ""
  Write-Host "==> $Title" -ForegroundColor Cyan
  if (-not [string]::IsNullOrWhiteSpace($Exe)) {
    $exeText = $Exe.Trim()
    if (($exeText -match '^[A-Za-z]:') -or $exeText.Contains("\\") -or $exeText.Contains("/")) {
      if (-not (Test-Path $exeText)) { throw "Executable not found: $exeText" }
    }
  }
  # Many native tools (flutter, dart, msbuild) write progress/warnings to stderr.
  # With $ErrorActionPreference=Stop, native stderr becomes terminating errors.
  # Redirect and stringify to keep full logs, and rely on exit codes for failure.
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

function Resolve-Flutter {
  param([string]$Provided)
  if ($Provided) {
    $p = $Provided.Trim()
    if ($p.Length -gt 0) { return $p }
  }
  $cmd = Get-Command flutter -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "flutter not found. Run the shared bootstrap first (appx\\scripts\\bootstrap_windows_appx.ps1) or add Flutter to PATH."
}

function Resolve-Dart {
  param([string]$Provided, [string]$ResolvedFlutter)
  if ($Provided) {
    $p = $Provided.Trim()
    if ($p.Length -gt 0) { return $p }
  }
  $cmd = Get-Command dart -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  # flutter.bat path -> ...\\flutter\\bin\\flutter.bat
  if ($ResolvedFlutter) {
    $flutterBin = Split-Path -Parent $ResolvedFlutter
    $dart = Join-Path $flutterBin "cache\\dart-sdk\\bin\\dart.exe"
    if (Test-Path $dart) { return $dart }
  }
  throw "dart not found. Install Flutter (includes Dart) or provide -DartPath."
}

function Get-FlutterPinnedEngineVersion {
  param([string]$ResolvedFlutter)

  if ([string]::IsNullOrWhiteSpace($ResolvedFlutter)) { return $null }

  $flutterBin = Split-Path -Parent $ResolvedFlutter
  if ([string]::IsNullOrWhiteSpace($flutterBin)) { return $null }

  $flutterRoot = Split-Path -Parent $flutterBin
  if ([string]::IsNullOrWhiteSpace($flutterRoot)) { return $null }

  $engineVersionPath = Join-Path $flutterRoot "bin\\internal\\engine.version"
  if (-not (Test-Path $engineVersionPath)) { return $null }

  try {
    $value = (Get-Content -Raw -Path $engineVersionPath).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
  } catch {
    return $null
  }
}

function Resolve-GitExe {
  $cmd = Get-Command git -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  $candidates = @(
    (Join-Path $env:ProgramFiles "Git\\cmd\\git.exe"),
    (Join-Path $env:ProgramFiles "Git\\bin\\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\\cmd\\git.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\\bin\\git.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\\Git\\cmd\\git.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\\Git\\bin\\git.exe")
  ) | Where-Object { $_ } | Select-Object -Unique

  foreach ($c in $candidates) {
    if (Test-Path $c) {
      $dir = Split-Path -Parent $c
      if ($dir -and (Test-Path $dir)) { $env:Path = $dir + ";" + $env:Path }
      return $c
    }
  }
  return $null
}

function Resolve-WindowsRunnerReleaseDir {
  param([string]$ProjectRoot)

  $buildWindows = Join-Path $ProjectRoot "build\\windows"
  if (-not (Test-Path $buildWindows)) {
    throw "Missing build output folder: $buildWindows (did flutter build windows run?)"
  }

  $candidates = @(
    (Join-Path $ProjectRoot "build\\windows\\x64\\runner\\Release"),
    (Join-Path $ProjectRoot "build\\windows\\runner\\Release"),
    (Join-Path $ProjectRoot "build\\windows\\arm64\\runner\\Release")
  ) | Where-Object { $_ } | Select-Object -Unique

  foreach ($c in $candidates) {
    if (-not (Test-Path $c)) { continue }
    $exe = Get-ChildItem -Path $c -File -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $c }
  }

  # Fallback: find any runner\\Release dir under build\\windows that contains an exe.
  $dirs = Get-ChildItem -Path $buildWindows -Directory -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\runner\\Release$' } |
    Sort-Object FullName -Descending

  foreach ($d in $dirs) {
    $exe = Get-ChildItem -Path $d.FullName -File -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $d.FullName }
  }

  throw "Windows runner Release directory not found under: $buildWindows"
}

function Find-MainExeName {
  param([string]$ReleaseDir)
  $exe = Get-ChildItem -Path $ReleaseDir -File -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $exe) { return $null }
  return $exe.Name
}

function New-PortableFolder {
  param(
    [string]$ProjectRoot,
    [string]$ReleaseDir,
    [string]$AppName
  )

  $portableRoot = Join-Path $ProjectRoot ($AppName + "-portable")
  if (Test-Path $portableRoot) { Remove-Item -Recurse -Force -Path $portableRoot }
  New-Item -ItemType Directory -Force -Path $portableRoot | Out-Null

  Copy-Item -Recurse -Force -Path (Join-Path $ReleaseDir "*") -Destination $portableRoot

  $mainExe = Find-MainExeName -ReleaseDir $portableRoot
  if ($mainExe) {
    $safe = ($AppName.ToLowerInvariant() -replace '[^0-9a-z._-]', '')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "run" }
    $runBat = Join-Path $portableRoot ("run_" + $safe + ".bat")
    Set-Content -Path $runBat -Encoding ASCII -Value @(
      "@echo off",
      "setlocal",
      "cd /d `%~dp0",
      ("`"%~dp0" + $mainExe + "`"")
    )
  }

  return $portableRoot
}

function Get-AppxPublisherFromManifest {
  param([string]$ManifestPath)

  [xml]$xml = Get-Content -Path $ManifestPath
  $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
  $ns.AddNamespace("a", $xml.DocumentElement.NamespaceURI)
  $id = $xml.SelectSingleNode("/a:Package/a:Identity", $ns)
  if (-not $id) { throw "AppxManifest.xml is missing the <Identity> element: $ManifestPath" }

  $publisher = $id.GetAttribute("Publisher")
  if ([string]::IsNullOrWhiteSpace($publisher)) { throw "AppxManifest.xml Identity Publisher is empty: $ManifestPath" }
  return $publisher.Trim()
}

function Get-AppxIdentityNameFromManifest {
  param([string]$ManifestPath)

  [xml]$xml = Get-Content -Path $ManifestPath
  $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
  $ns.AddNamespace("a", $xml.DocumentElement.NamespaceURI)
  $id = $xml.SelectSingleNode("/a:Package/a:Identity", $ns)
  if (-not $id) { throw "AppxManifest.xml is missing the <Identity> element: $ManifestPath" }

  $name = $id.GetAttribute("Name")
  if ([string]::IsNullOrWhiteSpace($name)) { throw "AppxManifest.xml Identity Name is empty: $ManifestPath" }
  return $name.Trim()
}

function Get-AppxVersionFromManifest {
  param([string]$ManifestPath)

  [xml]$xml = Get-Content -Path $ManifestPath
  $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
  $ns.AddNamespace("a", $xml.DocumentElement.NamespaceURI)
  $id = $xml.SelectSingleNode("/a:Package/a:Identity", $ns)
  if (-not $id) { throw "AppxManifest.xml is missing the <Identity> element: $ManifestPath" }

  $v = $id.GetAttribute("Version")
  if ([string]::IsNullOrWhiteSpace($v)) { throw "AppxManifest.xml Identity Version is empty: $ManifestPath" }

  try { return [Version]$v.Trim() } catch { throw "Invalid AppxManifest Identity Version '$v' in: $ManifestPath" }
}

function Set-AppxIdentityNameInManifest {
  param(
    [string]$ManifestPath,
    [string]$IdentityName
  )

  if ([string]::IsNullOrWhiteSpace($IdentityName)) {
    throw "IdentityName is required."
  }

  [xml]$xml = Get-Content -Path $ManifestPath
  $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
  $ns.AddNamespace("a", $xml.DocumentElement.NamespaceURI)
  $id = $xml.SelectSingleNode("/a:Package/a:Identity", $ns)
  if (-not $id) { throw "AppxManifest.xml is missing the <Identity> element: $ManifestPath" }

  $id.SetAttribute("Name", $IdentityName.Trim()) | Out-Null
  $xml.Save($ManifestPath)
}

function Set-AppxVersionInManifest {
  param(
    [string]$ManifestPath,
    [Version]$Version
  )

  [xml]$xml = Get-Content -Path $ManifestPath
  $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
  $ns.AddNamespace("a", $xml.DocumentElement.NamespaceURI)
  $id = $xml.SelectSingleNode("/a:Package/a:Identity", $ns)
  if (-not $id) { throw "AppxManifest.xml is missing the <Identity> element: $ManifestPath" }

  $id.SetAttribute("Version", $Version.ToString()) | Out-Null
  $xml.Save($ManifestPath)
}

function Get-AppxVersionFromAppx {
  param([string]$AppxPath)

  if (-not (Test-Path $AppxPath)) { return $null }

  try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch { }
  $zip = [System.IO.Compression.ZipFile]::OpenRead($AppxPath)
  try {
    $entry = $zip.Entries | Where-Object { $_.FullName -ieq "AppxManifest.xml" } | Select-Object -First 1
    if (-not $entry) { return $null }
    $sr = New-Object System.IO.StreamReader($entry.Open())
    try {
      $xmlText = $sr.ReadToEnd()
    } finally {
      $sr.Close()
    }
    [xml]$xml = $xmlText
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace("a", $xml.DocumentElement.NamespaceURI)
    $id = $xml.SelectSingleNode("/a:Package/a:Identity", $ns)
    if (-not $id) { return $null }
    $v = $id.GetAttribute("Version")
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  try { return [Version]$v.Trim() } catch { return $null }
  } finally {
    $zip.Dispose()
  }
}

function Get-CanonicalAppxIdentityFromPubspec {
  param([string]$ProjectRoot)

  $pubspec = Join-Path $ProjectRoot "pubspec.yaml"
  if (-not (Test-Path $pubspec)) { return $null }

  $msixIndent = $null
  foreach ($raw in (Get-Content -Path $pubspec)) {
    $line = $raw -replace "`t", "  "

    if ($msixIndent -eq $null) {
      if ($line -match '^(\s*)msix_config:\s*$') {
        $msixIndent = $Matches[1].Length
      }
      continue
    }

    if ($line -match '^\s*$') { continue }
    if ($line -match '^\s*#') { continue }

    if ($line -match '^(\s*)([^:#][^:]*)\s*:\s*(.*?)\s*$') {
      $indent = $Matches[1].Length
      if ($indent -le $msixIndent) { break }

      $key = $Matches[2].Trim()
      $value = $Matches[3].Trim()
      if ($key -ne "identity_name") { continue }

      $hash = $value.IndexOf("#")
      if ($hash -ge 0) {
        $value = $value.Substring(0, $hash).Trim()
      }

      if (
        (($value.StartsWith("'")) -and $value.EndsWith("'")) -or
        (($value.StartsWith('"')) -and $value.EndsWith('"'))
      ) {
        $value = $value.Substring(1, $value.Length - 2)
      }

      if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value.Trim()
      }
      return $null
    }

    if ($line -match '^(\s*)\S') {
      $indent = $Matches[1].Length
      if ($indent -le $msixIndent) { break }
    }
  }

  return $null
}

function Increment-AppxVersion {
  param([Version]$V)

  $major = $V.Major
  $minor = $V.Minor
  $build = $V.Build
  $rev = $V.Revision

  if ($rev -lt 0) { $rev = 0 }
  if ($build -lt 0) { $build = 0 }

  if ($rev -lt 65535) {
    return New-Object System.Version -ArgumentList @($major, $minor, $build, ($rev + 1))
  }
  if ($build -lt 65535) {
    return New-Object System.Version -ArgumentList @($major, $minor, ($build + 1), 0)
  }
  throw "APPX version overflow (can't increment beyond $V)."
}

function Get-InstalledAppxVersion {
  param([string]$IdentityName)
  if ([string]::IsNullOrWhiteSpace($IdentityName)) { return $null }
  try {
    $pkg = Get-AppxPackage -Name $IdentityName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { return $null }
    $v = $pkg.Version
    if (-not $v) { return $null }
    try { return [Version]$v.ToString() } catch { return $null }
  } catch {
    return $null
  }
}

function Warn-ConflictingInstalledPackages {
  param(
    [string]$CanonicalIdentity,
    [string]$AppName
  )

  if ([string]::IsNullOrWhiteSpace($CanonicalIdentity)) { return }

  $lookups = @()
  foreach ($name in @($CanonicalIdentity, $AppName)) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $trimmed = $name.Trim()
    if ($lookups -contains $trimmed) { continue }
    $lookups += $trimmed
  }

  $pkgs = @()
  foreach ($name in $lookups) {
    $found = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue
    if ($found) { $pkgs += $found }
  }

  if (-not $pkgs) { return }

  $conflicts = $pkgs |
    Sort-Object -Property PackageFullName -Unique |
    Where-Object { $_.Name -ne $CanonicalIdentity }

  if (-not $conflicts) { return }

  Write-Host ""
  Write-Host "WARNING: Conflicting installed APPX package identities detected." -ForegroundColor Yellow
  Write-Host ("Canonical identity: " + $CanonicalIdentity) -ForegroundColor Yellow
  foreach ($pkg in $conflicts) {
    Write-Host ("  " + $pkg.PackageFullName) -ForegroundColor Yellow
  }
  Write-Host ("Uninstall the conflicting package(s), or Windows may launch the wrong " + $AppName + " build.") -ForegroundColor Yellow
}

function Ensure-DevSigningCertificate {
  param(
    [string]$Publisher,
    [bool]$Trust
  )

  function Test-IsAdmin {
    try {
      $id = [Security.Principal.WindowsIdentity]::GetCurrent()
      $p = New-Object Security.Principal.WindowsPrincipal($id)
      return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
      return $false
    }
  }

  function Test-CertInStore {
    param(
      [string]$StoreName,
      [string]$Scope,
      [string]$Thumbprint
    )

    $psPath = "Cert:\\" + $Scope + "\\" + $StoreName
    $found = Get-ChildItem -Path $psPath -ErrorAction SilentlyContinue |
      Where-Object { $_.Thumbprint -eq $Thumbprint } |
      Select-Object -First 1
    return [bool]$found
  }

  function Add-CertToStore {
    param(
      [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
      [string]$StoreName,
      [string]$Scope
    )

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($StoreName, $Scope)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
      $store.Add($Cert)
    } finally {
      $store.Close()
    }
  }

  $existing = Get-ChildItem -Path "Cert:\\CurrentUser\\My" -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq $Publisher -and $_.NotAfter -gt (Get-Date) } |
    Sort-Object -Property NotAfter -Descending |
    Select-Object -First 1

  if (-not $existing) {
    Write-Host ""
    Write-Host "Creating dev code-signing certificate: $Publisher" -ForegroundColor Cyan
    $existing = New-SelfSignedCertificate `
      -Type CodeSigningCert `
      -Subject $Publisher `
      -KeyAlgorithm RSA `
      -KeyLength 2048 `
      -HashAlgorithm SHA256 `
      -CertStoreLocation "Cert:\\CurrentUser\\My" `
      -NotAfter (Get-Date).AddYears(5)
  }

  if ($Trust) {
    $thumb = $existing.Thumbprint

    $currentUserTargets = @(
      @{ Store = "TrustedPeople"; Scope = "CurrentUser"; Label = "CurrentUser\\TrustedPeople" },
      @{ Store = "Root"; Scope = "CurrentUser"; Label = "CurrentUser\\Root" }
    )

    foreach ($t in $currentUserTargets) {
      if (Test-CertInStore -StoreName $t.Store -Scope $t.Scope -Thumbprint $thumb) { continue }
      Write-Host ""
      Write-Host "Trusting dev certificate in $($t.Label)..." -ForegroundColor Cyan
      try {
        Add-CertToStore -Cert $existing -StoreName $t.Store -Scope $t.Scope
      } catch {
        Write-Host "WARNING: Failed to add certificate to $($t.Label): $($_.Exception.Message)" -ForegroundColor Yellow
      }
    }

    $machineTargets = @(
      @{ Store = "TrustedPeople"; Scope = "LocalMachine"; Label = "LocalMachine\\TrustedPeople" },
      @{ Store = "Root"; Scope = "LocalMachine"; Label = "LocalMachine\\Root" }
    )

    $missingMachine = @()
    foreach ($t in $machineTargets) {
      if (-not (Test-CertInStore -StoreName $t.Store -Scope $t.Scope -Thumbprint $thumb)) {
        $missingMachine += $t
      }
    }

    if ($missingMachine.Count -gt 0) {
      if (Test-IsAdmin) {
        foreach ($t in $missingMachine) {
          Write-Host ""
          Write-Host "Trusting dev certificate in $($t.Label)..." -ForegroundColor Cyan
          Add-CertToStore -Cert $existing -StoreName $t.Store -Scope $t.Scope
        }
      } else {
        $safe = ($AppName.ToLowerInvariant() -replace '[^0-9a-z._-]', '')
        if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "app" }
        $cerPath = Join-Path $env:PUBLIC ($safe + "-dev-cert-" + $thumb + ".cer")
        try {
          [IO.File]::WriteAllBytes(
            $cerPath,
            $existing.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
          )

          $elevatedCmd = @"
`$ErrorActionPreference = 'Stop'
`$cerPath = '$cerPath'
if (-not (Test-Path `$cerPath)) { throw 'Missing certificate file: ' + `$cerPath }

function Import-Into([string]`$storeName) {
  try {
    if (Get-Command Import-Certificate -ErrorAction SilentlyContinue) {
      Import-Certificate -FilePath `$cerPath -CertStoreLocation ('Cert:\\LocalMachine\\' + `$storeName) | Out-Null
      return
    }
    throw 'Import-Certificate not available'
  } catch {
    & certutil.exe -addstore -f `$storeName `$cerPath | Out-Null
  }
}

Import-Into 'Root'
Import-Into 'TrustedPeople'
"@

          Write-Host ""
          Write-Host "Requesting admin permission to trust the APPX signing certificate (UAC prompt)..." -ForegroundColor Cyan
          $p = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            $elevatedCmd
          )

          if ($p.ExitCode -ne 0) {
            throw "Elevated certificate import failed with exit code $($p.ExitCode)."
          }
        } finally {
          if (Test-Path $cerPath) { Remove-Item -Force -Path $cerPath -ErrorAction SilentlyContinue }
        }

        foreach ($t in $machineTargets) {
          if (-not (Test-CertInStore -StoreName $t.Store -Scope $t.Scope -Thumbprint $thumb)) {
            throw "Certificate trust missing in $($t.Label). Re-run as Administrator."
          }
        }
      }
    }
  }

  return $existing
}

function Resolve-AppxHook {
  param([string]$ProjectRoot)
  $p = Join-Path $ProjectRoot "scripts\\appx_hook.ps1"
  if (Test-Path $p) { return $p }
  return $null
}

function Invoke-AppxHookStage {
  param(
    [string]$HookScript,
    [string]$Stage,
    [string]$ProjectRoot,
    [string]$AppName,
    [string]$Flutter,
    [string]$Dart,
    [string]$BuildDir,
    [string]$PortableDir,
    [string]$AppxPath
  )

  if ([string]::IsNullOrWhiteSpace($HookScript)) { return }
  if (-not (Test-Path $HookScript)) { return }

  Write-Host ""
  Write-Host "==> Hook: $Stage" -ForegroundColor Cyan

  & $HookScript `
    -Stage $Stage `
    -ProjectRoot $ProjectRoot `
    -AppName $AppName `
    -FlutterPath $Flutter `
    -DartPath $Dart `
    -BuildDir $BuildDir `
    -PortableDir $PortableDir `
    -AppxPath $AppxPath `
    -PortableOnly:$PortableOnly
}

function Get-PubCacheRoot {
  if ($env:PUB_CACHE -and (Test-Path $env:PUB_CACHE)) { return $env:PUB_CACHE }
  return (Join-Path $env:LOCALAPPDATA "Pub\\Cache")
}

function Convert-RootUriToPath {
  param(
    [string]$RootUri,
    [string]$BaseDir
  )

  if ([string]::IsNullOrWhiteSpace($RootUri)) { return $null }
  $u = $RootUri.Trim()

  try {
    if ($u -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
      $uri = [System.Uri]$u
      if ($uri.Scheme -eq "file") { return $uri.LocalPath }
      return $null
    }
  } catch {
    # Not a valid URI; treat as a path below.
  }

  $p = $u
  if (-not [System.IO.Path]::IsPathRooted($p)) {
    if (-not [string]::IsNullOrWhiteSpace($BaseDir)) {
      $p = Join-Path $BaseDir $p
    }
  }
  return $p
}

function Patch-ResolveSymlinksScript {
  param([string]$ScriptPath)

  if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return $false }
  if (-not (Test-Path $ScriptPath)) { return $false }

  try {
    $text = Get-Content -Raw -Path $ScriptPath
  } catch {
    return $false
  }

  if ($text -match '(?m)^\s*\$item\s*=\s*Get-Item\s+-Force\s+\$realPath\s*$') { return $true }

  $patched = $text -replace '(?m)^(\s*\$item\s*=\s*)Get-Item(\s+\$realPath\s*)$', '${1}Get-Item -Force${2}'
  if ($patched -eq $text) { return $false }

  try {
    Set-Content -Path $ScriptPath -Value $patched -Encoding UTF8
    Write-Host ("Patched resolve_symlinks.ps1: " + $ScriptPath) -ForegroundColor DarkGray
    return $true
  } catch {
    Write-Host ("WARNING: Failed to patch resolve_symlinks.ps1: " + $ScriptPath) -ForegroundColor Yellow
    Write-Host ("  " + $_.Exception.Message) -ForegroundColor Yellow
    return $false
  }
}

function Try-Patch-RinfResolveSymlinks {
  param([string]$ProjectRoot)

  $cfg = Join-Path $ProjectRoot ".dart_tool\\package_config.json"
  if (-not (Test-Path $cfg)) { return $false }

  $pkgRootUri = $null
  try {
    $json = Get-Content -Raw -Path $cfg | ConvertFrom-Json
    $pkg = $json.packages | Where-Object { $_.name -eq "rinf" } | Select-Object -First 1
    if ($pkg) { $pkgRootUri = $pkg.rootUri }
  } catch {
    return $false
  }

  if ([string]::IsNullOrWhiteSpace($pkgRootUri)) { return $false }

  $baseDir = Split-Path -Parent $cfg
  $pkgRoot = Convert-RootUriToPath -RootUri $pkgRootUri -BaseDir $baseDir
  $scriptPaths = @()

  if (-not [string]::IsNullOrWhiteSpace($pkgRoot)) {
    $pkgRoot = $pkgRoot.TrimEnd("\\", "/")
    $scriptPaths += (Join-Path $pkgRoot "cargokit\\cmake\\resolve_symlinks.ps1")
  }

  $scriptPaths += (Join-Path $ProjectRoot "windows\\flutter\\ephemeral\\.plugin_symlinks\\rinf\\cargokit\\cmake\\resolve_symlinks.ps1")
  $scriptPaths += (Join-Path $ProjectRoot "linux\\flutter\\ephemeral\\.plugin_symlinks\\rinf\\cargokit\\cmake\\resolve_symlinks.ps1")

  $patchedAny = $false
  foreach ($scriptPath in ($scriptPaths | Select-Object -Unique)) {
    if (Patch-ResolveSymlinksScript -ScriptPath $scriptPath) {
      $patchedAny = $true
    }
  }

  return $patchedAny
}

# --- main ---

$root = $ProjectRoot.Trim()
$AppName = $AppName.Trim()
if ([string]::IsNullOrWhiteSpace($root)) { throw "ProjectRoot is required." }
if ([string]::IsNullOrWhiteSpace($AppName)) { throw "AppName is required." }
if (-not (Test-Path $root)) { throw "ProjectRoot not found: $root" }
Set-Location $root

$flutter = Resolve-Flutter -Provided $FlutterPath
$dart = $null
if (-not $PortableOnly) {
  $dart = Resolve-Dart -Provided $DartPath -ResolvedFlutter $flutter
}

$git = Resolve-GitExe
if (-not $git) {
  Write-Host ""
  Write-Host "WARNING: Git for Windows not found; continuing without it." -ForegroundColor Yellow
  Write-Host "If flutter later fails due to missing git, install it with:" -ForegroundColor Yellow
  Write-Host "  winget install --id Git.Git -e --source winget" -ForegroundColor Yellow
}

Run-Command -Title "flutter pub get" -Exe $flutter -Arguments @("pub", "get")

try { [void](Try-Patch-RinfResolveSymlinks -ProjectRoot $root) } catch { }

try {
  Run-Command -Title "flutter build windows --release" -Exe $flutter -Arguments @("build", "windows", "--release")
} catch {
  $cmakeFiles = Join-Path $root "build\\windows\\x64\\CMakeFiles"
  $cfgYaml = Join-Path $cmakeFiles "CMakeConfigureLog.yaml"
  $errLog = Join-Path $cmakeFiles "CMakeError.log"
  $outLog = Join-Path $cmakeFiles "CMakeOutput.log"

  Write-Host ""
  Write-Host "==> CMake logs (tail)" -ForegroundColor Cyan
  if (Test-Path $cfgYaml) {
    Write-Host $cfgYaml -ForegroundColor DarkGray
    Get-Content -Tail 220 $cfgYaml | Out-Host
  }
  if (Test-Path $errLog) {
    Write-Host $errLog -ForegroundColor DarkGray
    Get-Content -Tail 220 $errLog | Out-Host
  }
  if (Test-Path $outLog) {
    Write-Host $outLog -ForegroundColor DarkGray
    Get-Content -Tail 120 $outLog | Out-Host
  }

  throw
}

$buildDir = Resolve-WindowsRunnerReleaseDir -ProjectRoot $root
$buildDirRel = $buildDir.Substring($root.Length).TrimStart("\\")
Write-Host "Release dir: $buildDirRel" -ForegroundColor DarkGray

# Avoid accidentally packaging old artifacts.
foreach ($pattern in @("*.appx", "*.msix", "*.msixbundle", "*.appinstaller")) {
  Get-ChildItem -Path $buildDir -File -Filter $pattern -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

$hook = Resolve-AppxHook -ProjectRoot $root
Invoke-AppxHookStage -HookScript $hook -Stage "after_windows_build" -ProjectRoot $root -AppName $AppName -Flutter $flutter -Dart $dart -BuildDir $buildDir -PortableDir "" -AppxPath ""

if ($PortableOnly) {
  $portableDir = New-PortableFolder -ProjectRoot $root -ReleaseDir $buildDir -AppName $AppName
  Invoke-AppxHookStage -HookScript $hook -Stage "after_portable_copy" -ProjectRoot $root -AppName $AppName -Flutter $flutter -Dart $dart -BuildDir $buildDir -PortableDir $portableDir -AppxPath ""

  Write-Host ""
  Write-Host "Portable folder: $portableDir" -ForegroundColor Green
  Write-Host "Portable build requested; skipping APPX packaging." -ForegroundColor Yellow
  return
}

# Create AppxManifest/resources/icons in the Release folder (without rebuilding).
$oldPrebuiltEngineVersion = $env:FLUTTER_PREBUILT_ENGINE_VERSION
$pinnedEngineVersion = Get-FlutterPinnedEngineVersion -ResolvedFlutter $flutter
if ([string]::IsNullOrWhiteSpace($oldPrebuiltEngineVersion) -and -not [string]::IsNullOrWhiteSpace($pinnedEngineVersion)) {
  Write-Host ""
  Write-Host ("Using pinned Flutter engine version: " + $pinnedEngineVersion) -ForegroundColor DarkGray
  $env:FLUTTER_PREBUILT_ENGINE_VERSION = $pinnedEngineVersion
}

try {
  Run-Command -Title "dart run msix:build (generate AppxManifest/resources)" -Exe $dart -Arguments @(
    "run", "msix:build", "--build-windows", "false"
  )
} finally {
  if ([string]::IsNullOrWhiteSpace($oldPrebuiltEngineVersion)) {
    Remove-Item Env:FLUTTER_PREBUILT_ENGINE_VERSION -ErrorAction SilentlyContinue
  } else {
    $env:FLUTTER_PREBUILT_ENGINE_VERSION = $oldPrebuiltEngineVersion
  }
}

$outAppx = Join-Path $root ($AppName + ".appx")
$manifest = Join-Path $buildDir "AppxManifest.xml"

if (-not (Test-Path $manifest)) {
  $alt = $null
  try {
    $alt = Get-ChildItem -Path (Join-Path $root "build\\windows") -Recurse -File -Filter "AppxManifest.xml" -ErrorAction SilentlyContinue |
      Sort-Object -Property LastWriteTimeUtc -Descending |
      Select-Object -First 1
  } catch {
    $alt = $null
  }

  if ($alt) {
    $altDir = Split-Path -Parent $alt.FullName
    Write-Host ""
    Write-Host "AppxManifest.xml was generated in a different folder; copying into Release dir..." -ForegroundColor Yellow
    Write-Host "From: $altDir" -ForegroundColor DarkGray
    Copy-Item -Force -Path $alt.FullName -Destination $manifest

    $assetsSrc = Join-Path $altDir "Assets"
    if (Test-Path $assetsSrc) {
      $assetsDst = Join-Path $buildDir "Assets"
      if (Test-Path $assetsDst) { Remove-Item -Recurse -Force -Path $assetsDst -ErrorAction SilentlyContinue }
      Copy-Item -Recurse -Force -Path $assetsSrc -Destination $buildDir
    }

    foreach ($name in @("resources.pri", "priconfig.xml")) {
      $p = Join-Path $altDir $name
      if (Test-Path $p) {
        Copy-Item -Force -Path $p -Destination (Join-Path $buildDir $name)
      }
    }
  }

  if (-not (Test-Path $manifest)) {
    throw "Missing AppxManifest.xml at $manifest (msix:build failed)."
  }
}

$expectedIdentityName = Get-CanonicalAppxIdentityFromPubspec -ProjectRoot $root
$manifestIdentityName = Get-AppxIdentityNameFromManifest -ManifestPath $manifest
if (-not [string]::IsNullOrWhiteSpace($expectedIdentityName)) {
  if ($manifestIdentityName -ne $expectedIdentityName) {
    Write-Host ""
    Write-Host "Forcing APPX identity: $manifestIdentityName -> $expectedIdentityName" -ForegroundColor Cyan
    Set-AppxIdentityNameInManifest -ManifestPath $manifest -IdentityName $expectedIdentityName
    $manifestIdentityName = $expectedIdentityName
  } else {
    Write-Host ""
    Write-Host ("APPX identity: " + $manifestIdentityName) -ForegroundColor DarkGray
  }
} else {
  Write-Host ""
  Write-Host ("APPX identity: " + $manifestIdentityName) -ForegroundColor DarkGray
}

# Keep the Release folder clean (don't bundle msix outputs into the appx).
foreach ($pattern in @("*.msix", "*.msixbundle", "*.appinstaller")) {
  Get-ChildItem -Path $buildDir -File -Filter $pattern -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
}
foreach ($name in @($AppName + ".msix", $AppName + ".msixbundle", $AppName + ".appinstaller")) {
  $p = Join-Path $root $name
  if (Test-Path $p) { Remove-Item -Force -Path $p -ErrorAction SilentlyContinue }
}

# Ensure every build produces a strictly increasing package version so Windows can upgrade in-place.
try {
  $manifestVer = Get-AppxVersionFromManifest -ManifestPath $manifest
  $existingVer = Get-AppxVersionFromAppx -AppxPath $outAppx
  $identityName = Get-AppxIdentityNameFromManifest -ManifestPath $manifest
  $installedVer = Get-InstalledAppxVersion -IdentityName $identityName

  $baselineVer = $existingVer
  if ($installedVer -and ((-not $baselineVer) -or ($installedVer -gt $baselineVer))) {
    $baselineVer = $installedVer
  }

  $targetVer = $manifestVer
  if ($baselineVer -and ($baselineVer -ge $manifestVer)) {
    $targetVer = Increment-AppxVersion -V $baselineVer
  }

  if ($targetVer -ne $manifestVer) {
    Write-Host ""
    Write-Host "Bumping APPX version: $manifestVer -> $targetVer" -ForegroundColor Cyan
    Set-AppxVersionInManifest -ManifestPath $manifest -Version $targetVer
  } else {
    Write-Host ""
    Write-Host "APPX version: $manifestVer" -ForegroundColor DarkGray
  }
} catch {
  Write-Host "WARNING: Failed to auto-bump APPX version: $($_.Exception.Message)" -ForegroundColor Yellow
}

$pubCache = Get-PubCacheRoot
$msixPackage = Get-ChildItem -Path (Join-Path $pubCache "hosted\\pub.dev") -Directory -Filter "msix-*" |
  ForEach-Object {
    $verText = $_.Name.Substring(5)
    try { $ver = [Version]$verText } catch { $ver = [Version]"0.0.0.0" }
    [PSCustomObject]@{ Dir = $_; Ver = $ver }
  } |
  Sort-Object -Property Ver -Descending |
  Select-Object -First 1 |
  Select-Object -ExpandProperty Dir

if (-not $msixPackage) {
  throw "msix package not found in pub cache. Run: flutter pub get"
}

$msixAssets = Join-Path $msixPackage.FullName "lib\\assets"
$toolkit = Join-Path $msixAssets "MSIX-Toolkit\\Redist.x64"
$makeappx = Join-Path $toolkit "MakeAppx.exe"
$signtool = Join-Path $toolkit "signtool.exe"

if (-not (Test-Path $makeappx)) { throw "MakeAppx.exe not found at $makeappx" }
if (-not (Test-Path $signtool)) { throw "signtool.exe not found at $signtool" }

Run-Command -Title "MakeAppx pack" -Exe $makeappx -Arguments @(
  "pack", "/v", "/o", "/d", $buildDir, "/p", $outAppx
)

if (-not (Test-Path $outAppx)) {
  throw "APPX not created: $outAppx"
}

$publisher = Get-AppxPublisherFromManifest -ManifestPath $manifest
$cert = Ensure-DevSigningCertificate -Publisher $publisher -Trust $InstallSigningCertificate

Run-Command -Title "SignTool sign (dev certificate)" -Exe $signtool -Arguments @(
  "sign", "/sha1", $cert.Thumbprint, "/fd", "SHA256", "/a", $outAppx
)

Warn-ConflictingInstalledPackages -CanonicalIdentity $manifestIdentityName -AppName $AppName

Invoke-AppxHookStage -HookScript $hook -Stage "after_appx" -ProjectRoot $root -AppName $AppName -Flutter $flutter -Dart $dart -BuildDir $buildDir -PortableDir "" -AppxPath $outAppx

Write-Host ""
Write-Host "Created: $outAppx" -ForegroundColor Green
