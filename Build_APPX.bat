@echo off
setlocal EnableExtensions

REM Double-click builder for Context on Windows (avoids WSL/UNC build issues).
REM Builds into a real NTFS work dir, then copies `Context.appx` back here.

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

set "PS1=%ROOT%\scripts\windows_build_appx_local.ps1"
if not exist "%PS1%" (
  echo ERROR: Missing script: "%PS1%"
  echo.
  pause
  exit /b 1
)

REM Override these by setting environment variables before launching this .bat:
REM   CONTEXT_WORKDIR, CONTEXT_FLUTTER_DIR, CONTEXT_FLUTTER_VERSION
set "WORKDIR=%TEMP%\context-win"
if not "%CONTEXT_WORKDIR%"=="" set "WORKDIR=%CONTEXT_WORKDIR%"

REM Optional: override Flutter install dir.
REM If unset, the PowerShell wrapper uses a shared deps cache (default: %LOCALAPPDATA%\AppxKit\deps).
set "FLUTTERDIR="
if not "%CONTEXT_FLUTTER_DIR%"=="" set "FLUTTERDIR=%CONTEXT_FLUTTER_DIR%"

set "FLUTTERVER="
if not "%CONTEXT_FLUTTER_VERSION%"=="" set "FLUTTERVER=%CONTEXT_FLUTTER_VERSION%"

set "LOG=%ROOT%\build_appx.log"
del /f /q "%LOG%" >nul 2>&1

echo.
echo == Context APPX build ==
echo Project: "%ROOT%"
echo WorkDir:  "%WORKDIR%"
if not "%FLUTTERDIR%"=="" (
  echo Flutter:  "%FLUTTERDIR%"
) else (
  echo Flutter:  (auto; shared deps in %LOCALAPPDATA%\AppxKit\deps)
)
if not "%FLUTTERVER%"=="" echo Version:  "%FLUTTERVER%"
echo.

REM `cmd.exe` cannot `cd` into a UNC path (e.g. \\wsl.localhost\...). `pushd` handles it by mapping a temp drive.
pushd "%ROOT%" >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo ERROR: Failed to enter project folder: "%ROOT%"
  echo.
  pause
  exit /b 1
)

if "%FLUTTERVER%"=="" (
  if "%FLUTTERDIR%"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$ErrorActionPreference='Continue';" ^
      "$log='%LOG%';" ^
      "try { & '%PS1%' -WorkDir '%WORKDIR%' -CleanWorkDir *>&1 | Tee-Object -FilePath $log } catch { $_ | Out-String | Tee-Object -FilePath $log -Append | Out-Host; exit 1 }"
  ) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$ErrorActionPreference='Continue';" ^
      "$log='%LOG%';" ^
      "try { & '%PS1%' -WorkDir '%WORKDIR%' -FlutterInstallDir '%FLUTTERDIR%' -CleanWorkDir *>&1 | Tee-Object -FilePath $log } catch { $_ | Out-String | Tee-Object -FilePath $log -Append | Out-Host; exit 1 }"
  )
) else (
  if "%FLUTTERDIR%"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$ErrorActionPreference='Continue';" ^
      "$log='%LOG%';" ^
      "try { & '%PS1%' -WorkDir '%WORKDIR%' -FlutterVersion '%FLUTTERVER%' -CleanWorkDir *>&1 | Tee-Object -FilePath $log } catch { $_ | Out-String | Tee-Object -FilePath $log -Append | Out-Host; exit 1 }"
  ) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$ErrorActionPreference='Continue';" ^
      "$log='%LOG%';" ^
      "try { & '%PS1%' -WorkDir '%WORKDIR%' -FlutterInstallDir '%FLUTTERDIR%' -FlutterVersion '%FLUTTERVER%' -CleanWorkDir *>&1 | Tee-Object -FilePath $log } catch { $_ | Out-String | Tee-Object -FilePath $log -Append | Out-Host; exit 1 }"
  )
)

set "CODE=%ERRORLEVEL%"

if "%CODE%"=="0" (
  REM Print resulting APPX identity + version, and persist the version.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression.FileSystem;" ^
    "$p=Join-Path '%ROOT%' 'Context.appx';" ^
    "if (-not (Test-Path $p)) { Write-Host 'APPX not found: ' $p -ForegroundColor Yellow; exit 0 }" ^
    "$z=[IO.Compression.ZipFile]::OpenRead($p);" ^
    "try { $e=$z.Entries | Where-Object { $_.FullName -ieq 'AppxManifest.xml' } | Select-Object -First 1; if (-not $e) { throw 'AppxManifest.xml not found in package.' }" ^
    "  $r=New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8, $true);" ^
    "  try { [xml]$x=$r.ReadToEnd() } finally { $r.Close() }" ^
    "  $ns=New-Object Xml.XmlNamespaceManager($x.NameTable); $ns.AddNamespace('a',$x.DocumentElement.NamespaceURI);" ^
    "  $id=$x.SelectSingleNode('/a:Package/a:Identity',$ns);" ^
    "  $name=if ($id) { $id.GetAttribute('Name') } else { '' };" ^
    "  $ver=if ($id) { $id.GetAttribute('Version') } else { '' };" ^
    "  if ([string]::IsNullOrWhiteSpace($name)) { throw 'Identity name not found in AppxManifest.xml.' }" ^
    "  if ([string]::IsNullOrWhiteSpace($ver)) { throw 'Version not found in AppxManifest.xml.' }" ^
    "  Write-Host ('Built Context.appx identity: ' + $name) -ForegroundColor Green;" ^
    "  Write-Host ('Built Context.appx version: ' + $ver) -ForegroundColor Green;" ^
    "  Set-Content -Path (Join-Path '%ROOT%' 'Context.appx.version.txt') -Encoding ASCII -Value $ver" ^
    "} finally { $z.Dispose() }"
)

popd >nul 2>&1

echo.
echo Exit code: %CODE%
echo Log: "%LOG%"
echo.
if "%CONTEXT_NO_PAUSE%"=="" pause
exit /b %CODE%
