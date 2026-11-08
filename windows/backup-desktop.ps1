#Requires -Version 5.1
param(
  [string]$Nas = 'mariarosaria',
  [string]$Share = 'nas',
  [string]$User = $(if ($env:NASPI_USER) { $env:NASPI_USER } else { '' }),
  [string]$Password = $(if ($env:NASPI_PASS) { $env:NASPI_PASS } else { '' }),
  [switch]$Mirror,
  [switch]$Silent
)

$ErrorActionPreference = 'Stop'
$Desktop = [Environment]::GetFolderPath('Desktop')
$Unc = "\\$Nas\$Share"
$Dest = Join-Path $Unc "backup\$env:COMPUTERNAME\Desktop"
$LogDir = Join-Path $env:LOCALAPPDATA 'naspi'
$Log = Join-Path $LogDir 'backup-desktop.log'

function Write-Info([string]$m) {
  if (-not $Silent) { Write-Host $m }
}

function Write-Brand {
  if ($Silent) { return }
  $line = '-' * 56
  Write-Host ''
  Write-Host '  V E R G E N' -ForegroundColor Cyan -NoNewline
  Write-Host '   T E C H N O L O G Y' -ForegroundColor White
  Write-Host '  NASPI' -ForegroundColor Blue -NoNewline
  Write-Host '  -  Backup del Desktop sul NAS' -ForegroundColor Gray
  Write-Host "  $line" -ForegroundColor DarkBlue
}

function Write-Step([string]$label, [string]$value) {
  if ($Silent) { return }
  Write-Host ('    {0,-10}' -f $label) -ForegroundColor DarkGray -NoNewline
  Write-Host " $value"
}

function Write-Result([bool]$good, [string]$m) {
  if ($Silent) { return }
  if ($good) { Write-Host "    [OK] $m" -ForegroundColor Green }
  else { Write-Host "    [!!] $m" -ForegroundColor Yellow }
}

function Connect-Nas {
  if (Test-Path -LiteralPath $Unc) { return }
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

  $map = {
    param($u, $p)
    if ($u) {
      cmd /c "net use `"$Unc`" /user:$u `"$p`" /persistent:yes" | Out-Null
    } else {
      cmd /c "net use `"$Unc`" /persistent:yes" | Out-Null
    }
    return (Test-Path -LiteralPath $Unc)
  }

  if (& $map $null $null) { return }

  if (-not $User -and -not $Silent) { $script:User = Read-Host 'Utente NAS (vuoto = ospite)' }
  if ($User -and -not $Password -and -not $Silent) {
    $sec = Read-Host 'Password NAS' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $script:Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }

  if (-not (& $map $User $Password)) {
    throw "NAS non raggiungibile: $Unc  (PC e Pi sulla stessa rete, o Tailscale attivo)"
  }
}

if (-not (Test-Path -LiteralPath $Desktop)) {
  throw "Desktop non trovato: $Desktop"
}

Write-Brand
Write-Step 'Origine' $Desktop
Write-Step 'Destinazione' $Dest
Write-Step 'Modalita' $(if ($Mirror) { 'specchio (/MIR: elimina sul NAS cio che non esiste piu)' } else { 'copia (non elimina nulla)' })
Write-Info ''
Connect-Nas
Write-Result $true "NAS raggiungibile: $Unc"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
$rcArgs = @(
  $Desktop, $Dest,
  '/E', '/COPY:DAT', '/DCOPY:DAT',
  '/R:3', '/W:5', '/XJ', '/FFT', '/DST',
  '/NP', '/TEE', "/LOG+:$Log"
)
if ($Mirror) { $rcArgs += '/MIR' }

& $robocopy @rcArgs
$code = $LASTEXITCODE
if ($code -ge 8) {
  throw "Robocopy errore $code  (log: $Log)"
}

Write-Info ''
if ($code -le 1) {
  Write-Result $true "Backup completato (robocopy $code)"
} else {
  Write-Result $true "Backup completato con differenze segnalate (robocopy $code)"
}
Write-Step 'Log' $Log
if (-not $Silent) {
  Write-Host ''
  Write-Host '  VERGEN TECHNOLOGY' -ForegroundColor Cyan -NoNewline
  Write-Host '  -  NASPI' -ForegroundColor DarkGray
  Write-Host ''
}
exit 0
