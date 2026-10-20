param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\orchestrator-session.ps1')
. (Join-Path $PluginRoot 'scripts\codex-runtime.ps1')

function Assert-Label([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$separator = ' ' + [char]0x00B7 + ' '
$localId = 'local:20261020-113041-c068b7ec'
$asanaId = '1219601066590603'
$contexts = @(
    [pscustomobject]@{ repositoryRoot = 'C:\fixture\motivehr'; projectKey = 'motivehr-4893d8fb' },
    [pscustomobject]@{ repositoryRoot = 'C:\fixture\auditors'; projectKey = 'auditors-8ce0822d' }
)
foreach ($entry in @(
    @{ config = [pscustomobject]@{ orchestrator = @{ name = 'AwesomeHR' } }; context = $contexts[0]; label = 'AwesomeHR' },
    @{ config = [pscustomobject]@{ orchestrator = @{ name = 'Auditors' } }; context = $contexts[1]; label = 'Auditors' },
    @{ config = [pscustomobject]@{ orchestrator = @{} }; context = $contexts[0]; label = 'Motivehr-4893' },
    @{ config = [pscustomobject]@{ orchestrator = @{} }; context = $contexts[1]; label = 'Auditors-8ce0' }
)) {
    # Use PSCustomObjects as real deserialized config objects, not hashtables.
    $entry.config.orchestrator = [pscustomobject]$entry.config.orchestrator
    $alias = Get-FactoryOrchestratorAlias -Config $entry.config -Context $entry.context
    Assert-Label ($alias -ceq $entry.label) 'Factory owner resolution changed.'
    Assert-Label ((Get-FactoryOrchestratorDisplayName $alias) -ceq ('Factory ' + $entry.label)) 'Orchestrator name includes extra role words.'
    $local = Get-FactoryWorkerSessionName -TaskId $localId -Title 'Access sync' -Config $entry.config -Context $entry.context
    $asana = Get-FactoryWorkerSessionName -TaskId $asanaId -Title 'ZenHub connector' -Config $entry.config -Context $entry.context
    Assert-Label ($local -ceq ($entry.label + $separator + 'c068b7ec' + $separator + 'access-sync')) 'Local worker lost its factory or readable identity.'
    Assert-Label ($asana -ceq ($entry.label + $separator + $asanaId + $separator + 'zenhub-connector')) 'Asana worker lost its factory or full GID.'

    $oldName = 'Factory' + $separator + $entry.label
    $rows = @(
        [pscustomobject]@{ id = 'old'; name = $oldName; cwd = $entry.context.repositoryRoot },
        [pscustomobject]@{ id = 'old-numbered'; name = "$oldName (2)"; cwd = $entry.context.repositoryRoot },
        [pscustomobject]@{ id = 'new'; name = 'Factory ' + $entry.label; cwd = $entry.context.repositoryRoot },
        [pscustomobject]@{ id = 'foreign'; name = $oldName; cwd = 'C:\other' },
        [pscustomobject]@{ id = 'worker'; name = $local; cwd = $entry.context.repositoryRoot }
    )
    $matches = @(Get-FactoryMatchingOrchestratorRows -Rows $rows -RepositoryRoot $entry.context.repositoryRoot -Name ('Factory ' + $entry.label))
    Assert-Label ($matches.Count -eq 3 -and 'foreign' -notin @($matches.id) -and 'worker' -notin @($matches.id)) 'Old/new orchestrator families mixed workers or repositories.'
}

$longAlias = 'A' * 32
$longConfig = [pscustomobject]@{ orchestrator = [pscustomobject]@{ name = $longAlias } }
foreach ($taskId in @($localId, $asanaId, ('nonstandard-task-' * 10))) {
    $name = Get-FactoryWorkerSessionName -TaskId $taskId -Title ('Long task title ' * 20) -Config $longConfig -Context $contexts[0]
    Assert-Label ($name.Length -le 64 -and $name.StartsWith($longAlias + $separator)) 'Name cap truncated the factory owner.'
    if ($taskId -eq $asanaId) { Assert-Label ($name.Contains($asanaId)) 'A long alias shortened the Asana identity unnecessarily.' }
    if ($taskId -eq $localId) { Assert-Label ($name.Contains('c068b7ec')) 'A long alias shortened the local identity.' }
}
$unicodeTitle = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('0JjRgdC/0YDQsNCy0LjRgtGMINGN0LrRgdC/0L7RgNGCINC/0YDQvtGE0LjQu9GP'))
$unicodeName = Get-FactoryWorkerSessionName -TaskId $localId -Title $unicodeTitle -Config ([pscustomobject]@{ orchestrator = [pscustomobject]@{ name = 'AwesomeHR' } }) -Context $contexts[0]
Assert-Label ($unicodeName.Contains($unicodeTitle.Split(' ')[0].ToLowerInvariant())) 'Project labels discarded Unicode titles.'

# Exercise the real detached launcher and native name API with a fake Codex
# executable and isolated Git/runtime directories. No real agents are started.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-session-labels-' + [Guid]::NewGuid().ToString('N'))
$savedRuntime = $env:CLAUDE_FACTORY_HOME
$savedLocation = Get-Location
try {
    $repository = Join-Path $fixtureRoot 'repository'
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    $env:CLAUDE_FACTORY_HOME = Join-Path $fixtureRoot 'runtime'
    & git init --quiet $repository
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize name fixture.' }
    $null = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize
    $fakeCodex = Join-Path $fixtureRoot 'fake-codex.exe'
    $compile = "Add-Type -Path '" + (Join-Path $PluginRoot 'tests\FakeCodex.cs').Replace("'", "''") +
        "' -OutputAssembly '" + $fakeCodex.Replace("'", "''") + "' -OutputType ConsoleApplication"
    & powershell -NoProfile -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compile)))
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile fake Codex for names.' }
    $promptPath = Join-Path $fixtureRoot 'prompt.txt'
    [IO.File]::WriteAllText($promptPath, 'FACTORY_TASK {"taskId":"labels-fixture"}', $script:FactoryUtf8NoBom)
    $logPath = Join-Path $fixtureRoot 'requests.tsv'
    foreach ($scenario in @('awesomehr', 'auditors', 'name-failure', 'wrong-thread', 'cwd-release')) {
        $nativeName = if ($scenario -eq 'awesomehr') { 'AwesomeHR' + $separator + 'c068b7ec' + $separator + 'access-sync' } else { 'Auditors' + $separator + 'abcd1234' + $separator + 'audit' }
        $threadId = [Guid]::NewGuid().ToString()
        $workerEnvironment = @{
            CLAUDE_FACTORY_HOME = $env:CLAUDE_FACTORY_HOME
            CLAUDE_FACTORY_TASK_ID = ''
            CLAUDE_FACTORY_TEST_CODEX_THREAD_ID = $threadId
            CLAUDE_FACTORY_TEST_CODEX_LOG = $logPath
            CLAUDE_FACTORY_TEST_CODEX_APP_SERVER_FAIL_METHOD = $(if ($scenario -eq 'name-failure') { 'thread/name/set' } else { '' })
            CLAUDE_FACTORY_TEST_CODEX_READ_THREAD_ID = $(if ($scenario -eq 'wrong-thread') { [Guid]::NewGuid().ToString() } else { '' })
            CLAUDE_FACTORY_TEST_CODEX_NAME_DELAY_MS = $(if ($scenario -eq 'cwd-release') { '2000' } else { '' })
        }
        $workerRepository = $repository
        if ($scenario -eq 'cwd-release') {
            $workerRepository = Join-Path $fixtureRoot 'removed-worker'
            & git init --quiet $workerRepository
            $null = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $workerRepository -Initialize
        }
        $worker = Start-FactoryCodexWorkerProcess -CodexCommand $fakeCodex -PluginRoot $PluginRoot -Worktree $workerRepository `
            -PromptPath $promptPath -ArtifactPrefix (Join-Path $fixtureRoot $scenario) -SessionName $nativeName `
            -Capabilities ([pscustomobject]@{ supported = $true; version = 'fake' }) -Environment $workerEnvironment
        if ($scenario -eq 'cwd-release') {
            $nameDeadline = [DateTime]::UtcNow.AddSeconds(10)
            do {
                $nameStarted = Test-Path -LiteralPath $logPath
                if ($nameStarted) { $nameStarted = @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Where-Object { $_.Contains('thread/name/set') -and $_.Contains($threadId) }).Count -gt 0 }
                if ($nameStarted) { break }
                Start-Sleep -Milliseconds 25
            } while ([DateTime]::UtcNow -lt $nameDeadline)
            Assert-Label $nameStarted 'Native name request was not observed before the cleanup probe.'
            $resolvedWorker = [IO.Path]::GetFullPath($workerRepository)
            Assert-Label ($resolvedWorker -eq (Join-Path $fixtureRoot 'removed-worker')) 'Unsafe worker cleanup probe path.'
            Remove-Item -LiteralPath $resolvedWorker -Recurse -Force
            Assert-Label (-not (Test-Path -LiteralPath $resolvedWorker)) 'Naming held a completed worker worktree open.'
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            $nameStatus = if (Test-Path -LiteralPath $worker.nameStatusPath) { Read-FactoryJson $worker.nameStatusPath } else { $null }
            if ($null -ne $nameStatus -and $nameStatus.status -in @('named', 'failed')) { break }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert-Label ($null -ne $nameStatus) 'Detached Codex naming produced no status.'
        $expectedStatus = if ($scenario -in @('name-failure', 'wrong-thread')) { 'failed' } else { 'named' }
        Assert-Label ($nameStatus.status -eq $expectedStatus) "Unexpected native naming outcome: $($nameStatus | ConvertTo-Json -Compress)"
        Assert-Label ($worker.name -ceq $nativeName) 'Codex Factory metadata lost the visible owner label.'
        $snapshot = Get-FactoryCodexSessionSnapshot -Session $worker
        Assert-Label ($snapshot.state -eq 'done' -and $snapshot.sessionId -eq $threadId) 'Native naming altered the worker result or UUID.'
        Assert-Label (($expectedStatus -eq 'failed') -eq [bool]$snapshot.nameWarning) 'Native naming failure was hidden or leaked into the worker result.'
    }
    $requests = @(Get-Content -LiteralPath $logPath -Encoding UTF8 | Where-Object { $_.StartsWith("app-server-request`t") } | ForEach-Object { $_.Substring("app-server-request`t".Length) | ConvertFrom-Json })
    $names = @($requests | Where-Object { $_.method -eq 'thread/name/set' })
    Assert-Label ($names.Count -eq 4 -and $names[0].params.name.StartsWith('AwesomeHR') -and $names[1].params.name.StartsWith('Auditors')) 'Codex native titles did not distinguish factories.'
    Assert-Label (@($requests | Where-Object { $_.method -in @('thread/start', 'turn/start', 'thread/archive') }).Count -eq 0) 'Naming started a turn or changed session lifecycle.'
} finally {
    Set-Location $savedLocation
    $env:CLAUDE_FACTORY_HOME = $savedRuntime
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') -or (Split-Path -Leaf $resolved) -notlike 'factory-session-labels-*') { throw 'Unsafe name fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}

# Mixed legacy/current rows, a reused task ID in a different factory, and
# interactive rows must remain safe when a task closes after a rename.
$script:labelRemoved = New-Object Collections.Generic.List[string]
$script:labelStopped = New-Object Collections.Generic.List[string]
$script:labelRows = @(
    [pscustomobject]@{ id = 'legacy'; kind = 'background'; name = 'factory-1219601066590603-old'; cwd = 'C:\fixture\worker'; state = 'done' },
    [pscustomobject]@{ id = 'current'; kind = 'background'; name = 'AwesomeHR' + $separator + $asanaId + $separator + 'sync'; cwd = 'C:\fixture\worker'; state = 'working' },
    [pscustomobject]@{ id = 'recorded'; sessionId = 'recorded-uuid'; kind = 'background'; name = 'Renamed manually'; state = 'done' },
    [pscustomobject]@{ id = 'previous-attempt'; kind = 'background'; name = 'factory-1219601066590603-old'; cwd = 'C:\fixture\worker-1219601066590603-a1'; state = 'done' },
    [pscustomobject]@{ id = 'foreign'; kind = 'background'; name = 'factory-1219601066590603-old'; cwd = 'C:\auditors\worker'; state = 'working' },
    [pscustomobject]@{ id = 'foreign-current'; kind = 'background'; name = 'AwesomeHR' + $separator + $asanaId + $separator + 'sync'; cwd = 'C:\auditors\worker'; state = 'working' },
    [pscustomobject]@{ id = 'foreign-previous'; kind = 'background'; name = 'factory-1219601066590603-old'; cwd = 'C:\auditors\worker-1219601066590603-a1'; state = 'working' },
    [pscustomobject]@{ id = 'orchestrator'; kind = 'background'; name = 'Factory AwesomeHR'; cwd = 'C:\fixture\worker'; state = 'working' },
    [pscustomobject]@{ id = 'old-orchestrator'; kind = 'background'; name = 'Factory' + $separator + 'AwesomeHR'; cwd = 'C:\fixture\worker'; state = 'working' },
    [pscustomobject]@{ kind = 'interactive'; name = 'User chat'; cwd = 'C:\fixture\worker' }
)
function Get-FactoryClaudeAgentRows { param($ClaudeCommand) return $script:labelRows }
function Stop-FactoryClaudeSessionAndWait { param($ClaudeCommand, $BackgroundId) $script:labelStopped.Add($BackgroundId) }
function Remove-FactoryAgentSessionRow { param($ClaudeCommand, $BackgroundId) $script:labelRemoved.Add($BackgroundId); return [pscustomobject]@{ removed = $true; alreadyGone = $false } }
$closed = Remove-FactoryTaskAgentSessions -ClaudeCommand 'unused-fake' -TaskId $asanaId -Worktree 'C:\fixture\worker' -Session ([pscustomobject]@{ id = 'recorded'; sessionId = 'recorded-uuid' })
Assert-Label (@(Compare-Object @('legacy', 'current', 'recorded', 'previous-attempt') @($closed.removedAgentSessions)).Count -eq 0) 'Cleanup crossed a factory boundary or lost legacy/renamed rows.'
Assert-Label ($script:labelStopped.Count -eq 1 -and $script:labelStopped[0] -eq 'current') 'Cleanup stopped another factory or an orchestrator.'

Write-Host 'Factory session labels passed (mixed owners, legacy rows, native Codex titles, failure isolation).'
