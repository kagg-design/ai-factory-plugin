[CmdletBinding()]
param([string]$PluginRoot = '', [string]$BaselinePluginRoot = '', [switch]$InjectInheritedPipe)
$ErrorActionPreference = 'Stop'
if (-not $PluginRoot) { $PluginRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PSScriptRoot 'codex-slot-fill.helpers.ps1')

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
    $oldRelease = $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH
    $context = $null
    try {
        $null = New-Item -ItemType Directory -Path $repository -Force
        $env:CLAUDE_FACTORY_HOME = Join-Path $fixture 'runtime'
        $env:CLAUDE_FACTORY_TEST_CODEX_LOG = Join-Path $fixture 'codex.tsv'
        $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH = Join-Path $fixture 'release'
        if ($InjectInheritedPipe) {
            # Mutate only the disposable plugin, restoring the exact Windows
            # handle-inheritance defect this regression must detect.
            $fixturePlugin = Join-Path $fixture 'plugin'
            $null = New-Item -ItemType Directory -Path $fixturePlugin
            foreach ($item in @('scripts', 'resources', 'config.default.json')) {
                Copy-Item -LiteralPath (Join-Path $SourceRoot $item) -Destination $fixturePlugin -Recurse
            }
            $schedulerPath = Join-Path $fixturePlugin 'scripts\factory-scheduler.ps1'
            $schedulerText = [IO.File]::ReadAllText($schedulerPath)
            $pattern = '(?m)^(\s*)false,(\r?\n\s*CREATE_NO_WINDOW,)'
            if ([regex]::Matches($schedulerText, $pattern).Count -ne 1) { throw 'Inherited-pipe mutation point needs updating.' }
            [IO.File]::WriteAllText($schedulerPath, [regex]::Replace($schedulerText, $pattern, '${1}true,${2}'))
            $workerLauncherPath = Join-Path $fixturePlugin 'scripts\DetachedWorkerProcess.cs'
            $workerLauncher = [IO.File]::ReadAllText($workerLauncherPath)
            $workerCall = 'CreateProcess(application, command, IntPtr.Zero, IntPtr.Zero, false,'
            if (-not $workerLauncher.Contains($workerCall)) { throw 'Worker inheritance mutation point needs updating.' }
            [IO.File]::WriteAllText($workerLauncherPath, $workerLauncher.Replace($workerCall, $workerCall.Replace('false,', 'true,')))
            $SourceRoot = $fixturePlugin
        }
        foreach ($compilerInput in @(@{source='FakeClaude.cs';output=$fakeClaude}, @{source='FakeCodex.cs';output=$fakeCodex})) {
            $compile = "Add-Type -Path '" + (Join-Path $PSScriptRoot $compilerInput.source).Replace("'", "''") + "' -OutputAssembly '" + $compilerInput.output.Replace("'", "''") + "' -OutputType ConsoleApplication"
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
        $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_MILLISECONDS=''
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $tick = (Invoke-CodexSlotFillProcess -Command powershell -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $SourceRoot 'scripts\factory-scheduler.ps1'),'-Action','tick','-Repository',$repository,'-ClaudeCommand',$fakeClaude,'-RuntimeHome',$env:CLAUDE_FACTORY_HOME)) | ConvertFrom-Json
        $timer.Stop()
        $recorded = Read-FactoryJson $context.statePath
        if (@($recorded.tasks).Count -ne 3) { throw 'Slot-fill fixture did not retain exactly three queued tasks.' }
        Assert-CodexSlotFillWorkers -Tick $tick -State $recorded -TaskIds @($recorded.tasks | ForEach-Object { [string]$_.id })
        [pscustomobject]@{ label=$Label; launched=[int]$tick.launchedCount; liveWorkers=@($recorded.tasks).Count; seconds=[Math]::Round($timer.Elapsed.TotalSeconds,3) }
    } finally {
        if ($env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH) { [IO.File]::WriteAllText($env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH, 'release') }
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
        $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH=$oldRelease
        $absolute = [IO.Path]::GetFullPath($fixture)
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\rock-scheduler-compat-'
        if ($absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $absolute)) { Remove-Item -LiteralPath $absolute -Recurse -Force }
    }
}
if ($InjectInheritedPipe) {
    try { Test-RockDisabledScheduler -SourceRoot $PluginRoot -Label inherited-pipe-mutant }
    catch {
        if ($_.Exception.Message -like 'SLOT_FILL_INHERITED_PIPE:*') {
            Write-Host 'Inherited-pipe mutation detected after launcher exit; no worker lifetime or 28-second threshold used.'
            return
        }
        throw
    }
    throw 'Slot-fill check failed to detect the inherited-pipe mutation.'
}
if ($BaselinePluginRoot) { Test-RockDisabledScheduler -SourceRoot $BaselinePluginRoot -Label baseline | ConvertTo-Json -Compress }
Test-RockDisabledScheduler -SourceRoot $PluginRoot -Label direct-rock-disabled | ConvertTo-Json -Compress
