param(
    [Parameter(Mandatory=$true)][string]$ConnectionRepository,
    [Parameter(Mandatory=$true)][string]$PhpExecutable,
    [Parameter(Mandatory=$true)][string]$PhpUnitPath,
    [switch]$AllowDaemonRestart,
    [switch]$UseCurrentDaemon,
    [string]$PluginRoot = ''
)

# Deliberately excluded from run-tests.ps1: this consumes real Claude turns,
# restarts the machine-wide daemon, and creates/drops two disposable databases.
$ErrorActionPreference = 'Stop'
if (-not $AllowDaemonRestart -and -not $UseCurrentDaemon) { throw 'Obtain operator approval, then pass -AllowDaemonRestart (or -UseCurrentDaemon for an approved follow-up).' }
if (-not $PluginRoot) { $PluginRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\worker-launch.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('factory-worker-live-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixture 'repository'
$databasePrefix = 'factory_env_' + [Guid]::NewGuid().ToString('N').Substring(0,12)
$databases = @(); $sessions = @(); $previous = @(); $restartAttempted = $false
$savedEnvironment = @{}
$report = [ordered]@{ fixture=$fixture; sessions=@(); overlap=$false; restored=@(); restorationDeferred=@(); passed=$false }
function Invoke-LiveClaude {
    param([string[]]$Arguments, [string]$Directory=$repository)
    $result = Invoke-FactoryNativeProcess -Command claude -Arguments $Arguments -WorkingDirectory $Directory
    if ($result.exitCode -ne 0) { throw $result.output }
    return $result
}
function Get-LiveRows {
    # Windows PowerShell 5.1 does not enumerate ConvertFrom-Json arrays in a
    # downstream pipeline. Materialize first, then filter individual rows.
    $rows = (Invoke-LiveClaude @('agents','--json','--all')).stdout | ConvertFrom-Json
    return @($rows | Where-Object { $_.kind -eq 'background' })
}
function Get-LiveMessages {
    param($Session)
    $job = Read-FactoryJson (Join-Path $env:USERPROFILE ".claude\jobs\$($Session.id)\state.json")
    $path = [string](Get-FactoryNestedValue $job 'linkScanPath' '')
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }
    return @([IO.File]::ReadLines($path) | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { } # A last line may still be streaming.
    })
}
try {
    foreach ($name in @('CLAUDE_FACTORY_HOME','CLAUDE_FACTORY_TASK_ID','CLAUDE_FACTORY_PROMPT_PATH','DB_DATABASE')) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    & git init --quiet $repository
    & git -C $repository -c user.name=FactoryTest -c user.email=factory@example.invalid -c commit.gpgsign=false commit --allow-empty -m base --quiet
    if ($LASTEXITCODE) { throw 'Could not initialize disposable repository.' }
    $context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
    $report.projectData = $context.projectData
    $config = Read-FactoryJson $context.configPath
    $config.nativeScheduler.enabled = $false
    $config.testDatabaseIsolation.enabled = $true
    $config.testDatabaseIsolation.databasePrefix = $databasePrefix
    Write-FactoryJsonAtomic $context.configPath $config
    $settings = Get-FactoryTestDatabaseSettings $config $ConnectionRepository
    # Never copy database credentials into fixtures, prompts, reports, or logs.
    $null = Invoke-FactoryPostgresMaintenance $settings 'SELECT 1'
    $state = Read-FactoryJson $context.statePath
    $state.active = $false
    $state.tasks = @()
    foreach ($id in @('one','two')) {
        $worktree = Join-Path $fixture "worker-$id"
        & git -C $repository worktree add --quiet -b "factory-worker/$id" $worktree
        if ($LASTEXITCODE) { throw 'Could not create disposable worktree.' }
        $database = Get-FactoryTestDatabaseName $settings worker $id
        # No IF NOT EXISTS: a collision must fail, never adopt an existing DB.
        $null = Invoke-FactoryPostgresMaintenance $settings ('CREATE DATABASE "' + $database + '"')
        $databases += $database
        $test = @'
<?php
require '__AUTOLOAD__';
final class DatabaseIdentityTest extends \PHPUnit\Framework\TestCase {
    public function testAssignedDatabase(): void {
        $values = \Dotenv\Dotenv::parse(file_get_contents('__ENVFILE__'));
        $assigned = '__ASSIGNED__';
        self::assertSame($assigned, getenv('DB_DATABASE'));
        $pdo = new \PDO('pgsql:host=' . ($values['DB_HOST'] ?? '127.0.0.1')
            . ';port=' . ($values['DB_PORT'] ?? '5432') . ';dbname=' . getenv('DB_DATABASE'),
            $values['DB_USERNAME'], $values['DB_PASSWORD'] ?? '');
        $actual = $pdo->query('SELECT current_database()')->fetchColumn();
        self::assertSame($assigned, $actual);
        echo "FACTORY_DB_PROOF=$actual\n";
    }
}
'@
        $autoload = Join-Path (Split-Path (Split-Path $PhpUnitPath -Parent) -Parent) 'autoload.php'
        $test = $test.Replace('__AUTOLOAD__', ($autoload -replace '\\','/').Replace("'", "\'"))
        $test = $test.Replace('__ENVFILE__', ([string]$settings.connectionEnvironmentPath -replace '\\','/').Replace("'", "\'"))
        $test = $test.Replace('__ASSIGNED__', $database)
        [IO.File]::WriteAllText((Join-Path $worktree 'DatabaseIdentityTest.php'), $test, (New-Object Text.UTF8Encoding($false)))
        $state.tasks += [pscustomobject]@{id=$id; branch="factory-worker/$id"; worktree=$worktree; testDatabase=$database; status='blocked'; backgroundSession=$null}
    }
    $mutex = Enter-FactoryMutex $context.projectKey
    try { Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $mutex }

    if (-not $UseCurrentDaemon) { $previous = @(Get-LiveRows | Where-Object { Get-FactoryNestedValue $_ 'pid' 0 }) }
    [IO.File]::WriteAllText((Join-Path $fixture 'sessions-before.json'), ($previous | ConvertTo-Json -Depth 10))
    $report.daemonBefore = (Invoke-LiveClaude @('daemon','status')).output
    foreach ($row in $previous) {
        if ([string]$row.status -eq 'busy') { throw "Background session $($row.id) became busy; obtain approval again before interrupting its work." }
    }
    Write-Host "Live fixture: $fixture"
    if (-not $UseCurrentDaemon) {
        $restartAttempted = $true
        Write-Host (Invoke-LiveClaude @('daemon','stop','--any')).output
    }
    $report.daemonRestarted = $restartAttempted
    foreach ($round in 1..2) {
        foreach ($task in $state.tasks) {
            $command = "DB_DATABASE=$($task.testDatabase) '$($PhpExecutable -replace '\\','/')' '$($PhpUnitPath -replace '\\','/')' --no-configuration --do-not-cache-result DatabaseIdentityTest.php"
            $firstCommand = 'printf ''FACTORY_PARENT_DB=%s\n'' "${DB_DATABASE:-<empty>}"; git status --short; sleep 8'
            $prompt = "This is an operator-approved Factory hook E2E in a disposable worktree. Use exactly two Bash calls, sequentially: first [$firstCommand], then [$command]. Do not edit files, read any credentials yourself, call other tools, load skills, touch other repositories, change environment globally, or bypass hooks. The provided test reads the local connection settings internally and reports only its disposable database name. Stop and report any refusal. After both commands, reply LIVE_PROBE_DONE."
            # --tools is variadic; a following option must terminate its values
            # or Claude consumes the initial prompt as another tool name.
            $result = Invoke-LiveClaude @('--bg','--plugin-dir',$PluginRoot,'--name',"Factory env E2E $round $($task.id)",'--tools','Bash','--permission-mode','auto',$prompt) $task.worktree
            $backgroundId = Get-FactoryBackgroundId $result.output
            if (-not $backgroundId) { throw "Cannot resolve launched probe: $($result.output)" }
            $session = [pscustomobject]@{ id=$backgroundId; task=$task.id; database=$task.testDatabase; round=$round }
            $sessions += $session
            $null = Wait-FactoryClaudeSessionVisible -ClaudeCommand claude -BackgroundId $backgroundId
            $job = Read-FactoryJson (Join-Path $env:USERPROFILE ".claude\jobs\$backgroundId\state.json")
            if (-not [string](Get-FactoryNestedValue $job 'intent' '')) { throw 'Claude created a probe without its initial prompt.' }
            Write-Host "Probe $round/$($task.id): $backgroundId"
        }
        $pair = @($sessions | Where-Object { $_.round -eq $round })
        $overlapDeadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            $rows = @(Get-LiveRows | Where-Object { $_.id -in $pair.id -and (Get-FactoryNestedValue $_ 'pid' 0) })
            if ($rows.Count -eq 2) { break }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $overlapDeadline)
        if ($rows.Count -eq 2) { $report.overlap = $true }
        $deadline = [DateTime]::UtcNow.AddMinutes(6)
        do {
            $complete = $true
            foreach ($session in $pair) {
                $messages = @(Get-LiveMessages $session)
                $done = @($messages | Where-Object { $_.type -eq 'assistant' } | ForEach-Object { $_.message.content } |
                    Where-Object { (Get-FactoryNestedValue $_ 'type' '') -eq 'text' -and $_.text -match 'LIVE_PROBE_DONE' })
                if (-not $done.Count) { $complete = $false }
            }
            if ($complete) { break }
            Start-Sleep -Seconds 5
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $complete) { throw 'Live probes did not finish within six minutes. Inspect retained transcripts.' }
    }
    $failedProbes = @()
    foreach ($session in $sessions) {
        $messages = @(Get-LiveMessages $session)
        $calls = @($messages | Where-Object { $_.type -eq 'assistant' } | ForEach-Object { $_.message.content } | Where-Object { (Get-FactoryNestedValue $_ 'type' '') -eq 'tool_use' })
        $results = @($messages | Where-Object { $_.type -eq 'user' } | ForEach-Object { $_.message.content } | Where-Object { (Get-FactoryNestedValue $_ 'type' '') -eq 'tool_result' })
        $errors = @($results | Where-Object { (Get-FactoryNestedValue $_ 'is_error' $false) -or ($_.content | ConvertTo-Json -Depth 10 -Compress) -match 'Factory Git guard blocked|Factory test-command guard' })
        $text = $results | ConvertTo-Json -Depth 20 -Compress
        $proof = $text -match [regex]::Escape("FACTORY_DB_PROOF=$($session.database)")
        $empty = @($results | Where-Object { [string]$_.content -match '(?m)^FACTORY_PARENT_DB=(?:<empty>)?\r?$' }).Count -gt 0
        $report.sessions += [pscustomobject]@{id=$session.id;task=$session.task;round=$session.round;toolCalls=$calls.Count;refusalsOrErrors=$errors.Count;database=$session.database;databaseProven=$proof;parentDatabaseAbsent=$empty}
        if ($calls.Count -ne 2 -or $errors.Count -or -not $proof -or -not $empty) { $failedProbes += $session.id }
    }
    if ($failedProbes.Count) { throw "Probes did not meet acceptance criteria: $($failedProbes -join ', ')." }
    if (-not $report.overlap) { throw 'No overlapping daemon workers were observed.' }
    $report.passed = $true
} finally {
    foreach ($session in $sessions) {
        try { $null = Invoke-LiveClaude @('stop',$session.id); $null = Invoke-LiveClaude @('rm',$session.id) }
        catch { Write-Warning "Probe cleanup $($session.id): $($_.Exception.Message)" }
    }
    foreach ($database in $databases) {
        if ($database -notmatch ('^' + [regex]::Escape($databasePrefix) + '_worker_(one|two)$')) { throw 'Unsafe disposable database cleanup target.' }
        try { $null = Invoke-FactoryPostgresMaintenance $settings ('DROP DATABASE "' + $database + '"') }
        catch { Write-Warning "Disposable database retained: $database" }
    }
    if ($restartAttempted) {
        foreach ($row in $previous) {
            # Never replay an old intent when the retained transcript has no
            # messages. Keep that stopped conversation available for the user.
            $jobPath = Join-Path $env:USERPROFILE ".claude\jobs\$($row.id)\state.json"
            try {
                $job = Read-FactoryJson $jobPath
                $path = [string](Get-FactoryNestedValue $job 'linkScanPath' '')
                if (-not $path -or -not (Test-Path -LiteralPath $path) -or
                    [IO.Path]::GetFileNameWithoutExtension($path) -ne [string]$row.sessionId -or
                    (Get-Item -LiteralPath $path).Length -lt 1000) {
                    $report.restorationDeferred += $row.id
                    continue
                }
                $null = Invoke-LiveClaude @('respawn',$row.id)
                $report.restored += $row.id
            } catch { $report.restorationDeferred += $row.id; Write-Warning "Restore $($row.id): $($_.Exception.Message)" }
        }
    }
    if (Test-Path -LiteralPath $fixture) {
        [IO.File]::WriteAllText((Join-Path $fixture 'report.json'), ($report | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        Write-Host "Live report: $(Join-Path $fixture 'report.json')"
    }
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process') }
}
$report | ConvertTo-Json -Depth 20
