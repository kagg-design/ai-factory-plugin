param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\worker-event.ps1')
. (Join-Path $PluginRoot 'scripts\codex-runtime.ps1')

function Assert-ParallelSafety {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('factory-parallel-safety-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixture 'repository'
$savedEnvironment = @{}
foreach ($name in @('CLAUDE_FACTORY_HOME', 'CLAUDE_FACTORY_PROMPT_PATH', 'CLAUDE_FACTORY_TASK_ID', 'DB_DATABASE', 'DATABASE_URL')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$env:CLAUDE_FACTORY_HOME = Join-Path $fixture 'runtime'
$lease = $null
$fakeWorkers = @()

function Invoke-SafetyLease {
    param([string[]]$Arguments)
    return Invoke-FactoryNativeProcess -Command powershell -Arguments (@(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PluginRoot 'scripts\test-lease.ps1'),
        '-Repository', $repository
    ) + $Arguments)
}

function Invoke-SafetyGuard {
    param([hashtable]$Environment, [string]$Payload)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command powershell).Source
    $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-FactoryWindowsArgument (Join-Path $PluginRoot 'scripts\worker-git-guard.ps1'))
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -eq $entry.Value) { $start.EnvironmentVariables.Remove([string]$entry.Key) }
        else { $start.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value }
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start the shell hook fixture.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($Payload)
        $process.StandardInput.Close()
        $process.WaitForExit()
        return [pscustomobject]@{ exitCode = $process.ExitCode; output = $stdout.Result + $stderr.Result }
    } finally { $process.Dispose() }
}

try {
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    & git init --quiet $repository
    if ($LASTEXITCODE) { throw 'Fixture git init failed.' }
    $context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
    $config = Read-FactoryJson $context.configPath
    $config.nativeScheduler.enabled = $false
    $config.testLease.heartbeatSeconds = 1
    $config.testDatabaseIsolation.enabled = $true
    $config.testDatabaseIsolation.databasePrefix = 'fixture'
    Write-FactoryJsonAtomic $context.configPath $config

    $composer = Join-Path $fixture 'composer'
    New-Item -ItemType Directory -Path (Join-Path $composer 'vendor\composer') -Force | Out-Null
    $lockPath = Join-Path $composer 'composer.lock'
    $lock = '{"packages":[{"name":"barryvdh/laravel-dompdf","version":"v3.1.1","extra":{"laravel":{"aliases":{"PDF":"Facade","Pdf":"Facade"}}}}]}'
    [IO.File]::WriteAllText((Join-Path $composer 'composer.json'), '{}')
    [IO.File]::WriteAllText($lockPath, $lock)
    [IO.File]::WriteAllText((Join-Path $composer 'vendor\composer\installed.json'), '{"packages":[]}')
    $installCalls = New-Object Collections.Generic.List[string]
    $installer = {
        param($Command, $Arguments, $WorkingDirectory)
        $installCalls.Add($Command)
        return [pscustomobject]@{ exitCode = 0; output = '' }
    }
    $null = @(Sync-FactoryWorktreeDependencies -Worktree $composer -Invoker $installer)
    Assert-ParallelSafety ($installCalls.Count -eq 1 -and $installCalls[0] -eq 'composer') 'A case-sensitive Composer alias prevented safe install fallback.'
    Assert-ParallelSafety ([IO.File]::ReadAllText($lockPath) -ceq $lock) 'Composer lock contents were rewritten.'
    $null = @(Sync-FactoryWorktreeDependencies -Worktree $composer -Invoker $installer)
    Assert-ParallelSafety ($installCalls.Count -eq 1) 'A verified dependency stamp did not skip the next install.'
    $stampPath = Join-Path $composer 'vendor\composer\.factory-composer-lock.sha256'
    [IO.File]::WriteAllText($stampPath, 'stale')
    $failedInstall = $false
    try { $null = @(Sync-FactoryWorktreeDependencies -Worktree $composer -Invoker { [pscustomobject]@{ exitCode = 1; output = 'installation failed' } }) } catch { $failedInstall = $true }
    Assert-ParallelSafety ($failedInstall -and [IO.File]::ReadAllText($stampPath) -ceq 'stale') 'Failed install blessed an unverified lock.'

    foreach ($separator in @("`r`n  `n", "`n``````json`r`n", "`n```````n", ': ', ":`n``````json`n")) {
        $message = 'FACTORY_RESULT' + $separator + '{"taskId":"a","status":"completed","notes":"braces { and }"}' + "`n``````"
        $parsed = ConvertFrom-FactoryWorkerMarkerMessage $message
        Assert-ParallelSafety ($parsed.kind -eq 'result' -and $parsed.payload.taskId -eq 'a') 'Whitespace or fenced JSON was rejected.'
    }
    foreach ($tail in @('', "`nProse before unrelated {`"example`":true}", "`n{bad}")) {
        $parsed = ConvertFrom-FactoryWorkerMarkerMessage ('FACTORY_RESULT' + $tail)
        Assert-ParallelSafety ($parsed.kind -eq 'invalid-marker' -and $parsed.payload.error -match 'Following marker:') 'A malformed report was accepted or lacked a payload preview.'
    }
    $parsed = ConvertFrom-FactoryWorkerMarkerMessage ('FACTORY_RESULT' + ('x' * 400))
    Assert-ParallelSafety ($parsed.payload.followingMarker.Length -eq 200) 'Malformed report preview is not bounded.'

    $settings = [pscustomobject]@{
        databasePrefix = 'fixture'; connectionEnvironmentPath = (Join-Path $fixture '.env')
        databaseEnvironmentVariable = 'DB_DATABASE'; hostEnvironmentVariable = 'DB_HOST'
        portEnvironmentVariable = 'DB_PORT'; usernameEnvironmentVariable = 'DB_USERNAME'; passwordEnvironmentVariable = 'DB_PASSWORD'
    }
    [IO.File]::WriteAllText($settings.connectionEnvironmentPath, "DB_HOST=127.0.0.1`n")
    $env:DB_DATABASE = 'foreign-worker-database'
    $env:DATABASE_URL = 'postgres://foreign-server/foreign-database'
    $env:CLAUDE_FACTORY_PROMPT_PATH = Join-Path $fixture 'foreign-prompt.txt'
    $env:CLAUDE_FACTORY_TASK_ID = 'foreign-task'
    $workerEnvironments = @()
    foreach ($id in @('worker-one', 'worker-two', 'worker-three')) {
        $task = [pscustomobject]@{ id = $id; testDatabase = (Get-FactoryTestDatabaseName $settings -Scope worker -TaskId $id) }
        $prompt = Join-Path $fixture "$id-prompt.txt"
        $environment = New-FactoryWorkerEnvironment -Context $context -Task $task -Worktree $repository -PromptPath $prompt -DatabaseSettings $settings -DatabaseName $task.testDatabase
        $workerEnvironments += $environment
        Assert-ParallelSafety ($environment.DB_DATABASE -ceq $task.testDatabase -and $environment.CLAUDE_FACTORY_PROMPT_PATH -ceq $prompt) 'A worker inherited another task environment.'
        Assert-ParallelSafety ($null -eq $environment.DATABASE_URL) 'An inherited database URL overrides the assigned database.'
        $probe = Invoke-FactoryNativeProcess -Command powershell -Environment $environment -Arguments @('-NoProfile', '-Command', '[Console]::Write($env:DB_DATABASE + "|" + $env:CLAUDE_FACTORY_TASK_ID + "|" + $env:DATABASE_URL)')
        Assert-ParallelSafety ($probe.exitCode -eq 0 -and $probe.stdout -ceq ($task.testDatabase + '|' + $id + '|')) 'The native child did not receive its private environment.'
    }
    Assert-ParallelSafety ($env:DB_DATABASE -ceq 'foreign-worker-database' -and $env:CLAUDE_FACTORY_TASK_ID -eq 'foreign-task') 'Preparing workers mutated the launcher environment.'
    Assert-ParallelSafety ($workerEnvironments[0].DB_DATABASE -ne $workerEnvironments[2].DB_DATABASE) 'Worker environment maps were reused.'
    $guarded = $false
    try { Assert-FactoryWorkerEnvironment -Task $task -DatabaseSettings $settings -PromptPath $prompt } catch { $guarded = $_.Exception.Message -match 'environment mismatch' }
    Assert-ParallelSafety $guarded 'Foreign inherited database did not fail closed.'

    # Launch three overlapping native Codex workers through the detached,
    # private-environment boundary; no real Codex or database is contacted.
    $fakeCodex = Join-Path $fixture 'fake-codex.exe'
    Add-Type -Path (Join-Path $PluginRoot 'tests\FakeCodex.cs') -OutputAssembly $fakeCodex -OutputType ConsoleApplication
    $state = Read-FactoryJson $context.statePath
    $state.tasks = @($workerEnvironments | ForEach-Object { [pscustomobject]@{ id = $_.CLAUDE_FACTORY_TASK_ID; testDatabase = $_.DB_DATABASE; status = 'done'; backgroundSession = [pscustomobject]@{ state = 'done' } } })
    $stateLock = Enter-FactoryMutex -ProjectKey $context.projectKey
    try { Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $stateLock }
    foreach ($environment in $workerEnvironments) {
        $id = $environment.CLAUDE_FACTORY_TASK_ID
        $capture = Join-Path $fixture "$id-environment.txt"
        $environment.CLAUDE_FACTORY_TEST_WORKER_ENV_CAPTURE = $capture
        $environment.CLAUDE_FACTORY_TEST_CODEX_WORKER_MILLISECONDS = '20000'
        [IO.File]::WriteAllText($environment.CLAUDE_FACTORY_PROMPT_PATH, ('FACTORY_TASK' + "`n" + '{"taskId":"' + $id + '"}'))
        $worker = Start-FactoryCodexWorkerProcess -CodexCommand $fakeCodex -PluginRoot $PluginRoot -Worktree $repository `
            -PromptPath $environment.CLAUDE_FACTORY_PROMPT_PATH -ArtifactPrefix (Join-Path $fixture $id) `
            -SessionName $id -Environment $environment -Capabilities ([pscustomobject]@{ supported = $true; version = 'fake' })
        $fakeWorkers += $worker
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $capture) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        $captured = [IO.File]::ReadAllLines($capture)
        Assert-ParallelSafety ($captured[0] -ceq $environment.DB_DATABASE -and $captured[1] -ceq $id -and $captured[2] -ceq $environment.CLAUDE_FACTORY_PROMPT_PATH -and -not $captured[3]) 'A detached worker received another worker environment.'
    }
    foreach ($worker in $fakeWorkers) {
        Assert-ParallelSafety (Test-FactoryRecordedProcess ([pscustomobject]@{ pid = $worker.processId; processStartTimeUtc = $worker.processStartTimeUtc })) 'Concurrent environment fixture workers did not overlap.'
    }
    Assert-ParallelSafety ($env:DB_DATABASE -ceq 'foreign-worker-database' -and $env:CLAUDE_FACTORY_TASK_ID -eq 'foreign-task') 'Detached worker launch changed the parent environment.'

    $withoutOwner = Invoke-SafetyLease @('-Action', 'acquire', '-TaskId', 'one-shot', '-Phase', 'verify')
    Assert-ParallelSafety ($withoutOwner.exitCode -ne 0 -and $withoutOwner.output -match 'requires -OwnerPid') 'A one-shot acquire without a durable owner succeeded.'
    $first = Invoke-SafetyLease @('-Action', 'acquire', '-TaskId', 'worker-one', '-Phase', 'verify', '-OwnerPid', [string]$PID)
    Assert-ParallelSafety ($first.exitCode -eq 0) "Owned acquire failed: $($first.output)"
    $lease = $first.stdout | ConvertFrom-Json
    $before = (Read-FactoryJson $context.testLeasePath).holder.heartbeatAt
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 200
        $holder = (Read-FactoryJson $context.testLeasePath).holder
    } while ($holder.heartbeatAt -eq $before -and [DateTime]::UtcNow -lt $deadline)
    Assert-ParallelSafety ($holder.heartbeatAt -ne $before -and $holder.token -eq $lease.token) 'Heartbeat did not survive the acquire subprocess exiting.'
    $second = Invoke-SafetyLease @('-Action', 'acquire', '-TaskId', 'worker-two', '-Phase', 'verify', '-OwnerPid', [string]$PID, '-WaitTimeoutSeconds', '1', '-NoHeartbeat')
    Assert-ParallelSafety ($second.exitCode -ne 0 -and $second.output -match 'Timed out waiting') 'A second suite took the live first suite lease.'
    $released = Invoke-SafetyLease @('-Action', 'release', '-Token', $lease.token)
    Assert-ParallelSafety (($released.stdout | ConvertFrom-Json).released) 'The original holder could not release its own lease.'
    $lease = $null
    $next = Invoke-SafetyLease @('-Action', 'acquire', '-TaskId', 'worker-two', '-Phase', 'verify', '-OwnerPid', [string]$PID, '-NoHeartbeat')
    Assert-ParallelSafety ($next.exitCode -eq 0) 'The waiter could not acquire after release.'
    $lease = $next.stdout | ConvertFrom-Json
    $null = Invoke-SafetyLease @('-Action', 'release', '-Token', $lease.token)
    $lease = $null

    # A committed clean task with a malformed report waits for correction;
    # correction alone restores review readiness without another code commit.
    & git -C $repository -c user.name=FactoryTest -c user.email=factory@example.invalid -c commit.gpgsign=false commit --allow-empty -m base --quiet
    if ($LASTEXITCODE) { throw 'Could not create report fixture base.' }
    & git -C $repository checkout --quiet -b factory-worker/report
    & git -C $repository -c user.name=FactoryTest -c user.email=factory@example.invalid -c commit.gpgsign=false commit --allow-empty -m task --quiet
    if ($LASTEXITCODE) { throw 'Could not create report fixture commit.' }
    $reportCommit = (& git -C $repository rev-parse HEAD).Trim()
    $reportTask = [pscustomobject]@{
        id = 'report'; title = 'Report correction'; status = 'running'; startMode = 'auto'
        worktree = $repository; branch = 'factory-worker/report'; commit = $null
        testDatabase = 'fixture_worker_report'
        workerResult = $null; reworkRequestedAt = $null; attempts = 1
        backgroundSession = [pscustomobject]@{ id = 'report-bg'; runtime = 'claude'; sessionId = 'report-session'; state = 'done'; lastSeenAt = Get-FactoryUtcTimestamp }
    }
    $stateLock = Enter-FactoryMutex -ProjectKey $context.projectKey
    try {
        $state = Read-FactoryJson $context.statePath
        $state.tasks = @($state.tasks) + @($reportTask)
        Write-FactoryJsonAtomic $context.statePath $state
    } finally { Exit-FactoryMutex $stateLock }
    $reportPrompt = Join-Path $fixture 'report-prompt.txt'
    Write-FactoryJsonAtomic (Join-Path $context.sessionsPath 'report.json') ([ordered]@{ promptPath = $reportPrompt })
    $guardPayload = [ordered]@{ cwd = $repository; tool_input = @{ command = 'php artisan test' } } | ConvertTo-Json -Compress
    $guardEnvironment = New-FactoryWorkerEnvironment -Context $context -Task $reportTask -Worktree $repository -PromptPath $reportPrompt -DatabaseSettings $settings -DatabaseName $reportTask.testDatabase
    $guardRun = Invoke-SafetyGuard -Environment $guardEnvironment -Payload $guardPayload
    Assert-ParallelSafety ($guardRun.exitCode -eq 0) "The shell hook rejected the correct task environment: $($guardRun.output)"
    $guardEnvironment.DB_DATABASE = 'foreign-worker-database'
    $guardRun = Invoke-SafetyGuard -Environment $guardEnvironment -Payload $guardPayload
    Assert-ParallelSafety ($guardRun.exitCode -eq 2 -and $guardRun.output -match 'environment mismatch') 'The shell hook allowed tests with another worker database.'
    $guardEnvironment.DB_DATABASE = $reportTask.testDatabase
    $guardEnvironment.CLAUDE_FACTORY_PROMPT_PATH = Join-Path $fixture 'foreign-prompt.txt'
    $guardRun = Invoke-SafetyGuard -Environment $guardEnvironment -Payload $guardPayload
    Assert-ParallelSafety ($guardRun.exitCode -eq 2 -and $guardRun.output -match 'prompt environment belongs to another task') 'The shell hook allowed another worker prompt pointer.'
    $fakeClaude = Join-Path $fixture 'fake-claude.exe'
    Add-Type -Path (Join-Path $PluginRoot 'tests\FakeClaude.cs') -OutputAssembly $fakeClaude -OutputType ConsoleApplication
    $null = Publish-FactoryWorkerEvent -Context $context -Task $reportTask -SessionId 'report-session' -Worktree $repository -Message "FACTORY_RESULT`nThe work is finished."
    $reconcileArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PluginRoot 'scripts\reconcile-worker-sessions.ps1'), '-Repository', $repository, '-ClaudeCommand', $fakeClaude)
    $reconciled = Invoke-FactoryNativeProcess -Command powershell -Arguments $reconcileArguments -Environment @{ CLAUDE_FACTORY_TEST_NO_AGENTS = '1' }
    Assert-ParallelSafety ($reconciled.exitCode -eq 0) "Report reconciliation failed: $($reconciled.output)"
    $recorded = Get-FactoryTask -State (Read-FactoryJson $context.statePath) -TaskId 'report'
    Assert-ParallelSafety ($recorded.status -eq 'awaiting-input' -and -not (Test-FactoryTaskHasValidatedResult $recorded)) 'A malformed report failed the code task or enabled review.'
    Assert-ParallelSafety ($recorded.error -match 'Following marker:' -and $recorded.error -match 'factory chat report') 'Report recovery omitted diagnostics or the exact chat command.'
    Assert-ParallelSafety ((& git -C $repository rev-parse HEAD).Trim() -eq $reportCommit -and @(& git -C $repository status --porcelain).Count -eq 0) 'Report failure modified the committed work.'
    $corrected = [ordered]@{ taskId = 'report'; status = 'completed'; commit = $reportCommit; branch = 'factory-worker/report'; worktree = $repository; tests = @([pscustomobject]@{ command = 'synthetic check'; status = 'passed' }) }
    $null = Publish-FactoryWorkerEvent -Context $context -Task $reportTask -SessionId 'report-session' -Worktree $repository -Message ('FACTORY_RESULT' + "`n``````json`n" + ($corrected | ConvertTo-Json -Depth 10) + "`n``````")
    $reconciled = Invoke-FactoryNativeProcess -Command powershell -Arguments $reconcileArguments -Environment @{ CLAUDE_FACTORY_TEST_NO_AGENTS = '1' }
    Assert-ParallelSafety ($reconciled.exitCode -eq 0) "Corrected report reconciliation failed: $($reconciled.output)"
    $recorded = Get-FactoryTask -State (Read-FactoryJson $context.statePath) -TaskId 'report'
    Assert-ParallelSafety ($recorded.status -eq 'awaiting-review' -and $recorded.commit -eq $reportCommit) 'Correcting the report did not restore review for the original commit.'
    Write-Host 'Parallel safety focused tests passed (Composer fallback, marker diagnostics, task environments and durable exclusive lease).'
} finally {
    if ($lease) { $null = Invoke-SafetyLease @('-Action', 'release', '-Token', $lease.token) }
    foreach ($worker in $fakeWorkers) {
        if (Test-FactoryRecordedProcess ([pscustomobject]@{ pid = $worker.processId; processStartTimeUtc = $worker.processStartTimeUtc })) {
            Stop-Process -Id ([int]$worker.processId) -Force
        }
    }
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    # Retain isolated fixture files for diagnostics; no real workers or databases are used.
}
