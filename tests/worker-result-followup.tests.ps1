param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\worker-event.ps1')

function Assert-Followup {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-Followup ((ConvertFrom-FactoryWorkerMarkerMessage 'The FACTORY_RESULT above remains in force.').kind -eq 'message') 'Inline prose was classified as a marker.'
Assert-Followup ((ConvertFrom-FactoryWorkerMarkerMessage "FACTORY_RESULT`nNo JSON follows.").kind -eq 'invalid-marker') 'Standalone marker without JSON was accepted.'
Assert-Followup ((ConvertFrom-FactoryWorkerMarkerMessage ('FACTORY_RESULT: ```json' + "`n" + '{"status":"completed"}')).kind -eq 'result') 'Inline fenced JSON was not parsed.'
Assert-Followup ((ConvertFrom-FactoryWorkerMarkerMessage 'FACTORY_RESULT: {"status": broken}').kind -eq 'invalid-marker') 'Inline broken JSON was accepted.'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "factory-result-followup-$([Guid]::NewGuid().ToString('N'))"
$repository = Join-Path $fixtureRoot 'repository'
$runtimeHome = Join-Path $fixtureRoot 'runtime'
$shellCommand = (Get-Process -Id $PID).Path
$savedRuntimeHome = $env:CLAUDE_FACTORY_HOME
try {
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    $env:CLAUDE_FACTORY_HOME = $runtimeHome
    & git init -b factory-worker/followup $repository | Out-Null
    & git -C $repository config user.name 'Factory Test'
    & git -C $repository config user.email 'factory-test@example.invalid'
    [IO.File]::WriteAllText((Join-Path $repository 'README.md'), "first`n", (New-Object Text.UTF8Encoding($false)))
    & git -C $repository add README.md
    & git -C $repository commit -m 'test: initial result' | Out-Null
    $commit = (& git -C $repository rev-parse HEAD).Trim()

    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize) | ConvertFrom-Json
    $state = Read-FactoryJson -Path $context.statePath
    $task = [pscustomobject]@{
        id = 'followup'; title = 'Follow-up marker'; brief = 'Fixture'; startMode = 'auto'
        status = 'running'; branch = 'factory-worker/followup'; worktree = $repository
        commit = $null; workerResult = $null; review = $null; approval = $null
        error = $null; resultRecordedAt = $null; reworkRequestedAt = $null
        backgroundSession = [pscustomobject]@{
            runtime = 'claude'; id = 'fixture-agent'; sessionId = 'fixture-session'
            name = 'fixture-worker'; state = 'working'; transcriptPath = ''
        }
        createdAt = (Get-FactoryUtcTimestamp); updatedAt = (Get-FactoryUtcTimestamp)
    }
    $state.tasks = @($task)
    $stateMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
    try {
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    } finally {
        Exit-FactoryMutex -Mutex $stateMutex
    }

    $result = [ordered]@{
        taskId = 'followup'; status = 'completed'; branch = 'factory-worker/followup'
        worktree = $repository; commit = $commit; notes = 'Ready for review.'
        tests = @(); blockingReason = ''
    }
    $resultMessage = "FACTORY_RESULT`n" + ($result | ConvertTo-Json -Depth 10)
    $null = Publish-FactoryWorkerEvent -Context $context -Task $task -SessionId 'fixture-session' -Worktree $repository -Message $resultMessage
    $reconcileScript = Join-Path $PluginRoot 'scripts\reconcile-worker-sessions.ps1'
    $reconcile = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File $reconcileScript -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    Assert-Followup ($LASTEXITCODE -eq 0) 'Initial result reconciliation failed.'
    $task = (Read-FactoryJson -Path $context.statePath).tasks[0]
    Assert-Followup ($task.status -eq 'awaiting-review' -and $task.commit -eq $commit) 'Initial result did not enter review.'

    $resultPath = Join-Path (Join-Path $context.eventsPath 'followup') 'latest-result.json'
    $latestPath = Join-Path (Join-Path $context.eventsPath 'followup') 'latest.json'
    $resultEvent = Read-FactoryJson -Path $resultPath
    $baseTime = ConvertTo-FactoryUtcDateTime -Value $resultEvent.capturedAt
    $prose = 'The FACTORY_RESULT above remains in force; the commit is ready.'
    $null = Publish-FactoryWorkerEvent -Context $context -Task $task -SessionId 'fixture-session' -Worktree $repository -Message $prose
    $latest = Read-FactoryJson -Path $latestPath
    $latest.capturedAt = $baseTime.AddSeconds(8).ToString('o')
    Write-FactoryJsonAtomic -Path $latestPath -Value $latest
    $null = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File $reconcileScript -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    Assert-Followup ($LASTEXITCODE -eq 0) 'Prose follow-up reconciliation failed.'
    $task = (Read-FactoryJson -Path $context.statePath).tasks[0]
    Assert-Followup ($task.status -eq 'awaiting-review' -and $task.commit -eq $commit) 'Later prose displaced a valid result.'
    Assert-Followup ([string]$task.workerEventWarning -match 'FACTORY_RESULT above remains') 'Prose warning was not recorded.'
    $inspect = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') inspect followup -Repository $repository -NoReconcile | Out-String)
    Assert-Followup ($inspect.Contains('Warning: Worker follow-up')) 'Inspect omitted the later message warning.'

    $null = Publish-FactoryWorkerEvent -Context $context -Task $task -SessionId 'fixture-session' -Worktree $repository -Message "FACTORY_RESULT`n{`"status`": broken}"
    $latest = Read-FactoryJson -Path $latestPath
    $latest.capturedAt = $baseTime.AddSeconds(16).ToString('o')
    Write-FactoryJsonAtomic -Path $latestPath -Value $latest
    $null = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File $reconcileScript -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    Assert-Followup ($LASTEXITCODE -eq 0) 'Broken marker follow-up reconciliation failed.'
    $task = (Read-FactoryJson -Path $context.statePath).tasks[0]
    Assert-Followup ($task.status -eq 'awaiting-review' -and [string]$task.workerEventWarning -match 'Invalid FACTORY_RESULT follow-up') 'Broken marker displaced a still-valid result.'

    $task.review = [pscustomobject]@{ verdict = 'approved'; commit = $commit; summary = 'Fixture review' }
    $state = Read-FactoryJson -Path $context.statePath
    $state.tasks[0] = $task
    $stateMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
    try {
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    } finally {
        Exit-FactoryMutex -Mutex $stateMutex
    }
    $null = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File $reconcileScript -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    $task = (Read-FactoryJson -Path $context.statePath).tasks[0]
    Assert-Followup ($task.review.verdict -eq 'approved') 'Follow-up validation reset an existing review.'

    [IO.File]::AppendAllText((Join-Path $repository 'README.md'), "second`n", (New-Object Text.UTF8Encoding($false)))
    & git -C $repository add README.md
    & git -C $repository commit -m 'test: move HEAD' | Out-Null
    $null = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File $reconcileScript -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    Assert-Followup ($LASTEXITCODE -eq 0) 'Moved HEAD reconciliation failed.'
    $task = (Read-FactoryJson -Path $context.statePath).tasks[0]
    Assert-Followup ($task.status -eq 'awaiting-input' -and [string]$task.error -match 'Invalid FACTORY_RESULT payload') 'Moved HEAD did not expose the broken result marker.'

    $result.commit = (& git -C $repository rev-parse HEAD).Trim()
    $correctedMessage = "FACTORY_RESULT`n" + ($result | ConvertTo-Json -Depth 10)
    $null = Publish-FactoryWorkerEvent -Context $context -Task $task -SessionId 'fixture-session' -Worktree $repository -Message $correctedMessage
    $null = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File $reconcileScript -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    $task = (Read-FactoryJson -Path $context.statePath).tasks[0]
    Assert-Followup ($task.status -eq 'awaiting-review' -and $task.commit -eq $result.commit) 'Corrected result did not restore review.'
    Assert-Followup (-not [string]$task.workerEventWarning) 'Corrected result retained an obsolete warning.'

    # An unsynced moved HEAD must still fail when a later message arrives.
    $oldResultEvent = Read-FactoryJson -Path $resultPath
    $oldResultTime = ConvertTo-FactoryUtcDateTime -Value $oldResultEvent.capturedAt
    [IO.File]::AppendAllText((Join-Path $repository 'README.md'), "third`n", (New-Object Text.UTF8Encoding($false)))
    & git -C $repository add README.md
    & git -C $repository commit -m 'test: rebased HEAD fixture' | Out-Null
    $rebasedCommit = (& git -C $repository rev-parse HEAD).Trim()
    $null = Publish-FactoryWorkerEvent -Context $context -Task $task -SessionId 'fixture-session' -Worktree $repository -Message 'A later plain-text follow-up.'
    $latest = Read-FactoryJson -Path $latestPath
    $latest.capturedAt = $oldResultTime.AddSeconds(30).ToString('o')
    Write-FactoryJsonAtomic -Path $latestPath -Value $latest
    $null = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File $reconcileScript -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    $task = (Read-FactoryJson -Path $context.statePath).tasks[0]
    Assert-Followup ($task.status -eq 'failed' -and [string]$task.error -match 'does not match result commit') 'An unsynced moved HEAD did not fail validation.'

    # Model sync-task.ps1 finalize: it adopts the new HEAD and stamps a later
    # resultRecordedAt, while latest-result.json still holds the old commit.
    $state = Read-FactoryJson -Path $context.statePath
    $task = $state.tasks[0]
    $task.commit = $rebasedCommit
    $task.workerResult.commit = $rebasedCommit
    $task.status = 'awaiting-review'
    $task.error = $null
    $task.resultRecordedAt = $oldResultTime.AddSeconds(60).ToString('o')
    $state.tasks[0] = $task
    $stateMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
    try {
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    } finally {
        Exit-FactoryMutex -Mutex $stateMutex
    }

    $null = Publish-FactoryWorkerEvent -Context $context -Task $task -SessionId 'fixture-session' -Worktree $repository -Message 'Still chatting after orchestrator sync.'
    $latest = Read-FactoryJson -Path $latestPath
    $latest.capturedAt = $oldResultTime.AddSeconds(90).ToString('o')
    Write-FactoryJsonAtomic -Path $latestPath -Value $latest
    $null = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File $reconcileScript -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    $task = (Read-FactoryJson -Path $context.statePath).tasks[0]
    Assert-Followup ($task.status -eq 'awaiting-review' -and $task.commit -eq $rebasedCommit -and
        $task.workerResult.commit -eq $rebasedCommit -and -not $task.error) 'Late message revalidated a result superseded by sync.'

    $null = Publish-FactoryWorkerEvent -Context $context -Task $task -SessionId 'fixture-session' -Worktree $repository -Message 'FACTORY_RESULT: {"status": broken}'
    $latest = Read-FactoryJson -Path $latestPath
    $latest.capturedAt = $oldResultTime.AddSeconds(120).ToString('o')
    Write-FactoryJsonAtomic -Path $latestPath -Value $latest
    $null = (& $shellCommand -NoProfile -ExecutionPolicy Bypass -File $reconcileScript -Repository $repository -ClaudeCommand 'missing-factory-claude-fixture') | ConvertFrom-Json
    $task = (Read-FactoryJson -Path $context.statePath).tasks[0]
    Assert-Followup ($task.status -eq 'awaiting-review' -and $task.commit -eq $rebasedCommit -and
        $task.workerResult.commit -eq $rebasedCommit -and -not $task.error) 'Late invalid marker displaced a synced result.'

    Write-Output "Worker result follow-up tests passed under PowerShell $($PSVersionTable.PSVersion)."
} finally {
    $env:CLAUDE_FACTORY_HOME = $savedRuntimeHome
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
