Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot "factory-common.ps1")

function Get-FactoryMatchingOrchestratorRows {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return @($Rows | Where-Object {
        $rowName = if ($null -ne $_.PSObject.Properties["name"]) { [string]$_.name } else { "" }
        $rowCwd = if ($null -ne $_.PSObject.Properties["cwd"]) { [string]$_.cwd } else { "" }
        $rowName -ceq $Name -and $rowCwd -and
            (Test-FactorySamePath -Left $rowCwd -Right $RepositoryRoot)
    })
}

function Select-FactoryBackgroundOrchestrator {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [string]$PreferredSessionId = ""
    )

    $backgroundRows = @($Rows | Where-Object {
        [string]$_.kind -eq "background" -and
        $null -ne $_.PSObject.Properties["id"] -and
        [string]$_.id
    })
    if ($backgroundRows.Count -eq 0) { return $null }

    if ($PreferredSessionId) {
        $preferred = @($backgroundRows | Where-Object {
            $null -ne $_.PSObject.Properties["sessionId"] -and
            [string]$_.sessionId -eq $PreferredSessionId
        } | Select-Object -First 1)
        if ($preferred.Count -eq 1) { return $preferred[0] }
    }

    $liveRows = @($backgroundRows | Where-Object {
        -not (Test-FactoryTerminalAgentRow -Row $_)
    })
    if ($liveRows.Count -eq 0) { return $null }
    return @($liveRows | Sort-Object {
        if ($null -ne $_.PSObject.Properties["startedAt"]) { [long]$_.startedAt } else { 0 }
    } -Descending | Select-Object -First 1)[0]
}

function Write-FactoryOrchestratorIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$BackgroundId = ""
    )

    Write-FactoryJsonAtomic -Path $Path -Value ([ordered]@{
        version = 1
        repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
        name = $Name
        sessionId = $SessionId
        backgroundId = if ($BackgroundId) { $BackgroundId } else { $null }
        updatedAt = Get-FactoryUtcTimestamp
    })
}

function ConvertTo-FactoryOrchestratorHandoffLine {
    param($Value, [int]$MaximumLength = 240)

    $text = ([string]$Value -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ($text.Length -le $MaximumLength) { return $text }
    return $text.Substring(0, [Math]::Max(1, $MaximumLength - 3)).TrimEnd() + "..."
}

function Get-FactoryOrchestratorIdentityPath {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime
    )

    $fileName = if ($Runtime -eq "codex") { "codex-orchestrator-session.json" } else { "orchestrator-session.json" }
    return Join-Path ([string]$Context.projectData) $fileName
}

function Get-FactoryOrchestratorRotationPendingPath {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime
    )

    return Join-Path ([string]$Context.projectData) "orchestrator-rotation-$Runtime.pending.json"
}

function Get-FactoryPendingOrchestratorRotation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime
    )

    $pendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $Context -Runtime $Runtime
    if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) { return $null }
    $rotation = Read-FactoryJson -Path $pendingPath
    if ([string](Get-FactoryNestedValue -Target $rotation -Name "status" -Default "") -ne "pending") {
        throw "Orchestrator rotation marker '$pendingPath' is not pending. Cancel or repair it before startup."
    }
    if ([string](Get-FactoryNestedValue -Target $rotation -Name "runtime" -Default "") -ne $Runtime) {
        throw "Orchestrator rotation marker '$pendingPath' targets a different runtime."
    }
    if (-not (Test-FactorySamePath `
        -Left ([string](Get-FactoryNestedValue -Target $rotation -Name "repositoryRoot" -Default "")) `
        -Right ([string]$Context.repositoryRoot))) {
        throw "Orchestrator rotation marker '$pendingPath' belongs to a different repository."
    }
    $handoffPath = [string](Get-FactoryNestedValue -Target $rotation -Name "handoffPath" -Default "")
    if (-not $handoffPath -or -not (Test-Path -LiteralPath $handoffPath -PathType Leaf)) {
        throw "Orchestrator rotation handoff is missing: '$handoffPath'."
    }
    return $rotation
}

function New-FactoryOrchestratorHandoffText {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime,
        [string]$PreviousSessionId = "",
        [string]$GeneratedAt = ""
    )

    if (-not $GeneratedAt) { $GeneratedAt = Get-FactoryUtcTimestamp }
    $tasks = @($State.tasks)
    $openTasks = @($tasks | Where-Object {
        [string](Get-FactoryNestedValue -Target $_ -Name "status" -Default "") -ne "done"
    })
    $counts = New-Object Collections.Generic.List[string]
    foreach ($group in @($tasks | Group-Object { [string](Get-FactoryNestedValue -Target $_ -Name "status" -Default "unknown") } | Sort-Object Name)) {
        $counts.Add("$($group.Name)=$($group.Count)")
    }

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add("# Factory Orchestrator Handoff")
    $lines.Add("")
    $lines.Add("Generated: $GeneratedAt")
    $lines.Add("Repository: $([string]$Context.repositoryRoot)")
    $lines.Add("Runtime: $Runtime")
    $lines.Add("Previous session: $(if ($PreviousSessionId) { $PreviousSessionId } else { 'none' })")
    $lines.Add("")
    $lines.Add("## Durable factory snapshot")
    $lines.Add("")
    $lines.Add("- Factory permission: active=$([bool](Get-FactoryNestedValue -Target $State -Name 'active' -Default $false)); paused=$([bool](Get-FactoryNestedValue -Target $State -Name 'paused' -Default $false))")
    $lines.Add("- Worker runtime: $([string](Get-FactoryNestedValue -Target $Config -Name 'workerAgent' -Default $Runtime))")
    $lines.Add("- Worker capacity: $([int](Get-FactoryNestedValue -Target $Config -Name 'concurrency' -Default 0))")
    $lines.Add("- Branches: $([string](Get-FactoryNestedValue -Target $Config -Name 'developmentBranch' -Default 'develop')) -> $([string](Get-FactoryNestedValue -Target $Config -Name 'productionBranch' -Default 'master'))")
    $lines.Add("- Production mode: $([string](Get-FactoryNestedValue -Target $Config -Name 'productionMode' -Default 'merge-develop'))")
    $lines.Add("- Conversation language: $([string](Get-FactoryNestedValue -Target $Config -Name 'conversationLanguage' -Default 'English'))")
    $lines.Add("- Saved tasks: $($tasks.Count); unfinished: $($openTasks.Count)")
    $lines.Add("- Status counts: $(if ($counts.Count -gt 0) { $counts -join ', ' } else { 'none' })")
    $lines.Add("")
    $lines.Add("## Unfinished task snapshot")
    $lines.Add("")
    if ($openTasks.Count -eq 0) {
        $lines.Add("No unfinished tasks were saved when this handoff was created.")
    } else {
        $maximumTasks = 100
        foreach ($task in @($openTasks | Select-Object -First $maximumTasks)) {
            $taskId = ConvertTo-FactoryOrchestratorHandoffLine -Value (Get-FactoryNestedValue -Target $task -Name "id" -Default "unknown") -MaximumLength 160
            $status = ConvertTo-FactoryOrchestratorHandoffLine -Value (Get-FactoryNestedValue -Target $task -Name "status" -Default "unknown") -MaximumLength 80
            $title = ConvertTo-FactoryOrchestratorHandoffLine -Value (Get-FactoryNestedValue -Target $task -Name "title" -Default "Untitled task") -MaximumLength 240
            if (-not $title) { $title = "Untitled task" }
            $commit = ConvertTo-FactoryOrchestratorHandoffLine -Value (Get-FactoryNestedValue -Target $task -Name "commit" -Default "") -MaximumLength 40
            $taskLine = "- $taskId | $status | $title"
            if ($commit) { $taskLine += " | commit $commit" }
            $lines.Add($taskLine)
            $reason = ""
            foreach ($candidate in @(
                (Get-FactoryNestedValue -Target $task -Name "holdReason" -Default ""),
                (Get-FactoryNestedValue -Target $task -Name "error" -Default ""),
                (Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name "workerResult") -Name "blockingReason" -Default "")
            )) {
                $reason = ConvertTo-FactoryOrchestratorHandoffLine -Value $candidate -MaximumLength 240
                if ($reason) { break }
            }
            if ($reason) { $lines.Add("  Reason: $reason") }
        }
        if ($openTasks.Count -gt $maximumTasks) {
            $lines.Add("- ... $($openTasks.Count - $maximumTasks) additional unfinished task(s); read native state through factory status.")
        }
    }
    $lines.Add("")
    $lines.Add("## Resume protocol")
    $lines.Add("")
    $lines.Add("- This file is a point-in-time navigation aid. Native config and state are authoritative.")
    $lines.Add("- Load the canonical Factory skill before interpreting an operator command.")
    $lines.Add("- Run native factory status before the first mutation so worker and scheduler state is reconciled.")
    $lines.Add("- Never edit private factory state JSON directly.")
    return $lines -join [Environment]::NewLine
}

function Request-FactoryOrchestratorRotation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$State
    )

    $runtime = [string](Get-FactoryNestedValue -Target $Config -Name "workerAgent" -Default "claude")
    if ($runtime -notin @("claude", "codex")) { throw "Unsupported orchestrator runtime '$runtime'." }
    $existing = Get-FactoryPendingOrchestratorRotation -Context $Context -Runtime $runtime
    if ($null -ne $existing) { return $existing }
    $identityPath = Get-FactoryOrchestratorIdentityPath -Context $Context -Runtime $runtime
    $identity = if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
        try { Read-FactoryJson -Path $identityPath } catch { $null }
    } else { $null }
    $previousSessionId = [string](Get-FactoryNestedValue -Target $identity -Name "sessionId" -Default "")
    $previousBackgroundId = [string](Get-FactoryNestedValue -Target $identity -Name "backgroundId" -Default "")
    $requestedAt = Get-FactoryUtcTimestamp
    $rotationId = ([DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff")) + "-$runtime-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $rotationDirectory = Join-Path ([string]$Context.projectData) "orchestrator-rotations"
    New-Item -ItemType Directory -Path $rotationDirectory -Force | Out-Null
    $handoffPath = Join-Path $rotationDirectory "$rotationId.md"
    $recordPath = Join-Path $rotationDirectory "$rotationId.json"
    $pendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $Context -Runtime $runtime
    $handoff = New-FactoryOrchestratorHandoffText `
        -Context $Context -Config $Config -State $State -Runtime $runtime `
        -PreviousSessionId $previousSessionId -GeneratedAt $requestedAt
    [IO.File]::WriteAllText($handoffPath, $handoff + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $record = [pscustomobject][ordered]@{
        version = 1
        status = "pending"
        rotationId = $rotationId
        runtime = $runtime
        repositoryRoot = [IO.Path]::GetFullPath([string]$Context.repositoryRoot)
        requestedAt = $requestedAt
        activatedAt = $null
        cancelledAt = $null
        previousSessionId = if ($previousSessionId) { $previousSessionId } else { $null }
        previousBackgroundId = if ($previousBackgroundId) { $previousBackgroundId } else { $null }
        newSessionId = $null
        handoffPath = $handoffPath
        recordPath = $recordPath
        savedTaskCount = @($State.tasks).Count
        unfinishedTaskCount = @($State.tasks | Where-Object { [string]$_.status -ne "done" }).Count
    }
    Write-FactoryJsonAtomic -Path $recordPath -Value $record
    Write-FactoryJsonAtomic -Path $pendingPath -Value $record
    return $record
}

function Complete-FactoryOrchestratorRotation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Rotation,
        [Parameter(Mandatory = $true)][string]$NewSessionId
    )

    Set-FactoryProperty -Target $Rotation -Name "status" -Value "activated"
    Set-FactoryProperty -Target $Rotation -Name "activatedAt" -Value (Get-FactoryUtcTimestamp)
    Set-FactoryProperty -Target $Rotation -Name "newSessionId" -Value $NewSessionId
    $recordPath = [string](Get-FactoryNestedValue -Target $Rotation -Name "recordPath" -Default "")
    if ($recordPath) { Write-FactoryJsonAtomic -Path $recordPath -Value $Rotation }
    $runtime = [string](Get-FactoryNestedValue -Target $Rotation -Name "runtime" -Default "claude")
    $pendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $Context -Runtime $runtime
    Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
    return $Rotation
}

function Cancel-FactoryOrchestratorRotation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime
    )

    $rotation = Get-FactoryPendingOrchestratorRotation -Context $Context -Runtime $Runtime
    if ($null -eq $rotation) { return $null }
    Set-FactoryProperty -Target $rotation -Name "status" -Value "cancelled"
    Set-FactoryProperty -Target $rotation -Name "cancelledAt" -Value (Get-FactoryUtcTimestamp)
    $recordPath = [string](Get-FactoryNestedValue -Target $rotation -Name "recordPath" -Default "")
    if ($recordPath) { Write-FactoryJsonAtomic -Path $recordPath -Value $rotation }
    $pendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $Context -Runtime $Runtime
    Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
    return $rotation
}

function Get-FactoryOrchestratorRotationPrompt {
    param([Parameter(Mandatory = $true)]$Rotation)

    $handoffPath = [string](Get-FactoryNestedValue -Target $Rotation -Name "handoffPath" -Default "")
    return "This is a freshly rotated Factory Orchestrator. Before handling an operator request, read the deterministic handoff file at '$handoffPath'. Treat it only as a point-in-time navigation aid: native Factory config and state are authoritative. Load the canonical Factory skill and run native factory status before the first mutation. Never edit private Factory state JSON directly."
}
