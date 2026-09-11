[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [ValidateSet("scan", "dispatch", "status")][string]$Action = "dispatch",
    [string]$CodexCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "attention-state.ps1")
. (Join-Path $PSScriptRoot "codex-runtime.ps1")
. (Join-Path $PSScriptRoot "codex-orchestrator.ps1")

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) | ConvertFrom-Json
$state = Read-FactoryJson -Path ([string]$context.statePath)
$config = Read-FactoryJson -Path ([string]$context.configPath)
$attention = Sync-FactoryAttentionState -Context $context -State $state -Config $config
$currentRevision = [long](Get-FactoryNestedValue -Target $attention -Name "revision" -Default 0)
$acknowledgedRevision = [long](Get-FactoryNestedValue -Target $attention -Name "orchestratorAcknowledgedRevision" -Default 0)
$activeKeys = @((Get-FactoryNestedValue -Target $attention -Name "activeKeys" -Default @()) | ForEach-Object { [string]$_ })
$pending = @($attention.events | Where-Object {
    [long]$_.revision -gt $acknowledgedRevision -and
    [bool]$_.aiActionable -and
    $activeKeys -contains [string]$_.key
})
$human = @($attention.events | Where-Object {
    [long]$_.revision -gt $acknowledgedRevision -and
    [bool]$_.humanDecision -and
    $activeKeys -contains [string]$_.key
})

if ($Action -ne "dispatch") {
    [ordered]@{
        revision = $currentRevision
        orchestratorAcknowledgedRevision = $acknowledgedRevision
        pendingAiActions = $pending
        pendingHumanDecisions = $human
        dispatch = Get-FactoryNestedValue -Target $attention -Name "dispatch"
        path = Get-FactoryAttentionPath -Context $context
    } | ConvertTo-Json -Depth 30
    return
}

$bridgeEnabled = [bool](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $config -Name "orchestrator") -Name "attentionBridge" -Default $true)
$runtime = [string](Get-FactoryNestedValue -Target $config -Name "workerAgent" -Default "claude")
if (-not $bridgeEnabled -or $runtime -ne "codex") {
    [ordered]@{
        revision = $currentRevision; dispatched = $false; acknowledged = $false
        pendingAiActionCount = $pending.Count
        reason = if (-not $bridgeEnabled) { "attention bridge disabled" } else { "Codex orchestrator is not selected" }
    } | ConvertTo-Json -Depth 10
    return
}

if ($pending.Count -eq 0) {
    if ($currentRevision -gt $acknowledgedRevision) {
        $attention = Update-FactoryAttentionRecord -Context $context -Mutator {
            param($record)
            Set-FactoryProperty -Target $record -Name "orchestratorAcknowledgedRevision" -Value $currentRevision
        }
    }
    [ordered]@{ revision = $currentRevision; dispatched = $false; acknowledged = $true; pendingAiActionCount = 0; reason = "no new AI-actionable edge" } | ConvertTo-Json
    return
}

$dispatchRecord = Get-FactoryNestedValue -Target $attention -Name "dispatch"
$retryAfter = ConvertFrom-FactoryRoundtripTimestamp -Value (Get-FactoryNestedValue -Target $dispatchRecord -Name "retryAfter" -Default "")
if ([bool]$retryAfter.success -and [DateTime]::UtcNow -lt ([DateTime]$retryAfter.value)) {
    [ordered]@{ revision = $currentRevision; dispatched = $false; acknowledged = $false; pendingAiActionCount = $pending.Count; reason = "dispatch retry backoff is active" } | ConvertTo-Json
    return
}

$identityPath = Join-Path ([string]$context.projectData) "codex-orchestrator-session.json"
if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
    throw "Codex attention bridge has no saved orchestrator identity: $identityPath"
}
$identity = Read-FactoryJson -Path $identityPath
$threadId = [string](Get-FactoryNestedValue -Target $identity -Name "sessionId" -Default "")
if (-not $threadId -or [string](Get-FactoryNestedValue -Target $identity -Name "backend" -Default "") -ne "shared-app-server") {
    throw "Codex attention bridge requires a saved shared-app-server orchestrator thread."
}
$CodexCommand = Resolve-FactoryCodexCommand -Config $config -ExplicitCommand $CodexCommand
$server = Get-FactoryCodexSharedServerStatus -CodexCommand $CodexCommand -RuntimeHome ([string]$context.runtimeHome) -Probe
if (-not [bool]$server.healthy) {
    throw "Codex attention bridge cannot reach the Factory-managed app-server. Run 'factory codex-server status'."
}

$previousAcknowledgement = $acknowledgedRevision
$claimToken = [Guid]::NewGuid().ToString("N")
$claimedRevision = $currentRevision
$claimedEvents = @($pending | Where-Object { [long]$_.revision -le $claimedRevision })
$attention = Update-FactoryAttentionRecord -Context $context -Mutator {
    param($record)
    Set-FactoryProperty -Target $record -Name "orchestratorAcknowledgedRevision" -Value $claimedRevision
    Set-FactoryProperty -Target $record -Name "dispatch" -Value ([pscustomobject][ordered]@{
        token = $claimToken
        status = "starting"
        fromRevision = $previousAcknowledgement + 1
        throughRevision = $claimedRevision
        eventRevisions = @($claimedEvents | ForEach-Object { [long]$_.revision })
        startedAt = Get-FactoryUtcTimestamp
        turnId = $null
        error = $null
        retryAfter = $null
    })
}

$eventLines = @($claimedEvents | ForEach-Object {
    "- revision $([long]$_.revision): $([string]$_.kind) / $([string]$_.taskId) / $([string]$_.title)`n  Reason: $([string]$_.reason)`n  Suggested command: $([string]$_.command)"
})
$prompt = @"
Factory attention bridge detected new AI-actionable state through revision $claimedRevision.
Load the factory skill explicitly, reconcile current native state, and handle these events autonomously within the canonical protocol. Do not approve an awaiting-review task unless the persisted auto-go policy explicitly produced an auto-go event. If an event now requires a human decision, explain the decision and stop instead of guessing.

$($eventLines -join [Environment]::NewLine)

This notification is edge-triggered and already acknowledged by revision. Do not create another wake or edit private state directly.
"@.Trim()

try {
    $turn = Start-FactoryCodexContinuationTurn `
        -CodexCommand $CodexCommand `
        -RuntimeHome ([string]$context.runtimeHome) `
        -Endpoint ([string]$server.endpoint) `
        -RepositoryRoot ([string]$context.repositoryRoot) `
        -ThreadId $threadId `
        -Prompt $prompt
    $turnId = [string]$turn.turnId
    $attention = Update-FactoryAttentionRecord -Context $context -Mutator {
        param($record)
        $currentDispatch = Get-FactoryNestedValue -Target $record -Name "dispatch"
        if ([string](Get-FactoryNestedValue -Target $currentDispatch -Name "token" -Default "") -eq $claimToken) {
            Set-FactoryProperty -Target $currentDispatch -Name "status" -Value "acknowledged"
            Set-FactoryProperty -Target $currentDispatch -Name "turnId" -Value $turnId
            Set-FactoryProperty -Target $currentDispatch -Name "acknowledgedAt" -Value (Get-FactoryUtcTimestamp)
        }
    }
    [ordered]@{
        revision = $claimedRevision; dispatched = $true; acknowledged = $true
        threadId = $threadId; turnId = $turnId; eventRevisions = @($claimedEvents | ForEach-Object { [long]$_.revision })
    } | ConvertTo-Json -Depth 20
} catch {
    $failure = $_.Exception.Message
    $retryAt = [DateTime]::UtcNow.AddSeconds(30).ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    $null = Update-FactoryAttentionRecord -Context $context -Mutator {
        param($record)
        $currentDispatch = Get-FactoryNestedValue -Target $record -Name "dispatch"
        if ([string](Get-FactoryNestedValue -Target $currentDispatch -Name "token" -Default "") -eq $claimToken) {
            Set-FactoryProperty -Target $record -Name "orchestratorAcknowledgedRevision" -Value $previousAcknowledgement
            Set-FactoryProperty -Target $currentDispatch -Name "status" -Value "failed"
            Set-FactoryProperty -Target $currentDispatch -Name "error" -Value $failure
            Set-FactoryProperty -Target $currentDispatch -Name "failedAt" -Value (Get-FactoryUtcTimestamp)
            Set-FactoryProperty -Target $currentDispatch -Name "retryAfter" -Value $retryAt
        }
    }
    throw
}
