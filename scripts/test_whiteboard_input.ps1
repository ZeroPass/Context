param([string]$EvidenceDir = '.buildlog\whiteboard-drop\native')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$evidence = Join-Path $root $EvidenceDir
$work = Join-Path $env:TEMP ('context-input-check-' + [guid]::NewGuid().ToString('N'))
$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$include = Join-Path $env:LOCALAPPDATA 'AppxKit\deps\flutter\bin\cache\artifacts\engine\windows-x64\cpp_client_wrapper\include'
$sources = @('windows\runner\whiteboard_input.cpp', 'windows\runner\whiteboard_input.h', 'test\windows_whiteboard_input_smoke.cpp', 'scripts\test_whiteboard_input.ps1')
New-Item -ItemType Directory -Force -Path $evidence, $work | Out-Null
$hashes = @{}
foreach ($file in $sources) {
  $hashes[$file] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)).Hash
  if ($file -notlike '*.ps1') { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $work }
}
$compile = 'call "' + $vcvars + '" >nul && cl.exe /nologo /std:c++17 /EHsc /W4 /WX /DUNICODE /D_UNICODE /DNOMINMAX /I. /I"' + $include + '" windows_whiteboard_input_smoke.cpp whiteboard_input.cpp user32.lib shell32.lib ole32.lib uuid.lib /Fe:input_smoke.exe'
Push-Location $work
try {
  $ErrorActionPreference = 'Continue'
  & cmd.exe /d /c $compile 2>&1 | ForEach-Object { $_.ToString() } | Out-File (Join-Path $evidence 'compile.log') -Encoding utf8
  $code = $LASTEXITCODE
  Get-Content (Join-Path $evidence 'compile.log') -Tail 20
  if ($code -ne 0) { throw "Compilation failed ($code)" }
  & (Join-Path $work 'input_smoke.exe') 2>&1 | Out-File (Join-Path $evidence 'test.log') -Encoding utf8
  if ($LASTEXITCODE -ne 0) { throw 'Input smoke failed' }
  Get-Content (Join-Path $evidence 'test.log')
  $ErrorActionPreference = 'Stop'
  $report = @("UTC: $([DateTime]::UtcNow.ToString('o'))", "Compile: cmd.exe /d /c $compile", "Test: $work\input_smoke.exe", 'SHA256:')
  foreach ($file in $sources) {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)).Hash -ne $hashes[$file]) { throw "Source changed: $file" }
    $report += "$($hashes[$file]) $file"
  }
  foreach ($file in @('compile.log', 'test.log')) { $report += "$((Get-FileHash -Algorithm SHA256 (Join-Path $evidence $file)).Hash) $file" }
  $report | Set-Content (Join-Path $evidence 'report.txt') -Encoding utf8
} finally { Pop-Location }
