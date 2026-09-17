param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\orchestrator-session.ps1')

function Assert-Lifecycle {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

# A completed turn and a released conversation are different things. No OS
# process is killed by PID: the native Claude listing owns the session identity.
foreach ($stateName in @('done', 'stopped', 'failed')) {
    foreach ($reportedPid in @($null, 0, -1)) {
        $row = [pscustomobject]@{ state = $stateName; status = 'idle'; pid = $reportedPid }
        Assert-Lifecycle (Test-FactoryTerminalAgentRow $row) 'A terminal row without a positive PID remained resident.'
    }
    $resident = [pscustomobject]@{ state = $stateName; status = 'idle'; pid = 4242 }
    Assert-Lifecycle (-not (Test-FactoryTerminalAgentRow $resident)) 'A resident terminal row was treated as closed.'
}
Assert-Lifecycle (Test-FactoryTerminalAgentRow ([pscustomobject]@{ status = 'done' })) 'Status-only terminal rows stopped working.'
Assert-Lifecycle (-not (Test-FactoryTerminalAgentRow ([pscustomobject]@{ state = 'working'; status = 'idle' }))) 'An idle worker was treated as closed.'

$residentOrchestrator = [pscustomobject]@{
    id = 'resident'; sessionId = 'resident-session'; kind = 'background'
    state = 'done'; status = 'idle'; pid = 4242; startedAt = 1
}
$otherOrchestrator = [pscustomobject]@{
    id = 'other'; sessionId = 'other-session'; kind = 'background'; state = 'working'; startedAt = 2
}
$selected = Select-FactoryBackgroundOrchestrator -Rows @($residentOrchestrator, $otherOrchestrator) -PreferredSessionId 'resident-session'
Assert-Lifecycle ($selected.id -eq 'resident') 'The stored resident conversation lost priority to another orchestrator.'
$selected = Select-FactoryBackgroundOrchestrator -Rows @($residentOrchestrator)
Assert-Lifecycle ($selected.id -eq 'resident') 'A resident completed conversation could not be discovered without a stored identity.'
$residentOrchestrator.pid = 0
Assert-Lifecycle ($null -eq (Select-FactoryBackgroundOrchestrator -Rows @($residentOrchestrator))) 'A completed conversation without a PID was selected for attachment.'

$oldRow = [pscustomobject]@{ id = 'old'; sessionId = 'old-session'; kind = 'background'; name = 'Claude Factory Orchestrator'; cwd = 'C:\fixture'; state = 'done'; startedAt = 1000 }
$numberedRow = [pscustomobject]@{ id = 'numbered'; sessionId = 'new-session'; kind = 'background'; name = 'Claude Factory Orchestrator (2)'; cwd = 'C:\fixture'; state = 'done'; startedAt = 3000 }
$unrelatedRow = [pscustomobject]@{ id = 'unrelated'; sessionId = 'other-session'; kind = 'background'; name = 'Claude Factory Orchestrator notes'; cwd = 'C:\fixture'; state = 'done'; startedAt = 4000 }
$foreignRow = [pscustomobject]@{ id = 'foreign'; sessionId = 'foreign-session'; kind = 'background'; name = 'Claude Factory Orchestrator (2)'; cwd = 'C:\other'; state = 'working'; startedAt = 5000 }
$renamedRow = [pscustomobject]@{ id = 'renamed'; sessionId = 'recorded-session'; kind = 'interactive'; name = 'Custom title'; cwd = 'C:\fixture'; state = 'working'; startedAt = 6000 }
$matched = @(Get-FactoryMatchingOrchestratorRows -Rows @($oldRow, $numberedRow, $unrelatedRow, $foreignRow, $renamedRow) -RepositoryRoot 'C:\fixture' -Name 'Claude Factory Orchestrator' -SessionId 'recorded-session')
Assert-Lifecycle ($matched.Count -eq 3 -and @($matched | Where-Object id -eq 'numbered').Count -eq 1 -and @($matched | Where-Object id -eq 'renamed').Count -eq 1) 'Numbered names/recorded UUID were missed or unrelated rows matched.'
$recovered = Select-FactoryOrchestratorConversation -Rows @($oldRow, $numberedRow) -PreferredSessionId 'old-session' -IdentityUpdatedAt '1970-01-01T00:00:02.000Z'
Assert-Lifecycle ($recovered.id -eq 'numbered') 'A newer stopped numbered conversation lost to stale saved identity.'
$preserved = Select-FactoryOrchestratorConversation -Rows @($oldRow, $numberedRow) -PreferredSessionId 'old-session' -IdentityUpdatedAt '1970-01-01T00:00:04.000Z'
Assert-Lifecycle ($preserved.id -eq 'old') 'Older history overrode a deliberately refreshed identity.'
Assert-Lifecycle ($null -eq (Select-FactoryOrchestratorConversation -Rows @($oldRow, $numberedRow) -PreferredSessionId 'rotation-session' -IdentityUpdatedAt '1970-01-01T00:00:04.000Z')) 'Old rows overrode a new rotation UUID that has no Agent View row yet.'

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-claude-lifecycle-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixtureRoot 'repository'
$runtime = Join-Path $fixtureRoot 'runtime'
$fakeClaude = Join-Path $fixtureRoot 'fake-claude.exe'
$argvPath = Join-Path $fixtureRoot 'argv.txt'
$backgroundArgvPath = Join-Path $fixtureRoot 'background-argv.txt'
$launchCountPath = Join-Path $fixtureRoot 'launch-count.txt'
$respawnPath = Join-Path $fixtureRoot 'respawns.txt'
$transcriptsPath = Join-Path $fixtureRoot 'transcripts'
$registryPath = Join-Path $fixtureRoot 'sessions.tsv'
$stopsPath = Join-Path $fixtureRoot 'stops.txt'
$sessionId = '11111111-2222-4333-8444-555555555555'
$environment = @{
    CLAUDE_FACTORY_HOME = $runtime
    CLAUDE_FACTORY_ORCHESTRATOR = $null
    CLAUDECODE = $null
    CLAUDE_FACTORY_TEST_AGENT_CWD = $repository
    CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE = $registryPath
    CLAUDE_FACTORY_TEST_ARGV_FILE = $argvPath
    CLAUDE_FACTORY_TEST_BACKGROUND_ARGV_FILE = $backgroundArgvPath
    CLAUDE_FACTORY_TEST_ORCHESTRATOR_LAUNCH_COUNT_FILE = $launchCountPath
    CLAUDE_FACTORY_TEST_ORCHESTRATOR_LAUNCH_MODE = $null
    CLAUDE_FACTORY_TEST_ORCHESTRATOR_TRANSCRIPTS = $transcriptsPath
    CLAUDE_FACTORY_TEST_RESPAWN_FILE = $respawnPath
    CLAUDE_FACTORY_TEST_RESPAWN_TRANSIENT_FILE = (Join-Path $fixtureRoot 'transient.txt')
    CLAUDE_FACTORY_TEST_RESPAWN_FAIL = $null
    CLAUDE_FACTORY_TEST_ATTACH_FAIL = $null
    CLAUDE_FACTORY_TEST_STOP_FILE = $stopsPath
    CLAUDE_FACTORY_TEST_RM_FILE = (Join-Path $fixtureRoot 'removed.txt')
    CLAUDE_FACTORY_TEST_LIVE_TERMINAL_ID = 'test1234'
    CLAUDE_FACTORY_TEST_AGENT_LIVE_STATUS = 'idle'
    CLAUDE_FACTORY_TEST_AGENT_STATUS = $null
    CLAUDE_FACTORY_TEST_NO_AGENTS = $null
    CLAUDE_FACTORY_TEST_ORCHESTRATOR_SESSION_ID = $null
    CLAUDE_FACTORY_TEST_INTERACTIVE_ORCHESTRATOR = $null
    CLAUDE_FACTORY_TEST_STOP_FAIL_ID = $null
    CLAUDE_FACTORY_TEST_SILENT = '1'
}
$savedEnvironment = @{}
foreach ($name in $environment.Keys) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
}

function Invoke-LifecycleCommand {
    param([string]$Action, [string[]]$ExtraArguments = @())
    return Invoke-FactoryNativeProcess -Command 'powershell' -Arguments (@(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PluginRoot 'factory.ps1'),
        $Action, '-Repository', $repository, '-ClaudeCommand', $fakeClaude
    ) + $ExtraArguments)
}

try {
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    New-Item -ItemType Directory -Path $transcriptsPath -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $transcriptsPath "$sessionId.jsonl"), '{"type":"user","message":"Do not replay me"}')
    & git init --quiet $repository
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the lifecycle fixture.' }
    Add-Type -Path (Join-Path $PluginRoot 'tests\FakeClaude.cs') -OutputAssembly $fakeClaude -OutputType ConsoleApplication
    $context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
    $config = Read-FactoryJson $context.configPath
    $config.nativeScheduler.enabled = $false
    $config.nativeScheduler.startWithOrchestrator = $false
    Write-FactoryJsonAtomic $context.configPath $config
    $identityPath = Join-Path $context.projectData 'orchestrator-session.json'
    Write-FactoryOrchestratorIdentity -Path $identityPath -RepositoryRoot $repository -Name 'Claude Factory Orchestrator' -SessionId $sessionId -BackgroundId 'test1234'
    $fixtureState = Read-FactoryJson $context.statePath
    $fixtureState.active = $true
    $fixtureState.tasks = @([pscustomobject]@{
        id = 'unrelated-running-task'; title = 'Worker must remain untouched'; status = 'running'
        backgroundSession = [pscustomobject]@{ id = 'unrelated-worker'; state = 'working' }
        worktree = (Join-Path $fixtureRoot 'active-worktree'); branch = 'factory-worker/unrelated-running-task'
    })
    $fixtureMutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    try { Write-FactoryJsonAtomic $context.statePath $fixtureState }
    finally { Exit-FactoryMutex -Mutex $fixtureMutex }
    # Normalize this fixture once before checking byte-identical preservation.
    $null = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize
    $beforeState = [IO.File]::ReadAllText($context.statePath)
    [IO.File]::WriteAllText($registryPath, (
        "launch`ttest1234`t$repository`tClaude Factory Orchestrator`tworking`n" +
        "launch`tforeign-orchestrator`t$repository-other`tClaude Factory Orchestrator`tworking`n" +
        "launch`tunrelated-worker`t$repository`tfactory-worker-unrelated`tworking`n"
    ), $script:FactoryUtf8NoBom)

    $listed = @(Get-FactoryClaudeAgentRows -ClaudeCommand $fakeClaude | Where-Object {
        [string](Get-FactoryNestedValue $_ 'id' '') -eq 'test1234'
    })[0]
    Assert-Lifecycle ($listed.state -eq 'done' -and $listed.status -eq 'idle' -and $listed.pid -gt 0) 'The fixture did not reproduce the reported Claude row.'

    $started = Invoke-LifecycleCommand 'start'
    Assert-Lifecycle ($started.exitCode -eq 0) "Start failed: $($started.output)"
    $argv = [IO.File]::ReadAllLines($argvPath)
    Assert-Lifecycle ($argv[0] -eq 'attach' -and $argv[1] -eq 'test1234') 'Start tried to resume a still-resident conversation instead of attaching it.'
    Assert-Lifecycle (-not [IO.File]::Exists($stopsPath)) 'Start stopped a resident session.'

    # A failed stop must never fall through to a second writer for the same UUID.
    Remove-Item -LiteralPath $argvPath -Force
    $env:CLAUDE_FACTORY_TEST_STOP_FAIL_ID = 'test1234'
    $refused = Invoke-LifecycleCommand 'restart'
    Assert-Lifecycle ($refused.exitCode -ne 0 -and $refused.output -match 'Failed to stop background session') 'Restart did not refuse a failed Claude stop.'
    Assert-Lifecycle (-not [IO.File]::Exists($argvPath)) 'Restart resumed the conversation after its process failed to stop.'
    Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FAIL_ID

    $restarted = Invoke-LifecycleCommand 'restart'
    Assert-Lifecycle ($restarted.exitCode -eq 0) "Restart failed: $($restarted.output)"
    Assert-Lifecycle ($restarted.output -match 'Stopped:.*test1234') 'Restart omitted the resident done/idle session from the stopped list.'
    Assert-Lifecycle ([IO.File]::ReadAllText($respawnPath).Trim() -eq 'test1234') 'Restart did not respawn the existing background session.'
    Assert-Lifecycle (-not (Test-Path $backgroundArgvPath)) 'Restart used --bg --resume, which forks a registered conversation.'
    $attachArgs = [IO.File]::ReadAllLines($argvPath)
    Assert-Lifecycle ($attachArgs[0] -eq 'attach' -and $attachArgs[1] -eq 'test1234') 'Restart did not attach the verified background row.'
    $stoppedIds = [IO.File]::ReadAllLines($stopsPath)
    Assert-Lifecycle (-not ($stoppedIds -contains 'foreign-orchestrator') -and -not ($stoppedIds -contains 'unrelated-worker')) 'Restart stopped an unrelated session.'
    $identity = Read-FactoryJson $identityPath
    Assert-Lifecycle ($identity.sessionId -eq $sessionId -and $identity.backgroundId -eq 'test1234') 'Restart did not save the verified resumed background identity.'
    Assert-Lifecycle ([IO.File]::ReadAllText($context.statePath) -ceq $beforeState) 'Orchestrator lifecycle changed the task ledger.'

    $startedAgain = Invoke-LifecycleCommand 'start'
    Assert-Lifecycle ($startedAgain.exitCode -eq 0) "Start after stop failed: $($startedAgain.output)"
    $argv = [IO.File]::ReadAllLines($argvPath)
    Assert-Lifecycle ($argv[0] -eq 'attach') 'Repeated start did not reuse the background session.'
    Assert-Lifecycle (-not (Test-Path $launchCountPath)) 'Repeated start launched another orchestrator.'
    Assert-Lifecycle ([IO.File]::ReadAllLines($respawnPath).Count -eq 1) 'Repeated start respawned a live orchestrator.'

    # History loss must not replay the original intent. Native failures and
    # late UUID confirmation must never trigger a replacement --bg launch.
    $savedRow = @(Get-FactoryClaudeAgentRows -ClaudeCommand $fakeClaude | Where-Object { (Get-FactoryNestedValue $_ 'id' '') -eq 'test1234' })[0]
    $transcriptPath = Join-Path $transcriptsPath "$sessionId.jsonl"
    Remove-Item -LiteralPath $transcriptPath
    $missingHistory = ''
    try { Resume-FactoryClaudeBackgroundOrchestrator -ClaudeCommand $fakeClaude -Context $context -Row $savedRow -Name 'Claude Factory Orchestrator' }
    catch { $missingHistory = $_.Exception.Message }
    Assert-Lifecycle ($missingHistory -match 'saved transcript is missing' -and [IO.File]::ReadAllLines($respawnPath).Count -eq 1) 'Missing history was allowed to replay the original intent.'
    [IO.File]::WriteAllText($transcriptPath, '{"type":"user","message":"Do not replay me"}')
    $env:CLAUDE_FACTORY_TEST_RESPAWN_FAIL = '1'
    $failedRespawn = ''
    try { Resume-FactoryClaudeBackgroundOrchestrator -ClaudeCommand $fakeClaude -Context $context -Row $savedRow -Name 'Claude Factory Orchestrator' }
    catch { $failedRespawn = $_.Exception.Message }
    Assert-Lifecycle ($failedRespawn -match 'could not respawn' -and -not (Test-Path $backgroundArgvPath)) 'Failed respawn launched a replacement.'
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RESPAWN_FAIL
    # Synthetic failure cleanup; never discard an unknown live launch receipt.
    $respawnReceipt = Join-Path $context.projectData 'orchestrator-launch.json'
    Remove-Item -LiteralPath $respawnReceipt
    $lateRespawn = ''
    try { Resume-FactoryClaudeBackgroundOrchestrator -ClaudeCommand $fakeClaude -Context $context -Row $savedRow -Name 'Claude Factory Orchestrator' -TimeoutMilliseconds 1 }
    catch { $lateRespawn = $_.Exception.Message }
    Assert-Lifecycle ($lateRespawn -match 'did not confirm' -and (Read-FactoryJson $respawnReceipt).operation -eq 'respawn') 'Transient UUID was accepted or pending respawn was forgotten.'
    $respawnsBeforeRecovery = [IO.File]::ReadAllText($respawnPath)
    $lateRespawnRecovery = Invoke-LifecycleCommand 'start'
    Assert-Lifecycle ($lateRespawnRecovery.exitCode -eq 0 -and [IO.File]::ReadAllText($respawnPath) -ceq $respawnsBeforeRecovery) 'Late respawn recovery restarted the process again.'
    Assert-Lifecycle ((Read-FactoryJson $identityPath).sessionId -eq $sessionId -and -not (Test-Path $respawnReceipt)) 'Late respawn recovery lost the original conversation.'
    # Reproduce a stale saved UUID plus a newer numbered Claude copy, first
    # with both stopped and then with the numbered copy still resident.
    $oldSessionId = 'aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb'
    foreach ($residentCopy in @($false, $true)) {
        $env:CLAUDE_FACTORY_TEST_LIVE_TERMINAL_ID = if ($residentCopy) { 'test1234' } else { '' }
        [IO.File]::WriteAllText($registryPath, (
            "launch`torchestrator-static`t$repository`tClaude Factory Orchestrator`tdone`t$oldSessionId`t1000`n" +
            "launch`ttest1234`t$repository`tClaude Factory Orchestrator (2)`tworking`t$sessionId`t3000`n" +
            $(if (-not $residentCopy) { "stop`ttest1234`n" } else { '' }) +
            "launch`tforeign-orchestrator`t$repository-other`tClaude Factory Orchestrator (2)`tdone`n" +
            "launch`tunrelated-worker`t$repository`tfactory-worker-unrelated`tdone`n"
        ), $script:FactoryUtf8NoBom)
        Write-FactoryJsonAtomic $identityPath ([ordered]@{ version = 1; repositoryRoot = $repository; name = 'Claude Factory Orchestrator'; sessionId = $oldSessionId; backgroundId = $null; updatedAt = '1970-01-01T00:00:02.000Z' })
        $action = if ($residentCopy) { 'restart' } else { 'start' }
        $recovery = Invoke-LifecycleCommand $action
        Assert-Lifecycle ($recovery.exitCode -eq 0) "Numbered $action failed: $($recovery.output)"
        Assert-Lifecycle ([IO.File]::ReadAllLines($respawnPath)[-1] -eq 'test1234' -and -not (Test-Path $backgroundArgvPath)) 'Recovery forked instead of respawning the newer conversation.'
        Assert-Lifecycle ((Read-FactoryJson $identityPath).sessionId -eq $sessionId) 'Recovered identity was not persisted.'
        $remaining = @(Get-FactoryClaudeAgentRows -ClaudeCommand $fakeClaude)
        Assert-Lifecycle (@($remaining | Where-Object { [string](Get-FactoryNestedValue $_ 'id' '') -eq 'orchestrator-static' }).Count -eq 0) 'Obsolete completed orchestrator remained in Agent View.'
        foreach ($retainedId in @('test1234', 'foreign-orchestrator', 'unrelated-worker')) {
            Assert-Lifecycle (@($remaining | Where-Object { [string](Get-FactoryNestedValue $_ 'id' '') -eq $retainedId }).Count -eq 1) "Recovery removed unrelated/retained session $retainedId."
        }
        Assert-Lifecycle ([IO.File]::ReadAllText($context.statePath) -ceq $beforeState) 'Numbered recovery changed the task ledger.'
    }

    # Fresh and explicit replacement identities come from Claude, not from an
    # unsupported --session-id flag. Bootstrap must not replay old work.
    [IO.File]::WriteAllText($registryPath, "rm`torchestrator-static`n", $script:FactoryUtf8NoBom)
    Remove-Item -LiteralPath $identityPath -Force
    $env:CLAUDE_FACTORY_TEST_LIVE_TERMINAL_ID = ''
    $fresh = Invoke-LifecycleCommand 'start'
    Assert-Lifecycle ($fresh.exitCode -eq 0) "Fresh background start failed: $($fresh.output)"
    $freshIdentity = Read-FactoryJson $identityPath
    $freshArgs = [IO.File]::ReadAllLines($backgroundArgvPath)
    Assert-Lifecycle ($freshArgs -contains '--bg' -and -not ($freshArgs -contains '--session-id') -and -not ($freshArgs -contains '--resume')) 'Fresh launch did not let Claude assign its background identity.'
    foreach ($preservedFlag in @('--plugin-dir', '--add-dir', '--permission-mode', '--name', '--remote-control')) {
        Assert-Lifecycle ($freshArgs -contains $preservedFlag) "Background launch lost $preservedFlag."
    }
    Assert-Lifecycle ($freshArgs[-1] -match 'Do not call tools, resume previous actions') 'UI startup can replay previous work.'
    Assert-Lifecycle ([IO.File]::ReadAllLines($argvPath)[1] -eq $freshIdentity.backgroundId) 'Fresh launch attached a guessed background ID.'
    [IO.File]::AppendAllText($registryPath, "stop`t$($freshIdentity.backgroundId)`n", $script:FactoryUtf8NoBom)
    $replacement = Invoke-LifecycleCommand 'start' @('-New')
    Assert-Lifecycle ($replacement.exitCode -eq 0 -and (Read-FactoryJson $identityPath).sessionId -ne $freshIdentity.sessionId) 'Explicit new conversation reused the old UUID.'

    # Fail closed on invalid/unknown launches. Never overwrite the saved UUID,
    # attach a foreign session, or retry by launching a second writer.
    $receiptPath = Join-Path $context.projectData 'orchestrator-launch.json'
    foreach ($mode in @('failure', 'no-id', 'fork', 'wrong-repository', 'stopped', 'invisible')) {
        [IO.File]::WriteAllText($registryPath, "rm`torchestrator-static`n", $script:FactoryUtf8NoBom)
        Write-FactoryOrchestratorIdentity $identityPath $repository 'Claude Factory Orchestrator' $sessionId
        $identityBeforeFailure = [IO.File]::ReadAllText($identityPath)
        $env:CLAUDE_FACTORY_TEST_ORCHESTRATOR_LAUNCH_MODE = $mode
        $failed = Invoke-LifecycleCommand 'start'
        Assert-Lifecycle ($failed.exitCode -ne 0) "Invalid launch '$mode' was accepted."
        Assert-Lifecycle ([IO.File]::ReadAllText($identityPath) -ceq $identityBeforeFailure) "Invalid launch '$mode' changed the saved UUID."
        Assert-Lifecycle ([IO.File]::ReadAllLines($argvPath)[0] -ne 'attach') "Invalid launch '$mode' attached an unverified session."
        $countBeforeRetry = [IO.File]::ReadAllText($launchCountPath)
        $failedRetry = Invoke-LifecycleCommand 'start'
        Assert-Lifecycle ($failedRetry.exitCode -ne 0 -and [IO.File]::ReadAllText($launchCountPath) -ceq $countBeforeRetry) "Retry of '$mode' launched a second session."
        $stopsBeforeRefusal = [IO.File]::ReadAllText($stopsPath)
        $unsafeRestart = Invoke-LifecycleCommand 'restart'
        Assert-Lifecycle ($unsafeRestart.exitCode -ne 0 -and [IO.File]::ReadAllText($stopsPath) -ceq $stopsBeforeRefusal) "Restart of '$mode' stopped a session with an unresolved launch."
        Assert-Lifecycle ([IO.File]::ReadAllText($identityPath) -ceq $identityBeforeFailure) "Restart of '$mode' adopted an unverified conversation."
        if ($mode -eq 'invisible') {
            $receipt = Read-FactoryJson $receiptPath
            [IO.File]::AppendAllText($registryPath, "launch`t$($receipt.backgroundId)`t$repository`tClaude Factory Orchestrator`tblocked`t$sessionId`n", $script:FactoryUtf8NoBom)
            $lateRecovery = Invoke-LifecycleCommand 'start'
            Assert-Lifecycle ($lateRecovery.exitCode -eq 0 -and [IO.File]::ReadAllText($launchCountPath) -ceq $countBeforeRetry) 'Late visibility recovery relaunched the orchestrator.'
            Assert-Lifecycle (-not (Test-Path -LiteralPath $receiptPath)) 'Verified recovery retained the pending receipt.'
        }
        if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force }
    }
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ORCHESTRATOR_LAUNCH_MODE

    # Failed attachment is not a failed launch: preserve the verified session
    # and simply reattach on the next start, with no fresh bootstrap turn.
    [IO.File]::WriteAllText($registryPath, "rm`torchestrator-static`n", $script:FactoryUtf8NoBom)
    $env:CLAUDE_FACTORY_TEST_ATTACH_FAIL = '1'
    $badAttach = Invoke-LifecycleCommand 'start'
    Assert-Lifecycle ($badAttach.exitCode -ne 0) 'The attach exit code was lost.'
    $verifiedBeforeRetry = [IO.File]::ReadAllText($identityPath)
    $countBeforeRetry = [IO.File]::ReadAllText($launchCountPath)
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ATTACH_FAIL
    $attachRetry = Invoke-LifecycleCommand 'start'
    Assert-Lifecycle ($attachRetry.exitCode -eq 0 -and [IO.File]::ReadAllText($launchCountPath) -ceq $countBeforeRetry) 'Failed attachment caused a new launch.'
    Assert-Lifecycle ((Read-FactoryJson $identityPath).sessionId -eq ($verifiedBeforeRetry | ConvertFrom-Json).sessionId) 'Failed attachment lost the saved UUID.'

    # Rotation is acknowledged only after the replacement row is verified.
    $beforeRotation = Read-FactoryJson $identityPath
    [IO.File]::AppendAllText($registryPath, "stop`t$($beforeRotation.backgroundId)`n", $script:FactoryUtf8NoBom)
    $rotation = Request-FactoryOrchestratorRotation -Context $context -Config $config -State (Read-FactoryJson $context.statePath)
    $env:CLAUDE_FACTORY_TEST_ORCHESTRATOR_LAUNCH_MODE = 'failure'
    $rotationFailure = Invoke-LifecycleCommand 'start'
    Assert-Lifecycle ($rotationFailure.exitCode -ne 0 -and $null -ne (Get-FactoryPendingOrchestratorRotation $context 'claude')) 'Failed launch consumed the pending rotation.'
    Assert-Lifecycle ((Read-FactoryJson $identityPath).sessionId -eq $beforeRotation.sessionId) 'Failed rotation replaced the saved conversation.'
    # This is synthetic failure cleanup inside this test's disposable runtime.
    Remove-Item -LiteralPath $receiptPath -Force
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ORCHESTRATOR_LAUNCH_MODE
    $rotated = Invoke-LifecycleCommand 'start'
    Assert-Lifecycle ($rotated.exitCode -eq 0 -and $null -eq (Get-FactoryPendingOrchestratorRotation $context 'claude')) 'Verified rotation was not completed.'
    Assert-Lifecycle ((Read-FactoryJson $identityPath).sessionId -ne $beforeRotation.sessionId) 'Rotation did not create a new conversation.'
    $rotationArgs = [IO.File]::ReadAllLines($backgroundArgvPath)
    Assert-Lifecycle ($rotationArgs -contains '--append-system-prompt' -and $rotationArgs -contains $context.projectData) 'Rotation lost the private handoff.'
    Assert-Lifecycle ([IO.File]::ReadAllText($context.statePath) -ceq $beforeState) 'Background lifecycle changed the task ledger.'
    Write-Host 'Claude orchestrator lifecycle tests passed (background-first launch, attach/restart, numbered recovery, unknown launches, task preservation).'
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    # This fixture starts no real Claude process or scheduler; retain its files
    # in the OS temporary directory so failures can be inspected.
}
