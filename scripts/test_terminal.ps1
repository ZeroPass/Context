param(
  [string]$EvidenceDir = ".buildlog\terminal-launch\native",
  [switch]$OpenTestTabs,
  [switch]$BrokerSmoke
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$evidence = Join-Path $root $EvidenceDir
$work = Join-Path $env:TEMP ("context-terminal-check-" + [guid]::NewGuid().ToString("N"))
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
$sources = @("windows\runner\session_terminal.cpp", "windows\runner\session_terminal.h", "test\windows_terminal_smoke.cpp", "scripts\test_terminal.ps1")
$sources += @("windows\runner\terminal_broker.cpp", "windows\runner\terminal_broker.h", "windows\runner\terminal_probe.h.in", "scripts\probe-terminal-tabs.ps1")
New-Item -ItemType Directory -Force -Path $evidence, $work | Out-Null
$hashes = @{}
foreach ($file in $sources) {
  $hashes[$file] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)).Hash
  if ($file -like "*.cpp" -or $file -like "*.h") { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $work }
}
$probeHeader = (Get-Content -LiteralPath (Join-Path $root "windows\runner\terminal_probe.h.in") -Raw).Replace('@CONTEXT_TERMINAL_PROBE_SCRIPT@', (Get-Content -LiteralPath (Join-Path $root "scripts\probe-terminal-tabs.ps1") -Raw))
$probeHeader | Set-Content -LiteralPath (Join-Path $work 'terminal_probe.h') -Encoding utf8
$compile = 'call "' + $vcvars + '" >nul && cl.exe /nologo /std:c++17 /EHsc /W4 /WX /DUNICODE /D_UNICODE /DNOMINMAX /DCONTEXT_BROKER_TESTS /I. windows_terminal_smoke.cpp session_terminal.cpp terminal_broker.cpp shell32.lib advapi32.lib user32.lib ole32.lib crypt32.lib /Fe:terminal_smoke.exe'
Push-Location $work
try {
  $ErrorActionPreference = "Continue"
  & cmd.exe /d /c $compile 2>&1 | ForEach-Object { $_.ToString() } | Out-File -LiteralPath (Join-Path $evidence "compile.log") -Encoding utf8
  $code = $LASTEXITCODE
  Get-Content -LiteralPath (Join-Path $evidence "compile.log") -Tail 20
  if ($code -ne 0) { throw "Terminal compilation failed ($code)." }
  $testArguments = @()
  if ($BrokerSmoke) { $testArguments = @('--broker-smoke') }
  if ($OpenTestTabs) {
    $live = Join-Path $evidence "live"
    New-Item -ItemType Directory -Force -Path $live | Out-Null
    $linux = $live.Replace("\\wsl.localhost\Ubuntu-24.04", "").Replace("\", "/")
    if (-not $linux.StartsWith("/home/luka/codex-out/Context/.buildlog/")) {
      throw "Live test requires the known private WSL evidence folder."
    }
    foreach ($name in @("tab1.txt", "tab2.txt")) {
      $old = Join-Path $live $name
      if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old }
    }
    $before = @(Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $settingsPath = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    $terminal = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $profile = @($terminal.profiles.list | Where-Object {
      $_.name -like "Ubuntu*" -and -not $_.hidden
    })[0]
    if (-not $profile.guid) { throw "Ubuntu profile missing for live test." }
    $testArguments = @("--open-test-tabs", $linux, $profile.guid)
  }
  & (Join-Path $work "terminal_smoke.exe") @testArguments 2>&1 | Out-File -LiteralPath (Join-Path $evidence "test.log") -Encoding utf8
  if ($LASTEXITCODE -ne 0) { throw "Terminal assertion failed." }
  Get-Content -LiteralPath (Join-Path $evidence "test.log")
  $ErrorActionPreference = "Stop"
  if ($OpenTestTabs) {
    # Allow cold WSL startup on a busy desktop without a polling loop.
    Start-Sleep -Seconds 45
    $first = @(Get-Content -LiteralPath (Join-Path $live "tab1.txt"))
    $second = @(Get-Content -LiteralPath (Join-Path $live "tab2.txt"))
    if ($first.Count -ne 5 -or $second.Count -ne 5) { throw "WSL payload did not complete." }
    if ($first[0] -ne $linux -or $second[0] -ne $linux) { throw "WSL cwd mismatch." }
    if ($first[2] -ne 'a "literal"; argument' -or $second[2] -ne $first[2]) { throw "Shell quoting mismatch." }
    if (-not $first[1] -or -not $second[1] -or $first[1] -eq $second[1]) { throw "Expected two distinct Terminal tabs." }
    if ($first[3] -ne "Ubuntu-24.04" -or $second[3] -ne "Ubuntu-24.04") { throw "Not an Ubuntu session." }
    if ($first[4] -ne $profile.guid -or $second[4] -ne $profile.guid) { throw "Ubuntu Terminal profile was not applied." }
    $after = @(Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if ($before.Count -gt 0 -and @($after | Where-Object { $_ -notin $before }).Count -gt 0) { throw "Created a new Terminal process instead of reusing one." }
    [pscustomobject]@{BeforePids=$before; AfterPids=$after; Tab1=$first; Tab2=$second} |
      ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence "live-tabs.log") -Encoding utf8
  }
  $report = @("UTC: $([DateTime]::UtcNow.ToString('o'))", "Compile: cmd.exe /d /c $compile", "Test: $work\terminal_smoke.exe $($testArguments -join ' ')", "OpenTestTabs: $OpenTestTabs", "Administrator restart/UAC flow not run.", "SHA256:")
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
  try { Remove-Item -LiteralPath $work -Recurse -Force }
  catch { Write-Warning "Temporary test folder is still in use: $work" }
}
