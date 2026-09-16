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

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-claude-lifecycle-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixtureRoot 'repository'
$runtime = Join-Path $fixtureRoot 'runtime'
$fakeClaude = Join-Path $fixtureRoot 'fake-claude.exe'
$argvPath = Join-Path $fixtureRoot 'argv.txt'
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
    CLAUDE_FACTORY_TEST_STOP_FILE = $stopsPath
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
    param([string]$Action)
    return Invoke-FactoryNativeProcess -Command 'powershell' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PluginRoot 'factory.ps1'),
        $Action, '-Repository', $repository, '-ClaudeCommand', $fakeClaude
    )
}

try {
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
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
    $argv = [IO.File]::ReadAllLines($argvPath)
    $resumeIndex = [Array]::IndexOf($argv, '--resume')
    Assert-Lifecycle ($resumeIndex -ge 0 -and $argv[$resumeIndex + 1] -eq $sessionId) 'Restart did not resume the exact saved conversation.'
    Assert-Lifecycle (-not ($argv -contains 'attach')) 'Restart attached the old process after stopping it.'
    $stoppedIds = [IO.File]::ReadAllLines($stopsPath)
    Assert-Lifecycle (-not ($stoppedIds -contains 'foreign-orchestrator') -and -not ($stoppedIds -contains 'unrelated-worker')) 'Restart stopped an unrelated session.'
    $identity = Read-FactoryJson $identityPath
    Assert-Lifecycle ($identity.sessionId -eq $sessionId -and -not $identity.backgroundId) 'Restart changed the conversation or retained the stopped background ID.'
    Assert-Lifecycle ([IO.File]::ReadAllText($context.statePath) -ceq $beforeState) 'Orchestrator lifecycle changed the task ledger.'

    $startedAgain = Invoke-LifecycleCommand 'start'
    Assert-Lifecycle ($startedAgain.exitCode -eq 0) "Start after stop failed: $($startedAgain.output)"
    $argv = [IO.File]::ReadAllLines($argvPath)
    $resumeIndex = [Array]::IndexOf($argv, '--resume')
    Assert-Lifecycle ($resumeIndex -ge 0 -and $argv[$resumeIndex + 1] -eq $sessionId) 'Start attached a stopped row without a PID.'
    Write-Host 'Claude orchestrator lifecycle tests passed (resident done/idle/PID, attach, restart, stop refusal, identity and task preservation).'
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
    # This fixture starts no real Claude process or scheduler; retain its files
    # in the OS temporary directory so failures can be inspected.
}
