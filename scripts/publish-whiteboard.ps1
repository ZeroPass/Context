param(
  [string]$Title = "",
  [string]$Provider = "",
  [string]$File = "",
  [switch]$Init,
  [switch]$Prune
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $File) { $File = Join-Path $root "whiteboard.md" }
$target = Join-Path $env:LOCALAPPDATA "AppxKit\deps\context-whiteboard-target"
& cargo build --quiet --locked --release --manifest-path (Join-Path $root "native\whiteboard_writer\Cargo.toml") --target-dir $target
if ($LASTEXITCODE -ne 0) { throw "Could not build Whiteboard publisher." }
function Quote([string]$Value) {
  '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
$arguments = @("--file", $File, "--title", $Title, "--provider", $Provider)
if ($Init) { $arguments += "--init" }
if ($Prune) { $arguments += "--prune" }
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $target "release\context-whiteboard.exe"
$info.Arguments = ($arguments | ForEach-Object { Quote $_ }) -join ' '
$info.WorkingDirectory = (Get-Location).ProviderPath
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
$info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
$process = New-Object Diagnostics.Process
$process.StartInfo = $info
$lines = @($input | ForEach-Object { $_.ToString() })
try {
  if (-not $process.Start()) { throw "Could not start publisher." }
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($lines -join "`n"))
  $stdin = $process.StandardInput.BaseStream
  $stdin.Write($bytes, 0, $bytes.Length)
  $stdin.Close()
  $process.WaitForExit()
  $out = $stdout.GetAwaiter().GetResult()
  $err = $stderr.GetAwaiter().GetResult()
  if ($process.ExitCode -ne 0) { throw "Whiteboard publication failed: $err" }
  $out.TrimEnd()
} finally { $process.Dispose() }
