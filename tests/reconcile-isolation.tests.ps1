param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\publication-ci.ps1')
. (Join-Path $PluginRoot 'scripts\attention-state.ps1')

function Assert-Reconcile { param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Save-ReconcileState { param($Value)
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    try { Write-FactoryJsonAtomic -Path $context.statePath -Value $Value }
    finally { Exit-FactoryMutex $mutex }
}
function New-ReconcileTask { param([string]$Id, [string]$Branch, [string]$Worktree)
    [pscustomobject]@{
        id = $Id; title = $Id; status = 'running'; startMode = 'auto'
        branch = $Branch; worktree = $Worktree; commit = $null; workerResult = $null
        resultRecordedAt = $null; updatedAt = Get-FactoryUtcTimestamp
        backgroundSession = [pscustomobject]@{
            runtime = 'claude'; id = "background-$Id"; sessionId = "session-$Id"
            name = "worker-$Id"; state = 'done'
        }
    }
}
function Save-ReconcileResult { param($Task, [string]$Sha, [string]$Worktree)
    $directory = Join-Path $context.eventsPath (ConvertTo-FactoryTaskArtifactName -TaskId $Task.id)
    $null = New-Item -ItemType Directory -Path $directory -Force
    $event = [pscustomobject]@{
        sessionId = $Task.backgroundSession.sessionId; capturedAt = Get-FactoryUtcTimestamp
        payload = [pscustomobject]@{
            status = 'completed'; taskId = $Task.id; branch = $Task.branch
            commit = $Sha; worktree = $Worktree; tests = @(); notes = ''; blockingReason = ''
        }
    }
    Write-FactoryJsonAtomic -Path (Join-Path $directory 'latest-result.json') -Value $event
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('factory-reconcile-isolation-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixture 'repository'
$badWorktree = Join-Path $fixture 'bad-worker'
$goodWorktree = Join-Path $fixture 'good-worker'
$savedRuntimeHome = $env:CLAUDE_FACTORY_HOME
$env:CLAUDE_FACTORY_HOME = Join-Path $fixture 'runtime'
try {
    $null = New-Item -ItemType Directory -Path $repository -Force
    & git -C $repository init -q
    & git -C $repository config user.name 'Factory Test'
    & git -C $repository config user.email 'factory-test@example.invalid'
    [IO.File]::WriteAllText((Join-Path $repository 'README.md'), "base`n")
    & git -C $repository add README.md
    & git -C $repository commit -qm 'fixture base'
    & git -C $repository worktree add -qb factory-worker/bad $badWorktree
    & git -C $repository worktree add -qb factory-worker/good $goodWorktree
    [IO.File]::AppendAllText((Join-Path $goodWorktree 'README.md'), "good`n")
    & git -C $goodWorktree add README.md
    & git -C $goodWorktree commit -qm 'healthy worker result'
    $badHead = (& git -C $badWorktree rev-parse HEAD).Trim()
    $goodHead = (& git -C $goodWorktree rev-parse HEAD).Trim()
    $fabricated = $badHead.Substring(0, 8) + ('0' * 32)
    if ($fabricated -eq $badHead) { $fabricated = $badHead.Substring(0, 8) + ('1' * 32) }
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize) | ConvertFrom-Json
    $state = Read-FactoryJson -Path $context.statePath
    $badTask = New-ReconcileTask -Id 'bad-sha' -Branch 'factory-worker/bad' -Worktree $badWorktree
    $goodTask = New-ReconcileTask -Id 'good-sha' -Branch 'factory-worker/good' -Worktree $goodWorktree
    $state.tasks = @($badTask, $goodTask)
    Save-ReconcileState $state
    Save-ReconcileResult -Task $badTask -Sha $fabricated -Worktree $badWorktree
    Save-ReconcileResult -Task $goodTask -Sha $goodHead -Worktree $goodWorktree

    $reconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\reconcile-worker-sessions.ps1') -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    $state = Read-FactoryJson -Path $context.statePath
    Assert-Reconcile ($reconcile.changed -eq 2) 'Reconcile did not process both tasks.'
    Assert-Reconcile ($state.tasks[0].status -eq 'awaiting-input' -and $state.tasks[0].error -eq "Worker commit is not valid: $fabricated") 'Fabricated SHA was not isolated with the precise validation error.'
    Assert-Reconcile ($state.tasks[1].status -eq 'awaiting-review' -and $state.tasks[1].commit -eq $goodHead) 'A bad worker SHA prevented healthy reconciliation.'

    # An unrelated per-task exception must also leave the rest of the loop intact.
    $state.tasks[0].status = 'running'; $state.tasks[0].resultRecordedAt = $null
    $state.tasks[1].status = 'running'; $state.tasks[1].resultRecordedAt = $null
    Save-ReconcileState $state
    Save-ReconcileResult -Task $badTask -Sha $badHead -Worktree ("bad" + [char]0 + "path")
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\reconcile-worker-sessions.ps1') -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    $state = Read-FactoryJson -Path $context.statePath
    Assert-Reconcile ($state.tasks[0].status -eq 'failed' -and $state.tasks[0].error -match 'Reconciliation failed for task') 'Per-task exception escaped or was not recorded.'
    Assert-Reconcile ($state.tasks[1].status -eq 'awaiting-review') 'Per-task exception stopped a later healthy task.'

    foreach ($task in $state.tasks) { $task.status = 'done' }
    Save-ReconcileState $state
    Register-FactoryCiPublication -Context $context -Task $goodTask -Slug 'fixture/project' -Branch develop -Sha $goodHead
    $journal = Read-FactoryCiJournal $context
    $entry = $journal.entries[0]
    $entry.status = 'unverified'; $entry.error = 'Native command gh timed out after 15 seconds.'
    $entry.lastPollAt = Get-FactoryUtcTimestamp
    Write-FactoryJsonAtomic -Path (Get-FactoryCiPath $context) -Value $journal
    $firstWait = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\wait-factory.ps1') -Repository $repository -TimeoutSeconds 1 -PollMilliseconds 100) | ConvertFrom-Json
    $secondWait = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\wait-factory.ps1') -Repository $repository -TimeoutSeconds 1 -PollMilliseconds 100) | ConvertFrom-Json
    Assert-Reconcile ($firstWait.signaled -and @($firstWait.actions | Where-Object { $_.kind -eq 'publication-ci' }).Count -eq 1) 'First wait did not return the unverified CI edge.'
    Assert-Reconcile (-not $secondWait.signaled -and $secondWait.timedOut) 'Default wait replayed an acknowledged unverified CI edge.'

    $state = Read-FactoryJson -Path $context.statePath
    $state.scheduler = [pscustomobject]@{
        status = 'failed'; pid = $PID
        processStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        lastError = 'reconcile failed'; failureCount = 3; lastFailureAt = Get-FactoryUtcTimestamp
    }
    Save-ReconcileState $state
    $config = Read-FactoryJson -Path $context.configPath
    $firstAttention = Sync-FactoryAttentionState -Context $context -State $state -Config $config
    Assert-Reconcile (@($firstAttention.events | Where-Object { $_.kind -eq 'scheduler-tick' }).Count -eq 1) 'Three failed ticks produced no attention edge.'
    $state.scheduler.failureCount = 4
    $state.scheduler.lastError = 'reconcile still failed'
    $secondAttention = Sync-FactoryAttentionState -Context $context -State $state -Config $config
    Assert-Reconcile ($firstAttention.revision -eq $secondAttention.revision) 'Repeated failed ticks produced duplicate attention edges.'
    Save-ReconcileState $state
    $statusText = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') status -NoReconcile -Repository $repository | Out-String)
    Assert-Reconcile ($statusText -match 'PROBLEMS' -and $statusText -match 'reconcile still failed') 'Status hid the live scheduler tick failure from PROBLEMS.'
    $tickWait = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\wait-factory.ps1') -Repository $repository -TimeoutSeconds 1 -PollMilliseconds 100) | ConvertFrom-Json
    Assert-Reconcile ($tickWait.signaled -and @($tickWait.actions | Where-Object { $_.kind -eq 'scheduler-tick' }).Count -eq 1) 'Wait did not report the sustained scheduler failure.'
    $state.scheduler.failureCount = 5
    $state.scheduler.lastError = 'another failed tick'
    Save-ReconcileState $state
    $repeatTickWait = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\wait-factory.ps1') -Repository $repository -TimeoutSeconds 1 -PollMilliseconds 100) | ConvertFrom-Json
    Assert-Reconcile (-not $repeatTickWait.signaled -and $repeatTickWait.timedOut) 'Wait replayed the unchanged scheduler failure.'
    Write-Output "Reconcile isolation and wait regressions passed under PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $env:CLAUDE_FACTORY_HOME = $savedRuntimeHome
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ((Split-Path $resolved -Leaf) -notlike 'factory-reconcile-isolation-*' -or
        -not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected reconcile fixture cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
