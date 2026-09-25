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
        events = @()
        waitAcknowledgedRevision = 0
        orchestratorAcknowledgedRevision = 0
        dispatch = $null
        lastScanAt = $null
        updatedAt = $null
    }
}

function Get-FactoryAttentionEventKey {
    param([Parameter(Mandatory = $true)]$Event)

    $parts = @(
        [string](Get-FactoryNestedValue -Target $Event -Name "kind" -Default ""),
        [string](Get-FactoryNestedValue -Target $Event -Name "taskId" -Default ""),
        [string](Get-FactoryNestedValue -Target $Event -Name "status" -Default ""),
        [string](Get-FactoryNestedValue -Target $Event -Name "reason" -Default ""),
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
    $ciEvents = @(Get-FactoryCiAttentionEvents -Context $Context)
    $path = Get-FactoryAttentionPath -Context $Context
    $mutex = Enter-FactoryMutex -ProjectKey "$([string]$Context.projectKey)-attention"
    try {
        $attention = if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { Read-FactoryJson -Path $path } catch { New-FactoryAttentionState }
        } else { New-FactoryAttentionState }
        Add-MissingFactoryProperties -Target $attention -Defaults (New-FactoryAttentionState)

        $currentEvents = @(Get-FactoryOperatorActionEvents -State $State -Config $Config) + $ciEvents
        $previousActive = @((Get-FactoryNestedValue -Target $attention -Name "activeKeys" -Default @()) | ForEach-Object { [string]$_ })
        $currentKeys = New-Object Collections.Generic.List[string]
        $journal = New-Object Collections.Generic.List[object]
        foreach ($saved in @((Get-FactoryNestedValue -Target $attention -Name "events" -Default @()))) { $journal.Add($saved) }
        $revision = [long](Get-FactoryNestedValue -Target $attention -Name "revision" -Default 0)
        foreach ($event in $currentEvents) {
            $key = Get-FactoryAttentionEventKey -Event $event
            $currentKeys.Add($key)
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

        if ($journal.Count -gt 1024) {
            $trimmed = @($journal.ToArray() | Select-Object -Last 1024)
            $journal = New-Object Collections.Generic.List[object]
            foreach ($saved in $trimmed) { $journal.Add($saved) }
        }
        $now = Get-FactoryUtcTimestamp
        Set-FactoryProperty -Target $attention -Name "version" -Value 1
        Set-FactoryProperty -Target $attention -Name "revision" -Value $revision
        Set-FactoryProperty -Target $attention -Name "activeKeys" -Value @($currentKeys.ToArray())
        Set-FactoryProperty -Target $attention -Name "events" -Value @($journal.ToArray())
        Set-FactoryProperty -Target $attention -Name "lastScanAt" -Value $now
        Set-FactoryProperty -Target $attention -Name "updatedAt" -Value $now
        Write-FactoryJsonAtomic -Path $path -Value $attention
        return $attention
    } finally {
        Exit-FactoryMutex -Mutex $mutex
    }
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
