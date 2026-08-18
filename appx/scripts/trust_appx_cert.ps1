param(
  # Path to the signed APPX.
  [string]$AppxPath = "",

  # If AppxPath is empty, these are used to derive it as:
  #   <ProjectRoot>\<AppName>.appx
  [string]$ProjectRoot = "",
  [string]$AppName = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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
    [string]$Thumbprint
  )
  $psPath = "Cert:\\LocalMachine\\" + $StoreName
  $found = Get-ChildItem -Path $psPath -ErrorAction SilentlyContinue |
    Where-Object { $_.Thumbprint -eq $Thumbprint } |
    Select-Object -First 1
  return [bool]$found
}

function Add-CertToLocalMachineStore {
  param(
    [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
    [string]$StoreName
  )
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($StoreName, "LocalMachine")
  $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  try {
    $store.Add($Cert)
  } finally {
    $store.Close()
  }
}

if ([string]::IsNullOrWhiteSpace($AppxPath)) {
  $ProjectRoot = $ProjectRoot.Trim()
  $AppName = $AppName.Trim()
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or [string]::IsNullOrWhiteSpace($AppName)) {
    throw @"
AppxPath was not provided.

Provide either:
  -AppxPath C:\path\to\App.appx

Or:
  -ProjectRoot C:\path\to\project -AppName App
"@
  }
  $AppxPath = Join-Path $ProjectRoot ($AppName + ".appx")
}

$AppxPath = (Resolve-Path -Path $AppxPath).Path
if (-not (Test-Path $AppxPath)) { throw "APPX not found: $AppxPath" }

if (-not (Test-IsAdmin)) {
  throw @"
This script must be run from an elevated PowerShell (Run as Administrator).

It adds the APPX signing certificate to:
  - LocalMachine\\Root
  - LocalMachine\\TrustedPeople

Without this, APPX install can fail with 0x800B0109 / 0x800B010A.
"@
}

$sig = Get-AuthenticodeSignature -FilePath $AppxPath
$cert = $sig.SignerCertificate
if (-not $cert) { throw "No signer certificate found in: $AppxPath" }

$thumb = $cert.Thumbprint
Write-Host ""
Write-Host "Signer certificate thumbprint: $thumb" -ForegroundColor Cyan

foreach ($storeName in @("Root", "TrustedPeople")) {
  if (Test-CertInStore -StoreName $storeName -Thumbprint $thumb) {
    Write-Host "Already trusted in LocalMachine\\$storeName" -ForegroundColor DarkGray
    continue
  }
  Write-Host "Trusting in LocalMachine\\$storeName..." -ForegroundColor Cyan
  Add-CertToLocalMachineStore -Cert $cert -StoreName $storeName
}

Write-Host ""
Write-Host "OK: certificate trusted for APPX installation." -ForegroundColor Green
