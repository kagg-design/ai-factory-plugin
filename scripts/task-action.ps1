param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][ValidateSet("go", "hold", "reject", "rework", "retry", "release")][string]$Action,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$Instructions = "",
    [string]$ClaudeCommand = "",
    [string]$CodexCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "codex-runtime.ps1")
if (-not $ClaudeCommand) {
    $ClaudeCommand = if ($env:CLAUDE_FACTORY_CLAUDE_COMMAND) { $env:CLAUDE_FACTORY_CLAUDE_COMMAND } else { "claude" }
}
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$CodexCommand = Resolve-FactoryCodexCommand -Config $config -ExplicitCommand $CodexCommand

$mutex = $null
try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId
    $now = Get-FactoryUtcTimestamp
    $previewCleanup = $null

    switch ($Action) {
        "go" {
            if ([string]$task.status -notin @("awaiting-review", "held")) {
                throw "Task '$TaskId' is '$($task.status)', not awaiting review."
            }
            if (Test-FactoryTaskRequiresFreshReview -Task $task) {
                throw "Task '$TaskId' has a failed publication attempt. Run review again before go."
            }
            if (-not [string]$task.commit -or $null -eq $task.workerResult) {
                throw "Task '$TaskId' has no validated worker commit."
            }
            if ([string]$task.workerResult.commit -ne [string]$task.commit) {
                throw "Validated worker result does not match task commit '$($task.commit)'."
            }
            $review = Get-FactoryNestedValue -Target $task -Name "review"
            if ($null -eq $review -or [string]$review.verdict -ne "approved") {
                throw "Task '$TaskId' has no approved formal review. Run review first."
            }
            if ([string]$review.commit -ne [string]$task.commit) {
                throw "Formal review does not match task commit '$($task.commit)'. Run review again."
            }
            $integrationPlan = Get-FactoryNestedValue -Target $review -Name "integrationPlan"
            if ($null -eq $integrationPlan) {
                throw "Task '$TaskId' review has no executable integration plan. Run review again."
            }
            $planHash = Assert-FactoryIntegrationPlan `
                -Plan $integrationPlan `
                -TaskId $TaskId `
                -Commit ([string]$task.commit)
            if (-not (Test-Path -LiteralPath ([string]$task.worktree))) {
                throw "Worker worktree is missing: $($task.worktree)"
            }

            $head = (& git -C $task.worktree rev-parse HEAD 2>$null).Trim()
            $dirty = @(& git -C $task.worktree status --porcelain 2>$null)
            if ($head -ne [string]$task.commit) {
                throw "Worker HEAD '$head' differs from reviewed commit '$($task.commit)'. Run review again."
            }
            if ($dirty.Count -gt 0) {
                throw "Worker worktree has uncommitted changes. Finish the worker session before approval."
            }

            $previewRun = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "factory-preview.ps1"),
                "-Action", "stop", "-Repository", [string]$context.repositoryRoot,
                "-RuntimeHome", [string]$context.runtimeHome, "-TaskId", $TaskId
            )
            if ([int]$previewRun.exitCode -ne 0) {
                throw "Approval could not stop the task browser preview: $($previewRun.output)"
            }
            $previewCleanup = [string]$previewRun.stdout | ConvertFrom-Json

            Set-FactoryProperty -Target $task -Name "approval" -Value ([pscustomobject]@{
                commit = [string]$task.commit
                planHash = $planHash
                approvedAt = $now
                mode = if ([string](Get-FactoryNestedValue -Target $review -Name "mode" -Default "ai") -eq "operator-direct") { "operator-direct" } else { "reviewed" }
            })
            Set-FactoryProperty -Target $task -Name "status" -Value "approved"
            Set-FactoryProperty -Target $state -Name "active" -Value $true
            Set-FactoryProperty -Target $state -Name "paused" -Value $false
        }
        "hold" {
            if ([string]$task.status -notin @("awaiting-review", "approved", "awaiting-input")) {
                throw "Task '$TaskId' cannot be held from status '$($task.status)'."
            }
            Set-FactoryProperty -Target $task -Name "approval" -Value $null
            Set-FactoryProperty -Target $task -Name "status" -Value "held"
            Set-FactoryProperty -Target $task -Name "holdReason" -Value "held by operator"
        }
        "reject" {
            throw "Use reject-task.ps1. State-only rejection now requires its explicit -Keep switch."
        }
        "rework" {
            if ($null -eq $task.backgroundSession -or -not [string]$task.backgroundSession.id) {
                throw "Task '$TaskId' has no background session to continue."
            }
            if (-not [string]$task.worktree -or -not (Test-Path -LiteralPath ([string]$task.worktree) -PathType Container)) {
                throw "Task '$TaskId' has no usable retained worktree."
            }
            $deliveryInstructions = $Instructions.Trim()
            if (-not $deliveryInstructions) {
                $existingReview = Get-FactoryNestedValue -Target $task -Name "review"
                $reviewSummary = [string](Get-FactoryNestedValue -Target $existingReview -Name "summary" -Default "")
                $reviewRisks = @((Get-FactoryNestedValue -Target $existingReview -Name "riskNotes" -Default @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
                $deliveryInstructions = @($reviewSummary, @($reviewRisks | ForEach-Object { "- $_" })) | Where-Object { $_ } | ForEach-Object { [string]$_ }
                $deliveryInstructions = ($deliveryInstructions -join [Environment]::NewLine).Trim()
            }
            if (-not $deliveryInstructions) {
                throw "Rework instructions are required when the recorded review contains no findings."
            }
            $oldBackgroundId = [string]$task.backgroundSession.id
            $sessionCleanup = Close-FactoryTaskWorkerSessions `
                -Session $task.backgroundSession `
                -TaskId $TaskId `
                -Worktree ([string]$task.worktree) `
                -ClaudeCommand $ClaudeCommand `
                -CodexCommand $CodexCommand `
                -CodexDisposition "archive"
            if (@($sessionCleanup.stopFailures).Count -gt 0) {
                $blockedIds = @($sessionCleanup.stopFailures | ForEach-Object { [string]$_.id }) -join ", "
                throw "Failed to stop task session(s) $blockedIds; rework was not queued."
            }
            Set-FactoryProperty -Target $task -Name "approval" -Value $null
            Set-FactoryProperty -Target $task -Name "review" -Value $null
            Set-FactoryProperty -Target $task -Name "backgroundSession" -Value $null
            Set-FactoryProperty -Target $task -Name "agentId" -Value $null
            Set-FactoryProperty -Target $task -Name "status" -Value "queued"
            Set-FactoryProperty -Target $task -Name "reworkRequestedAt" -Value $now
            Set-FactoryProperty -Target $task -Name "pendingInstructions" -Value $deliveryInstructions
            Set-FactoryProperty -Target $task -Name "error" -Value $null
            Set-FactoryProperty -Target $task -Name "holdReason" -Value $null
            Set-FactoryProperty -Target $state -Name "active" -Value $true
            Set-FactoryProperty -Target $state -Name "paused" -Value $false
            $Instructions = $deliveryInstructions
        }
        "retry" {
            $machineHoldReason = "background session stopped without a FACTORY_RESULT"
            $retryable = [string]$task.status -in @("blocked", "failed") -or (
                [string]$task.status -eq "held" -and [string]$task.holdReason -eq $machineHoldReason
            )
            if (-not $retryable) { throw "Task '$TaskId' is not in a retryable machine state." }
            if ([string]$task.commit -or $null -ne $task.workerResult) {
                throw "Task '$TaskId' has a validated result or commit and cannot be retried."
            }
            if (-not [string]$task.worktree -or -not (Test-Path -LiteralPath ([string]$task.worktree))) {
                throw "Task '$TaskId' has no usable retained worktree."
            }
            $oldBackgroundId = if ($null -ne $task.backgroundSession) { [string]$task.backgroundSession.id } else { "" }
            $oldBackgroundState = if ($null -ne $task.backgroundSession) { [string]$task.backgroundSession.state } else { "" }
            if ($oldBackgroundState -eq "working") {
                throw "Task '$TaskId' still has a working background session."
            }
            if ($oldBackgroundId -and $oldBackgroundState -notin @("stopped", "done", "failed")) {
                $sessionCleanup = Close-FactoryTaskWorkerSessions `
                    -Session $task.backgroundSession `
                    -TaskId $TaskId `
                    -Worktree ([string]$task.worktree) `
                    -ClaudeCommand $ClaudeCommand `
                    -CodexCommand $CodexCommand `
                    -CodexDisposition "archive"
                if (@($sessionCleanup.stopFailures).Count -gt 0) {
                    throw "Failed to stop old worker session '$oldBackgroundId'."
                }
            }
            Set-FactoryProperty -Target $task -Name "backgroundSession" -Value $null
            Set-FactoryProperty -Target $task -Name "agentId" -Value $null
            Set-FactoryProperty -Target $task -Name "plan" -Value $null
            Set-FactoryProperty -Target $task -Name "approval" -Value $null
            Set-FactoryProperty -Target $task -Name "error" -Value $null
            Set-FactoryProperty -Target $task -Name "holdReason" -Value $null
            Set-FactoryProperty -Target $task -Name "status" -Value "queued"
            Set-FactoryProperty -Target $state -Name "active" -Value $true
            Set-FactoryProperty -Target $state -Name "paused" -Value $false
        }
        "release" {
            if ([string]$task.status -in @("approved", "integrating", "production", "syncing", "done", "rejected")) {
                throw "Task '$TaskId' is in operator-controlled state '$($task.status)' and cannot release its session."
            }
            if ($null -eq $task.backgroundSession -or -not [string]$task.backgroundSession.id) {
                throw "Task '$TaskId' has no recorded background session to release."
            }
            $recordedSession = $task.backgroundSession
            $sessionRuntime = [string](Get-FactoryNestedValue -Target $recordedSession -Name "runtime" -Default "claude")
            $liveSession = $null
            if ($sessionRuntime -eq "codex") {
                $liveSession = Get-FactoryCodexSessionSnapshot -Session $recordedSession
            } else {
                $rows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
                $recordedId = [string](Get-FactoryNestedValue -Target $recordedSession -Name "id" -Default "")
                $recordedSessionId = [string](Get-FactoryNestedValue -Target $recordedSession -Name "sessionId" -Default "")
                $liveSession = @($rows | Where-Object {
                    ($recordedId -and [string](Get-FactoryNestedValue -Target $_ -Name "id" -Default "") -eq $recordedId) -or
                    ($recordedSessionId -and [string](Get-FactoryNestedValue -Target $_ -Name "sessionId" -Default "") -eq $recordedSessionId)
                } | Select-Object -First 1)
                $liveSession = if ($liveSession.Count -gt 0) { $liveSession[0] } else { $null }
            }
            $liveState = [string](Get-FactoryNestedValue -Target $liveSession -Name "state" -Default (Get-FactoryNestedValue -Target $liveSession -Name "status" -Default ""))
            if ($null -ne $liveSession -and $liveState -notin @("stopped", "done", "failed")) {
                throw "Task '$TaskId' session is still reported as '$liveState'; use chat, answer, or rework instead of release."
            }
            $validatedResult = (
                [string]$task.commit -and
                $null -ne $task.workerResult -and
                [string](Get-FactoryNestedValue -Target $task.workerResult -Name "commit" -Default "") -eq [string]$task.commit
            )
            $hasReworkDelivery = [string](Get-FactoryNestedValue -Target $task -Name "reworkRequestedAt" -Default "") -and
                [string](Get-FactoryNestedValue -Target $task -Name "pendingInstructions" -Default "")
            $restoredStatus = if ($validatedResult) {
                "awaiting-review"
            } elseif ($hasReworkDelivery) {
                "queued"
            } elseif ($null -ne (Get-FactoryNestedValue -Target $task -Name "plan")) {
                "awaiting-input"
            } else {
                "held"
            }
            Set-FactoryProperty -Target $task -Name "backgroundSession" -Value $null
            Set-FactoryProperty -Target $task -Name "agentId" -Value $null
            Set-FactoryProperty -Target $task -Name "status" -Value $restoredStatus
            Set-FactoryProperty -Target $task -Name "error" -Value $null
            Set-FactoryProperty -Target $task -Name "holdReason" -Value $(if ($restoredStatus -eq "held") { "stale worker session released by operator" } else { $null })
            if ($restoredStatus -eq "queued") {
                Set-FactoryProperty -Target $state -Name "active" -Value $true
                Set-FactoryProperty -Target $state -Name "paused" -Value $false
            }
        }
    }

    Set-FactoryProperty -Target $task -Name "updatedAt" -Value $now
    Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state

    [ordered]@{
        taskId = $TaskId
        action = $Action
        status = [string]$task.status
        approvedCommit = if ($null -ne $task.approval) { [string]$task.approval.commit } else { $null }
        approvedPlanHash = if ($null -ne $task.approval) { [string]$task.approval.planHash } else { $null }
        approvalMode = if ($null -ne $task.approval) { [string](Get-FactoryNestedValue -Target $task.approval -Name "mode" -Default "reviewed") } else { $null }
        backgroundId = if ($null -ne $task.backgroundSession) { [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "id" -Default "") } else { $null }
        attachCommand = if ($null -ne $task.backgroundSession) { [string](Get-FactoryNestedValue -Target $task.backgroundSession -Name "attachCommand" -Default "") } else { $null }
        instructions = $Instructions
        stoppedPreview = if ($null -ne $previewCleanup) { [bool](Get-FactoryNestedValue -Target $previewCleanup -Name "stopped" -Default $false) } else { $false }
    } | ConvertTo-Json -Depth 20
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
