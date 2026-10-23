param(
  [string]$EvidenceDir = ".buildlog\whiteboard-notifications\native",
  [switch]$SendToast
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$evidence = Join-Path $root $EvidenceDir
$work = Join-Path $env:TEMP ("context-notification-check-" + [guid]::NewGuid().ToString("N"))
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
$sources = @("windows\runner\whiteboard_notifications.cpp", "windows\runner\whiteboard_notifications.h", "test\windows_notification_smoke.cpp", "scripts\test_notifications.ps1")
New-Item -ItemType Directory -Force -Path $evidence, $work | Out-Null
$hashes = @{}
foreach ($file in $sources) {
  $hashes[$file] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)).Hash
  if ($file -notlike "*.ps1") { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $work }
}
$compile = 'call "' + $vcvars + '" >nul && cl.exe /nologo /std:c++17 /EHsc /W4 /WX /DUNICODE /D_UNICODE /DNOMINMAX /I. windows_notification_smoke.cpp whiteboard_notifications.cpp windowsapp.lib /Fe:notification_smoke.exe'
Push-Location $work
try {
  $ErrorActionPreference = "Continue"
  & cmd.exe /d /c $compile 2>&1 | ForEach-Object { $_.ToString() } | Out-File -LiteralPath (Join-Path $evidence "compile.log") -Encoding utf8
  $code = $LASTEXITCODE
  Get-Content -LiteralPath (Join-Path $evidence "compile.log") -Tail 20
  if ($code -ne 0) { throw "Notification compilation failed ($code)." }
  & (Join-Path $work "notification_smoke.exe") 2>&1 | Out-File -LiteralPath (Join-Path $evidence "test.log") -Encoding utf8
  if ($LASTEXITCODE -ne 0) { throw "Unpackaged notification test failed." }
  $ErrorActionPreference = "Stop"
  if ($SendToast) {
    $package = Get-AppxPackage -Name com.zeropass.context
    if (-not $package) { throw "Install Context before running the optional toast test." }
    [xml]$manifest = $package | Get-AppxPackageManifest
    $appId = @($manifest.Package.Applications.Application)[0].Id
    $result = Join-Path $work "packaged-result.txt"
    Invoke-CommandInDesktopPackage -PackageFamilyName $package.PackageFamilyName -AppId $appId -Command (Join-Path $work "notification_smoke.exe") -Args ('"' + $result + '"') -PreventBreakaway
    Start-Sleep -Seconds 3
    if (-not (Test-Path -LiteralPath $result)) { throw "Packaged test did not produce its result." }
    Copy-Item -LiteralPath $result -Destination (Join-Path $evidence "packaged-test.log")
    $text = Get-Content -LiteralPath $result -Raw
    Write-Host $text
    if ($text -notmatch "Show HRESULT: 0" -or $text -notmatch "history: 1") { throw "Native toast/history assertion failed." }
  }
  $report = @("UTC: $([DateTime]::UtcNow.ToString('o'))", "Compile: cmd.exe /d /c $compile", "Test: $work\notification_smoke.exe", "SendToast: $SendToast", "SHA256:")
  foreach ($file in $sources) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)).Hash -ne $hashes[$file]) { throw "Source changed: $file" }
    $report += "$($hashes[$file])  $file"
  }
  foreach ($file in Get-ChildItem -LiteralPath $evidence -Filter "*.log" -File) {
    $report += "$((Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash)  $($file.Name)"
  }
  $report | Set-Content -LiteralPath (Join-Path $evidence "report.txt") -Encoding utf8
} finally {
  Pop-Location
  Remove-Item -LiteralPath $work -Recurse -Force
}
