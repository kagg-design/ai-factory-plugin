[CmdletBinding()]
param(
    [string]$TaskName = '',
    [string]$EpicGid = '',
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'rock-cycle.json' }
if (-not $TaskName) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Rock config not found: $ConfigPath" }
    $epicGid = if ($EpicGid) { $EpicGid } else { [string]((Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).epicGid) }
    if ($epicGid -notmatch '^\d+$') { throw "Invalid epicGid in rock config: $ConfigPath" }
    $TaskName = "Rock Orchestrator Cycle $epicGid"
}
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Output "Uninstalled '$TaskName'."
} else {
    Write-Output "Task '$TaskName' is not installed."
}
