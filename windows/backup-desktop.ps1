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

Write-Info ""
Write-Info "Backup Desktop -> $Dest"
Write-Info "Origine: $Desktop"
Connect-Nas
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

Write-Info ""
Write-Info "Fatto. Codice robocopy: $code"
Write-Info "Log: $Log"
exit 0
