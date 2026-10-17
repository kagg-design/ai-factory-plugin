[CmdletBinding()]
param(
    [string]$TaskName = 'Rock Orchestrator Cycle',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'rock-cycle.json')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Rock config not found: $ConfigPath" }
$scriptPath = Join-Path $PSScriptRoot 'rock-cycle.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Rock launcher not found: $scriptPath" }
$hostPath = (Get-Process -Id $PID).Path
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $hostPath -Argument (
    '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $scriptPath, ([IO.Path]::GetFullPath($ConfigPath))
)
$trigger = New-ScheduledTaskTrigger -Daily -At '00:00'
$trigger.Repetition = New-CimInstance -ClientOnly -Namespace 'root/Microsoft/Windows/TaskScheduler' `
    -ClassName 'MSFT_TaskRepetitionPattern' -Property @{
        Interval = 'PT30M'
        Duration = 'P1D'
        StopAtDurationEnd = $false
    }
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel LeastPrivilege
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Output "Installed '$TaskName' for $user (interactive logon, every 30 minutes)."
