[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [int]$TimeoutSeconds = 0,
    [int]$PollMilliseconds = 1000,
    [switch]$IncludeOperatorApproval
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

$contextText = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize | Out-String).Trim()
if (-not $contextText) { throw "Factory project context returned no data." }
$context = $contextText | ConvertFrom-Json
$PollMilliseconds = [Math]::Max(100, $PollMilliseconds)
$deadline = if ($TimeoutSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($TimeoutSeconds) } else { [DateTime]::MaxValue }

while ($true) {
    $state = Read-FactoryJson -Path ([string]$context.statePath)
    $config = Read-FactoryJson -Path ([string]$context.configPath)
    $actions = @(
        Get-FactoryOperatorActionEvents -State $state -Config $config |
            Where-Object { $IncludeOperatorApproval -or [string]$_.audience -ne "human" }
    )
    if ($actions.Count -gt 0) {
        [ordered]@{
            signaled = $true
            timedOut = $false
            detectedAt = Get-FactoryUtcTimestamp
            actions = $actions
        } | ConvertTo-Json -Depth 20
        exit 0
    }
    if ([DateTime]::UtcNow -ge $deadline) {
        [ordered]@{
            signaled = $false
            timedOut = $true
            detectedAt = Get-FactoryUtcTimestamp
            actions = @()
        } | ConvertTo-Json -Depth 20
        exit 0
    }
    Start-Sleep -Milliseconds $PollMilliseconds
}
