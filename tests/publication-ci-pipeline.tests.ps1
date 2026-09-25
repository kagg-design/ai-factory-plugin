param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts/factory-common.ps1')
. (Join-Path $PluginRoot 'scripts/publication-ci.ps1')
$pipelineTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-ci-pipeline-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $pipelineTestRoot 'repository'
$remote = Join-Path $pipelineTestRoot 'remote.git'
$previousRuntime = $env:CLAUDE_FACTORY_HOME
$context = $null
$null = New-Item -ItemType Directory -Path $repository -Force
$env:CLAUDE_FACTORY_HOME = Join-Path $pipelineTestRoot 'runtime'
$fakeClaude = Join-Path $pipelineTestRoot 'claude-fake.exe'
function Assert-PipelineCi { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Invoke-CiGit { param([string]$Directory, [string[]]$Arguments)
    $run = Invoke-FactoryNativeProcess -Command git -Arguments (@('-C', $Directory) + $Arguments)
    if ($run.exitCode -ne 0) { throw $run.output }; return $run.stdout
}
function Invoke-CiScript { param([string]$Name, [string[]]$Arguments = @())
    $run = Invoke-FactoryNativeProcess -Command powershell -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PluginRoot "scripts/$Name"), '-Repository', $repository) + $Arguments)
    if ($run.exitCode -ne 0) { throw "$Name failed: $($run.output)" }
    return $run.stdout | ConvertFrom-Json
}
function New-CiApprovedTask { param([string]$Id, [string[]]$Checks = @('git diff --check'))
    $branch = "factory-worker/$Id"
    $worktree = Join-Path $context.worktreeRoot $Id
    $null = Invoke-CiGit $repository @('fetch', 'origin', 'develop')
    $null = Invoke-CiGit $repository @('worktree', 'add', '-b', $branch, $worktree, 'origin/develop')
    [IO.File]::WriteAllText((Join-Path $worktree "$Id.txt"), "Regression fixture $Id`n")
    $null = Invoke-CiGit $worktree @('add', '.')
    $null = Invoke-CiGit $worktree @('commit', '-m', "fix: $Id")
    $sha = Invoke-CiGit $worktree @('rev-parse', 'HEAD')
    $now = Get-FactoryUtcTimestamp
    $task = [pscustomobject]@{
        id = $Id; title = "CI pipeline $Id"; url = $null; source = $null; brief = 'Synthetic publication'
        status = 'awaiting-review'; startMode = 'auto'; attempts = 1; agentId = $null; backgroundSession = $null
        branch = $branch; worktree = $worktree; commit = $sha; review = $null; approval = $null; plan = $null
        workerResult = [pscustomobject]@{ status = 'completed'; commit = $sha; branch = $branch; worktree = $worktree
            tests = @([pscustomobject]@{ command = 'git diff --check'; status = 'passed'; summary = 'Fixture' }); notes = 'Targeted coverage.' }
        error = $null; createdAt = $now; updatedAt = $now
    }
    $mutex = Enter-FactoryMutex $context.projectKey
    try {
        $state = Read-FactoryJson $context.statePath
        $state.tasks = @($state.tasks) + @($task)
        Write-FactoryJsonAtomic $context.statePath $state
    } finally { Exit-FactoryMutex $mutex }
    $reviewPath = Join-Path $context.sessionsPath "$Id.review.json"
    Write-FactoryJsonAtomic $reviewPath ([pscustomobject]@{ commit = $sha; verdict = 'approved'; summary = 'Synthetic reviewed change'
        riskNotes = @(); integrationTestCommands = $Checks; releaseTestCommands = @() })
    $null = Invoke-CiScript 'record-review.ps1' @('-TaskId', $Id, '-ReviewPath', $reviewPath)
    $null = Invoke-CiScript 'task-action.ps1' @('-TaskId', $Id, '-Action', 'go', '-ClaudeCommand', $fakeClaude)
    return $task
}
function Save-PipelineCi { param($Journal)
    # Freeze the synthetic poll clock so this fixture never calls real GitHub.
    foreach ($entry in $Journal.entries) { $entry.lastPollAt = [DateTime]::UtcNow.AddDays(1).ToString('o') }
    $mutex = Enter-FactoryMutex "$($context.projectKey)-ci"
    try { Write-FactoryJsonAtomic (Get-FactoryCiPath $context) $Journal }
    finally { Exit-FactoryMutex $mutex }
}
try {
    Add-Type -Path (Join-Path $PluginRoot 'tests/FakeClaude.cs') -OutputAssembly $fakeClaude -OutputType ConsoleApplication
    $null = Invoke-CiGit $repository @('init', '-b', 'develop')
    $null = Invoke-CiGit $repository @('config', 'user.name', 'CI fixture')
    $null = Invoke-CiGit $repository @('config', 'user.email', 'ci@example.test')
    $null = Invoke-CiGit $repository @('config', 'commit.gpgsign', 'false')
    $null = Invoke-CiGit $repository @('config', 'core.hooksPath', (Join-Path $pipelineTestRoot 'no-hooks'))
    [IO.File]::WriteAllText((Join-Path $repository 'README.md'), "CI pipeline fixture`n")
    $null = Invoke-CiGit $repository @('add', '.')
    $null = Invoke-CiGit $repository @('commit', '-m', 'initial')
    $null = Invoke-CiGit $pipelineTestRoot @('init', '--bare', $remote)
    $null = Invoke-CiGit $repository @('remote', 'add', 'origin', $remote)
    $null = Invoke-CiGit $repository @('push', '-u', 'origin', 'develop')
    $context = Invoke-CiScript 'project-context.ps1' @('-Initialize')
    $config = Read-FactoryJson $context.configPath
    $config.productionBranch = ''; $config.integrationTestCommands = @('git diff --check')
    $config.nativeScheduler.enabled = $false
    $config.testLease.heartbeatSeconds = 1
    Write-FactoryJsonAtomic $context.configPath $config

    $task = New-CiApprovedTask 'ci-first'
    Register-FactoryCiPublication -Context $context -Task $task -Slug fixture/project -Branch develop -Sha ('a' * 40)
    Save-PipelineCi (Read-FactoryCiJournal $context)
    $result = Invoke-CiScript 'integrate-task.ps1' @('-TaskId', $task.id, '-ClaudeCommand', $fakeClaude)
    Assert-PipelineCi ($result.status -eq 'done') 'Pending CI prevented native local checks/push/cleanup.'
    Assert-PipelineCi ((Read-FactoryCiJournal $context).entries.Count -eq 1) 'Cleanup deleted CI history.'
    $lease = Invoke-CiScript 'test-lease.ps1' @('-Action', 'status')
    Assert-PipelineCi ($null -eq $lease.holder) 'Pending CI retained the publication test lease.'

    $task = New-CiApprovedTask 'ci-second'
    $journal = Read-FactoryCiJournal $context
    $entry = $journal.entries[0]
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @([pscustomobject]@{
        id = 501; run_attempt = 1; name = 'CI'; head_sha = $entry.sha; head_branch = 'develop'; event = 'push'
        status = 'completed'; conclusion = 'failure'
    }) })
    Save-PipelineCi $journal
    $before = Invoke-CiGit $remote @('rev-parse', 'refs/heads/develop')
    $result = Invoke-CiScript 'integrate-task.ps1' @('-TaskId', $task.id, '-ClaudeCommand', $fakeClaude)
    Assert-PipelineCi ($result.status -eq 'ci-blocked') 'Known failure did not block native publication.'
    Assert-PipelineCi ((Invoke-CiGit $remote @('rev-parse', 'refs/heads/develop')) -eq $before) 'CI-blocked task pushed anyway.'
    $savedTask = Get-FactoryTask -State (Read-FactoryJson $context.statePath) -TaskId $task.id
    Assert-PipelineCi ($savedTask.status -eq 'approved' -and $null -ne $savedTask.approval) 'CI gate discarded approval.'
    $status = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile', '-File', (Join-Path $PluginRoot 'factory.ps1'), 'status', '-Repository', $repository, '-NoReconcile', '-ClaudeCommand', $fakeClaude)
    Assert-PipelineCi ($status.exitCode -eq 0 -and $status.stdout.Contains('PUBLICATIONS BLOCKED') -and $status.stdout.Contains('actions/runs/501')) "Status lost CI evidence: $($status.output)"
    $ack = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile', '-File', (Join-Path $PluginRoot 'factory.ps1'),
        'ci', 'acknowledge', $entry.sha, 'Operator authorizes repair publication.', '-Repository', $repository)
    Assert-PipelineCi ($ack.exitCode -eq 0 -and $ack.stdout.Contains('operator acknowledged; not green')) "Native acknowledgement failed: $($ack.output)"
    $result = Invoke-CiScript 'integrate-task.ps1' @('-TaskId', $task.id, '-ClaudeCommand', $fakeClaude)
    Assert-PipelineCi ($result.status -eq 'done') 'Acknowledged CI failure prevented the repair publication.'
    Assert-PipelineCi ((Invoke-CiGit $remote @('rev-parse', 'refs/heads/develop')) -ne $before) 'Repair was not published.'
    # CI goes red while local checks are running: the pre-push gate must catch
    # it, preserve approval and release the lane without changing the remote.
    $raceJournalPath = Join-Path $pipelineTestRoot 'red-during-checks.json'
    $journal = Read-FactoryCiJournal $context
    $journal.entries[0].failures[0].attempt = 2
    $journal.entries[0].failures[0].key = '501/2'
    Write-FactoryJsonAtomic $raceJournalPath $journal
    $commonLiteral = (Join-Path $PluginRoot 'scripts/factory-common.ps1').Replace("'", "''")
    $sourceLiteral = $raceJournalPath.Replace("'", "''")
    $targetLiteral = (Get-FactoryCiPath $context).Replace("'", "''")
    $raceCheck = ". '$commonLiteral'; `$m = Enter-FactoryMutex '$($context.projectKey)-ci'; try { Write-FactoryJsonAtomic '$targetLiteral' (Read-FactoryJson '$sourceLiteral') } finally { Exit-FactoryMutex `$m }; git diff --check"
    $task = New-CiApprovedTask 'ci-during-checks' @($raceCheck)
    $before = Invoke-CiGit $remote @('rev-parse', 'refs/heads/develop')
    $result = Invoke-CiScript 'integrate-task.ps1' @('-TaskId', $task.id, '-ClaudeCommand', $fakeClaude)
    Assert-PipelineCi ($result.status -eq 'ci-blocked') 'A CI failure observed during local checks was ignored.'
    Assert-PipelineCi ((Invoke-CiGit $remote @('rev-parse', 'refs/heads/develop')) -eq $before) 'Pre-push gate allowed a known-red publication.'
    $savedTask = Get-FactoryTask -State (Read-FactoryJson $context.statePath) -TaskId $task.id
    Assert-PipelineCi ($savedTask.status -eq 'approved' -and $savedTask.integration.status -eq 'validated') 'Pre-push block lost the locally validated approval.'
    $lease = Invoke-CiScript 'test-lease.ps1' @('-Action', 'status')
    Assert-PipelineCi ($null -eq $lease.holder) 'Pre-push CI block retained the test lease.'
} finally {
    if ($null -eq $previousRuntime) { Remove-Item Env:CLAUDE_FACTORY_HOME -ErrorAction SilentlyContinue }
    else { $env:CLAUDE_FACTORY_HOME = $previousRuntime }
    $resolved = [IO.Path]::GetFullPath($pipelineTestRoot)
    if ((Split-Path $resolved -Leaf) -notlike 'factory-ci-pipeline-*' -or
        -not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected pipeline fixture cleanup path.'
    }
    # A released test-lease heartbeat can briefly retain its working directory.
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try { if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }; break }
        catch { if ($attempt -eq 39) { throw }; Start-Sleep -Milliseconds 250 }
    }
}
Write-Output 'Publication CI native pipeline regressions passed (pending -> publish; red -> block; acknowledgement -> repair; pre-push race).'
