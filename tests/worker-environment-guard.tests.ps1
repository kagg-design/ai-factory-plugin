param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('factory-worker-guard-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixture 'repository'
$saved = @{}
foreach ($name in @('CLAUDE_FACTORY_HOME','CLAUDE_FACTORY_TASK_ID','CLAUDE_FACTORY_PROMPT_PATH','DB_DATABASE','FIXTURE_DB')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
$env:CLAUDE_FACTORY_HOME = Join-Path $fixture 'runtime'
$probeCount = 0
function Assert-GuardFixture {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-GuardFixture {
    param([string]$Command, [string]$Tool = 'Bash', [string]$Worktree = $script:worktreeOne)
    $script:probeCount++
    $prefix = Join-Path $fixture "probe-$script:probeCount"
    $payload = [ordered]@{ tool_name=$Tool; cwd=$Worktree; tool_input=@{command=$Command} } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText("$prefix.json", $payload, (New-Object Text.UTF8Encoding($false)))
    # Real stdin, not a PowerShell object/text pipeline: the same boundary used
    # by Claude's hook. Each probe runs in a fresh native process.
    $process = Start-Process -FilePath (Get-Command powershell).Source -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (ConvertTo-FactoryWindowsArgument (Join-Path $PluginRoot 'scripts\worker-git-guard.ps1'))
    ) -RedirectStandardInput "$prefix.json" -RedirectStandardOutput "$prefix.out" -RedirectStandardError "$prefix.err" -WindowStyle Hidden -PassThru -Wait
    return [pscustomobject]@{ exitCode=$process.ExitCode; stdout=[IO.File]::ReadAllText("$prefix.out"); stderr=[IO.File]::ReadAllText("$prefix.err") }
}
function Assert-AllowedGuardFixture {
    param([string]$Command, [string]$Tool = 'Bash', [string]$Worktree = $script:worktreeOne)
    $result = Invoke-GuardFixture $Command $Tool $Worktree
    Assert-GuardFixture ($result.exitCode -eq 0 -and -not $result.stdout -and -not $result.stderr) "Unexpected refusal for [$Tool] $Command : $($result.stderr) $($result.stdout)"
}
function Assert-DeniedGuardFixture {
    param([string]$Command, [string]$Tool = 'Bash')
    $result = Invoke-GuardFixture $Command $Tool
    Assert-GuardFixture ($result.exitCode -eq 2 -and $result.stderr.Contains('fixture_worker_one') -and $result.stderr -match 'Expected:.*\r?\nActual.*\r?\nProcess: guard PID=\d+; parent PID=\d+') "Missing refusal/diagnostics for [$Tool] $Command : $($result.stderr)"
    return $result
}
try {
    $manifest = Read-FactoryJson (Join-Path $PluginRoot 'MANIFEST.json')
    Assert-GuardFixture ('scripts/worker-command-guard.ps1' -in $manifest.files) 'The distributable bundle omits the command guard.'
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    & git init --quiet $repository
    & git -C $repository -c user.name=FactoryTest -c user.email=factory@example.invalid -c commit.gpgsign=false commit --allow-empty -m base --quiet
    if ($LASTEXITCODE) { throw 'Could not initialize guard fixture.' }
    $context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
    $config = Read-FactoryJson $context.configPath
    $config.nativeScheduler.enabled = $false
    $config.testDatabaseIsolation.enabled = $true
    $config.testDatabaseIsolation.databasePrefix = 'fixture'
    Write-FactoryJsonAtomic $context.configPath $config
    $script:worktreeOne = Join-Path $fixture 'worker-one'
    $worktreeTwo = Join-Path $fixture 'worker-two'
    & git -C $repository worktree add --quiet -b factory-worker/one $worktreeOne
    if ($LASTEXITCODE) { throw 'Could not create first worktree.' }
    & git -C $repository worktree add --quiet -b factory-worker/two $worktreeTwo
    if ($LASTEXITCODE) { throw 'Could not create second worktree.' }
    $state = Read-FactoryJson $context.statePath
    $state.tasks = @(
        [pscustomobject]@{id='one';branch='factory-worker/one';worktree=$worktreeOne;testDatabase='fixture_worker_one';status='blocked'},
        [pscustomobject]@{id='two';branch='factory-worker/two';worktree=$worktreeTwo;testDatabase='fixture_worker_two';status='blocked'}
    )
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    try { Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $mutex }
    $before = [IO.File]::ReadAllText($context.statePath)

    $absent = Invoke-GuardFixture 'echo probe'
    Assert-GuardFixture ($absent.exitCode -eq 0 -and -not $absent.stderr) 'An absent database blocked a daemon-style shell.'
    $env:DB_DATABASE = 'fixture_worker_two'
    $foreign = Assert-DeniedGuardFixture 'echo probe'
    Assert-GuardFixture ($foreign.stderr.Contains("'fixture_worker_two'") -and $foreign.stderr.Contains('process environment DB_DATABASE') -and $foreign.stderr -cne $absent.stderr) 'Foreign and absent environments were confused.'
    $null = Assert-DeniedGuardFixture 'DB_DATABASE=fixture_worker_one phpunit'
    $env:DB_DATABASE = 'fixture_worker_one'
    Assert-AllowedGuardFixture 'echo probe'
    # A perfect process environment cannot hide a corrupt ledger assignment.
    $state.tasks[0].testDatabase = 'wrong_ledger_database'
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    try { Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $mutex }
    $badLedger = Assert-DeniedGuardFixture 'echo probe'
    Assert-GuardFixture ($badLedger.stderr.Contains("'wrong_ledger_database'") -and $badLedger.stderr.Contains('ledger task.testDatabase')) 'Ledger disagreement was not diagnosed.'
    $state.tasks[0].testDatabase = 'fixture_worker_one'
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    try { Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $mutex }

    $unpinned = Assert-DeniedGuardFixture 'php artisan test'
    Assert-GuardFixture ($unpinned.stderr.Contains("'<empty>'")) 'An absent command pin was not distinguished from a foreign one.'
    Remove-Item Env:\DB_DATABASE
    $env:CLAUDE_FACTORY_PROMPT_PATH = Join-Path $fixture 'another-attempt.txt'
    foreach ($command in @('cat README.md','git status','./vendor/bin/pint','npm run lint','yarn lint','tsc','echo "php artisan test"')) { Assert-AllowedGuardFixture $command }
    Assert-AllowedGuardFixture "cat <<'DOC'`nphp artisan test`nDOC"
    $null = Assert-DeniedGuardFixture "cat <<'DOC'`nphp artisan test`nDOC`nphpunit"
    foreach ($command in @('php artisan test','./vendor/bin/phpunit --filter Case','php vendor/bin/paratest','vendor/bin/paratest')) {
        $null = Assert-DeniedGuardFixture $command
        Assert-AllowedGuardFixture ("DB_DATABASE=fixture_worker_one $command")
    }
    Assert-AllowedGuardFixture "env DB_DATABASE='fixture_worker_one' php artisan test"
    Assert-AllowedGuardFixture "DB_DATABASE=fixture_worker_one \`nphp artisan test"
    Assert-AllowedGuardFixture 'if true; then DB_DATABASE=fixture_worker_one phpunit; fi'
    Assert-AllowedGuardFixture 'DB_DATABASE=fixture_worker_one phpunit && DB_DATABASE=fixture_worker_one paratest'
    foreach ($command in @(
        'DB_DATABASE=fixture_worker_two php artisan test',
        'DB_DATABASE=fixture_worker_one DB_DATABASE=fixture_worker_two phpunit',
        'echo DB_DATABASE=fixture_worker_one; phpunit',
        'DB_DATABASE=fixture_worker_one echo ready; phpunit',
        'DB_DATABASE=fixture_worker_one phpunit; paratest',
        'phpunit; DB_DATABASE=fixture_worker_one',
        'if true; then phpunit; fi',
        '/usr/bin/env -u DB_DATABASE phpunit',
        "# DB_DATABASE=fixture_worker_one`nphpunit"
    )) { $null = Assert-DeniedGuardFixture $command }
    foreach ($command in @(
        '$env:DB_DATABASE = ''fixture_worker_one''; php artisan test',
        '$env:DB_DATABASE = "fixture_worker_one"; & ''.\vendor\bin\phpunit''',
        '$env:DB_DATABASE = ''fixture_worker_one''; try { php artisan test } finally { Write-Host finished }'
    )) { Assert-AllowedGuardFixture $command PowerShell }
    foreach ($command in @(
        'php artisan test',
        '$env:DB_DATABASE = ''fixture_worker_two''; php artisan test',
        'php artisan test; $env:DB_DATABASE = ''fixture_worker_one''',
        'Write-Host ''$env:DB_DATABASE = fixture_worker_one''; phpunit',
        'if ($false) { $env:DB_DATABASE = ''fixture_worker_one'' }; phpunit',
        '$env:DB_DATABASE = ''fixture_worker_one''; $env:DB_DATABASE = ''fixture_worker_two''; phpunit'
    )) { $null = Assert-DeniedGuardFixture $command PowerShell }
    Assert-AllowedGuardFixture 'Write-Host ''php artisan test''' PowerShell
    Assert-AllowedGuardFixture 'powershell -NoProfile -Command ''$env:DB_DATABASE = "fixture_worker_one"; php artisan test'''
    $null = Assert-DeniedGuardFixture 'powershell -NoProfile -Command ''php artisan test'''
    $null = Assert-DeniedGuardFixture 'bash -c "phpunit"'
    $env:CLAUDE_FACTORY_TASK_ID = 'two'
    $wrongId = Invoke-GuardFixture 'git status'
    Assert-GuardFixture ($wrongId.exitCode -eq 2 -and $wrongId.stderr.Contains("Expected: 'one'") -and $wrongId.stderr.Contains("'two'")) 'Foreign task identity was accepted.'
    Remove-Item Env:\CLAUDE_FACTORY_TASK_ID

    # Interleaved independent worktrees resolve their own ledger identity even
    # when every shell inherits the same unrelated prompt from a shared donor.
    foreach ($round in 1..2) {
        Assert-AllowedGuardFixture 'git status' Bash $worktreeOne
        Assert-AllowedGuardFixture 'DB_DATABASE=fixture_worker_one phpunit' Bash $worktreeOne
        Assert-AllowedGuardFixture 'git status' Bash $worktreeTwo
        Assert-AllowedGuardFixture 'DB_DATABASE=fixture_worker_two phpunit' Bash $worktreeTwo
    }
    $gitDenied = Invoke-GuardFixture 'git push origin HEAD'
    Assert-GuardFixture ($gitDenied.exitCode -eq 0 -and ($gitDenied.stdout | ConvertFrom-Json).hookSpecificOutput.permissionDecision -eq 'deny') 'Existing Git protection regressed.'
    Assert-GuardFixture ([IO.File]::ReadAllText($context.statePath) -ceq $before) 'The guard mutated task state.'
    $orphan = Join-Path $fixture 'orphan'
    & git -C $repository worktree add --quiet -b factory-worker/orphan $orphan
    if ($LASTEXITCODE) { throw 'Could not create orphan worktree.' }
    Remove-Item Env:\CLAUDE_FACTORY_PROMPT_PATH
    $unowned = Invoke-GuardFixture 'git status' Bash $orphan
    Assert-GuardFixture ($unowned.exitCode -eq 2 -and $unowned.stderr -match 'exactly one task in the ledger') 'Missing identity variables allowed an unowned worker shell.'
    $config.testDatabaseIsolation.databaseEnvironmentVariable = 'FIXTURE_DB'
    Write-FactoryJsonAtomic $context.configPath $config
    Assert-AllowedGuardFixture 'FIXTURE_DB=fixture_worker_one phpunit'
    $null = Assert-DeniedGuardFixture 'DB_DATABASE=fixture_worker_one phpunit'
    $config.testDatabaseIsolation.enabled = $false
    Write-FactoryJsonAtomic $context.configPath $config
    Assert-AllowedGuardFixture 'phpunit'
    Write-Host "Worker environment guard tests passed ($probeCount real hook processes; isolated two-worktree fixture; no live daemon or database touched)."
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
