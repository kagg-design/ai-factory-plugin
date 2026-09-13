param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-status-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixtureRoot 'repository with spaces'
$runtime = Join-Path $fixtureRoot 'runtime'
$fakeRuntime = Join-Path $fixtureRoot 'status-runtime.exe'
$callsPath = Join-Path $fixtureRoot 'runtime-calls.txt'
$rowsPath = Join-Path $fixtureRoot 'claude-rows.json'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$environment = @{
    CLAUDE_FACTORY_HOME = $runtime
    FACTORY_STATUS_TEST_CALLS = $callsPath
    FACTORY_STATUS_TEST_ROWS = $rowsPath
}
$previous = @{}
$previousPath = $env:PATH
$originalPowerShellFunction = Get-Item Function:\powershell -ErrorAction SilentlyContinue

function Assert-Status {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Write-StatusState {
    param($Value)
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    try { Write-FactoryJsonAtomic -Path $context.statePath -Value $Value }
    finally { Exit-FactoryMutex -Mutex $mutex }
}
function New-StatusTask {
    param([string]$Id)
    [pscustomobject]@{
        id = $Id; title = "Status fixture $Id"; brief = ''; url = $null; source = $null
        acceptanceCriteria = @(); sourceNotes = @(); startMode = 'auto'; status = 'running'
        attempts = 1; agentId = $null; backgroundSession = $null; branch = $null
        commit = $null; worktree = $repository; plan = $null; workerResult = $null
        review = $null; approval = $null; error = $null
        createdAt = Get-FactoryUtcTimestamp; updatedAt = Get-FactoryUtcTimestamp
    }
}
function Read-StatusFixture {
    param([switch]$NoReconcile)
    (& (Join-Path $PluginRoot 'scripts\get-factory-status.ps1') -Repository $repository `
        -ClaudeCommand $fakeRuntime -CodexCommand $fakeRuntime -NoReconcile:$NoReconcile) | ConvertFrom-Json
}

try {
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    foreach ($entry in $environment.GetEnumerator()) {
        $previous[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    & git init --quiet $repository
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize status fixture.' }
    $fakeSource = Join-Path $fixtureRoot 'StatusRuntime.cs'
    @'
using System;
using System.IO;
public static class StatusRuntime {
    public static int Main(string[] args) {
        File.AppendAllText(Environment.GetEnvironmentVariable("FACTORY_STATUS_TEST_CALLS"), String.Join(" ", args) + "\n");
        if (args.Length > 0 && args[0] == "--version") { Console.WriteLine("codex-cli 0.154.0-test"); return 0; }
        if (args.Length > 0 && args[0] == "agents") { Console.WriteLine(File.ReadAllText(Environment.GetEnvironmentVariable("FACTORY_STATUS_TEST_ROWS"))); return 0; }
        return 1;
    }
}
'@ | Set-Content -LiteralPath $fakeSource -Encoding UTF8
    $compile = "Add-Type -Path '" + $fakeSource.Replace("'", "''") + "' -OutputAssembly '" +
        $fakeRuntime.Replace("'", "''") + "' -OutputType ConsoleApplication"
    & $windowsPowerShell -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compile)))
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile status runtime fixture.' }
    [IO.File]::WriteAllText($rowsPath, '[]')
    [IO.File]::WriteAllText($callsPath, '')
    $context = (& (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize) | ConvertFrom-Json
    $config = Read-FactoryJson -Path $context.configPath
    $config.workerAgent = 'codex'
    $config.codexCommand = $fakeRuntime
    Write-FactoryJsonAtomic -Path $context.configPath -Value $config
    $state = Read-FactoryJson -Path $context.statePath
    $codexTask = New-StatusTask -Id 'codex-fixture'
    $transcriptPath = Join-Path $fixtureRoot 'codex.jsonl'
    [IO.File]::WriteAllText($transcriptPath, '{"type":"turn.failed","error":{"message":"fixture failure"}}')
    $codexTask.backgroundSession = [pscustomobject]@{
        runtime = 'codex'; id = 'codex-fixture'; name = 'codex-fixture'; sessionId = 'codex-thread'
        state = 'working'; processId = 0; transcriptPath = $transcriptPath
        lastMessagePath = ''; stderrPath = ''
    }
    $state.tasks = @($codexTask)
    $state.scheduler.status = 'running'
    $state.scheduler.pid = [int]::MaxValue
    Write-StatusState -Value $state

    # Any accidental return to nested context/scheduler/lease processes fails.
    function powershell { throw 'Status attempted to launch a nested PowerShell process.' }
    $withoutReconcile = Read-StatusFixture -NoReconcile
    Assert-Status ($withoutReconcile.state.tasks[0].status -eq 'running') 'NoReconcile changed worker status.'
    Assert-Status ($withoutReconcile.state.scheduler.status -eq 'failed') 'Status missed the dead scheduler.'
    Assert-Status ($withoutReconcile.testLease.free) 'Initial test lane was not free.'

    # Existing status reads do not run the schema/default initialization path.
    $oldConfigWriteTime = [DateTime]::UtcNow.AddDays(-2)
    [IO.File]::SetLastWriteTimeUtc($context.configPath, $oldConfigWriteTime)
    $null = Read-StatusFixture -NoReconcile
    Assert-Status ([IO.File]::GetLastWriteTimeUtc($context.configPath) -eq $oldConfigWriteTime) 'Status rewrote an existing project config during initialization.'

    # A first status for a genuinely new repository retains the old behavior:
    # initialize its private files, then read the live empty factory.
    $newRepository = Join-Path $fixtureRoot 'new repository'
    New-Item -ItemType Directory -Path $newRepository -Force | Out-Null
    & git init --quiet $newRepository
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize new status repository fixture.' }
    $newStatus = (& (Join-Path $PluginRoot 'scripts\get-factory-status.ps1') -Repository $newRepository `
        -ClaudeCommand $fakeRuntime -CodexCommand $fakeRuntime -NoReconcile) | ConvertFrom-Json
    Assert-Status ((Test-Path -LiteralPath $newStatus.context.configPath) -and (Test-Path -LiteralPath $newStatus.context.statePath)) 'First status did not initialize a new factory.'

    $lease = [pscustomobject]@{ version = 1; holder = $null; queue = @(
        [pscustomobject]@{ taskId = 'live-waiter'; phase = 'verify'; token = 'live'; priority = 1; waiterPid = $PID; requestedAt = Get-FactoryUtcTimestamp },
        [pscustomobject]@{ taskId = 'dead-waiter'; phase = 'verify'; token = 'dead'; priority = 1; waiterPid = [int]::MaxValue; requestedAt = Get-FactoryUtcTimestamp }
    ); lastReclaim = $null }
    Write-FactoryJsonAtomic -Path $context.testLeasePath -Value $lease
    $fresh = Read-StatusFixture
    Assert-Status (-not $fresh.reconcileWarning -and -not $fresh.testLeaseError) 'Live collection suppressed a nested-call failure.'
    Assert-Status ($fresh.state.tasks[0].status -eq 'failed') 'Status did not import the worker failure.'
    Assert-Status (@($fresh.testLease.queue).Count -eq 1 -and $fresh.testLease.queue[0].taskId -eq 'live-waiter') 'Status reused an old lease or failed to remove a dead waiter.'
    Assert-Status (@(Get-Content -LiteralPath $callsPath | Where-Object { $_ -like 'agents*' }).Count -eq 0) 'Codex-only status queried Claude.'

    # Completed tasks retain their session metadata for inspection, but their
    # event/transcript artifacts are final and must not be reopened by status.
    $state = Read-FactoryJson -Path $context.statePath
    $doneTask = New-StatusTask -Id 'done-codex-fixture'
    $doneTask.status = 'done'
    $doneTask.backgroundSession = [pscustomobject]@{
        runtime = 'codex'; id = 'done-codex-fixture'; name = 'done-codex-fixture'; sessionId = 'done-thread'
        state = 'done'; processId = 0; transcriptPath = (Join-Path $fixtureRoot 'missing-done-transcript.jsonl')
        lastMessagePath = ''; stderrPath = ''
    }
    $state.tasks = @($state.tasks) + @($doneTask)
    Write-StatusState -Value $state
    $doneEventDirectory = Join-Path $context.eventsPath 'done-codex-fixture'
    New-Item -ItemType Directory -Path $doneEventDirectory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $doneEventDirectory 'latest.json'), 'invalid json')
    $settledStateWriteTime = [DateTime]::UtcNow.AddDays(-2)
    [IO.File]::SetLastWriteTimeUtc($context.statePath, $settledStateWriteTime)
    $withDone = Read-StatusFixture
    Assert-Status (-not $withDone.reconcileWarning) 'Status reopened malformed artifacts for a completed task.'
    Assert-Status ([IO.File]::GetLastWriteTimeUtc($context.statePath) -eq $settledStateWriteTime) 'Status rewrote unchanged settled session metadata.'

    # File-backed Codex reconciliation does not need to discover or execute a
    # Codex binary. Put an observable `codex.exe` first on PATH to catch it.
    Copy-Item -LiteralPath $fakeRuntime -Destination (Join-Path $fixtureRoot 'codex.exe')
    $env:PATH = "$fixtureRoot;$previousPath"
    $config = Read-FactoryJson -Path $context.configPath
    $config.codexCommand = 'codex'
    Write-FactoryJsonAtomic -Path $context.configPath -Value $config
    [IO.File]::WriteAllText($callsPath, '')
    $withoutCodexProbe = (& (Join-Path $PluginRoot 'scripts\get-factory-status.ps1') -Repository $repository `
        -ClaudeCommand $fakeRuntime) | ConvertFrom-Json
    Assert-Status (-not $withoutCodexProbe.reconcileWarning) "Status without an explicit Codex path failed: $($withoutCodexProbe.reconcileWarning)"
    Assert-Status (@(Get-Content -LiteralPath $callsPath | Where-Object { $_ -eq '--version' }).Count -eq 0) 'Status probed a Codex executable during file-backed reconciliation.'

    # Mixed and legacy queues still need Claude, and a failed listing must not
    # misclassify a working worker as a missing/stopped session.
    $state = Read-FactoryJson -Path $context.statePath
    $claudeTask = New-StatusTask -Id 'claude-fixture'
    $claudeTask.backgroundSession = [pscustomobject]@{ id = 'claude-fixture'; sessionId = 'claude-thread'; name = 'claude-fixture'; state = 'working' }
    $state.tasks = @($state.tasks) + @($claudeTask)
    Write-StatusState -Value $state
    [IO.File]::WriteAllText($rowsPath, '[{"id":"claude-fixture","sessionId":"claude-thread","name":"claude-fixture","state":"working"}]')
    $mixed = Read-StatusFixture
    Assert-Status (-not $mixed.reconcileWarning) "Mixed reconciliation failed: $($mixed.reconcileWarning)"
    Assert-Status (@(Get-Content -LiteralPath $callsPath | Where-Object { $_ -like 'agents*' }).Count -eq 1) 'Mixed status did not query Claude exactly once.'
    [IO.File]::WriteAllText($rowsPath, 'invalid json')
    $unavailable = Read-StatusFixture
    $retained = @($unavailable.state.tasks | Where-Object { $_.id -eq 'claude-fixture' })[0]
    Assert-Status ($retained.status -eq 'running' -and $retained.backgroundSession.state -eq 'working') 'Unavailable Claude listing stopped a worker.'

    # Fresh malformed lease data is surfaced, not hidden by the earlier result.
    [IO.File]::WriteAllText($context.testLeasePath, 'invalid json')
    $badLease = Read-StatusFixture -NoReconcile
    Assert-Status ([bool]$badLease.testLeaseError) 'Status hid malformed live lease data.'
    [IO.File]::WriteAllText($context.testLeasePath, '{"version":1,"holder":null,"queue":[]}')

    $state = Read-FactoryJson -Path $context.statePath
    $badEventTask = New-StatusTask -Id 'bad-event-fixture'
    $badEventTask.backgroundSession = [pscustomobject]@{
        runtime = 'codex'; id = 'bad-event-fixture'; name = 'bad-event-fixture'; sessionId = 'bad-event-thread'
        state = 'working'; processId = 0; transcriptPath = (Join-Path $fixtureRoot 'nonterminal.jsonl')
        lastMessagePath = ''; stderrPath = ''
    }
    [IO.File]::WriteAllText($badEventTask.backgroundSession.transcriptPath, '{"type":"thread.started","thread_id":"bad-event-thread"}')
    $state.tasks = @($state.tasks) + @($badEventTask)
    Write-StatusState -Value $state
    $badEventDirectory = Join-Path $context.eventsPath 'bad-event-fixture'
    New-Item -ItemType Directory -Path $badEventDirectory -Force | Out-Null
    $badEventPath = Join-Path $badEventDirectory 'latest.json'
    [IO.File]::WriteAllText($badEventPath, 'invalid json')
    $badEvent = Read-StatusFixture
    Assert-Status ($badEvent.reconcileWarning -like 'Session reconciliation failed:*showing saved state.') 'Status hid a reconciliation failure.'
    Assert-Status (@($badEvent.state.tasks).Count -eq 4 -and $badEvent.testLease.free) 'Reconciliation failure lost saved tasks or skipped lease status.'
    Remove-Item -LiteralPath $badEventPath

    # Exercise the public command in both hosts, including filtering and errors.
    foreach ($hostCommand in @($windowsPowerShell, (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source))) {
        if (-not $hostCommand) { continue }
        $output = & $hostCommand -NoProfile -File (Join-Path $PluginRoot 'factory.ps1') status failed `
            -Repository $repository -ClaudeCommand $fakeRuntime -CodexCommand $fakeRuntime -NoReconcile | Out-String
        Assert-Status ($LASTEXITCODE -eq 0 -and $output.Contains('codex-fixture') -and -not $output.Contains('claude-fixture')) 'Public status filtering or JSON transport failed.'
        Assert-Status ($output.Contains('test lane free')) 'Public status omitted live test-lane state.'
    }
    Write-Host 'Factory live status regressions passed.' -ForegroundColor Green
} finally {
    if ($null -ne $originalPowerShellFunction) {
        Set-Item Function:\powershell -Value $originalPowerShellFunction.ScriptBlock
    } else { Remove-Item Function:\powershell -ErrorAction SilentlyContinue }
    foreach ($entry in $previous.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    $env:PATH = $previousPath
    $fullFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path -Parent $fullFixture) -ne $tempRoot -or (Split-Path -Leaf $fullFixture) -notlike 'factory-status-*') {
        throw "Unsafe status fixture cleanup: $fullFixture"
    }
    Remove-Item -LiteralPath $fullFixture -Recurse -Force
}
