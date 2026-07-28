param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][ValidateSet("go", "hold", "reject", "rework")][string]$Action,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$Instructions = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json

$mutex = $null
try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId
    $now = Get-FactoryUtcTimestamp

    switch ($Action) {
        "go" {
            if ([string]$task.status -notin @("awaiting-review", "held")) {
                throw "Task '$TaskId' is '$($task.status)', not awaiting review."
            }
            if (-not [string]$task.commit -or $null -eq $task.workerResult) {
                throw "Task '$TaskId' has no validated worker commit."
            }
            if ([string]$task.workerResult.commit -ne [string]$task.commit) {
                throw "Validated worker result does not match task commit '$($task.commit)'."
            }
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

            Set-FactoryProperty -Target $task -Name "approval" -Value ([pscustomobject]@{
                commit = [string]$task.commit
                approvedAt = $now
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
        }
        "reject" {
            if ([string]$task.status -eq "done") {
                throw "A completed production task cannot be rejected."
            }
            Set-FactoryProperty -Target $task -Name "approval" -Value $null
            Set-FactoryProperty -Target $task -Name "status" -Value "rejected"
        }
        "rework" {
            if ($null -eq $task.backgroundSession -or -not [string]$task.backgroundSession.id) {
                throw "Task '$TaskId' has no background session to continue."
            }
            Set-FactoryProperty -Target $task -Name "approval" -Value $null
            Set-FactoryProperty -Target $task -Name "review" -Value $null
            Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-input"
            Set-FactoryProperty -Target $task -Name "reworkRequestedAt" -Value $now
            Set-FactoryProperty -Target $task -Name "pendingInstructions" -Value $Instructions
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
        backgroundId = if ($null -ne $task.backgroundSession) { [string]$task.backgroundSession.id } else { $null }
        attachCommand = if ($null -ne $task.backgroundSession) { [string]$task.backgroundSession.attachCommand } else { $null }
        instructions = $Instructions
    } | ConvertTo-Json -Depth 20
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
