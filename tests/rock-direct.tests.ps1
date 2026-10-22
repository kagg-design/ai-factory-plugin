[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PluginRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\rock-actions.ps1')
function Assert-Rock { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-RockThrows { param([scriptblock]$Code, [string]$Pattern) $caught = ''; try { & $Code | Out-Null } catch { $caught = $_.Exception.Message }; Assert-Rock ($caught -match $Pattern) "Expected '$Pattern', got '$caught'." }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "factory-rock-tests-$([Guid]::NewGuid().ToString('N'))"
$oldFactoryHome = $env:CLAUDE_FACTORY_HOME
$env:CLAUDE_FACTORY_HOME = Join-Path $testRoot 'factory'
$repository = Join-Path $testRoot 'repository'
$configurationPath = Join-Path $testRoot 'rock-config.json'
function Update-RockFixtureState {
    param([scriptblock]$Mutator)
    $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
    try { $state = Read-FactoryJson $context.statePath; & $Mutator $state; Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $mutex }
}
try {
    $null = New-Item -ItemType Directory -Path $repository -Force
    git -C $repository init --quiet
    git -C $repository config user.name 'ROCK Test'
    git -C $repository config user.email 'rock-test@example.test'
    git -C $repository config commit.gpgsign false
    [IO.File]::WriteAllText((Join-Path $repository 'README.txt'), 'fixture')
    git -C $repository add README.txt
    git -C $repository commit --quiet -m fixture
    $context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
    $configuration = [ordered]@{
        claudePath = 'must-never-run'; timeoutMinutes = 1
        direct = @{ enabled = $true; memoryDir = (Join-Path $testRoot 'rocks') }
        orchestrators = @(
            @{ name = 'access'; epicGid = '100'; epicUrl = 'https://app.asana.com/0/0/100'; repoPath = $repository; extraDirs = @(); ownedTasks = @(@{taskId='123';repository=$repository;requiresMergeGate=$true}, @{taskId='124';repository=$repository}); watchedTasks = @() },
            @{ name = 'billing'; epicGid = '200'; epicUrl = 'https://app.asana.com/0/0/200'; repoPath = $repository; extraDirs = @(); ownedTasks = @(); watchedTasks = @(@{taskId='123';repository=$repository}) }
        )
    }
    Write-FactoryJsonAtomic $configurationPath $configuration
    $rock = Get-FactoryRockConfiguration -ConfigPath $configurationPath
    $owner = Get-FactoryRockOrchestrator $rock '100'
    $watcher = Get-FactoryRockOrchestrator $rock '200'
    $config = Read-FactoryJson $context.configPath
    $config.rocks.enabled = $true; $config.rocks.configPath = $configurationPath
    $config.nativeScheduler.enabled = $false
    $config.asana.tokenEnv = 'FACTORY_ROCK_TEST_' + [Guid]::NewGuid().ToString('N')
    Write-FactoryJsonAtomic $context.configPath $config
    Update-RockFixtureState { param($state) $state.active = $true }
    & {
        $counter = [pscustomobject]@{value=0}
        function Start-Process { param($FilePath,$WindowStyle,$ArgumentList,[switch]$PassThru) $counter.value++; return [pscustomobject]@{Id=12345} }
        $config.launcher.path = Join-Path $PluginRoot 'rock-cycle.ps1'
        Start-FactoryRockCycle -Config $config -Reason Done -Gid '123'
        Assert-Rock ($counter.value -eq 0) 'Direct owner received a duplicate legacy launcher wake.'
        Start-FactoryRockCycle -Config $config -Reason Done -Gid '999'
        Assert-Rock ($counter.value -eq 1) 'A direct pilot disabled legacy wake-ups for unbound tasks.'
    }

    Assert-Rock ((Get-FactoryRockPaths $rock '100').root -ne (Get-FactoryRockPaths $rock '200').root) 'ROCKs share state.'
    $renamed = $owner.name; $owner.name = 'renamed'
    Assert-Rock ((Get-FactoryRockPaths $rock '100').root -like '*\100') 'Rename changes ROCK storage identity.'
    $owner.name = $renamed
    Assert-Rock (Test-FactoryRockBinding $owner '123' $repository) 'Owner binding missing.'
    Assert-Rock (-not (Test-FactoryRockBinding $watcher '123' $repository)) 'Watcher has owner authority.'
    Assert-Rock (Test-FactoryRockBinding $watcher '123' $repository -IncludeWatched) 'Watcher did not receive observations.'
    Assert-RockThrows { Get-FactoryRockPaths $rock '..\escape' } 'identity'
    $dryRun = @(& (Join-Path $PluginRoot 'rock-cycle.ps1') -ConfigPath $configurationPath -DryRun)
    Assert-Rock (($dryRun -join ' ') -match 'Direct ROCK' -and -not (Test-Path -LiteralPath $rock.direct.memoryDir)) 'Direct dry-run wrote state or launched work.'
    $configuration.direct.memoryDir = Join-Path $repository 'private'
    Write-FactoryJsonAtomic $configurationPath $configuration
    Assert-RockThrows { Get-FactoryRockConfiguration -ConfigPath $configurationPath } 'outside Git'
    $configuration.direct.memoryDir = Join-Path $testRoot 'rocks'
    Write-FactoryJsonAtomic $configurationPath $configuration
    $configuration.orchestrators[1].ownedTasks = @(@{taskId='123';repository=$repository})
    Assert-RockThrows { Write-FactoryJsonAtomic $configurationPath $configuration; Get-FactoryRockConfiguration -ConfigPath $configurationPath } 'multiple ROCK owners|Duplicate'
    $configuration.orchestrators[1].ownedTasks = @()
    Write-FactoryJsonAtomic $configurationPath $configuration

    $payload = @{ kind = 'done'; taskId = '123'; repository = $repository; owner = $true }
    $head = (& git -C $repository rev-parse HEAD).Trim()
    $codePath = Write-FactoryRockCodeEvidence -Orchestrator $owner -Event ([pscustomobject]@{payload=[pscustomobject]@{commit=$head;taskId='123';repository=$repository}}) -Path (Join-Path $testRoot 'code-evidence.json')
    $codeEvidence = Read-FactoryJson $codePath
    Assert-Rock ($codeEvidence.available -and $codeEvidence.commit -ceq $head -and $codeEvidence.diff -match 'fixture') 'Exact local commit evidence was not captured.'
    Assert-RockThrows { Write-FactoryRockCodeEvidence -Orchestrator $watcher -Event ([pscustomobject]@{payload=[pscustomobject]@{commit=$head;taskId='124';repository=$repository}}) -Path (Join-Path $testRoot 'forbidden-code.json') } 'configured ROCK task'
    $eventPath = Add-FactoryRockEvent $rock '100' 'completed-123' $payload
    $again = Add-FactoryRockEvent $rock '100' 'completed-123' @{ kind = 'tampered' }
    Assert-Rock ($again -ceq $eventPath -and (Read-FactoryJson $again).payload.kind -eq 'done') 'Event deduplication changed original evidence.'
    $eventId = (Read-FactoryJson $eventPath).id
    $valid = @{ version = 1; eventId = $eventId; summary = 'Current checkpoint'; decisions = @('Keep the existing contract'); actions = @() } | ConvertTo-Json -Depth 10
    $result = ConvertFrom-FactoryRockResult $valid $eventId
    Assert-Rock ($result.summary -eq 'Current checkpoint') 'Result could not be parsed.'
    $wrapped = @{result="ROCK_RESULT`n$valid";is_error=$false} | ConvertTo-Json -Depth 15
    Assert-Rock ((ConvertFrom-FactoryRockResult $wrapped $eventId).eventId -ceq $eventId) 'CLI JSON envelope was not parsed.'
    Assert-RockThrows { ConvertFrom-FactoryRockResult $valid ('a' * 64) } 'match'
    $forbidden = @{version=1;eventId=$eventId;summary='x';decisions=@();actions=@(@{id='go';type='approve';text='approve'})} | ConvertTo-Json -Depth 10
    Assert-RockThrows { ConvertFrom-FactoryRockResult $forbidden $eventId } 'Unsupported'
    $forged = @{version=1;eventId=$eventId;summary='x';decisions=@(@{actor='operator';text='yes'});actions=@()} | ConvertTo-Json -Depth 10
    Assert-RockThrows { ConvertFrom-FactoryRockResult $forged $eventId } 'decision'

    $script:modelCalls = 0
    Invoke-FactoryRockEvent $rock $owner $eventPath { param($prompt, $request) $script:modelCalls++; $valid }
    Assert-Rock ((Read-FactoryJson $eventPath).status -eq 'completed') 'Memory-only cycle did not complete.'
    Invoke-FactoryRockEvent $rock $owner $eventPath { throw 'Completed cycle reran' }
    $memory = Read-FactoryRockMemory $rock '100'
    Assert-Rock ($script:modelCalls -eq 1 -and $memory.decisions.Count -eq 1 -and $memory.decisions[0].actor -eq 'rock:100') 'Decision attribution/deduplication failed.'
    Assert-Rock ($memory.summary -eq 'Current checkpoint') 'Checkpoint did not survive a fresh read.'
    $null = Update-FactoryRockMemory $rock '100' { param($row) $row.summary = 'Newer checkpoint' }
    Assert-Rock (Test-Path -LiteralPath "$((Get-FactoryRockPaths $rock '100').memory).previous.bak") 'Memory lost its preceding recovery revision.'

    $event = Read-FactoryJson $eventPath
    $dispatch = [pscustomobject]@{id='dispatch';type='dispatch';taskId='123';repository=$repository;title='Native direct task';brief='Implement within existing requirements';acceptanceCriteria=@('Pass focused tests')}
    Invoke-FactoryRockAction $rock $owner $event $dispatch
    Invoke-FactoryRockAction $rock $owner $event $dispatch
    $state = Read-FactoryJson $context.statePath
    Assert-Rock ($state.tasks.Count -eq 1 -and $state.tasks[0].rockId -eq '100' -and $state.tasks[0].status -eq 'queued') 'Direct intake did not queue exactly one task.'
    Assert-Rock ($state.tasks[0].brief -match 'Merge gate: ask Igor before merging' -and -not $state.tasks[0].asanaMode) 'Direct intake dropped a configured merge gate or entered the Asana transport.'
    Assert-RockThrows { Invoke-FactoryRockAction $rock $watcher $event $dispatch } 'ownership'
    Assert-RockThrows { $dispatch.id='different'; Invoke-FactoryRockAction $rock $owner $event $dispatch } 'existing'
    $dispatch.id = 'dispatch'

    $worktree = Join-Path $testRoot 'retained-worker'; $null = New-Item -ItemType Directory -Path $worktree
    Update-RockFixtureState {
        param($state)
        $task = $state.tasks[0]; $task.status='running'; $task.attempts=1; $task.worktree=$worktree
    }
    $null = & (Join-Path $PluginRoot 'scripts\asana-question.ps1') -Repository $repository -TaskId '123' -Question 'Which option?' -QuestionContext 'Existing requirements' -Options 'A or B'
    $questionToken = (Read-FactoryJson $context.statePath).tasks[0].asanaQuestion.storyGid
    Assert-Rock ($questionToken -like 'rock:*') 'Question creation did not use the local transport without a token.'
    $config.rocks.enabled=$false; Write-FactoryJsonAtomic $context.configPath $config
    Assert-RockThrows { & (Join-Path $PluginRoot 'scripts\asana-question.ps1') -Repository $repository -TaskId '123' -Question 'Another?' -QuestionContext 'Disabled direct transport' -Options 'A or B' } 'configuration is unavailable'
    $config.rocks.enabled=$true; Write-FactoryJsonAtomic $context.configPath $config
    $null = & (Join-Path $PluginRoot 'scripts\asana-question.ps1') -Repository $repository -TaskId '123' -Question 'Which option?' -QuestionContext 'Existing requirements' -Options 'A or B'
    Assert-Rock ((Read-FactoryJson $context.statePath).tasks[0].asanaQuestion.storyGid -ceq $questionToken) 'Repeated question changed its correlation ID.'
    Update-RockFixtureState { param($state) $state.tasks[0].status='blocked'; $state.tasks[0].workerResult = [pscustomobject]@{status='blocked'} }
    $state = Read-FactoryJson $context.statePath
    Sync-FactoryRockTaskEvents $context $config $state
    $events = @(Get-ChildItem (Get-FactoryRockPaths $rock '100').events -Filter '*.json' | ForEach-Object { Read-FactoryJson $_.FullName })
    $questionEvent = @($events | Where-Object { $_.payload.kind -eq 'Question' })[0]
    Assert-Rock ($null -ne $questionEvent) 'Question was not durably published.'
    $watcherEvents = @(Get-ChildItem (Get-FactoryRockPaths $rock '200').events -Filter '*.json' | ForEach-Object { Read-FactoryJson $_.FullName })
    Assert-Rock ($watcherEvents.Count -eq 1 -and -not $watcherEvents[0].payload.owner) 'Watched question granted owner authority.'
    $answer = [pscustomobject]@{id='answer';type='answer';taskId='123';repository=$repository;questionId=$questionToken;text='Use the documented option A.'}
    Update-RockFixtureState { param($state) $state.paused=$true }
    Assert-RockThrows { Invoke-FactoryRockAction $rock $owner $questionEvent $answer } 'paused'
    Assert-Rock ((Read-FactoryJson $context.statePath).paused) 'ROCK silently unpaused Factory.'
    Update-RockFixtureState { param($state) $state.paused=$false; $state.tasks[0].asanaQuestion.requiresHuman=$true }
    Assert-RockThrows { Invoke-FactoryRockAction $rock $owner $questionEvent $answer } 'operator decision'
    Update-RockFixtureState { param($state) $state.tasks[0].asanaQuestion.requiresHuman=$false }
    Update-RockFixtureState { param($state) $state.active=$false }
    Assert-RockThrows { Invoke-FactoryRockAction $rock $owner $questionEvent $answer } 'inactive'
    Assert-Rock (-not (Read-FactoryJson $context.statePath).active) 'ROCK reactivated an inactive Factory.'
    $inactiveEdges = @(Get-FactoryRockAttentionEvents $context $config | Where-Object kind -eq 'rock-factory-inactive')
    Assert-Rock ($inactiveEdges.Count -eq 1 -and $inactiveEdges[0].humanDecision -and -not $inactiveEdges[0].aiActionable) 'Inactive Factory did not request an explicit human resume.'
    Update-RockFixtureState { param($state) $state.active=$true; $state.tasks[0].status='held' }
    Assert-RockThrows { Invoke-FactoryRockAction $rock $owner $questionEvent $answer } 'held'
    Update-RockFixtureState { param($state) $state.tasks[0].status='blocked' }
    $answer.questionId = 'rock:stale'
    Assert-RockThrows { Invoke-FactoryRockAction $rock $owner $questionEvent $answer } 'correlate'
    $answer.questionId = $questionToken
    Invoke-FactoryRockAction $rock $owner $questionEvent $answer
    Invoke-FactoryRockAction $rock $owner $questionEvent $answer
    $state = Read-FactoryJson $context.statePath
    Assert-Rock ($state.tasks[0].status -eq 'queued' -and $state.tasks[0].attempts -eq 2 -and $null -eq $state.tasks[0].asanaQuestion) 'Direct answer did not resume once.'
    Assert-Rock ($state.tasks[0].rockAnswer.actor -eq 'rock:100' -and -not $state.tasks[0].approval) 'ROCK impersonated the operator or granted approval.'
    Assert-Rock ((Get-Content (Join-Path $worktree 'FACTORY-DECISIONS.md') -Raw) -match 'documented option') 'Worker did not receive its answer.'
    Update-RockFixtureState { param($state) $state.tasks[0].status='running'; $state.tasks[0].workerResult=$null }
    $null = & (Join-Path $PluginRoot 'scripts\asana-question.ps1') -Repository $repository -TaskId '123' -Question 'Approve scope?' -QuestionContext 'Needs a human decision' -Options 'A or B' -RequiresHuman
    Update-RockFixtureState { param($state) $state.tasks[0].status='blocked'; $state.tasks[0].workerResult=[pscustomobject]@{status='blocked'} }
    $null = & (Join-Path $PluginRoot 'factory.ps1') answer '123' --text 'Keep scope A.' -Repository $repository -NoReconcile
    $operatorState = Read-FactoryJson $context.statePath
    Assert-Rock ($operatorState.tasks[0].rockAnswer.actor -eq 'operator' -and $operatorState.tasks[0].attempts -eq 3 -and -not $operatorState.tasks[0].approval) 'Operator answer was not attributed correctly or approved publication.'
    Sync-FactoryRockTaskEvents $context $config $operatorState
    $revision = (Read-FactoryRockMemory $rock '100').revision
    Sync-FactoryRockTaskEvents $context $config $operatorState
    Assert-Rock ((Read-FactoryRockMemory $rock '100').revision -eq $revision) 'Routine polling rewrote an already-imported operator decision.'

    $replayPath = Add-FactoryRockEvent $rock '100' 'replay' $payload
    $replay = Read-FactoryJson $replayPath
    $replay.result = @{version=1;eventId=$replay.id;summary='After replay';decisions=@();actions=@($dispatch)}
    # Simulate a saved model result and a lost action receipt after native intake.
    $replay.result.actions[0].id = 'dispatch'
    $mutex = Enter-FactoryMutex $context.projectKey
    try { $state=Read-FactoryJson $context.statePath; $state.tasks[0].rockDispatchId="$($replay.id)/dispatch"; Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $mutex }
    Write-FactoryJsonAtomic $replayPath $replay
    Invoke-FactoryRockEvent $rock $owner $replayPath { throw 'Saved result called model again' }
    Assert-Rock ((Read-FactoryJson $replayPath).status -eq 'completed' -and (Read-FactoryJson $context.statePath).tasks.Count -eq 1) 'Crash replay duplicated native intake.'

    $escalationPath = Add-FactoryRockEvent $rock '100' 'escalate' $payload
    Invoke-FactoryRockEvent $rock $owner $escalationPath {
        param($prompt,$request)
        @{version=1;eventId=$request.event.id;summary='Waiting for operator';decisions=@();actions=@(@{id='ask';type='escalate';text='Choose scope. A keeps it small; B expands it. Recommend A.'})} | ConvertTo-Json -Depth 10
    }
    $attention = @(Get-FactoryRockAttentionEvents $context $config)
    Assert-Rock ($attention.Count -eq 1 -and $attention[0].humanDecision -and -not $attention[0].aiActionable) 'Escalation was not a durable human-only notification.'
    $null = & (Join-Path $PluginRoot 'factory.ps1') rock questions -Repository $repository
    $questionId = (Read-FactoryRockMemory $rock '100').questions[0].id
    $null = & (Join-Path $PluginRoot 'factory.ps1') rock answer '100' $questionId --text 'Keep the original scope.' -Repository $repository
    $null = & (Join-Path $PluginRoot 'factory.ps1') rock answer '100' $questionId --text 'Keep the original scope.' -Repository $repository
    $answered = Read-FactoryRockMemory $rock '100'
    Assert-Rock ($answered.questions[0].status -eq 'answered' -and @($answered.decisions | Where-Object { $_.actor -eq 'operator' -and $_.text -eq 'Keep the original scope.' }).Count -eq 1) 'Operator escalation answer was not stored once.'

    $noSourcePath = Add-FactoryRockEvent $rock '100' 'missing-sources' $payload
    Invoke-FactoryRockEvent $rock $owner $noSourcePath
    Assert-Rock ((Read-FactoryJson $noSourcePath).attempts -eq 0 -and (Read-FactoryRockMemory $rock '100').sourceRefreshRequired) 'Missing browser sources invoked the model.'
    Assert-Rock (@(Get-FactoryRockAttentionEvents $context $config | Where-Object kind -eq 'rock-source-refresh').Count -eq 1) 'Missing sources did not request a browser refresh.'
    $snapshotPath = Join-Path $testRoot 'browser-snapshot.txt'
    [IO.File]::WriteAllText($snapshotPath, 'Browser snapshot: binding goal, decisions, task requirements.')
    $null = & (Join-Path $PluginRoot 'factory.ps1') rock import '100' -File $snapshotPath -Repository $repository
    $null = & (Join-Path $PluginRoot 'factory.ps1') rock import '100' --file $snapshotPath -Repository $repository
    $imported = Read-FactoryRockMemory $rock '100'
    Assert-Rock (-not $imported.sourceRefreshRequired -and $imported.sources.Count -eq 1) 'Browser source import did not satisfy the refresh request.'
    Assert-Rock ((Read-FactoryJson $imported.sources[0]).content -ceq 'Browser snapshot: binding goal, decisions, task requirements.') 'Import changed source text.'
    Assert-Rock (Test-FactoryRockHasPendingWork $config) 'Scheduler can disarm while ROCK has pending work.'

    $interruptedPath = Add-FactoryRockEvent $rock '100' 'interrupted-models' $payload
    $interrupted = Read-FactoryJson $interruptedPath; $interrupted.attempts=3; Write-FactoryJsonAtomic $interruptedPath $interrupted
    Invoke-FactoryRockEvent $rock $owner $interruptedPath { throw 'A fourth model invocation was allowed' }
    Assert-Rock ((Read-FactoryJson $interruptedPath).status -eq 'failed') 'Interrupted launches escaped the model-attempt limit.'

    $invalidPath = Add-FactoryRockEvent $rock '100' 'invalid-output' $payload
    for ($attempt=0;$attempt -lt 3;$attempt++) {
        $row = Read-FactoryJson $invalidPath; $row.retryAt=$null; Write-FactoryJsonAtomic $invalidPath $row
        Invoke-FactoryRockEvent $rock $owner $invalidPath { 'not JSON' } -WarningAction SilentlyContinue
    }
    Assert-Rock ((Read-FactoryJson $invalidPath).status -eq 'failed') 'Invalid output caused an unbounded model loop.'
    . (Join-Path $PluginRoot 'scripts\attention-state.ps1')
    $memoryPath = (Get-FactoryRockPaths $rock '100').memory
    $validMemory = Read-FactoryJson $memoryPath
    [IO.File]::WriteAllText($memoryPath, '{torn')
    Assert-RockThrows { Read-FactoryRockMemory $rock '100' } 'valid JSON'
    $attentionRecord = Sync-FactoryAttentionState -Context $context -Config $config -State (Read-FactoryJson $context.statePath)
    Assert-Rock (@($attentionRecord.events | Where-Object kind -eq 'rock-runtime-error').Count -eq 1) 'Corrupt ROCK state prevented durable error notification.'
    Assert-Rock ((Get-Content -LiteralPath $memoryPath -Raw) -eq '{torn') 'Corrupt memory was silently replaced.'
    Write-FactoryJsonAtomic $memoryPath $validMemory
    Reset-FactoryAsanaRun -Context $context -Fresh ([pscustomobject]@{gid='123';name='Explicit legacy re-Ready';notes='New legacy run'})
    $legacyAgain = (Read-FactoryJson $context.statePath).tasks[0]
    Assert-Rock ($null -eq $legacyAgain.rockId -and $null -eq $legacyAgain.rockDispatchId -and $legacyAgain.asanaMode) 'Legacy rollback inherited direct transport ownership.'
    Assert-Rock ($legacyAgain.previousRuns[0].rockId -eq '100') 'Legacy rollback discarded the previous ROCK audit trail.'
    Write-Host 'Direct ROCK tests passed (memory, ownership, correlation, pause, native dispatch/answers, replay, escalation, bounded retries).' -ForegroundColor Green
} finally {
    $env:CLAUDE_FACTORY_HOME = $oldFactoryHome
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
