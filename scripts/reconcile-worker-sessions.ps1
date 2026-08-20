param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = "",
    [string]$CodexCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "codex-runtime.ps1")
. (Join-Path $PSScriptRoot "worker-event.ps1")

if (-not $ClaudeCommand) {
    $ClaudeCommand = if ($env:CLAUDE_FACTORY_CLAUDE_COMMAND) {
        $env:CLAUDE_FACTORY_CLAUDE_COMMAND
    } else {
        "claude"
    }
}

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$CodexCommand = Resolve-FactoryCodexCommand -Config $config -ExplicitCommand $CodexCommand

$agentRows = @()
$claudeListingAvailable = $true
try {
    $agentRows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
} catch {
    $agentRows = @()
    $claudeListingAvailable = $false
}

$mutex = $null
$changes = New-Object System.Collections.Generic.List[object]
$metadataChanged = $false
$codexSessionsSeen = 0
try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Read-FactoryJson -Path $context.statePath

    foreach ($task in @($state.tasks)) {
        if ($null -eq $task.backgroundSession -or -not [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "id" -Default "")) {
            continue
        }

        $before = [string]$task.status
        $taskId = [string]$task.id
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
            $sessionLookupAvailable = $claudeListingAvailable
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
            $recordedSessionState = [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "state" -Default "")
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
        if ($latestEventIsCurrent) {
            Set-FactoryProperty -Target $task.backgroundSession -Name "transcriptPath" -Value ([string]$latestEvent.transcriptPath)
            Set-FactoryProperty -Target $task.backgroundSession -Name "lastAssistantMessage" -Value ([string]$latestEvent.lastAssistantMessage)
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
        $planRecordedAt = if ($null -ne $task.PSObject.Properties["planRecordedAt"]) { [string]$task.planRecordedAt } else { "" }
        if ($planIsCurrent -and $planRecordedAt) {
            $planIsCurrent = [DateTime]::Parse([string]$planEvent.capturedAt).ToUniversalTime() -gt
                [DateTime]::Parse($planRecordedAt).ToUniversalTime()
        }
        if ($planIsCurrent -and [string]$task.reworkRequestedAt) {
            $planIsCurrent = [DateTime]::Parse([string]$planEvent.capturedAt).ToUniversalTime() -gt
                [DateTime]::Parse([string]$task.reworkRequestedAt).ToUniversalTime()
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
            Set-FactoryProperty -Target $task -Name "planRecordedAt" -Value ([string]$planEvent.capturedAt)
        }

        $resultEvent = if (Test-Path -LiteralPath $resultPath) {
            Read-FactoryJson -Path $resultPath
        } else {
            $null
        }
        $resultIsCurrent = (
            $null -ne $resultEvent -and
            $expectedEventSessionId -and
            $null -ne $resultEvent.PSObject.Properties["sessionId"] -and
            [string]$resultEvent.sessionId -eq $expectedEventSessionId
        )
        $recordedAt = if ($null -ne $task.PSObject.Properties["resultRecordedAt"]) { [string]$task.resultRecordedAt } else { "" }
        if ($resultIsCurrent -and $recordedAt) {
            $resultIsCurrent = [DateTime]::Parse([string]$resultEvent.capturedAt).ToUniversalTime() -gt
                [DateTime]::Parse($recordedAt).ToUniversalTime()
        }
        if ($resultIsCurrent -and [string]$task.reworkRequestedAt) {
            $resultIsCurrent = [DateTime]::Parse([string]$resultEvent.capturedAt).ToUniversalTime() -gt
                [DateTime]::Parse([string]$task.reworkRequestedAt).ToUniversalTime()
        }

        if ($resultIsCurrent) {
            $result = $resultEvent.payload
            $resultStatus = [string]$result.status
            $validationError = $null

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
                    $resolvedCommit = (& git -C $task.worktree rev-parse "$reportedCommit^{commit}" 2>$null).Trim()
                    if ($LASTEXITCODE -ne 0 -or -not $resolvedCommit) {
                        $validationError = "Worker commit is not valid: $reportedCommit"
                    } else {
                        $head = (& git -C $task.worktree rev-parse HEAD 2>$null).Trim()
                        $currentBranch = (& git -C $task.worktree branch --show-current 2>$null).Trim()
                        $dirty = @(& git -C $task.worktree status --porcelain 2>$null)
                        if ($head -ne $resolvedCommit) {
                            $validationError = "Worker HEAD '$head' does not match result commit '$resolvedCommit'."
                        } elseif ($currentBranch -ne [string]$task.branch) {
                            $validationError = "Worker worktree is on '$currentBranch', expected '$($task.branch)'."
                        } elseif ($dirty.Count -gt 0) {
                            $validationError = "Worker worktree is not clean."
                        } else {
                            $actualFiles = @(& git -C $task.worktree diff-tree --no-commit-id --name-only -r $resolvedCommit 2>$null |
                                Where-Object { $_ } |
                                Sort-Object -Unique)
                            $reportedFiles = @($result.changedFiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)
                            if (($actualFiles -join "`n") -ne ($reportedFiles -join "`n")) {
                                $validationError = "Reported changedFiles do not match commit '$resolvedCommit'."
                            } else {
                                Set-FactoryProperty -Target $task -Name "commit" -Value $resolvedCommit
                            }
                        }
                    }
                }
            }

            if ($validationError) {
                Set-FactoryProperty -Target $task -Name "status" -Value "failed"
                Set-FactoryProperty -Target $task -Name "error" -Value $validationError
            } elseif ($resultStatus -eq "completed") {
                Set-FactoryProperty -Target $task -Name "workerResult" -Value $result
                Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-review"
                Set-FactoryProperty -Target $task -Name "review" -Value $null
                Set-FactoryProperty -Target $task -Name "approval" -Value $null
                Set-FactoryProperty -Target $task -Name "pendingInstructions" -Value $null
                Set-FactoryProperty -Target $task -Name "reworkRequestedAt" -Value $null
                Set-FactoryProperty -Target $task -Name "error" -Value $null
            } elseif ($resultStatus -eq "blocked") {
                Set-FactoryProperty -Target $task -Name "workerResult" -Value $result
                Set-FactoryProperty -Target $task -Name "status" -Value "blocked"
                Set-FactoryProperty -Target $task -Name "error" -Value ([string]$result.blockingReason)
            } else {
                Set-FactoryProperty -Target $task -Name "workerResult" -Value $result
                Set-FactoryProperty -Target $task -Name "status" -Value "failed"
                Set-FactoryProperty -Target $task -Name "error" -Value ([string]$result.blockingReason)
            }
            Set-FactoryProperty -Target $task -Name "resultRecordedAt" -Value ([string]$resultEvent.capturedAt)
        } elseif ($null -ne $sessionRow -or $sessionMarkedMissing) {
            $sessionState = [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "state" -Default "")
            $validatedArtifacts = (
                [string](Get-FactoryNestedValue -Target $task -Name "commit" -Default "") -and
                $null -ne (Get-FactoryNestedValue -Target $task -Name "workerResult") -and
                [string](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name "workerResult") -Name "commit" -Default "") -eq
                    [string](Get-FactoryNestedValue -Target $task -Name "commit" -Default "")
            )
            if ($validatedArtifacts) {
                # Validated Git artifacts outrank a lagging or vanished session row.
            } elseif ($sessionState -eq "working" -and [string]$task.status -in @("starting", "planning")) {
                Set-FactoryProperty -Target $task -Name "status" -Value $(if ([string]$task.startMode -eq "interactive") { "planning" } else { "running" })
            } elseif ($sessionState -eq "blocked" -and [string]$task.status -in @("starting", "planning", "running")) {
                Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-input"
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
}
