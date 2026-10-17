[CmdletBinding()]
param(
    [string]$TaskName = 'Rock Orchestrator Cycle'
)

$ErrorActionPreference = 'Stop'
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "Uninstalled '$TaskName'."
} else {
    Write-Output "Task '$TaskName' is not installed."
}
