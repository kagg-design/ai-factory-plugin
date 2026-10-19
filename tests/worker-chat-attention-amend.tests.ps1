param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\worker-event.ps1')
. (Join-Path $PluginRoot 'scripts\attention-state.ps1')
function Assert-Chat { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-chat-attention-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixtureRoot 'repository'
$runtime = Join-Path $fixtureRoot 'runtime'
$savedEnvironment = @{}
foreach ($name in @('CLAUDE_FACTORY_HOME', 'CLAUDE_FACTORY_CLAUDE_COMMAND', 'CLAUDE_FACTORY_REAL_GIT', 'CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE', 'CLAUDE_FACTORY_TEST_AGENT_CWD', 'CLAUDE_FACTORY_TEST_AGENT_STATUS', 'CLAUDE_FACTORY_TEST_NO_AGENTS', 'CLAUDE_FACTORY_TEST_RESUME_STATE_PATH', 'CLAUDE_FACTORY_TEST_RESUME_STATE_CAPTURE')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
function Invoke-ChatScript {
    param([string]$Name, [string[]]$Arguments = @())
    return Invoke-FactoryNativeProcess -Command powershell -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PluginRoot "scripts\$Name")) + $Arguments)
}
function Invoke-ChatHook {
    param([string]$Name, $Payload, [string[]]$Arguments = @())
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Command powershell).Source
    $start.Arguments = (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PluginRoot "scripts\$Name")) + $Arguments | ForEach-Object { ConvertTo-FactoryWindowsArgument $_ }) -join ' '
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process; $process.StartInfo = $start
    try {
        $null = $process.Start()
        $process.StandardInput.Write(($Payload | ConvertTo-Json -Depth 20 -Compress)); $process.StandardInput.Close()
        $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw "Hook fixture '$Name/$($Payload.hook_event_name)' exceeded its deadline." }
        return [pscustomobject]@{ exitCode = $process.ExitCode; stdout = $outTask.Result; stderr = $errTask.Result }
    } finally { $process.Dispose() }
}
function Save-ChatTask {
    param($Task)
    $stateMutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    try {
        $state = Read-FactoryJson -Path $context.statePath
        $state.tasks = @($Task)
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    } finally { Exit-FactoryMutex -Mutex $stateMutex }
}
function New-ChatWaitingTask {
    Remove-Item -LiteralPath (Join-Path $eventDirectory "latest-result.json") -ErrorAction SilentlyContinue
    $task = [pscustomobject]@{
        id = 'chat-task'; title = 'Chat replies'; brief = 'Synthetic fixture'; startMode = 'interactive'
        status = 'awaiting-input'; attempts = 1; branch = 'factory-worker/chat-task'; worktree = $worktree
        commit = $null; workerResult = $null; plan = [pscustomobject]@{ taskId = 'chat-task'; plan = @('Implement') }
        approval = $null; review = $null; error = 'waiting'; holdReason = 'waiting'; pendingInstructions = $null
        planRecordedAt = $waitingAt; resultRecordedAt = $null; reworkRequestedAt = $null
        backgroundSession = [pscustomobject]@{
            runtime = 'claude'; id = 'test1234'; sessionId = $sessionId; name = 'factory-chat-task'; state = 'working'
            startedAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o'); transcriptPath = ''
        }
        createdAt = $waitingAt; updatedAt = $waitingAt
    }
    $plan = [pscustomobject]@{ taskId = $task.id; kind = 'plan'; sessionId = $sessionId; capturedAt = $waitingAt; payload = $task.plan; transcriptPath = ''; lastAssistantMessage = 'Plan' }
    Write-FactoryJsonAtomic -Path $latestPath -Value $plan
    Write-FactoryJsonAtomic -Path (Join-Path $eventDirectory 'latest-plan.json') -Value $plan
    return $task
}
try {
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    $env:CLAUDE_FACTORY_HOME = $runtime
    & git init -b develop $repository | Out-Null
    & git -C $repository config user.name 'Factory Fixture'
    & git -C $repository config user.email 'fixture@example.invalid'
    Set-Content -LiteralPath (Join-Path $repository 'base.txt') -Value 'base'
    & git -C $repository add .
    & git -C $repository commit -m base | Out-Null
    & git -C $repository commit --allow-empty -m 'Second development commit' | Out-Null
    $remote = Join-Path $fixtureRoot 'remote.git'
    & git init --bare $remote | Out-Null
    & git -C $repository remote add origin $remote
    & git -C $repository push origin develop | Out-Null
    $context = (Invoke-ChatScript 'project-context.ps1' @('-Repository',$repository,'-Initialize')).stdout | ConvertFrom-Json
    $config = Read-FactoryJson -Path $context.configPath
    $config.productionBranch = ''; $config.workerAgent = 'claude'
    Write-FactoryJsonAtomic -Path $context.configPath -Value $config
    $worktree = Join-Path $context.worktreeRoot 'chat-task'
    & git -C $repository worktree add -b factory-worker/chat-task $worktree develop | Out-Null
    Set-Content -LiteralPath (Join-Path $worktree 'change.txt') -Value 'task'
    & git -C $worktree add .
    & git -C $worktree commit -m task | Out-Null
    $originalCommit = (& git -C $worktree rev-parse HEAD).Trim()
    $parent = (& git -C $worktree rev-parse 'HEAD^').Trim()
    $fakeClaude = Join-Path $fixtureRoot 'claude-fixture.exe'
    $build = Join-Path $fixtureRoot 'build.ps1'
    Set-Content -LiteralPath $build -Value 'param($Source, $Destination) Add-Type -Path $Source -OutputAssembly $Destination -OutputType ConsoleApplication'
    $built = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile','-File',$build,(Join-Path $PSScriptRoot 'FakeClaude.cs'),$fakeClaude)
    Assert-Chat ($built.exitCode -eq 0) "Fake Claude failed to build: $($built.output)"
    $env:CLAUDE_FACTORY_CLAUDE_COMMAND = $fakeClaude
    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = $worktree
    $env:CLAUDE_FACTORY_TEST_AGENT_STATUS = 'working'
    $env:CLAUDE_FACTORY_TEST_NO_AGENTS = $null
    $registry = Join-Path $fixtureRoot 'sessions.tsv'
    $sessionId = '11111111-2222-4333-8444-555555555555'
    Set-Content -LiteralPath $registry -Value "launch`ttest1234`t$worktree`tfactory-chat-task`tworking`t$sessionId"
    $env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE = $registry
    $eventDirectory = Join-Path $context.eventsPath 'chat-task'
    New-Item -ItemType Directory -Path $eventDirectory -Force | Out-Null
    $latestPath = Join-Path $eventDirectory 'latest.json'
    $replyPath = Join-Path $eventDirectory 'latest-reply.json'
    $waitingAt = [DateTime]::UtcNow.AddMinutes(-2).ToString('o')
    $row = [pscustomobject]@{ id = 'test1234'; sessionId = $sessionId; state = 'working' }
    $task = New-ChatWaitingTask
    Save-ChatTask $task
    $payload = @{ session_id = $sessionId; cwd = $worktree; hook_event_name = 'UserPromptSubmit'; prompt = 'Begin implementation now.' }
    $hook = Invoke-ChatHook 'capture-worker-reply.ps1' $payload
    Assert-Chat ($hook.exitCode -eq 0 -and (Test-Path -LiteralPath $replyPath)) 'Reply hook did not capture the prompt.'
    $reply = Read-FactoryJson $replyPath
    Assert-Chat ($reply.kind -eq 'reply' -and $reply.promptSha256 -eq (Get-FactoryTextSha256 $payload.prompt)) 'Reply hash/identity was not preserved.'
    Assert-Chat ((Read-FactoryJson $latestPath).kind -eq 'plan') 'Reply overwrote latest Stop envelope.'
    $payload.prompt = 'FACTORY_PROMPT_FILE=C:\synthetic\prompt.md'
    $null = Invoke-ChatHook 'capture-worker-reply.ps1' $payload
    Assert-Chat ((Read-FactoryJson $replyPath).capturedAt -eq $reply.capturedAt) 'Launch pointer was captured as an operator reply.'

    foreach ($guard in @('old-session','early','held','validated','pending','asana','shape','rework','started','no-marker','syncing','review')) {
        $guarded = New-ChatWaitingTask
        $testReply = $reply | ConvertTo-Json | ConvertFrom-Json
        $testRow = $row
        switch ($guard) {
            'old-session' { $testReply.sessionId = 'old' }
            'early' { $testReply.capturedAt = $waitingAt }
            'held' { $guarded.status = 'held' }
            'validated' { $guarded.commit = $originalCommit; $guarded.workerResult = [pscustomobject]@{ commit = $originalCommit; status = 'completed' } }
            'pending' { $guarded.pendingInstructions = 'undelivered' }
            'asana' { Set-FactoryProperty $guarded 'asanaQuestion' ([pscustomobject]@{ text = 'Question' }) }
            'shape' { $testRow = [pscustomobject]@{ id = 'foreign'; sessionId = 'foreign'; name = 'factory-chat-task'; cwd = $worktree } }
            'rework' { $guarded.reworkRequestedAt = [DateTime]::UtcNow.AddMinutes(1).ToString('o') }
            'started' { $guarded.backgroundSession.startedAt = [DateTime]::UtcNow.AddMinutes(1).ToString('o') }
            'no-marker' { Write-FactoryJsonAtomic $latestPath ([pscustomobject]@{ kind = 'message'; sessionId = $sessionId; capturedAt = $waitingAt }) }
            'syncing' { $guarded.status = 'syncing' }
            'review' { $guarded.status = 'awaiting-review' }
        }
        Write-FactoryJsonAtomic $replyPath $testReply
        Assert-Chat (-not (Resume-FactoryTaskFromInSessionReply -Context $context -Task $guarded -SessionRow $testRow)) "Reply bypassed guard '$guard'."
    }
    $task = New-ChatWaitingTask; Save-ChatTask $task
    Write-FactoryJsonAtomic $replyPath $reply
    # No reconcile between the actual reply and sync prepare.
    $lease = (Invoke-ChatScript 'test-lease.ps1' @('-Repository',$repository,'-TaskId','chat-task','-Action','acquire','-Phase','verify','-OwnerPid',"$PID",'-NoHeartbeat')).stdout | ConvertFrom-Json
    try {
        $prepared = Invoke-ChatScript 'sync-task.ps1' @('-Repository',$repository,'-TaskId','chat-task','-LeaseToken',$lease.token)
        Assert-Chat ($prepared.exitCode -eq 0) "Immediate sync prepare refused the same-session reply: $($prepared.output)"
    } finally { $null = Invoke-ChatScript 'test-lease.ps1' @('-Repository',$repository,'-Action','release','-Token',$lease.token) }
    $task = (Read-FactoryJson $context.statePath).tasks[0]
    Assert-Chat ($task.status -eq 'running' -and $task.inSessionReply.fromStatus -eq 'awaiting-input' -and $null -eq $task.error -and $null -eq $task.holdReason -and $null -ne $task.plan) 'Reply promotion lost provenance or task artifacts.'
    $null = Publish-FactoryWorkerEvent -Context $context -Task $task -SessionId $sessionId -Worktree $worktree -Message 'Here is a conversational answer.'
    $run = Invoke-ChatScript 'reconcile-worker-sessions.ps1' @('-Repository',$repository,'-ClaudeCommand',$fakeClaude)
    Assert-Chat ($run.exitCode -eq 0) "Conversational Stop reconcile failed: $($run.output)"
    Assert-Chat ((Read-FactoryJson $context.statePath).tasks[0].status -eq 'awaiting-input') 'Conversational Stop did not return to input.'
    foreach ($kind in @('blocked-result','blocked-timeout','invalid-marker')) {
        $task = New-ChatWaitingTask
        if ($kind -eq 'invalid-marker') {
            $waiting = [pscustomobject]@{ kind = 'invalid-marker'; sessionId = $sessionId; capturedAt = $waitingAt }
        } else {
            $task.status = 'blocked'; $task.commit = $originalCommit
            $task.workerResult = [pscustomobject]@{ status = 'blocked'; blockingReason = 'test' }
            $waiting = [pscustomobject]@{ kind = 'result'; sessionId = $sessionId; capturedAt = $waitingAt; payload = $task.workerResult }
        }
        Write-FactoryJsonAtomic $latestPath $waiting
        Write-FactoryJsonAtomic (Join-Path $eventDirectory 'latest-result.json') $waiting
        if ($kind -eq 'blocked-timeout') { Set-FactoryProperty $task 'inSessionWaiting' ([pscustomobject]@{ sessionId = $sessionId; capturedAt = $waitingAt; kind = 'blocked-timeout' }) }
        Write-FactoryJsonAtomic $replyPath $reply
        Assert-Chat (Resume-FactoryTaskFromInSessionReply -Context $context -Task $task -SessionRow $row) "Eligible $kind did not resume."
        Assert-Chat ($task.status -eq 'running' -and $null -eq $task.workerResult -and ($kind -eq 'invalid-marker' -or $task.commit -eq $originalCommit)) 'Blocked promotion cleared the commit or kept a blocked result.'
    }
    # Reconcile uses the same shared boundary, including a delayed scheduler tick.
    $task = New-ChatWaitingTask; Save-ChatTask $task
    $run = Invoke-ChatScript 'reconcile-worker-sessions.ps1' @('-Repository',$repository,'-ClaudeCommand',$fakeClaude)
    Assert-Chat ($run.exitCode -eq 0 -and (Read-FactoryJson $context.statePath).tasks[0].status -eq 'running') "Reply reconciliation failed: $($run.output)"

    # Observe the real wrapper boundary before the fake interactive CLI returns.
    $fakeCodex = Join-Path $fixtureRoot 'codex-fixture.exe'
    $built = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile','-File',$build,(Join-Path $PSScriptRoot 'FakeCodex.cs'),$fakeCodex)
    Assert-Chat ($built.exitCode -eq 0) "Fake Codex failed to build: $($built.output)"
    $codexTask = New-ChatWaitingTask
    Set-FactoryProperty $codexTask 'testDatabase' $null
    $threadId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    $shimDirectory = Join-Path $fixtureRoot 'codex-bin'
    New-Item -ItemType Directory -Path $shimDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PluginRoot 'scripts\codex-git.cmd') -Destination (Join-Path $shimDirectory 'git.cmd')
    $codexTask.backgroundSession = [pscustomobject]@{
        runtime = 'codex'; id = 'codex-reply-fixture'; sessionId = $threadId; name = 'Codex reply fixture'; state = 'done'
        startedAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o'); processId = 0
        shimDirectory = $shimDirectory; transcriptPath = Join-Path $fixtureRoot 'codex.jsonl'
        lastMessagePath = Join-Path $fixtureRoot 'codex-last.txt'
    }
    foreach ($path in @($latestPath, (Join-Path $eventDirectory 'latest-plan.json'))) {
        $plan = Read-FactoryJson $path; $plan.sessionId = $threadId; Write-FactoryJsonAtomic $path $plan
    }
    $promptPath = Join-Path $context.sessionsPath 'codex-prompt.md'
    Set-Content -LiteralPath $promptPath -Value 'Synthetic Codex worker prompt'
    Write-FactoryJsonAtomic (Join-Path $context.sessionsPath 'chat-task.json') ([pscustomobject]@{ promptPath = $promptPath })
    Save-ChatTask $codexTask
    $env:CLAUDE_FACTORY_TEST_RESUME_STATE_PATH = $context.statePath
    $env:CLAUDE_FACTORY_TEST_RESUME_STATE_CAPTURE = Join-Path $fixtureRoot 'codex-resume-state.json'
    $resumed = Invoke-ChatScript 'resume-codex-worker.ps1' @('-Repository',$repository,'-TaskId','chat-task','-CodexCommand',$fakeCodex)
    Assert-Chat ($resumed.exitCode -eq 0) "Codex resume wrapper failed: $($resumed.output)"
    $beforeResume = (Read-FactoryJson $env:CLAUDE_FACTORY_TEST_RESUME_STATE_CAPTURE).tasks[0]
    Assert-Chat ($beforeResume.status -eq 'running' -and $beforeResume.inSessionReply.fromStatus -eq 'awaiting-input') 'Codex was opened before the waiting task was promoted.'
    Assert-Chat ((Read-FactoryJson $context.statePath).tasks[0].status -eq 'awaiting-input') 'A repeated Codex plan did not restore the input wait.'
    Assert-Chat ((Read-FactoryJson $replyPath).source -eq 'codex-resume') 'Codex resume did not persist its reply source.'
    $env:CLAUDE_FACTORY_TEST_RESUME_STATE_PATH = $savedEnvironment.CLAUDE_FACTORY_TEST_RESUME_STATE_PATH
    $env:CLAUDE_FACTORY_TEST_RESUME_STATE_CAPTURE = $savedEnvironment.CLAUDE_FACTORY_TEST_RESUME_STATE_CAPTURE
    $task = New-ChatWaitingTask

    # Sanctioned amend retains parent/branch and never writes commit into state.
    $task.status = 'running'; Save-ChatTask $task
    Add-Content -LiteralPath (Join-Path $worktree 'change.txt') -Value 'amended'
    & git -C $worktree add change.txt
    $amended = Invoke-ChatScript 'amend-task-commit.ps1' @('-Repository',$repository,'-TaskId','chat-task')
    Assert-Chat ($amended.exitCode -eq 0) "Sanctioned amend failed: $($amended.output)"
    $amend = $amended.stdout | ConvertFrom-Json
    Assert-Chat ($amend.oldCommit -eq $originalCommit -and $amend.commit -ne $originalCommit -and $amend.parent -eq $parent -and -not (& git -C $worktree status --porcelain)) 'Amend broke parent, SHA, or clean-tree postconditions.'
    Assert-Chat ($null -eq (Read-FactoryJson $context.statePath).tasks[0].commit) 'Amend wrote a commit into Factory state.'
    $invalidated = (Read-FactoryJson $context.statePath).tasks[0].resultInvalidatedAt
    Assert-Chat ([bool]$invalidated) 'Amend did not invalidate earlier result events.'
    $oldPayload = [pscustomobject]@{ taskId = 'chat-task'; status = 'completed'; branch = 'factory-worker/chat-task'; commit = $originalCommit; worktree = $worktree
        tests = @([pscustomobject]@{ command = 'git diff --check'; status = 'passed'; summary = 'Fixture' }) }
    $oldEvent = [pscustomobject]@{ sessionId = $sessionId; capturedAt = (ConvertTo-FactoryUtcDateTime $invalidated).AddSeconds(-1).ToString('o'); kind = 'result'; payload = $oldPayload }
    Write-FactoryJsonAtomic (Join-Path $eventDirectory 'latest-result.json') $oldEvent
    $null = Invoke-ChatScript 'reconcile-worker-sessions.ps1' @('-Repository',$repository,'-ClaudeCommand',$fakeClaude)
    $afterOld = (Read-FactoryJson $context.statePath).tasks[0]
    Assert-Chat ($afterOld.status -ne 'failed' -and $null -eq $afterOld.commit) 'An older result caused a HEAD mismatch after guarded amend.'
    $oldPayload.commit = $amend.commit
    $null = Publish-FactoryWorkerEvent -Context $context -Task $afterOld -SessionId $sessionId -Worktree $worktree -Message ("FACTORY_RESULT`n" + ($oldPayload | ConvertTo-Json -Depth 10))
    $null = Invoke-ChatScript 'reconcile-worker-sessions.ps1' @('-Repository',$repository,'-ClaudeCommand',$fakeClaude)
    $afterFinal = (Read-FactoryJson $context.statePath).tasks[0]
    Assert-Chat ($afterFinal.commit -eq $amend.commit -and $afterFinal.workerResult.commit -eq $amend.commit) 'The final amended HEAD was not recorded from a fresh result.'
    foreach ($guard in @('review','held','wrong-branch','outside','unstaged','untracked','cherry-pick','two-commits','merge-commit','development-head','detached','shim','empty','message-inside')) {
        $task = New-ChatWaitingTask; $task.status = 'running'
        $args = @('-Repository',$repository,'-TaskId','chat-task')
        switch ($guard) {
            'review' { $task.status = 'awaiting-review' }
            'held' { $task.status = 'held' }
            'wrong-branch' { $task.branch = 'develop' }
            'outside' { $task.worktree = $repository }
            'unstaged' { Add-Content -LiteralPath (Join-Path $worktree 'change.txt') -Value 'unstaged' }
            'untracked' { Set-Content -LiteralPath (Join-Path $worktree 'untracked.txt') -Value 'untracked' }
            'cherry-pick' { $pickPath = (& git -C $worktree rev-parse --path-format=absolute --git-path CHERRY_PICK_HEAD).Trim(); Set-Content -LiteralPath $pickPath -Value $amend.commit }
            'two-commits' { & git -C $worktree commit --allow-empty -m extra | Out-Null }
            'merge-commit' {
                $mergeCommit = (& git -C $worktree commit-tree 'HEAD^{tree}' -p HEAD -p $parent -m 'Synthetic merge').Trim()
                & git -C $worktree reset --hard $mergeCommit | Out-Null
            }
            'development-head' {
                & git -C $worktree reset --hard $parent | Out-Null
                Set-Content -LiteralPath (Join-Path $worktree 'change.txt') -Value 'Staged on the development base'
                & git -C $worktree add change.txt
            }
            'detached' { $null = Invoke-FactoryNativeProcess -Command git -Arguments @('-C',$worktree,'checkout','--detach','HEAD') }
            'shim' { $shim = Join-Path $fixtureRoot 'git.cmd'; Set-Content -LiteralPath $shim -Value '@echo git version shim'; $env:CLAUDE_FACTORY_REAL_GIT = $shim }
            'message-inside' { $args += @('-MessageFile',(Join-Path $worktree 'change.txt')) }
        }
        Save-ChatTask $task
        $refused = Invoke-ChatScript 'amend-task-commit.ps1' $args
        Assert-Chat ($refused.exitCode -ne 0) "Unsafe amend '$guard' was accepted."
        $env:CLAUDE_FACTORY_REAL_GIT = $savedEnvironment.CLAUDE_FACTORY_REAL_GIT
        if ($guard -eq 'unstaged') { & git -C $worktree restore change.txt }
        if ($guard -eq 'untracked') { Remove-Item -LiteralPath (Join-Path $worktree 'untracked.txt') }
        if ($guard -eq 'cherry-pick') { Remove-Item -LiteralPath $pickPath }
        if ($guard -in @('two-commits','merge-commit','development-head')) { & git -C $worktree reset --hard $amend.commit | Out-Null }
        if ($guard -eq 'detached') { $null = Invoke-FactoryNativeProcess -Command git -Arguments @('-C',$worktree,'switch','factory-worker/chat-task') }
    }
    $messageFile = Join-Path $fixtureRoot 'amend-message.txt'
    Set-Content -LiteralPath $messageFile -Value 'Synthetic message-only amendment'
    $messageOnly = Invoke-ChatScript 'amend-task-commit.ps1' @('-Repository',$repository,'-TaskId','chat-task','-MessageFile',$messageFile)
    Assert-Chat ($messageOnly.exitCode -eq 0) "Message-only amend failed: $($messageOnly.output)"
    $task = New-ChatWaitingTask; $task.status = 'running'; Save-ChatTask $task
    $completed = [pscustomobject]@{ taskId = $task.id; status = 'completed'; branch = $task.branch; worktree = $worktree; commit = (& git -C $worktree rev-parse HEAD).Trim(); tests = @(); notes = 'Synthetic completion'; blockingReason = '' }
    $null = Publish-FactoryWorkerEvent -Context $context -Task $task -SessionId $sessionId -Worktree $worktree -Message ("FACTORY_RESULT`n" + ($completed | ConvertTo-Json -Depth 10))
    $run = Invoke-ChatScript 'reconcile-worker-sessions.ps1' @('-Repository',$repository,'-ClaudeCommand',$fakeClaude)
    Assert-Chat ($run.exitCode -eq 0 -and (Read-FactoryJson $context.statePath).tasks[0].status -eq 'awaiting-review') "Same-session completion did not reach review: $($run.output)"

    # Claude delivery claims survive a crash; only a later Stop acknowledges.
    $task = New-ChatWaitingTask; $task.status = 'blocked'; $task.error = 'Synthetic blocker'; Save-ChatTask $task
    $orchestratorId = '33333333-2222-4333-8444-555555555555'
    Write-FactoryJsonAtomic (Join-Path $context.projectData 'orchestrator-session.json') ([pscustomobject]@{ sessionId = $orchestratorId })
    $scan = Invoke-ChatScript 'factory-scheduler.ps1' @('-Repository',$repository,'-Action','tick','-ClaudeCommand',$fakeClaude)
    Assert-Chat ($scan.exitCode -eq 0) "Claude scheduler tick failed: $($scan.output)"
    $attention = Read-FactoryJson $context.attentionPath
    Assert-Chat (@($attention.events | Where-Object kind -eq 'blocked').Count -eq 1) 'Claude tick did not journal the blocked edge without wait.'
    $input = @{ session_id = $orchestratorId; cwd = $repository; hook_event_name = 'SessionStart' }
    # SessionStart must survive arriving before the launcher saves its verified UUID.
    $identityPath = Join-Path $context.projectData 'orchestrator-session.json'
    Write-FactoryJsonAtomic $identityPath ([pscustomobject]@{ sessionId = 'previous-conversation' })
    $receiptPath = Join-Path $context.projectData 'orchestrator-launch.json'
    Write-FactoryJsonAtomic $receiptPath ([pscustomobject]@{ requestedSessionId = $orchestratorId })
    $updaterPath = Join-Path $fixtureRoot 'publish-identity.ps1'
    Set-Content -LiteralPath $updaterPath -Value 'param($Path,$SessionId) Start-Sleep -Seconds 4; [IO.File]::WriteAllText($Path, (ConvertTo-Json @{sessionId=$SessionId}))'
    $updaterArguments = @('-NoProfile','-File',$updaterPath,$identityPath,$orchestratorId) | ForEach-Object { ConvertTo-FactoryWindowsArgument $_ }
    $updater = Start-Process -FilePath (Get-Command powershell).Source -ArgumentList ($updaterArguments -join ' ') -WindowStyle Hidden -PassThru
    try {
        $wake = Invoke-ChatHook 'orchestrator-attention-hook.ps1' $input @('-ConsumerSeconds','1')
    } finally {
        $null = $updater.WaitForExit(10000); $updater.Dispose()
        Remove-Item -LiteralPath $receiptPath -ErrorAction SilentlyContinue
    }
    Assert-Chat ($wake.exitCode -eq 2 -and $wake.stdout.Contains('Synthetic blocker')) "Orchestrator did not receive the batch: $($wake.stderr) $($wake.stdout)"
    $attention = Read-FactoryJson $context.attentionPath
    Assert-Chat ($attention.orchestratorAcknowledgedRevision -gt 0 -and $attention.claudeClaim.status -eq 'delivered') 'Claim/cursor were not durable before waking.'
    $redelivery = Invoke-ChatHook 'orchestrator-attention-hook.ps1' $input @('-ConsumerSeconds','1')
    Assert-Chat ($redelivery.exitCode -eq 2 -and $redelivery.stdout.Contains('Redelivered: True')) 'Dead consumer claim was not redelivered on restart.'
    $input.hook_event_name = 'Stop'
    $input.stop_hook_active = $false
    $null = Invoke-ChatHook 'orchestrator-attention-hook.ps1' $input @('-ConsumerSeconds','1')
    Assert-Chat ((Read-FactoryJson $context.attentionPath).claudeClaim.status -eq 'delivered') 'An unrelated initial Stop acknowledged a queued rewake before its turn ran.'
    $input.stop_hook_active = $true
    $ack = Invoke-ChatHook 'orchestrator-attention-hook.ps1' $input @('-ConsumerSeconds','1')
    $attention = Read-FactoryJson $context.attentionPath
    Assert-Chat ($attention.claudeClaim.status -eq 'acknowledged' -and -not $ack.stdout.Contains('Synthetic blocker')) 'Stop did not acknowledge, or replayed an acknowledged claim.'
    $cursor = $attention.orchestratorAcknowledgedRevision
    $null = Invoke-ChatScript 'wait-factory.ps1' @('-Repository',$repository,'-TimeoutSeconds','1')
    Assert-Chat ((Read-FactoryJson $context.attentionPath).orchestratorAcknowledgedRevision -eq $cursor) 'Manual wait moved the orchestrator cursor.'
    foreach ($foreign in @($sessionId, 'foreign-session')) {
        $input.session_id = $foreign
        Assert-Chat ((Invoke-ChatHook 'orchestrator-attention-hook.ps1' $input @('-ConsumerSeconds','1')).exitCode -eq 0) 'Foreign/worker session acquired the consumer.'
    }
    $input.session_id = $orchestratorId
    $null = Update-FactoryAttentionRecord -Context $context -Mutator {
        param($record)
        $record.claudeConsumer = [pscustomobject]@{ pid = $PID; processStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); sessionId = $orchestratorId; token = 'existing'; heartbeatAt = Get-FactoryUtcTimestamp }
    }
    Assert-Chat ((Invoke-ChatHook 'orchestrator-attention-hook.ps1' $input @('-ConsumerSeconds','1')).exitCode -eq 0) 'Second consumer was allowed.'
    $staleConsumer = (Read-FactoryJson $context.attentionPath).claudeConsumer
    $staleConsumer.heartbeatAt = [DateTime]::UtcNow.AddMinutes(-2).ToString('o')
    Assert-Chat (-not (Test-FactoryClaudeAttentionConsumer $staleConsumer)) 'A stale orphan consumer retained its lease.'
    $staleConsumer.heartbeatAt = Get-FactoryUtcTimestamp
    Set-FactoryProperty $staleConsumer 'hostProcess' ([pscustomobject]@{ pid = 2147483647; processStartTimeUtc = Get-FactoryUtcTimestamp })
    Assert-Chat (-not (Test-FactoryClaudeAttentionConsumer $staleConsumer)) 'A child whose Claude host died retained its lease.'
    $null = Update-FactoryAttentionRecord -Context $context -Mutator {
        param($record)
        $record.claudeConsumer = $null
        $record.orchestratorAcknowledgedRevision = 0
        foreach ($edge in $record.events) { $edge.detectedAt = [DateTime]::UtcNow.AddMinutes(-2).ToString('o') }
    }
    $health = Get-FactoryClaudeAttentionHealth -Context $context -Config $config
    Assert-Chat ($health.needsAction) 'Dead consumer with old pending attention was silent.'
    $status = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile','-File',(Join-Path $PluginRoot 'factory.ps1'),'status','-Repository',$repository,'-NoReconcile')
    Assert-Chat ($status.stdout.Contains('ORCHESTRATOR ATTENTION') -and $status.stdout.Contains('NEEDS YOUR ACTION')) 'Status omitted the dead attention consumer.'
    $attention = New-FactoryAttentionState
    $attention.activeKeys = @('go','human','auto')
    $attention.events = @(
        [pscustomobject]@{ revision = 1; key = 'go'; kind = 'awaiting-approval'; aiActionable = $false; humanDecision = $true; includeInDefaultWait = $false },
        [pscustomobject]@{ revision = 2; key = 'human'; kind = 'awaiting-input'; aiActionable = $false; humanDecision = $true; includeInDefaultWait = $true },
        [pscustomobject]@{ revision = 3; key = 'auto'; kind = 'auto-go'; aiActionable = $true; humanDecision = $false; includeInDefaultWait = $false }
    )
    $deliverable = @(Get-FactoryClaudeDeliverableEvents $attention)
    Assert-Chat ($deliverable.Count -eq 2 -and @($deliverable | Where-Object kind -eq 'awaiting-approval').Count -eq 0) 'Human GO entered the Claude default delivery batch.'
    Write-Output 'Worker chat, Claude attention, and guarded amend regressions passed.'
} finally {
    foreach ($entry in $savedEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
