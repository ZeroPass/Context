@echo off
rem Double-click updater for the Context APPX in this folder.
rem App Installer silently refuses packages opened over a network (UNC) path,
rem so this stages the file to a local temp copy and registers it.
setlocal EnableExtensions
set "ROOT=%~dp0"
set "APPX=%ROOT%Context.appx"
set "VERSION_FILE=%ROOT%Context.appx.version.txt"

if not exist "%APPX%" (
  echo [Context] Context.appx not found next to this script:
  echo   %APPX%
  echo.
  pause
  exit /b 1
)

pushd "%ROOT%" || (
  echo [Context] Could not access folder: %ROOT%
  echo.
  pause
  exit /b 1
)

set "VERSION=unknown"
if exist "%VERSION_FILE%" (
  for /f "usebackq delims=" %%V in ("%VERSION_FILE%") do set "VERSION=%%V"
)
echo [Context] Installing Context.appx version %VERSION% ...
echo.

set "STAGE=%TEMP%\Context-install.appx"
copy /y "%APPX%" "%STAGE%" >nul || (
  echo [Context] Could not stage the package to %STAGE%
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-AppxPackage -Path '%STAGE%'"
if errorlevel 1 (
  echo.
  echo [Context] Install FAILED with exit code %errorlevel%.
  echo If the app is open, close it and run this again.
  echo.
  pause
  exit /b 1
)

del "%STAGE%" >nul 2>&1
echo.
echo [Context] Installed OK. Launch Context from the Start menu.
echo.
pause
