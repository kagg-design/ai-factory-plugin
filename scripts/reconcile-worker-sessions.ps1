param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = "",
    [string]$CodexCommand = "",
    [Parameter(DontShow = $true)]$ProjectContext = $null
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "codex-runtime.ps1")
. (Join-Path $PSScriptRoot "worker-event.ps1")
. (Join-Path $PSScriptRoot 'quality-gates.ps1')

if (-not $ClaudeCommand) {
    $ClaudeCommand = if ($env:CLAUDE_FACTORY_CLAUDE_COMMAND) {
        $env:CLAUDE_FACTORY_CLAUDE_COMMAND
    } else {
        "claude"
    }
}

if ($null -ne $ProjectContext) {
    if (-not (Test-FactorySamePath -Left ([string]$ProjectContext.repositoryRoot) -Right $Repository)) {
        throw "Project context does not match the reconciliation repository."
    }
    $context = $ProjectContext
} else {
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
        ConvertFrom-Json
}
$config = Read-FactoryJson -Path $context.configPath
. (Join-Path $PSScriptRoot "publication-ci.ps1")
# Reconciliation is a fresh child invocation even in an already-running
# scheduler. Observe pushes without waiting for CI or touching the test lane.
$null = Sync-FactoryPublicationCi -Context $context
$blockedSessionTimeoutMinutes = [Math]::Max(
    1,
    [int](Get-FactoryNestedValue -Target $config -Name "blockedSessionTimeoutMinutes" -Default 30)
)
$workerLaunchTimeoutSeconds = [Math]::Max(
    1,
    [int](Get-FactoryNestedValue -Target $config -Name "workerLaunchTimeoutSeconds" -Default 300)
)

function Get-FactoryBlockedSessionReason {
    param($SessionRow)

    foreach ($name in @(
        "blockedReason", "waitingFor", "permissionDecisionReason", "pendingToolCall",
        "toolCall", "currentTool", "error", "lastAssistantMessage"
    )) {
        $value = Get-FactoryNestedValue -Target $SessionRow -Name $name
        if ($null -eq $value) { continue }
        $text = if ($value -is [string]) { [string]$value } else { $value | ConvertTo-Json -Depth 10 -Compress }
        if ($text) { return "$name`: $text" }
    }
    return "The runtime reports a blocked worker session; attach to inspect the pending tool call."
}

function Get-ReconcileClaudeListing {
    try {
        return [pscustomobject]@{ rows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand); available = $true }
    } catch {
        return [pscustomobject]@{ rows = @(); available = $false }
    }
}

$agentRows = @()
$claudeListing = $null
# Avoid querying an unrelated runtime for a Codex-only queue. Prefetch outside
# the state lock when Claude sessions are present; recheck the fresh locked
# state below so a concurrently added Claude session is still reconciled.
$initialState = Read-FactoryJson -Path $context.statePath
$hasClaudeSessions = @($initialState.tasks | Where-Object {
    (Test-FactoryTaskHasRecordedSession -Task $_) -and
    [string](Get-FactoryNestedValue -Target $_.backgroundSession -Name "runtime" -Default "claude") -ne "codex"
}).Count -gt 0
if ($hasClaudeSessions) {
    $claudeListing = Get-ReconcileClaudeListing
    $agentRows = @($claudeListing.rows)
}

$mutex = $null
$changes = New-Object System.Collections.Generic.List[object]
$metadataChanged = $false
$codexSessionsSeen = 0
$stalledWorkers = New-Object Collections.Generic.List[object]
$settledTaskStates = @("awaiting-review", "approved", "integrating", "production", "cleaning", "held", "rejected", "blocked", "failed", "done")
try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Read-FactoryJson -Path $context.statePath

    foreach ($task in @($state.tasks)) {
        $before = [string]$task.status
        $taskId = [string]$task.id
        try {
        $recordedSessionState = [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "state" -Default "")
        # Once a terminal worker has already moved its task into a settled
        # state, its final event has been consumed. Retained session metadata is
        # useful for inspection, but reopening its transcript cannot produce a
        # valid transition and used to force a state rewrite on every status.
        if ($recordedSessionState -in @("stopped", "done", "failed") -and $before -in $settledTaskStates -and $before -ne "blocked") { continue }
        if (-not (Test-FactoryTaskHasRecordedSession -Task $task)) {
            if ($before -in @("starting", "planning")) {
                $launchStartedAt = Get-FactoryNestedValue -Target $task -Name "launchStartedAt"
                $parsedLaunchStartedAt = ConvertFrom-FactoryRoundtripTimestamp -Value $launchStartedAt
                if (-not [bool]$parsedLaunchStartedAt.success) {
                    $fallbackStartedAt = ConvertFrom-FactoryRoundtripTimestamp -Value (Get-FactoryNestedValue -Target $task -Name "updatedAt")
                    $normalizedStartedAt = if ([bool]$fallbackStartedAt.success) {
                        ConvertTo-FactoryRoundtripTimestamp -Value $fallbackStartedAt.value
                    } else {
                        Get-FactoryUtcTimestamp
                    }
                    Set-FactoryProperty -Target $task -Name "launchStartedAt" -Value $normalizedStartedAt
                    $metadataChanged = $true
                }
                $stall = Get-FactoryLaunchStallInfo `
                    -Task $task `
                    -TimeoutSeconds $workerLaunchTimeoutSeconds
                if ([bool]$stall.stalled) {
                    $failure = "Worker launch did not record a background session within $workerLaunchTimeoutSeconds second(s); the launcher process may have exited or been terminated."
                    $timestamp = Get-FactoryUtcTimestamp
                    Set-FactoryProperty -Target $task -Name "status" -Value "failed"
                    Set-FactoryProperty -Target $task -Name "error" -Value $failure
                    Set-FactoryProperty -Target $task -Name "launchFailedAt" -Value $timestamp
                    Set-FactoryProperty -Target $task -Name "launchProcessId" -Value $null
                    Set-FactoryProperty -Target $task -Name "launchProcessStartTimeUtc" -Value $null
                    Set-FactoryProperty -Target $task -Name "updatedAt" -Value $timestamp
                    $changes.Add([pscustomobject]@{
                        taskId = $taskId
                        from = $before
                        to = "failed"
                        reason = $failure
                    })
                }
            }
            continue
        }

        if ($null -ne (Get-FactoryNestedValue -Target $task -Name "launchProcessId")) {
            Set-FactoryProperty -Target $task -Name "launchProcessId" -Value $null
            Set-FactoryProperty -Target $task -Name "launchProcessStartTimeUtc" -Value $null
            if ($null -eq (Get-FactoryNestedValue -Target $task -Name "launchCompletedAt")) {
                Set-FactoryProperty -Target $task -Name "launchCompletedAt" -Value (Get-FactoryUtcTimestamp)
            }
            $metadataChanged = $true
        }
        $safeTaskId = ConvertTo-FactoryTaskArtifactName -TaskId $taskId
        $sessionRuntime = if ($null -ne $task.backgroundSession.PSObject.Properties["runtime"] -and [string]$task.backgroundSession.runtime) {
            [string]$task.backgroundSession.runtime
        } else { "claude" }
        # Identity match wins over the name+cwd fallback, in two passes. A relaunched task
        # leaves the previous session listed under the SAME name and worktree, so a single
        # first-match loop can bind a live worker's task to the dead attempt's row and then
        # "reconcile" a working session into held.
        $sessionRow = $null
        $sessionLookupAvailable = $true
        $sessionMarkedMissing = $false
        $expectedBackgroundId = [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "id" -Default "")
        $expectedSessionId = [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "sessionId" -Default "")
        $expectedName = [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "name" -Default "")
        if ($sessionRuntime -eq "codex") {
            $sessionRow = Get-FactoryCodexSessionSnapshot -Session $task.backgroundSession
            $codexSessionsSeen++
        } else {
            if ($null -eq $claudeListing) {
                $claudeListing = Get-ReconcileClaudeListing
                $agentRows = @($claudeListing.rows)
            }
            $sessionLookupAvailable = [bool]$claudeListing.available
            foreach ($pass in @("backgroundId", "sessionId", "shape")) {
                foreach ($candidateSessionRow in @($agentRows)) {
                $rowId = if ($null -ne $candidateSessionRow.PSObject.Properties["id"]) { [string]$candidateSessionRow.id } else { "" }
                $rowSessionId = if ($null -ne $candidateSessionRow.PSObject.Properties["sessionId"]) { [string]$candidateSessionRow.sessionId } else { "" }
                $rowName = if ($null -ne $candidateSessionRow.PSObject.Properties["name"]) { [string]$candidateSessionRow.name } else { "" }
                $rowCwd = if ($null -ne $candidateSessionRow.PSObject.Properties["cwd"]) { [string]$candidateSessionRow.cwd } else { "" }
                $expectedCwd = [string]$task.worktree

                $matchesSession = if ($pass -eq "backgroundId") {
                    $rowId -and $rowId -eq $expectedBackgroundId
                } elseif ($pass -eq "sessionId") {
                    $rowSessionId -and $expectedSessionId -and $rowSessionId -eq $expectedSessionId
                } else {
                    $rowName -and $expectedName -and $rowName -eq $expectedName -and
                    $rowCwd -and $expectedCwd -and
                    $rowCwd.TrimEnd("\").Equals($expectedCwd.TrimEnd("\"), [StringComparison]::OrdinalIgnoreCase)
                }
                    if ($matchesSession) {
                        $sessionRow = $candidateSessionRow
                        break
                    }
                }
                if ($null -ne $sessionRow) {
                    break
                }
            }
        }
        if ($null -eq $sessionRow -and $sessionLookupAvailable) {
            if ($recordedSessionState -notin @("stopped", "done", "failed")) {
                $missingAt = Get-FactoryUtcTimestamp
                Set-FactoryProperty -Target $task.backgroundSession -Name "state" -Value "stopped"
                Set-FactoryProperty -Target $task.backgroundSession -Name "stoppedAt" -Value $missingAt
                Set-FactoryProperty -Target $task.backgroundSession -Name "missingAt" -Value $missingAt
                $metadataChanged = $true
                $sessionMarkedMissing = $true
            }
        }

        if ($null -ne $sessionRow) {
            $metadataChanged = $true
            $rowState = if ($null -ne $sessionRow.PSObject.Properties["state"] -and [string]$sessionRow.state) {
                [string]$sessionRow.state
            } elseif ($null -ne $sessionRow.PSObject.Properties["status"] -and [string]$sessionRow.status) {
                [string]$sessionRow.status
            } else {
                [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "state" -Default "")
            }
            Set-FactoryProperty -Target $task.backgroundSession -Name "state" -Value $rowState
            Set-FactoryProperty -Target $task.backgroundSession -Name "lastSeenAt" -Value (Get-FactoryUtcTimestamp)
            if ($rowState -eq "blocked" -and $before -in @("starting", "planning", "running")) {
                $blockedAt = Get-FactoryNestedValue -Target $task.backgroundSession -Name "blockedAt"
                if ($null -eq $blockedAt) {
                    $candidateBlockedAt = Get-FactoryNestedValue -Target $sessionRow -Name "blockedAt"
                    if ($null -eq $candidateBlockedAt) { $candidateBlockedAt = Get-FactoryNestedValue -Target $sessionRow -Name "updatedAt" }
                    if ($null -eq $candidateBlockedAt) { $candidateBlockedAt = Get-FactoryNestedValue -Target $task -Name "updatedAt" }
                    $parsedCandidate = ConvertFrom-FactoryRoundtripTimestamp -Value $candidateBlockedAt
                    $blockedAt = if ([bool]$parsedCandidate.success) {
                        ConvertTo-FactoryRoundtripTimestamp -Value $parsedCandidate.value
                    } else {
                        Get-FactoryUtcTimestamp
                    }
                    Set-FactoryProperty -Target $task.backgroundSession -Name "blockedAt" -Value $blockedAt
                }
                Set-FactoryProperty -Target $task.backgroundSession -Name "blockedReason" -Value (Get-FactoryBlockedSessionReason -SessionRow $sessionRow)
            } elseif ($rowState -ne "blocked") {
                Set-FactoryProperty -Target $task.backgroundSession -Name "blockedAt" -Value $null
                Set-FactoryProperty -Target $task.backgroundSession -Name "blockedReason" -Value $null
            }
            # Only adopt a UUID from a row that IS this background session (or when nothing is
            # recorded yet). A name+cwd match can land on a previous attempt's row, and writing
            # its UUID here would permanently pin the task to the dead session.
            $storedSessionId = $expectedSessionId
            $rowMatchesBackgroundId = (
                $null -ne $sessionRow.PSObject.Properties["id"] -and
                [string]$sessionRow.id -eq $expectedBackgroundId
            )
            $rowMatchesStoredSessionId = (
                $storedSessionId -and
                $null -ne $sessionRow.PSObject.Properties["sessionId"] -and
                [string]$sessionRow.sessionId -eq $storedSessionId
            )
            $rowIsAuthoritative = $rowMatchesBackgroundId -or $rowMatchesStoredSessionId
            if (
                $null -ne $sessionRow.PSObject.Properties["sessionId"] -and [string]$sessionRow.sessionId -and
                $rowMatchesBackgroundId
            ) {
                Set-FactoryProperty -Target $task.backgroundSession -Name "sessionId" -Value ([string]$sessionRow.sessionId)
            }
            if ($rowIsAuthoritative -and $null -ne $sessionRow.PSObject.Properties["name"] -and [string]$sessionRow.name) {
                Set-FactoryProperty -Target $task.backgroundSession -Name "name" -Value ([string]$sessionRow.name)
            }
            if ($sessionRuntime -eq "codex") {
                Set-FactoryProperty -Target $task.backgroundSession -Name "transcriptPath" -Value ([string]$sessionRow.transcriptPath)
                if ([string]$sessionRow.sessionId) {
                    $resumeScript = Join-Path ([string]$context.pluginRoot) "scripts\resume-codex-worker.ps1"
                    $codexAttach = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$resumeScript`" -Repository `"$([string]$context.repositoryRoot)`" -TaskId `"$taskId`""
                    Set-FactoryProperty -Target $task.backgroundSession -Name "attachCommand" -Value $codexAttach
                    Set-FactoryProperty -Target $task.backgroundSession -Name "nativeResumeCommand" -Value "codex resume -C `"$([string]$task.worktree)`" $([string]$sessionRow.sessionId)"
                }
                if ([string]$sessionRow.error -and [string]$sessionRow.state -eq "failed") {
                    Set-FactoryProperty -Target $task -Name "error" -Value ([string]$sessionRow.error)
                }
                $lastCapturedHash = if ($null -ne $task.backgroundSession.PSObject.Properties["lastCapturedMessageHash"]) {
                    [string]$task.backgroundSession.lastCapturedMessageHash
                } else { "" }
                if (
                    [string]$sessionRow.sessionId -and [string]$sessionRow.lastAssistantMessage -and
                    [string]$sessionRow.messageHash -ne $lastCapturedHash
                ) {
                    $null = Publish-FactoryWorkerEvent `
                        -Context $context `
                        -Task $task `
                        -SessionId ([string]$sessionRow.sessionId) `
                        -Worktree ([string]$task.worktree) `
                        -Message ([string]$sessionRow.lastAssistantMessage) `
                        -TranscriptPath ([string]$sessionRow.transcriptPath) `
                        -EventName "CodexExecStop"
                    Set-FactoryProperty -Target $task.backgroundSession -Name "lastCapturedMessageHash" -Value ([string]$sessionRow.messageHash)
                }
            }
        }

        $eventDirectory = Join-Path $context.eventsPath $safeTaskId
        $latestPath = Join-Path $eventDirectory "latest.json"
        $resultPath = Join-Path $eventDirectory "latest-result.json"
        $planPath = Join-Path $eventDirectory "latest-plan.json"
        $latestEvent = if (Test-Path -LiteralPath $latestPath) {
            Read-FactoryJson -Path $latestPath
        } else {
            $null
        }
        # A Codex snapshot can discover and persist the thread UUID during this
        # same pass, so event matching must read the updated session object.
        $expectedEventSessionId = [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "sessionId" -Default "")
        $latestEventIsCurrent = (
            $null -ne $latestEvent -and
            $expectedEventSessionId -and
            $null -ne $latestEvent.PSObject.Properties["sessionId"] -and
            [string]$latestEvent.sessionId -eq $expectedEventSessionId
        )
        $invalidMarkerIsCurrent = (
            $latestEventIsCurrent -and
            [string](Get-FactoryNestedValue -Target $latestEvent -Name "kind" -Default "") -eq "invalid-marker"
        )
        if ($latestEventIsCurrent) {
            Set-FactoryProperty -Target $task.backgroundSession -Name "transcriptPath" -Value ([string]$latestEvent.transcriptPath)
            Set-FactoryProperty -Target $task.backgroundSession -Name "lastAssistantMessage" -Value ([string]$latestEvent.lastAssistantMessage)
        }
        if ($before -in @('starting', 'planning', 'running', 'awaiting-review') -and
            [string](Get-FactoryNestedValue $task.backgroundSession 'state') -in @('working', 'blocked')) {
            $activity = Get-FactoryWorkerActivity -Task $task -SessionRow $sessionRow -Event $(if ($latestEventIsCurrent) { $latestEvent } else { $null })
            if ($null -eq $activity) { $activity = [DateTime]::UtcNow; $metadataChanged = $true }
            if ($null -ne $activity) {
                $savedActivity = ConvertFrom-FactoryRoundtripTimestamp -Value (Get-FactoryNestedValue $task.backgroundSession 'lastActivityAt')
                if (-not $savedActivity.success -or $savedActivity.value -ne $activity) {
                    Set-FactoryProperty -Target $task.backgroundSession -Name 'lastActivityAt' -Value ($activity.ToUniversalTime().ToString('o'))
                    $metadataChanged = $true
                }
                $hours = [Math]::Max(0.01, [double](Get-FactoryNestedValue $config 'stallHours' 2))
                if (([DateTime]::UtcNow - $activity.ToUniversalTime()).TotalHours -ge $hours) {
                    $reason = "stalled, no activity since $($activity.ToUniversalTime().ToString('o'))"
                    Set-FactoryProperty -Target $task -Name 'status' -Value 'failed'
                    Set-FactoryProperty -Target $task -Name 'error' -Value $reason
                    Set-FactoryProperty -Target $task -Name 'updatedAt' -Value (Get-FactoryUtcTimestamp)
                    $changes.Add([pscustomobject]@{ taskId = $taskId; from = $before; to = 'failed'; reason = $reason })
                    $stalledWorkers.Add($task)
                    continue
                }
            }
        }

        $planEvent = if (Test-Path -LiteralPath $planPath) {
            Read-FactoryJson -Path $planPath
        } else {
            $null
        }
        $planIsCurrent = (
            $null -ne $planEvent -and
            $expectedEventSessionId -and
            $null -ne $planEvent.PSObject.Properties["sessionId"] -and
            [string]$planEvent.sessionId -eq $expectedEventSessionId
        )
        $planRecordedAt = Get-FactoryNestedValue -Target $task -Name "planRecordedAt" -Default $null
        if ($planIsCurrent -and $planRecordedAt) {
            $planIsCurrent = (ConvertTo-FactoryUtcDateTime -Value $planEvent.capturedAt) -gt
                (ConvertTo-FactoryUtcDateTime -Value $planRecordedAt)
        }
        $reworkRequestedAt = Get-FactoryNestedValue -Target $task -Name "reworkRequestedAt" -Default $null
        if ($planIsCurrent -and $reworkRequestedAt) {
            $planIsCurrent = (ConvertTo-FactoryUtcDateTime -Value $planEvent.capturedAt) -gt
                (ConvertTo-FactoryUtcDateTime -Value $reworkRequestedAt)
        }
        if (
            $planIsCurrent -and
            [string]$task.startMode -eq "interactive" -and
            [string]$task.status -in @("starting", "planning", "running")
        ) {
            if ([string]$planEvent.payload.taskId -ne $taskId) {
                Set-FactoryProperty -Target $task -Name "status" -Value "failed"
                Set-FactoryProperty -Target $task -Name "error" -Value "FACTORY_PLAN taskId did not match '$taskId'."
            } else {
                Set-FactoryProperty -Target $task -Name "plan" -Value $planEvent.payload
                Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-input"
                Set-FactoryProperty -Target $task -Name "error" -Value $null
            }
            Set-FactoryProperty -Target $task -Name "planRecordedAt" -Value (ConvertTo-FactoryRoundtripTimestamp -Value $planEvent.capturedAt)
        }

        $resultEvent = if (Test-Path -LiteralPath $resultPath) {
            Read-FactoryJson -Path $resultPath
        } else {
            $null
        }
        $resultIsForSession = (
            $null -ne $resultEvent -and
            $expectedEventSessionId -and
            $null -ne $resultEvent.PSObject.Properties["sessionId"] -and
            [string]$resultEvent.sessionId -eq $expectedEventSessionId
        )
        if ($resultIsForSession -and $reworkRequestedAt) {
            $resultIsForSession = (ConvertTo-FactoryUtcDateTime -Value $resultEvent.capturedAt) -gt
                (ConvertTo-FactoryUtcDateTime -Value $reworkRequestedAt)
        }
        $invalidatedAt = Get-FactoryNestedValue -Target $task -Name 'resultInvalidatedAt'
        if ($resultIsForSession -and $invalidatedAt) {
            $resultIsForSession = (ConvertTo-FactoryUtcDateTime $resultEvent.capturedAt) -gt (ConvertTo-FactoryUtcDateTime $invalidatedAt)
        }
        $resultIsCurrent = $resultIsForSession
        $recordedAt = Get-FactoryNestedValue -Target $task -Name "resultRecordedAt" -Default $null
        if ($resultIsCurrent -and $recordedAt) {
            $resultIsCurrent = (ConvertTo-FactoryUtcDateTime -Value $resultEvent.capturedAt) -gt
                (ConvertTo-FactoryUtcDateTime -Value $recordedAt)
        }
        # Sync adopts a rebased commit and advances resultRecordedAt. The saved
        # result event is then historical and must not be checked against HEAD.
        $resultCommitMatchesTask = (
            $resultIsForSession -and
            [string]$task.commit -and
            [string]$resultEvent.payload.commit -eq [string]$task.commit
        )
        $resultMayBeValidated = $resultIsCurrent -or $resultCommitMatchesTask
        $latestKind = if ($latestEventIsCurrent) { [string]$latestEvent.kind } else { "" }
        # A later message or malformed marker cannot displace a completed
        # result while its commit and worktree still pass validation.
        $followupAfterResult = (
            $resultMayBeValidated -and
            [string]$resultEvent.payload.status -eq "completed" -and
            $latestKind -in @("message", "invalid-marker") -and
            (ConvertTo-FactoryUtcDateTime -Value $latestEvent.capturedAt) -gt
                (ConvertTo-FactoryUtcDateTime -Value $resultEvent.capturedAt)
        )

        if ($resultIsCurrent -or $followupAfterResult) {
            $result = $resultEvent.payload
            $resultStatus = [string]$result.status
            $validationError = $null
            $invalidReportedCommit = $false

            if ([string]$result.taskId -ne $taskId) {
                $validationError = "FACTORY_RESULT taskId did not match '$taskId'."
            } elseif ($resultStatus -notin @("completed", "blocked", "failed")) {
                $validationError = "FACTORY_RESULT status '$resultStatus' is invalid."
            } elseif ($resultStatus -eq "completed") {
                $reportedCommit = [string]$result.commit
                $reportedBranch = [string]$result.branch
                $reportedWorktree = [string]$result.worktree
                if (-not $reportedCommit -or -not $reportedBranch -or -not $reportedWorktree) {
                    $validationError = "Completed FACTORY_RESULT is missing branch, commit, or worktree."
                } elseif ($reportedBranch -ne [string]$task.branch) {
                    $validationError = "Worker reported branch '$reportedBranch'; expected '$($task.branch)'."
                } elseif (
                    -not ([IO.Path]::GetFullPath($reportedWorktree)).Equals(
                        [IO.Path]::GetFullPath([string]$task.worktree),
                        [StringComparison]::OrdinalIgnoreCase
                    )
                ) {
                    $validationError = "Worker reported an unexpected worktree: $reportedWorktree"
                } elseif (-not (Test-Path -LiteralPath ([string]$task.worktree))) {
                    $validationError = "Worker worktree no longer exists: $($task.worktree)"
                } else {
                    $commitRead = if ($reportedCommit -match '^[a-fA-F0-9]{40}$') {
                        Invoke-FactoryNativeProcess -Command git -Arguments @('-C', [string]$task.worktree, 'rev-parse', "$reportedCommit^{commit}") -TimeoutSeconds 10
                    } else { $null }
                    $resolvedCommit = if ($null -ne $commitRead) { ([string]$commitRead.stdout).Trim() } else { '' }
                    if ($null -eq $commitRead -or $commitRead.exitCode -ne 0 -or -not $resolvedCommit) {
                        $validationError = "Worker commit is not valid: $reportedCommit"
                        $invalidReportedCommit = $true
                    } else {
                        $headRead = Invoke-FactoryNativeProcess -Command git -Arguments @('-C', [string]$task.worktree, 'rev-parse', 'HEAD') -TimeoutSeconds 10
                        $branchRead = Invoke-FactoryNativeProcess -Command git -Arguments @('-C', [string]$task.worktree, 'branch', '--show-current') -TimeoutSeconds 10
                        $statusRead = Invoke-FactoryNativeProcess -Command git -Arguments @('-C', [string]$task.worktree, 'status', '--porcelain') -TimeoutSeconds 10
                        $head = ([string]$headRead.stdout).Trim()
                        $currentBranch = ([string]$branchRead.stdout).Trim()
                        if ($headRead.exitCode -ne 0 -or $branchRead.exitCode -ne 0 -or $statusRead.exitCode -ne 0) {
                            $validationError = "Worker Git state could not be verified."
                        } elseif ($head -ne $resolvedCommit) {
                            $validationError = "Worker HEAD '$head' does not match result commit '$resolvedCommit'."
                        } elseif ($currentBranch -ne [string]$task.branch) {
                            $validationError = "Worker worktree is on '$currentBranch', expected '$($task.branch)'."
                        } elseif ([string]$statusRead.stdout) {
                            $validationError = "Worker worktree is not clean."
                        } else {
                            $filesRead = Invoke-FactoryNativeProcess -Command git -Arguments @('-C', [string]$task.worktree, 'diff-tree', '--no-commit-id', '--name-only', '-r', $resolvedCommit) -TimeoutSeconds 10
                            if ($filesRead.exitCode -ne 0) { throw "Worker changed files could not be verified: $($filesRead.stderr)" }
                            $derivedFiles = @(([string]$filesRead.stdout) -split "`r?`n" | Where-Object { $_ } | Sort-Object -Unique)
                            $reportedFilesPresent = $null -ne $result.PSObject.Properties["changedFiles"]
                            $reportedFiles = if ($reportedFilesPresent) {
                                @(Get-FactoryNestedValue -Target $result -Name "changedFiles" -Default @() | ForEach-Object { [string]$_ })
                            } else { @() }
                            Set-FactoryProperty -Target $result -Name "changedFiles" -Value $derivedFiles
                            if ($reportedFilesPresent) {
                                $changedFilesDiagnostic = Get-FactoryChangedFilesDiagnostic `
                                    -DerivedFiles $derivedFiles `
                                    -ReportedFiles $reportedFiles
                            }
                            if ($reportedFilesPresent -and -not [bool]$changedFilesDiagnostic.matches) {
                                Set-FactoryProperty -Target $resultEvent -Name "changedFilesDiagnostic" -Value $changedFilesDiagnostic
                                Write-FactoryJsonAtomic -Path $resultPath -Value $resultEvent
                                if (
                                    $latestEventIsCurrent -and
                                    (ConvertTo-FactoryUtcDateTime -Value (Get-FactoryNestedValue -Target $latestEvent -Name "capturedAt")) -eq
                                        (ConvertTo-FactoryUtcDateTime -Value (Get-FactoryNestedValue -Target $resultEvent -Name "capturedAt"))
                                ) {
                                    Set-FactoryProperty -Target $latestEvent -Name "changedFilesDiagnostic" -Value $changedFilesDiagnostic
                                    Set-FactoryProperty -Target $latestEvent -Name "payload" -Value $result
                                    Write-FactoryJsonAtomic -Path $latestPath -Value $latestEvent
                                }
                            }
                            Set-FactoryProperty -Target $task -Name "commit" -Value $resolvedCommit
                        }
                    }
                }
            }

            if ($validationError) {
                if ($followupAfterResult -and $invalidMarkerIsCurrent -and [string]$latestEvent.payload.marker -eq "FACTORY_RESULT") {
                    $markerError = [string](Get-FactoryNestedValue -Target $latestEvent.payload -Name "error" -Default "The marker JSON could not be parsed.")
                    Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-input"
                    Set-FactoryProperty -Target $task -Name "error" -Value "Invalid FACTORY_RESULT payload: $markerError Worktree and commits are retained. Ask the worker via factory chat $taskId to emit a corrected FACTORY_RESULT report; publication remains gated."
                    Set-FactoryProperty -Target $task -Name "markerErrorRecordedAt" -Value (ConvertTo-FactoryRoundtripTimestamp -Value $latestEvent.capturedAt)
                } else {
                    Set-FactoryProperty -Target $task -Name "status" -Value $(if ($invalidReportedCommit) { "awaiting-input" } else { "failed" })
                    Set-FactoryProperty -Target $task -Name "error" -Value $validationError
                }
            } elseif ($resultStatus -eq "completed") {
                Set-FactoryProperty -Target $task -Name "workerResult" -Value $result
                if ($resultIsCurrent) {
                    Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-review"
                    Set-FactoryProperty -Target $task -Name "review" -Value $null
                    Set-FactoryProperty -Target $task -Name "approval" -Value $null
                    Set-FactoryProperty -Target $task -Name "pendingInstructions" -Value $null
                    Set-FactoryProperty -Target $task -Name "reworkRequestedAt" -Value $null
                    Set-FactoryProperty -Target $task -Name "error" -Value $null
                } elseif ([string]$task.status -eq "awaiting-input") {
                    Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-review"
                    Set-FactoryProperty -Target $task -Name "error" -Value $null
                }
            } elseif ($resultStatus -eq "blocked") {
                Set-FactoryProperty -Target $task -Name "workerResult" -Value $result
                Set-FactoryProperty -Target $task -Name "status" -Value "blocked"
                Set-FactoryProperty -Target $task -Name "error" -Value ([string]$result.blockingReason)
            } else {
                Set-FactoryProperty -Target $task -Name "workerResult" -Value $result
                Set-FactoryProperty -Target $task -Name "status" -Value "failed"
                Set-FactoryProperty -Target $task -Name "error" -Value ([string]$result.blockingReason)
            }
            if ($resultIsCurrent) {
                Set-FactoryProperty -Target $task -Name "resultRecordedAt" -Value (ConvertTo-FactoryRoundtripTimestamp -Value $resultEvent.capturedAt)
            }
            $eventWarning = ""
            if (-not $validationError -and $resultStatus -eq "completed" -and $followupAfterResult) {
                $followupText = if ($latestKind -eq "invalid-marker") {
                    "Invalid $([string]$latestEvent.payload.marker) follow-up: $([string]$latestEvent.payload.error)"
                } else {
                    "Worker follow-up after the validated result: $([string]$latestEvent.lastAssistantMessage)"
                }
                $eventWarning = ([regex]::Replace($followupText.Trim(), '\s+', ' '))
                if ($eventWarning.Length -gt 240) { $eventWarning = $eventWarning.Substring(0, 240) + "..." }
            }
            if ([string](Get-FactoryNestedValue -Target $task -Name "workerEventWarning" -Default "") -ne $eventWarning) {
                Set-FactoryProperty -Target $task -Name "workerEventWarning" -Value $eventWarning
                $metadataChanged = $true
            }
        } elseif (
            $invalidMarkerIsCurrent -and
            [string]$task.status -in @("starting", "planning", "running", "awaiting-input")
        ) {
            $marker = [string](Get-FactoryNestedValue -Target $latestEvent.payload -Name "marker" -Default "FACTORY marker")
            $markerError = [string](Get-FactoryNestedValue -Target $latestEvent.payload -Name "error" -Default "The marker JSON could not be parsed.")
            # A malformed envelope is a reporting problem, not a failed code
            # change. Keep artifacts and require correction; do not synthesize
            # a validated result or make the task eligible for review/GO.
            Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-input"
            Set-FactoryProperty -Target $task -Name "error" -Value "Invalid $marker payload: $markerError Worktree and commits are retained. Ask the worker via factory chat $taskId to emit a corrected $marker report; publication remains gated."
            Set-FactoryProperty -Target $task -Name "markerErrorRecordedAt" -Value (ConvertTo-FactoryRoundtripTimestamp -Value $latestEvent.capturedAt)
        } elseif ($null -ne $sessionRow -or $sessionMarkedMissing) {
            $sessionState = [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "state" -Default "")
            if (Test-FactoryTaskHasValidatedResult -Task $task) {
                # Validated Git artifacts outrank a lagging or vanished session row.
            } elseif ($sessionState -eq "working" -and [string]$task.status -in @("starting", "planning")) {
                Set-FactoryProperty -Target $task -Name "status" -Value $(if ([string]$task.startMode -eq "interactive") { "planning" } else { "running" })
            } elseif ($sessionState -eq "blocked" -and [string]$task.status -in @("starting", "planning", "running")) {
                $blockedAt = Get-FactoryNestedValue -Target $task.backgroundSession -Name "blockedAt"
                $parsedBlockedAt = ConvertFrom-FactoryRoundtripTimestamp -Value $blockedAt
                $blockedSeconds = if ([bool]$parsedBlockedAt.success) {
                    [Math]::Max(0, [int]([DateTime]::UtcNow - ([DateTime]$parsedBlockedAt.value)).TotalSeconds)
                } else { 0 }
                if ($blockedSeconds -ge ($blockedSessionTimeoutMinutes * 60)) {
                    $blockedReason = [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "blockedReason" -Default "reason unavailable")
                    $holdReason = "Worker session remained blocked for at least $blockedSessionTimeoutMinutes minute(s). Waiting for: $blockedReason"
                    Set-FactoryProperty -Target $task -Name "status" -Value "blocked"
                    Set-FactoryProperty -Target $task -Name "holdReason" -Value $holdReason
                    Set-FactoryProperty -Target $task -Name "error" -Value $holdReason
                    Set-FactoryProperty -Target $task -Name "inSessionWaiting" -Value ([pscustomobject]@{
                        sessionId = $expectedEventSessionId; capturedAt = Get-FactoryUtcTimestamp; kind = "blocked-timeout"
                    })
                }
            } elseif ($sessionState -eq "failed" -and [string]$task.status -in @("starting", "planning", "running")) {
                Set-FactoryProperty -Target $task -Name "status" -Value "failed"
                Set-FactoryProperty -Target $task -Name "error" -Value "Worker session failed before a valid FACTORY_RESULT was captured."
            } elseif ($sessionState -eq "stopped" -and [string]$task.status -in @("starting", "planning", "running")) {
                Set-FactoryProperty -Target $task -Name "status" -Value "held"
                Set-FactoryProperty -Target $task -Name "holdReason" -Value "background session stopped without a FACTORY_RESULT"
                Set-FactoryProperty -Target $task -Name "error" -Value "Background session stopped without a FACTORY_RESULT. Use /factory retry or /factory answer."
            } elseif (
                $sessionState -eq "done" -and
                [string]$task.status -in @("starting", "planning", "running") -and
                -not $latestEventIsCurrent
            ) {
                if ([string]$task.startMode -eq "interactive") {
                    Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-input"
                } else {
                    Set-FactoryProperty -Target $task -Name "status" -Value "failed"
                    Set-FactoryProperty -Target $task -Name "error" -Value "Worker ended without a captured FACTORY_RESULT."
                }
            }
        }

        if ([string]$task.status -in @("awaiting-input", "blocked") -and $latestEventIsCurrent) {
            $waitingKind = [string]$latestEvent.kind
            if ($waitingKind -in @("plan", "invalid-marker") -or
                ($waitingKind -eq "result" -and [string]$latestEvent.payload.status -eq "blocked")) {
                Set-FactoryProperty -Target $task -Name "inSessionWaiting" -Value ([pscustomobject]@{
                    sessionId = $expectedEventSessionId; capturedAt = $latestEvent.capturedAt; kind = $waitingKind
                })
            }
        }
        if (Resume-FactoryTaskFromInSessionReply -Context $context -Task $task -SessionRow $sessionRow) { $metadataChanged = $true }
        $inSessionReply = Get-FactoryNestedValue -Target $task -Name "inSessionReply"
        if ([string]$task.status -eq "running" -and $latestEventIsCurrent -and
            [string]$latestEvent.kind -eq "message" -and $null -ne $inSessionReply -and
            [string]$inSessionReply.sessionId -eq $expectedEventSessionId -and
            (ConvertTo-FactoryUtcDateTime -Value $latestEvent.capturedAt) -gt (ConvertTo-FactoryUtcDateTime -Value $inSessionReply.capturedAt)) {
            Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-input"
            Set-FactoryProperty -Target $task -Name "inSessionWaiting" -Value ([pscustomobject]@{
                sessionId = $expectedEventSessionId; capturedAt = $latestEvent.capturedAt; kind = "message"
            })
        }

        $after = [string]$task.status
        if ($after -ne $before) {
            $timestamp = Get-FactoryUtcTimestamp
            Set-FactoryProperty -Target $task -Name "updatedAt" -Value $timestamp
            $changes.Add([pscustomobject]@{
                taskId = $taskId
                from = $before
                to = $after
            })
        }
        } catch {
            $failure = "Reconciliation failed for task '$taskId': $($_.Exception.Message)"
            Set-FactoryProperty -Target $task -Name "status" -Value "failed"
            Set-FactoryProperty -Target $task -Name "error" -Value $failure
            Set-FactoryProperty -Target $task -Name "updatedAt" -Value (Get-FactoryUtcTimestamp)
            $metadataChanged = $true
            if ($before -ne "failed") {
                $changes.Add([pscustomobject]@{ taskId = $taskId; from = $before; to = "failed"; reason = $failure })
            }
        }
    }

    if ($changes.Count -gt 0 -or $metadataChanged) {
        Set-FactoryProperty -Target $state -Name "updatedAt" -Value (Get-FactoryUtcTimestamp)
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    }

    [ordered]@{
        changed = $changes.Count
        metadataChanged = $metadataChanged
        transitions = @($changes | ForEach-Object { $_ })
        sessionsSeen = $agentRows.Count + $codexSessionsSeen
        claudeSessionsSeen = $agentRows.Count
        codexSessionsSeen = $codexSessionsSeen
    } | ConvertTo-Json -Depth 20
} finally {
    Exit-FactoryMutex -Mutex $mutex
    # Stop exact stalled sessions outside the ledger lock. Retain their checkout,
    # branch and transcript, and release capacity only after a verified stop.
    foreach ($stalledTask in $stalledWorkers) {
        try {
            if ([string](Get-FactoryNestedValue $stalledTask.backgroundSession 'runtime') -eq 'codex') {
                $null = Stop-FactoryCodexWorkerProcess -Session $stalledTask.backgroundSession
            } else {
                Stop-FactoryClaudeSessionAndWait -ClaudeCommand $ClaudeCommand -BackgroundId ([string]$stalledTask.backgroundSession.id)
            }
            $stopLock = Enter-FactoryMutex -ProjectKey $context.projectKey
            try {
                $stoppedState = Read-FactoryJson -Path $context.statePath
                $stoppedTask = Get-FactoryTask -State $stoppedState -TaskId ([string]$stalledTask.id)
                if ([string]$stoppedTask.backgroundSession.id -eq [string]$stalledTask.backgroundSession.id) {
                    Set-FactoryProperty -Target $stoppedTask.backgroundSession -Name 'state' -Value 'stopped'
                    Write-FactoryJsonAtomic -Path $context.statePath -Value $stoppedState
                }
            } finally { Exit-FactoryMutex -Mutex $stopLock }
        } catch { [Console]::Error.WriteLine("Could not stop stalled worker $($stalledTask.id): $($_.Exception.Message)") }
    }
}
