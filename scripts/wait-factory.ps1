[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [int]$TimeoutSeconds = 0,
    [int]$PollMilliseconds = 1000,
    [long]$Cursor = -1,
    [switch]$IncludeOperatorApproval
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "attention-state.ps1")
. (Join-Path $PSScriptRoot "publication-ci.ps1")

$contextText = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize | Out-String).Trim()
if (-not $contextText) { throw "Factory project context returned no data." }
$context = $contextText | ConvertFrom-Json
$PollMilliseconds = [Math]::Max(100, $PollMilliseconds)
$deadline = if ($TimeoutSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($TimeoutSeconds) } else { [DateTime]::MaxValue }
$explicitCursor = $Cursor -ge 0

while ($true) {
    $null = Sync-FactoryPublicationCi -Context $context
    $state = Read-FactoryJson -Path ([string]$context.statePath)
    $config = Read-FactoryJson -Path ([string]$context.configPath)
    $attention = Sync-FactoryAttentionState -Context $context -State $state -Config $config
    $currentRevision = [long](Get-FactoryNestedValue -Target $attention -Name "revision" -Default 0)
    $previousCursor = if ($explicitCursor) {
        $Cursor
    } else {
        [long](Get-FactoryNestedValue -Target $attention -Name "waitAcknowledgedRevision" -Default 0)
    }
    $actions = @($attention.events | Where-Object {
        [long]$_.revision -gt $previousCursor -and
        ($IncludeOperatorApproval -or [bool](Get-FactoryNestedValue -Target $_ -Name "includeInDefaultWait" -Default $true))
    })
    if ($actions.Count -gt 0) {
        if (-not $explicitCursor) {
            $null = Update-FactoryAttentionRecord -Context $context -Mutator {
                param($record)
                Set-FactoryProperty -Target $record -Name "waitAcknowledgedRevision" -Value $currentRevision
            }
        }
        [ordered]@{
            signaled = $true
            timedOut = $false
            detectedAt = Get-FactoryUtcTimestamp
            previousCursor = $previousCursor
            cursor = $currentRevision
            actions = $actions
        } | ConvertTo-Json -Depth 20
        exit 0
    }
    if (-not $explicitCursor -and $currentRevision -gt $previousCursor) {
        $null = Update-FactoryAttentionRecord -Context $context -Mutator {
            param($record)
            Set-FactoryProperty -Target $record -Name "waitAcknowledgedRevision" -Value $currentRevision
        }
    }
    if ([DateTime]::UtcNow -ge $deadline) {
        [ordered]@{
            signaled = $false
            timedOut = $true
            detectedAt = Get-FactoryUtcTimestamp
            previousCursor = $previousCursor
            cursor = $currentRevision
            actions = @()
        } | ConvertTo-Json -Depth 20
        exit 0
    }
    Start-Sleep -Milliseconds $PollMilliseconds
}
