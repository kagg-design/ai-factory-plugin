[CmdletBinding()]
param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot), [string]$BaselinePluginRoot = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')

function Test-RockDisabledScheduler {
    param([string]$SourceRoot, [string]$Label)
    $fixture = Join-Path ([IO.Path]::GetTempPath()) "rock-scheduler-compat-$([Guid]::NewGuid().ToString('N'))"
    $repository = Join-Path $fixture 'repository'
    $remote = Join-Path $fixture 'remote.git'
    $fakeClaude = Join-Path $fixture 'fake-claude.exe'
    $fakeCodex = Join-Path $fixture 'fake-codex.exe'
    $oldHome = $env:CLAUDE_FACTORY_HOME
    $oldDelay = $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_MILLISECONDS
    $oldLog = $env:CLAUDE_FACTORY_TEST_CODEX_LOG
    $context = $null
    try {
        $null = New-Item -ItemType Directory -Path $repository -Force
        $env:CLAUDE_FACTORY_HOME = Join-Path $fixture 'runtime'
        $env:CLAUDE_FACTORY_TEST_CODEX_LOG = Join-Path $fixture 'codex.tsv'
        foreach ($compilerInput in @(@{source='FakeClaude.cs';output=$fakeClaude}, @{source='FakeCodex.cs';output=$fakeCodex})) {
            $compile = "Add-Type -Path '" + (Join-Path $SourceRoot "tests\$($compilerInput.source)").Replace("'", "''") + "' -OutputAssembly '" + $compilerInput.output.Replace("'", "''") + "' -OutputType ConsoleApplication"
            $compiled = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile','-Command',$compile) -TimeoutSeconds 60
            if ($compiled.exitCode -ne 0) { throw $compiled.output }
        }
        git -C $repository init --quiet --initial-branch=develop
        git init --bare --quiet $remote
        git -C $repository config user.name 'Scheduler compatibility test'
        git -C $repository config user.email 'scheduler@example.test'
        git -C $repository config commit.gpgsign false
        [IO.File]::WriteAllText((Join-Path $repository 'base.txt'),'fixture')
        git -C $repository add base.txt
        git -C $repository commit --quiet -m fixture
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated fixture commit.' }
        git -C $repository branch master
        git -C $repository remote add origin $remote
        git -C $repository push --quiet origin develop master
        if ($LASTEXITCODE -ne 0) { throw 'Could not seed the isolated fixture remote.' }
        $context = & (Join-Path $SourceRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
        $config = Read-FactoryJson $context.configPath
        $config.workerAgent='codex'; $config.codexCommand=$fakeCodex; $config.codingConcurrency=3
        $config.orchestrator.attentionBridge=$false; $config.ciMonitoring.enabled=$false
        Write-FactoryJsonAtomic $context.configPath $config
        foreach ($index in 1..3) {
            $null = & (Join-Path $SourceRoot 'scripts\enqueue-task.ps1') -Repository $repository -LocalText "Scheduler slot $index" -StartMode auto -NoResume
        }
        $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_MILLISECONDS='30000'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'scripts\factory-scheduler.ps1'),'-Action','tick','-Repository',$repository,'-ClaudeCommand',$fakeClaude,'-RuntimeHome',$env:CLAUDE_FACTORY_HOME) -TimeoutSeconds 180
        $timer.Stop()
        if ($run.exitCode -ne 0) { throw $run.output }
        $tick = $run.stdout | ConvertFrom-Json
        if ([int]$tick.launchedCount -ne 3) { throw "Only $($tick.launchedCount) of three slots launched: $($run.stdout)" }
        $recorded = Read-FactoryJson $context.statePath
        $live = 0
        foreach ($task in @($recorded.tasks)) {
            try { if ($null -ne (Get-Process -Id ([int]$task.backgroundSession.processId) -ErrorAction Stop)) { $live++ } } catch { }
        }
        if ($live -ne 3) { throw "The scheduler did not return while all three workers remained alive (alive: $live)." }
        [pscustomobject]@{ label=$Label; launched=[int]$tick.launchedCount; liveWorkers=$live; seconds=[Math]::Round($timer.Elapsed.TotalSeconds,3); original28SecondThreshold=($timer.Elapsed.TotalSeconds -lt 28) }
    } finally {
        if ($null -ne $context -and (Test-Path -LiteralPath $context.statePath)) {
            foreach ($task in @((Read-FactoryJson $context.statePath).tasks)) {
                $null = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'scripts\reject-task.ps1'),'-Repository',$repository,'-TaskId',[string]$task.id,'-Yes','-ClaudeCommand',$fakeClaude,'-CodexCommand',$fakeCodex) -TimeoutSeconds 60
            }
        }
        # Stop only generated executables at this exact fixture path.
        foreach ($name in @('fake-claude','fake-codex')) {
            foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                try {
                    if ([string]$process.Path -in @($fakeClaude,$fakeCodex)) { Stop-Process -Id $process.Id -Force; $null = $process.WaitForExit(5000) }
                } catch { }
            }
        }
        $env:CLAUDE_FACTORY_HOME=$oldHome
        $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_MILLISECONDS=$oldDelay
        $env:CLAUDE_FACTORY_TEST_CODEX_LOG=$oldLog
        $absolute = [IO.Path]::GetFullPath($fixture)
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\rock-scheduler-compat-'
        if ($absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $absolute)) { Remove-Item -LiteralPath $absolute -Recurse -Force }
    }
}
if ($BaselinePluginRoot) { Test-RockDisabledScheduler -SourceRoot $BaselinePluginRoot -Label baseline | ConvertTo-Json -Compress }
Test-RockDisabledScheduler -SourceRoot $PluginRoot -Label direct-rock-disabled | ConvertTo-Json -Compress
