#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$d = Get-Disk -Number 1
if ($d.BusType -ne 'USB') { throw "STOP: disco 1 non e USB ($($d.BusType))" }
if ($d.Size -lt 200GB -or $d.Size -gt 260GB) { throw "STOP: dimensione inattesa $($d.Size)" }
if ($d.FriendlyName -notmatch 'External') { throw "STOP: nome inatteso $($d.FriendlyName)" }

Set-Disk -Number 1 -IsReadOnly $false
Set-Disk -Number 1 -IsOffline $false
Clear-Disk -Number 1 -RemoveData -RemoveOEM -Confirm:$false
Initialize-Disk -Number 1 -PartitionStyle GPT
$part = New-Partition -DiskNumber 1 -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $part -FileSystem exFAT -NewFileSystemLabel 'nas' -AllocationUnitSize 4096 -Confirm:$false | Out-Null

$out = Join-Path $PSScriptRoot 'format-ssd-result.txt'
@(
  "OK"
  "Disk 1 $($d.FriendlyName) $([math]::Round($d.Size/1GB,1)) GB"
  "Lettera: $($part.DriveLetter):"
  "FS: exFAT  etichetta: nas"
) | Set-Content -Path $out -Encoding UTF8
Get-Partition -DiskNumber 1 | Format-List | Out-File -Append $out
exit 0
