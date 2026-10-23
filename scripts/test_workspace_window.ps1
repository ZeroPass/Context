param([string]$EvidenceDir = ".buildlog\workspace-window\native")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$evidence = Join-Path $root $EvidenceDir
$work = Join-Path $env:TEMP ("context-width-check-" + [guid]::NewGuid().ToString("N"))
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
$sources = @("windows\runner\workspace_window.cpp", "windows\runner\workspace_window.h", "test\windows_workspace_smoke.cpp", "scripts\test_workspace_window.ps1")
New-Item -ItemType Directory -Force -Path $evidence, $work | Out-Null
$hashes = @{}
foreach ($file in $sources) {
  $hashes[$file] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root $file)).Hash
  if ($file -notlike "*.ps1") { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $work }
}
$compile = 'call "' + $vcvars + '" >nul && cl.exe /nologo /std:c++17 /EHsc /W4 /WX /DUNICODE /D_UNICODE /DNOMINMAX /I. windows_workspace_smoke.cpp workspace_window.cpp user32.lib /Fe:workspace_smoke.exe'
Push-Location $work
try {
  $ErrorActionPreference = "Continue"
  & cmd.exe /d /c $compile 2>&1 | ForEach-Object { $_.ToString() } | Out-File -LiteralPath (Join-Path $evidence "compile.log") -Encoding utf8
  if ($LASTEXITCODE -ne 0) { throw "Workspace compilation failed." }
  & (Join-Path $work "workspace_smoke.exe") 2>&1 | Out-File -LiteralPath (Join-Path $evidence "test.log") -Encoding utf8
  if ($LASTEXITCODE -ne 0) { throw "Workspace width assertion failed." }
  Get-Content -LiteralPath (Join-Path $evidence "test.log")
  $ErrorActionPreference = "Stop"
  $report = @("UTC: $([DateTime]::UtcNow.ToString('o'))", "Compile: cmd.exe /d /c $compile", "Test: $work\workspace_smoke.exe", "Only hidden test-owned windows created; no user windows changed.", "SHA256:")
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
