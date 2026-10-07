param(
  [string]$EvidenceDir = ".buildlog\clipboard-fix\native",
  [string]$SessionCommand = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$evidence = Join-Path $root $EvidenceDir
$work = Join-Path $env:TEMP ("context-clipboard-check-" + [guid]::NewGuid().ToString("N"))
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path -LiteralPath $vcvars)) { throw "C++ toolchain missing: $vcvars" }
$sources = @("windows\runner\clipboard_writer.cpp", "windows\runner\clipboard_writer.h", "test\windows_clipboard_smoke.cpp", "scripts\test_clipboard.ps1")
$hashes = @{}
$oldCommand = $env:CONTEXT_CLIPBOARD_TEST_COMMAND
New-Item -ItemType Directory -Force -Path $evidence, $work | Out-Null
foreach ($file in $sources) {
  $hashes[$file] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)).Hash
}
foreach ($file in $sources | Where-Object { $_ -notlike "*.ps1" }) {
  Copy-Item -LiteralPath (Join-Path $root $file) -Destination $work
}
$compile = 'call "' + $vcvars + '" >nul && cl.exe /nologo /std:c++17 /EHsc /W4 /WX /DUNICODE /D_UNICODE /DNOMINMAX /I. windows_clipboard_smoke.cpp clipboard_writer.cpp user32.lib /Fe:clipboard_smoke.exe'
Push-Location $work
try {
  if ($SessionCommand) { $env:CONTEXT_CLIPBOARD_TEST_COMMAND = $SessionCommand }
  $ErrorActionPreference = "Continue"
  & cmd.exe /d /c $compile 2>&1 | ForEach-Object { $_.ToString() } | Out-File -LiteralPath (Join-Path $evidence "compile.log") -Encoding utf8
  $code = $LASTEXITCODE
  Get-Content -LiteralPath (Join-Path $evidence "compile.log") -Tail 20
  if ($code -ne 0) { throw "Native clipboard compilation failed ($code)." }
  & (Join-Path $work "clipboard_smoke.exe") 2>&1 | ForEach-Object { $_.ToString() } | Out-File -LiteralPath (Join-Path $evidence "test.log") -Encoding utf8
  $code = $LASTEXITCODE
  Get-Content -LiteralPath (Join-Path $evidence "test.log") -Tail 20
  if ($code -ne 0) { throw "Native clipboard test failed ($code). No interactive clipboard fallback is permitted." }
  $ErrorActionPreference = "Stop"
  $report = @("UTC: $([DateTime]::UtcNow.ToString('o'))", "Result: native clipboard test passed", "Reported command supplied: $([bool]$SessionCommand)", "Compile: cmd.exe /d /c $compile", "Test: $work\clipboard_smoke.exe", "SHA256:")
  foreach ($file in $sources) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)).Hash -ne $hashes[$file]) {
      throw "Source changed during native validation: $file"
    }
    $report += "$($hashes[$file])  $file"
  }
  foreach ($file in @("compile.log", "test.log")) {
    $report += "$((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $evidence $file)).Hash)  $file"
  }
  $report | Set-Content -LiteralPath (Join-Path $evidence "report.txt") -Encoding utf8
} finally {
  $env:CONTEXT_CLIPBOARD_TEST_COMMAND = $oldCommand
  Pop-Location
  Remove-Item -LiteralPath $work -Recurse -Force
}
