param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

if (-not $ClaudeCommand) {
    $ClaudeCommand = if ($env:CLAUDE_FACTORY_CLAUDE_COMMAND) {
        $env:CLAUDE_FACTORY_CLAUDE_COMMAND
    } else {
        "claude"
    }
}

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json

$agentRows = @()
try {
    $agentsText = (& $ClaudeCommand agents --json --all 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $agentsText) {
        $agentRows = @($agentsText | ConvertFrom-Json)
    }
} catch {
    $agentRows = @()
}

$mutex = $null
$changes = New-Object System.Collections.Generic.List[object]
try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Get-Content -LiteralPath $context.statePath -Raw | ConvertFrom-Json

    foreach ($task in @($state.tasks)) {
        if ($null -eq $task.backgroundSession -or -not [string]$task.backgroundSession.id) {
            continue
        }

        $before = [string]$task.status
        $taskId = [string]$task.id
        $safeTaskId = ConvertTo-FactorySafeName -Value $taskId
        $sessionRow = @($agentRows | Where-Object {
            $rowSessionId = if ($null -ne $_.PSObject.Properties["sessionId"]) { [string]$_.sessionId } else { "" }
            [string]$_.id -eq [string]$task.backgroundSession.id -or
            (
                [string]$task.backgroundSession.sessionId -and
                $rowSessionId -eq [string]$task.backgroundSession.sessionId
            )
        }) | Select-Object -First 1

        if ($null -ne $sessionRow) {
            Set-FactoryProperty -Target $task.backgroundSession -Name "state" -Value ([string]$sessionRow.state)
            Set-FactoryProperty -Target $task.backgroundSession -Name "lastSeenAt" -Value (Get-FactoryUtcTimestamp)
            if ($null -ne $sessionRow.PSObject.Properties["sessionId"] -and [string]$sessionRow.sessionId) {
                Set-FactoryProperty -Target $task.backgroundSession -Name "sessionId" -Value ([string]$sessionRow.sessionId)
            }
            if ($null -ne $sessionRow.PSObject.Properties["name"] -and [string]$sessionRow.name) {
                Set-FactoryProperty -Target $task.backgroundSession -Name "name" -Value ([string]$sessionRow.name)
            }
        }

        $eventDirectory = Join-Path $context.eventsPath $safeTaskId
        $latestPath = Join-Path $eventDirectory "latest.json"
        $resultPath = Join-Path $eventDirectory "latest-result.json"
        $planPath = Join-Path $eventDirectory "latest-plan.json"
        $latestEvent = if (Test-Path -LiteralPath $latestPath) {
            Get-Content -LiteralPath $latestPath -Raw | ConvertFrom-Json
        } else {
            $null
        }
        if ($null -ne $latestEvent) {
            Set-FactoryProperty -Target $task.backgroundSession -Name "transcriptPath" -Value ([string]$latestEvent.transcriptPath)
            Set-FactoryProperty -Target $task.backgroundSession -Name "lastAssistantMessage" -Value ([string]$latestEvent.lastAssistantMessage)
        }

        $planEvent = if (Test-Path -LiteralPath $planPath) {
            Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
        } else {
            $null
        }
        if (
            $null -ne $planEvent -and
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
        }

        $resultEvent = if (Test-Path -LiteralPath $resultPath) {
            Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        } else {
            $null
        }
        $resultIsCurrent = $null -ne $resultEvent
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
                Set-FactoryProperty -Target $task -Name "approval" -Value $null
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
        } elseif ($null -ne $sessionRow) {
            $sessionState = [string]$sessionRow.state
            if ($sessionState -eq "working" -and [string]$task.status -in @("starting", "planning", "awaiting-input")) {
                Set-FactoryProperty -Target $task -Name "status" -Value $(if ([string]$task.startMode -eq "interactive") { "planning" } else { "running" })
            } elseif ($sessionState -eq "blocked" -and [string]$task.status -in @("starting", "planning", "running")) {
                Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-input"
            } elseif ($sessionState -eq "failed" -and [string]$task.status -notin @("awaiting-review", "approved", "done")) {
                Set-FactoryProperty -Target $task -Name "status" -Value "failed"
                Set-FactoryProperty -Target $task -Name "error" -Value "Claude background session failed before a valid FACTORY_RESULT was captured."
            } elseif ($sessionState -eq "stopped" -and [string]$task.status -notin @("awaiting-review", "approved", "done")) {
                Set-FactoryProperty -Target $task -Name "status" -Value "held"
            } elseif (
                $sessionState -eq "done" -and
                [string]$task.status -in @("starting", "planning", "running") -and
                $null -eq $latestEvent
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

    if ($changes.Count -gt 0) {
        Set-FactoryProperty -Target $state -Name "updatedAt" -Value (Get-FactoryUtcTimestamp)
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    }

    [ordered]@{
        changed = $changes.Count
        transitions = @($changes | ForEach-Object { $_ })
        sessionsSeen = $agentRows.Count
    } | ConvertTo-Json -Depth 20
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
