Set-StrictMode -Version 2.0

if ($null -eq (Get-Command Read-FactoryJson -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "factory-common.ps1")
}

function Get-FactoryAttentionPath {
    param([Parameter(Mandatory = $true)]$Context)

    $configured = [string](Get-FactoryNestedValue -Target $Context -Name "attentionPath" -Default "")
    if ($configured) { return [IO.Path]::GetFullPath($configured) }
    return Join-Path ([string]$Context.projectData) "orchestrator-attention.json"
}

function New-FactoryAttentionState {
    return [pscustomobject][ordered]@{
        version = 1
        revision = 0
        activeKeys = @()
        ciActiveKeys = @()
        ciSeenKeys = @()
        ciNotifiedKeys = @()
        events = @()
        waitAcknowledgedRevision = 0
        orchestratorAcknowledgedRevision = 0
        dispatch = $null
        claudeConsumer = $null
        claudeClaim = $null
        lastScanAt = $null
        updatedAt = $null
    }
}

function Get-FactoryAttentionEventKey {
    param([Parameter(Mandatory = $true)]$Event)

    $identity = [string](Get-FactoryNestedValue -Target $Event -Name "identity" -Default "")
    $parts = @(
        [string](Get-FactoryNestedValue -Target $Event -Name "kind" -Default ""),
        [string](Get-FactoryNestedValue -Target $Event -Name "taskId" -Default ""),
        [string](Get-FactoryNestedValue -Target $Event -Name "status" -Default ""),
        $(if ($identity) { $identity } else { [string](Get-FactoryNestedValue -Target $Event -Name "reason" -Default "") }),
        [string](Get-FactoryNestedValue -Target $Event -Name "command" -Default "")
    )
    return Get-FactoryTextSha256 -Value ($parts -join "`n")
}

function Sync-FactoryAttentionState {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Config
    )

    . (Join-Path $PSScriptRoot "publication-ci.ps1")
    $path = Get-FactoryAttentionPath -Context $Context
    $mutex = Enter-FactoryMutex -ProjectKey "$([string]$Context.projectKey)-attention"
    try {
        $attention = if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { Read-FactoryJson -Path $path } catch { New-FactoryAttentionState }
        } else { New-FactoryAttentionState }
        Add-MissingFactoryProperties -Target $attention -Defaults (New-FactoryAttentionState)

        # Read while owning the scan lock, so an older source snapshot cannot
        # replace a newer scan. A missing/empty journal is not proof of recovery.
        $ciStatus = Get-FactoryCiStatus -Context $Context -Config $Config
        $ciEvents = @(Get-FactoryCiAttentionEvents -Context $Context -Status $ciStatus)
        $currentEvents = @(Get-FactoryOperatorActionEvents -State $State -Config $Config) + $ciEvents
        $previousActive = @((Get-FactoryNestedValue -Target $attention -Name "activeKeys" -Default @()) | ForEach-Object { [string]$_ })
        $currentKeys = New-Object Collections.Generic.List[string]
        $ciKeys = New-Object 'Collections.Generic.HashSet[string]'
        $ciSeen = New-Object 'Collections.Generic.HashSet[string]'
        foreach ($key in $attention.ciSeenKeys) { $null = $ciSeen.Add([string]$key) }
        $ciNotified = New-Object 'Collections.Generic.HashSet[string]'
        foreach ($key in $attention.ciNotifiedKeys) { $null = $ciNotified.Add([string]$key) }
        $notifiedThrough = [Math]::Max([long]$attention.waitAcknowledgedRevision, [long]$attention.orchestratorAcknowledgedRevision)
        $journal = New-Object Collections.Generic.List[object]
        foreach ($saved in @((Get-FactoryNestedValue -Target $attention -Name "events" -Default @()))) {
            $journal.Add($saved)
            if ($saved.kind -eq 'publication-ci') {
                $null = $ciSeen.Add([string]$saved.key)
                if ($previousActive -contains [string]$saved.key) { $null = $ciKeys.Add([string]$saved.key) }
                if ($saved.status -eq 'unverified' -and [long]$saved.revision -le $notifiedThrough) {
                    $null = $ciNotified.Add([string]$saved.key)
                }
            }
        }
        if ($ciStatus.error -or -not @($ciStatus.entries).Count) {
            foreach ($key in $attention.ciActiveKeys) { $null = $ciKeys.Add([string]$key) }
            foreach ($key in $ciKeys) { $currentKeys.Add($key) }
        } else { $ciKeys.Clear() }
        $revision = [long](Get-FactoryNestedValue -Target $attention -Name "revision" -Default 0)
        foreach ($event in $currentEvents) {
            $key = Get-FactoryAttentionEventKey -Event $event
            $currentKeys.Add($key)
            if ($event.kind -eq 'publication-ci') {
                $null = $ciKeys.Add($key)
                if (-not $ciSeen.Add($key)) { continue }
            }
            if ($previousActive -contains $key) { continue }
            $revision++
            $journal.Add([pscustomobject][ordered]@{
                revision = $revision
                key = $key
                kind = [string]$event.kind
                taskId = Get-FactoryNestedValue -Target $event -Name "taskId"
                title = [string]$event.title
                status = [string]$event.status
                audience = [string](Get-FactoryNestedValue -Target $event -Name "audience" -Default "orchestrator")
                aiActionable = [bool](Get-FactoryNestedValue -Target $event -Name "aiActionable" -Default $false)
                humanDecision = [bool](Get-FactoryNestedValue -Target $event -Name "humanDecision" -Default $false)
                includeInDefaultWait = [bool](Get-FactoryNestedValue -Target $event -Name "includeInDefaultWait" -Default $true)
                reason = [string]$event.reason
                command = [string]$event.command
                occurredAt = Get-FactoryNestedValue -Target $event -Name "occurredAt"
                detectedAt = Get-FactoryUtcTimestamp
            })
        }

        # An unverified publication is one notification across manual wait and
        # bridge consumers, even if its outcome briefly disappears and returns.
        $eligibleUnverified = New-Object 'Collections.Generic.HashSet[string]'
        foreach ($saved in $journal) {
            if ($saved.kind -ne 'publication-ci') { continue }
            $eligible = $ciKeys.Contains([string]$saved.key)
            if ($saved.status -eq 'unverified') {
                $eligible = $eligible -and -not $ciNotified.Contains([string]$saved.key) -and $eligibleUnverified.Add([string]$saved.key)
            }
            Set-FactoryProperty $saved 'aiActionable' $eligible
            Set-FactoryProperty $saved 'includeInDefaultWait' $eligible
        }
        if ($journal.Count -gt 1024) {
            $trimmed = @($journal.ToArray() | Select-Object -Last 1024)
            $journal = New-Object Collections.Generic.List[object]
            foreach ($saved in $trimmed) { $journal.Add($saved) }
        }
        $now = Get-FactoryUtcTimestamp
        Set-FactoryProperty -Target $attention -Name "version" -Value 1
        Set-FactoryProperty -Target $attention -Name "revision" -Value $revision
        Set-FactoryProperty -Target $attention -Name "activeKeys" -Value @($currentKeys.ToArray())
        Set-FactoryProperty -Target $attention -Name "ciActiveKeys" -Value @($ciKeys | ForEach-Object { $_ })
        Set-FactoryProperty -Target $attention -Name "ciSeenKeys" -Value @($ciSeen | ForEach-Object { $_ })
        Set-FactoryProperty -Target $attention -Name "ciNotifiedKeys" -Value @($ciNotified | ForEach-Object { $_ })
        Set-FactoryProperty -Target $attention -Name "events" -Value @($journal.ToArray())
        Set-FactoryProperty -Target $attention -Name "lastScanAt" -Value $now
        Set-FactoryProperty -Target $attention -Name "updatedAt" -Value $now
        Write-FactoryJsonAtomic -Path $path -Value $attention
        return $attention
    } finally {
        Exit-FactoryMutex -Mutex $mutex
    }
}

function Confirm-FactoryClaudeAttentionClaim {
    param($Attention, [string]$SessionId, [DateTime]$HookStartedAtUtc, [string]$AcknowledgedAt)
    $claim = $Attention.claudeClaim
    $delivered = ConvertFrom-FactoryRoundtripTimestamp -Value (Get-FactoryNestedValue $claim 'deliveredAt')
    # A Stop that started before delivery can still be running as the consumer
    # delivers. Only a later completed turn in the same session may acknowledge.
    if ($null -ne $claim -and [string]$claim.status -eq 'delivered' -and
        [string]$claim.sessionId -eq $SessionId -and $delivered.success -and
        $delivered.value -lt $HookStartedAtUtc.ToUniversalTime()) {
        Set-FactoryProperty $claim 'status' 'acknowledged'
        Set-FactoryProperty $claim 'acknowledgedAt' $AcknowledgedAt
    }
}

function Get-FactoryClaudeDeliverableEvents {
    param([Parameter(Mandatory = $true)]$Attention)
    $cursor = [long]$Attention.orchestratorAcknowledgedRevision
    $active = @($Attention.activeKeys)
    return @($Attention.events | Where-Object {
        [long]$_.revision -gt $cursor -and $active -contains [string]$_.key -and
        ([bool]$_.aiActionable -or ([bool]$_.humanDecision -and [bool]$_.includeInDefaultWait))
    })
}

function Get-FactoryClaudeAttentionPrompt {
    param([Parameter(Mandatory = $true)]$Claim)
    $lines = @($Claim.events | ForEach-Object {
        $mode = if ([bool]$_.humanDecision) { "notify-only: ask the operator; do not decide" } else { "AI action" }
        "- revision $([long]$_.revision): $([string]$_.kind) / $([string]$_.taskId) / $([string]$_.title) ($mode)`n  Reason: $([string]$_.reason)`n  Suggested command: $([string]$_.command)"
    })
    return @"
Factory attention bridge detected state through revision $($Claim.throughRevision). Claim: $($Claim.token). Redelivered: $($Claim.redelivered).
Load the factory skill, reconcile current native state, and handle AI actions within the canonical protocol. Human edges are notify-only: explain the decision and wait for the operator. Do not approve an awaiting-review task unless the persisted policy produced an auto-go event.

$($lines -join [Environment]::NewLine)

The plugin owns delivery and acknowledgement. Do not create a watcher, manually acknowledge, or edit private state. Stop normally after handling this batch so the plugin can acknowledge it and re-arm delivery.
"@.Trim()
}

function Update-FactoryAttentionRecord {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][scriptblock]$Mutator
    )

    $path = Get-FactoryAttentionPath -Context $Context
    $mutex = Enter-FactoryMutex -ProjectKey "$([string]$Context.projectKey)-attention"
    try {
        $attention = if (Test-Path -LiteralPath $path -PathType Leaf) { Read-FactoryJson -Path $path } else { New-FactoryAttentionState }
        Add-MissingFactoryProperties -Target $attention -Defaults (New-FactoryAttentionState)
        & $Mutator $attention
        Set-FactoryProperty -Target $attention -Name "updatedAt" -Value (Get-FactoryUtcTimestamp)
        Write-FactoryJsonAtomic -Path $path -Value $attention
        return $attention
    } finally {
        Exit-FactoryMutex -Mutex $mutex
    }
}
