[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Repository, [string]$TaskName = 'Factory weekly metrics')
$ErrorActionPreference = 'Stop'
$repositoryPath = (Resolve-Path -LiteralPath $Repository).Path
$scriptPath = Join-Path $PSScriptRoot 'factory-metrics.ps1'
. (Join-Path $PSScriptRoot 'scripts\factory-common.ps1')
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Repository', $repositoryPath, '-Post')
$hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $hostPath -Argument ((@($arguments | ForEach-Object { ConvertTo-FactoryWindowsArgument ([string]$_) })) -join ' ')
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '09:00'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Output "Installed '$TaskName': Mondays at 09:00 local, with -Post."
