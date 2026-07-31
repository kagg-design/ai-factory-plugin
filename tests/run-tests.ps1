[CmdletBinding()]
param(
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $pluginRoot "scripts\factory-common.ps1")
$testRoot = Join-Path "C:\tmp" "claude-factory-plugin-tests-$([Guid]::NewGuid().ToString('N'))"
$repository = Join-Path $testRoot "repository"
$remote = Join-Path $testRoot "remote.git"
$runtime = Join-Path $testRoot "runtime"
$fakeClaude = Join-Path $testRoot "claude-fake.cmd"

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    $pluginManifest = Read-FactoryJson -Path (Join-Path $pluginRoot ".claude-plugin\plugin.json")
    Assert-Equal "factory" ([string]$pluginManifest.name) "Plugin namespace is not source-neutral."

    $bundleManifest = Read-FactoryJson -Path (Join-Path $pluginRoot "MANIFEST.json")
    Assert-Equal "/factory" ([string]$bundleManifest.command) "Public command is not unnamespaced."
    foreach ($relativeFile in @($bundleManifest.files)) {
        Assert-True (Test-Path -LiteralPath (Join-Path $pluginRoot $relativeFile)) "Manifest file is missing: $relativeFile"
    }

    $publicSkill = Get-Content -LiteralPath (Join-Path $pluginRoot "standalone\.claude\skills\factory\SKILL.md") -Raw
    Assert-True ($publicSkill -match '(?m)^name: factory\s*$') "The /factory standalone skill is missing or misnamed."
    Assert-True ($publicSkill.Contains("Skill(factory:tick)")) "The public skill does not reference the internal tick."
    Assert-True ($publicSkill.Contains("conversationLanguage")) "The public skill does not honor the configured conversation language."

    $launcherSource = Get-Content -LiteralPath (Join-Path $pluginRoot "start-factory.ps1") -Raw
    Assert-True ($launcherSource.Contains('[string]$Repository = (Get-Location).Path')) "Launcher does not default to the current directory."
    Assert-True ($launcherSource.Contains('[string]$Name = "Claude Factory Orchestrator"')) "Launcher does not use the orchestrator display name by default."
    Assert-True ($launcherSource.Contains('"--name", $Name')) "Launcher does not set the Claude session display name."
    Assert-True ($launcherSource.Contains('"--add-dir", $standaloneRoot')) "Launcher does not load the /factory standalone skill."

    $workerLauncherSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Raw
    Assert-True ($workerLauncherSource.Contains('"factory:worker"')) "Worker launcher uses the wrong plugin namespace."
    Assert-True (-not $workerLauncherSource.Contains('"--session-id"')) "Worker launcher still passes the unsupported background session ID."
    Assert-True ($workerLauncherSource.Contains("conversationLanguage = [string]`$config.conversationLanguage")) "Worker payload does not include the configured conversation language."

    $cleanupSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\cleanup-task.ps1") -Raw
    Assert-True ($cleanupSource.Contains("core.longpaths=true")) "Task cleanup does not enable Git long-path support."
    Assert-True ($publicSkill.Contains("cleanup <task-id>")) "The public skill does not expose per-task cleanup."

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    & git init --bare $remote 1> $null
    & git init $repository 1> $null
    & git -C $repository config user.email "factory-tests@example.test"
    & git -C $repository config user.name "Factory Tests"
    [IO.File]::WriteAllText(
        (Join-Path $repository "README.md"),
        "initial`n",
        (New-Object Text.UTF8Encoding($false))
    )
    & git -C $repository add README.md
    & git -C $repository commit -m "initial" 1> $null
    & git -C $repository branch -M develop
    & git -C $repository branch master
    & git -C $repository remote add origin $remote
    & git -C $repository push -u origin develop 1> $null
    & git -C $repository push -u origin master 1> $null

    $fakeSessionId = "11111111-2222-4333-8444-555555555555"
    $ansiEscape = [char]27
    $fakeSource = @"
@echo off
setlocal EnableDelayedExpansion
if "%~1"=="--version" (
  echo 2.1.218 ^(Claude Code^)
  exit /b 0
)
if "%~1"=="agents" (
  if "%CLAUDE_FACTORY_TEST_NO_AGENTS%"=="1" (
    echo []
    exit /b 0
  )
  set "JSON_CWD=%CLAUDE_FACTORY_TEST_AGENT_CWD:\=\\%"
  echo [{"sessionId":"$fakeSessionId","status":"working","kind":"background","name":"factory-test-task-test-task","cwd":"!JSON_CWD!","startedAt":1}]
  exit /b 0
)
if "%~1"=="mcp" (
  echo asana: connected
  exit /b 0
)
echo Warning: benign background-launch warning 1>&2
echo backgrounded - $($ansiEscape)[36mtest1234$($ansiEscape)[0m - factory-test-task
echo claude attach test1234
exit /b 0
"@
    [IO.File]::WriteAllText(
        $fakeClaude,
        $fakeSource,
        (New-Object Text.ASCIIEncoding)
    )

    $env:CLAUDE_FACTORY_HOME = $runtime
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository -Initialize) |
        ConvertFrom-Json
    Assert-Equal 3 ((Read-FactoryJson -Path $context.configPath).version) "Config migration failed."
    Assert-Equal 3 ((Read-FactoryJson -Path $context.statePath).version) "State migration failed."

    $legacyConfig = Read-FactoryJson -Path $context.configPath
    $legacyConfig.version = 2
    $legacyConfig.autoPushDevelopment = $false
    $legacyConfig.PSObject.Properties.Remove("maxConcurrency")
    $legacyConfig.PSObject.Properties.Remove("defaultStartMode")
    $legacyConfig.PSObject.Properties.Remove("conversationLanguage")
    Write-FactoryJsonAtomic -Path $context.configPath -Value $legacyConfig
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository -Initialize) | ConvertFrom-Json
    $migratedConfig = Read-FactoryJson -Path $context.configPath
    Assert-Equal 3 ([int]$migratedConfig.version) "Legacy config version was not migrated."
    Assert-Equal 20 ([int]$migratedConfig.maxConcurrency) "Missing config defaults were not added."
    Assert-Equal "English" ([string]$migratedConfig.conversationLanguage) "Conversation language default was not migrated."
    Assert-Equal $false ([bool]$migratedConfig.autoPushDevelopment) "Migration overwrote a repository-specific config value."

    $now = [DateTime]::UtcNow.ToString("o")
    $state = [pscustomobject]@{
        version = 3
        active = $true
        paused = $false
        cronJobId = $null
        createdAt = $now
        updatedAt = $now
        resolvedCommands = [pscustomobject]@{ integration = @(); release = @() }
        tasks = @(
            [pscustomobject]@{
                id = "test-task"
                url = "https://app.asana.com/0/0/test-task"
                title = "Test task"
                brief = "Change README."
                acceptanceCriteria = @("README changed")
                sourceNotes = @()
                startMode = "auto"
                status = "queued"
                attempts = 0
                agentId = $null
                backgroundSession = $null
                branch = $null
                commit = $null
                worktree = $null
                plan = $null
                workerResult = $null
                review = $null
                approval = $null
                integration = $null
                production = $null
                reworkRequestedAt = $null
                pendingInstructions = $null
                error = $null
                planRecordedAt = $null
                resultRecordedAt = $null
                createdAt = $now
                updatedAt = $now
            }
        )
    }
    $state.version = 2
    foreach ($propertyName in @("startMode", "backgroundSession", "plan", "review", "approval", "reworkRequestedAt", "planRecordedAt", "resultRecordedAt", "pendingInstructions")) {
        $state.tasks[0].PSObject.Properties.Remove($propertyName)
    }
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository -Initialize) | ConvertFrom-Json
    $migratedState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 3 ([int]$migratedState.version) "Legacy state version was not migrated."
    Assert-Equal "auto" ([string]$migratedState.tasks[0].startMode) "Legacy task start mode was not defaulted."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["backgroundSession"]) "Legacy task session field was not added."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["planRecordedAt"]) "Legacy task plan timestamp field was not added."


    $launch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "test-task" -Mode "auto" -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-Equal "test1234" ([string]$launch.backgroundSession.id) "Background ID was not captured."
    $launchMetadata = Read-FactoryJson -Path (Join-Path $context.sessionsPath "test-task.json")
    Assert-True ([string]$launchMetadata.launchOutput -match 'benign background-launch warning') "Benign stderr warning was not captured."
    Assert-True (-not [string]$launch.backgroundSession.sessionId) "Launcher recorded a session UUID that Claude did not accept."
    Assert-True (Test-Path -LiteralPath $launch.worktree) "Worker worktree was not created."

    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = [string]$launch.worktree
    $sessionReconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    $sessionState = Read-FactoryJson -Path $context.statePath
    Assert-Equal $fakeSessionId ([string]$sessionState.tasks[0].backgroundSession.sessionId) "Current Claude agents schema was not reconciled."
    Assert-Equal "working" ([string]$sessionState.tasks[0].backgroundSession.state) "Current Claude status field was not captured."
    $planText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0J/RgNC+0LLQtdGA0LrQsCDigJQg0YLQtdGB0YIg4oCiIG9r"))
    $planTextBytes = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($planText))
    $planCapturedAt = [DateTime]::UtcNow.AddMinutes(-1).ToString("o")
    $planEvent = [ordered]@{
        version = 1
        taskId = "test-task"
        kind = "plan"
        capturedAt = $planCapturedAt
        transcriptPath = (Join-Path $testRoot "plan-transcript.jsonl")
        lastAssistantMessage = "FACTORY_PLAN"
        payload = [ordered]@{
            taskId = "test-task"
            understanding = $planText
            plan = @("Keep the text intact")
            questions = @()
            readyToImplement = $true
        }
    }
    $planEventPath = Join-Path (Join-Path $context.eventsPath "test-task") "latest-plan.json"
    Write-FactoryJsonAtomic -Path $planEventPath -Value $planEvent

    $planState = Read-FactoryJson -Path $context.statePath
    $planState.tasks[0].startMode = "interactive"
    $planState.tasks[0].status = "planning"
    $planState.tasks[0].plan = $null
    $planState.tasks[0].planRecordedAt = $null
    Write-FactoryJsonAtomic -Path $context.statePath -Value $planState

    $env:CLAUDE_FACTORY_TEST_NO_AGENTS = "1"
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $recordedPlanState = Read-FactoryJson -Path $context.statePath
    Assert-Equal "awaiting-input" ([string]$recordedPlanState.tasks[0].status) "Current interactive plan was not recorded."
    Assert-Equal $planCapturedAt ([string]$recordedPlanState.tasks[0].planRecordedAt) "Plan capture timestamp was not recorded."
    Assert-Equal $planText ([string]$recordedPlanState.tasks[0].plan.understanding) "Non-ASCII plan text did not round-trip."

    $recordedPlanState.tasks[0].status = "planning"
    Write-FactoryJsonAtomic -Path $context.statePath -Value $recordedPlanState
    $stalePlanReconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $stalePlanState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 0 ([int]$stalePlanReconcile.changed) "An already-recorded plan caused another transition."
    Assert-Equal "planning" ([string]$stalePlanState.tasks[0].status) "An already-recorded plan forced the task back to awaiting input."

    $initialStateSize = (Get-Item -LiteralPath $context.statePath).Length
    for ($reconcilePass = 0; $reconcilePass -lt 5; $reconcilePass++) {
        $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    }
    $finalStateSize = (Get-Item -LiteralPath $context.statePath).Length
    $roundTrippedState = Read-FactoryJson -Path $context.statePath
    $roundTrippedPlanBytes = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$roundTrippedState.tasks[0].plan.understanding))
    Assert-Equal $initialStateSize $finalStateSize "Repeated reconciles grew state.json."
    Assert-Equal $planTextBytes $roundTrippedPlanBytes "Repeated reconciles changed the UTF-8 plan bytes."
    Remove-Item Env:\CLAUDE_FACTORY_TEST_NO_AGENTS -ErrorAction SilentlyContinue


    $workerContext = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $launch.worktree) |
        ConvertFrom-Json
    Assert-Equal ([IO.Path]::GetFullPath($repository)) ([IO.Path]::GetFullPath([string]$workerContext.repositoryRoot)) "Linked worktree did not resolve to the main repository."
    Assert-Equal ([string]$context.projectKey) ([string]$workerContext.projectKey) "Linked worktree used a different project key."

    [IO.File]::AppendAllText(
        (Join-Path $launch.worktree "README.md"),
        "changed`n",
        (New-Object Text.UTF8Encoding($false))
    )
    & git -C $launch.worktree add README.md
    & git -C $launch.worktree commit -m "fix(test-task): change README" 1> $null
    $commit = (& git -C $launch.worktree rev-parse HEAD).Trim()

    $result = [ordered]@{
        status = "completed"
        taskId = "test-task"
        branch = [string]$launch.branch
        commit = $commit
        worktree = [string]$launch.worktree
        changedFiles = @("README.md")
        tests = @(
            [ordered]@{
                command = "manual assertion"
                status = "passed"
                summary = "fixture updated"
            }
        )
        notes = "test"
        blockingReason = ""
    }
    $message = "FACTORY_RESULT`n" + ($result | ConvertTo-Json -Depth 20)
    $hookInput = [ordered]@{
        session_id = $fakeSessionId
        transcript_path = (Join-Path $testRoot "transcript.jsonl")
        cwd = [string]$launch.worktree
        hook_event_name = "Stop"
        last_assistant_message = $message
    } | ConvertTo-Json -Depth 20
    $hookInput |
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\capture-worker-stop.ps1")

    $reconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-True ($reconcile.changed -ge 1) "Reconciliation recorded no transition."

    $state = Read-FactoryJson -Path $context.statePath
    $task = $state.tasks[0]
    Assert-Equal "awaiting-review" ([string]$task.status) "Completed worker bypassed or missed the review gate."
    Assert-Equal $commit ([string]$task.commit) "Validated commit was not recorded."
    Assert-True (-not [string]$task.approval) "Task was approved automatically."

    $decision = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") -Repository $repository -Action go -TaskId "test-task") |
        ConvertFrom-Json
    Assert-Equal "approved" ([string]$decision.status) "Explicit go did not approve the task."
    Assert-Equal $commit ([string]$decision.approvedCommit) "Approval did not pin the exact commit."

    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $stateAfterSecondReconcile = Read-FactoryJson -Path $context.statePath
    Assert-Equal "approved" ([string]$stateAfterSecondReconcile.tasks[0].status) "Reconciliation invalidated an unchanged approval."

    $concurrency = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\set-concurrency.ps1") -Repository $repository -Value 5) |
        ConvertFrom-Json
    Assert-Equal 3 ([int]$concurrency.previous) "Unexpected initial concurrency."
    Assert-Equal 5 ([int]$concurrency.current) "Concurrency did not update."

    $held = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") -Repository $repository -Action hold -TaskId "test-task") |
        ConvertFrom-Json
    Assert-Equal "held" ([string]$held.status) "Approved task could not be held before cleanup."
    & git -C $launch.worktree push origin HEAD:develop HEAD:master 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Failed to publish cleanup fixture commit." }
    $cleanupState = Read-FactoryJson -Path $context.statePath
    $cleanupState.tasks[0].backgroundSession.state = "done"
    Write-FactoryJsonAtomic -Path $context.statePath -Value $cleanupState

    $cleanup = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\cleanup-task.ps1") -Repository $repository -TaskId "test-task") |
        ConvertFrom-Json
    Assert-Equal "done" ([string]$cleanup.status) "Task cleanup did not mark the task done."
    Assert-True (-not (Test-Path -LiteralPath $launch.worktree)) "Task cleanup did not remove the worker worktree."
    $remainingWorkerBranch = @(& git -C $repository branch --list ([string]$launch.branch))
    Assert-Equal 0 $remainingWorkerBranch.Count "Task cleanup did not remove the local worker branch."
    $cleanedState = Read-FactoryJson -Path $context.statePath
    Assert-Equal "done" ([string]$cleanedState.tasks[0].status) "Task cleanup state was not persisted."

    $doctor = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-doctor.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-True ([bool]$doctor.healthy) "Factory doctor reported required failures in the valid fixture."

    Write-Host "All factory runtime tests passed." -ForegroundColor Green
} finally {
    Remove-Item Env:\CLAUDE_FACTORY_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_CWD -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_NO_AGENTS -ErrorAction SilentlyContinue
    if ($KeepTemp) {
        Write-Host "Kept test directory: $testRoot" -ForegroundColor Yellow
    } elseif (
        (Test-Path -LiteralPath $testRoot) -and
        ([IO.Path]::GetFullPath($testRoot)).StartsWith(
            [IO.Path]::GetFullPath("C:\tmp\claude-factory-plugin-tests-"),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
