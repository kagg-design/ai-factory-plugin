[CmdletBinding()]
param(
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $pluginRoot "scripts\factory-common.ps1")
. (Join-Path $pluginRoot "scripts\worker-launch.ps1")
. (Join-Path $pluginRoot "scripts\orchestrator-session.ps1")
$testRoot = Join-Path "C:\tmp" "claude-factory-plugin-tests-$([Guid]::NewGuid().ToString('N'))"
$repository = Join-Path $testRoot "repository"
$remote = Join-Path $testRoot "remote.git"
$runtime = Join-Path $testRoot "runtime"
$fakeClaude = Join-Path $testRoot "claude-fake.exe"

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

function New-FactoryTestTask {
    param([string]$Id, [string]$Title, [string]$Now)
    return [pscustomobject]@{
        id = $Id
        url = $null
        title = $Title
        brief = "Test worker launch behavior."
        acceptanceCriteria = @("launch behavior is verified")
        sourceNotes = @()
        startMode = "auto"
        status = "queued"
        attempts = 0
        attemptPrepared = $false
        agentId = $null
        backgroundSession = $null
        branch = $null
        commit = $null
        worktree = $null
        plan = $null
        workerResult = $null
        review = $null
        approval = $null
        error = $null
        createdAt = $Now
        updatedAt = $Now
    }
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
    Assert-True ($publicSkill.Contains('argument-hint: "help | <command>"')) "The public skill still has an overflowing argument hint."
    Assert-True ($publicSkill.Contains('### `help [command]`')) "The public skill does not expose factory help."
    Assert-True ($publicSkill.Contains('Details: /factory help <command>')) "Factory help does not advertise command-specific help."
    Assert-True ($publicSkill.Contains('### `status [state|all]`')) "Factory status does not support actionable filters."
    Assert-True ($publicSkill.Contains('one continuous Unicode tree')) "Factory status is not rendered as one tree."
    Assert-True ($publicSkill.Contains('There must be no physically empty line anywhere inside the tree')) "Factory status allows broken connector lines."
    Assert-True ($publicSkill.Contains('The tree layout is mandatory')) "Factory status does not mandate the tree template."
    Assert-True ($publicSkill.Contains('Preserve the vertical trunk exactly')) "Factory status does not preserve a solid tree trunk."
    Assert-True ($publicSkill.Contains('one primary exact')) "Factory status does not require a next action."
    Assert-True ($publicSkill.Contains('full canonical task URL as the first nested detail')) "Factory status does not require the task URL."
    Assert-True ($publicSkill.Contains('URL: https://app.asana.com/0/PROJECT/TASK_ID')) "Factory status template does not show task URLs."
    Assert-True ($publicSkill.Contains('full title, full canonical task URL, completion summary')) "Completed status history omits task identity or URL."
    Assert-True ($publicSkill.Contains('`/factory status done` for history')) "Factory status does not collapse completed history."
    Assert-True ($publicSkill.Contains('Never claim `/factory retry` works for a')) "Factory status does not distinguish manual holds."

    $workerAgentSource = Get-Content -LiteralPath (Join-Path $pluginRoot "agents\worker.md") -Raw
    Assert-True ($workerAgentSource -match '(?m)^name: worker\s*$') "The scoped factory:worker agent is not resolvable."

    $launcherSource = Get-Content -LiteralPath (Join-Path $pluginRoot "start-factory.ps1") -Raw
    Assert-True ($launcherSource.Contains('[string]$Repository = (Get-Location).Path')) "Launcher does not default to the current directory."
    Assert-True ($launcherSource.Contains('[string]$Name = "Claude Factory Orchestrator"')) "Launcher does not use the orchestrator display name by default."
    Assert-True ($launcherSource.Contains('"--name", $Name')) "Launcher does not set the Claude session display name."
    Assert-True ($launcherSource.Contains('"--add-dir", $standaloneRoot')) "Launcher does not load the /factory standalone skill."
    Assert-True ($launcherSource.Contains('"--session-id", $newSessionId')) "Launcher does not assign a durable orchestrator session ID."
    Assert-True ($launcherSource.Contains('@("--resume", $storedSessionId)')) "Launcher does not resume the stored orchestrator conversation."
    Assert-True ($launcherSource.Contains('& $ClaudeCommand attach $backgroundId')) "Launcher does not attach an existing background orchestrator."

    $orchestratorRows = @(
        [pscustomobject]@{ id = "oldbg"; sessionId = "11111111-1111-4111-8111-111111111111"; kind = "background"; name = "Claude Factory Orchestrator"; cwd = "C:\repo"; state = "blocked"; startedAt = 1 },
        [pscustomobject]@{ id = "newbg"; sessionId = "22222222-2222-4222-8222-222222222222"; kind = "background"; name = "Claude Factory Orchestrator"; cwd = "C:\repo"; state = "working"; startedAt = 2 },
        [pscustomobject]@{ id = "donebg"; sessionId = "33333333-3333-4333-8333-333333333333"; kind = "background"; name = "Claude Factory Orchestrator"; cwd = "C:\repo"; state = "done"; startedAt = 3 },
        [pscustomobject]@{ id = "other"; sessionId = "44444444-4444-4444-8444-444444444444"; kind = "background"; name = "Claude Factory Orchestrator"; cwd = "C:\other"; state = "working"; startedAt = 4 }
    )
    $matchingOrchestrators = @(Get-FactoryMatchingOrchestratorRows -Rows $orchestratorRows -RepositoryRoot "C:\repo" -Name "Claude Factory Orchestrator")
    Assert-Equal 3 $matchingOrchestrators.Count "Orchestrator matching mixed repositories or names."
    $newestOrchestrator = Select-FactoryBackgroundOrchestrator -Rows $matchingOrchestrators
    Assert-Equal "newbg" ([string]$newestOrchestrator.id) "Launcher did not choose the newest live background orchestrator."
    $preferredOrchestrator = Select-FactoryBackgroundOrchestrator -Rows $matchingOrchestrators -PreferredSessionId "11111111-1111-4111-8111-111111111111"
    Assert-Equal "oldbg" ([string]$preferredOrchestrator.id) "Launcher ignored the stored orchestrator identity."

    $workerLauncherSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Raw
    $workerLaunchHelperSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\worker-launch.ps1") -Raw
    Assert-True ($workerLaunchHelperSource.Contains('"factory:worker"')) "Worker launcher uses the wrong plugin namespace."
    Assert-True (-not $workerLauncherSource.Contains('"--session-id"')) "Worker launcher still passes the unsupported background session ID."
    Assert-True ($workerLauncherSource.Contains("conversationLanguage = [string]`$config.conversationLanguage")) "Worker payload does not include the configured conversation language."
    Assert-True ($workerLauncherSource.Contains("Invoke-FactoryWorkerLaunch")) "Worker launcher does not use the safe native process helper."
    Assert-True (-not $workerLauncherSource.Contains("Get-FileHash")) "Worker launcher still depends on ambient PowerShell utility modules for hashing."
    Assert-True ((Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\worker-git-guard.ps1") -Raw).Contains("exit 2")) "Worker Git guard does not fail closed."

    $cleanupSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\cleanup-task.ps1") -Raw
    Assert-True ($cleanupSource.Contains("core.longpaths=true")) "Task cleanup does not enable Git long-path support."
    Assert-True ($cleanupSource.Contains("rm `$backgroundId")) "Task cleanup does not remove completed Agent View sessions."
    Assert-True ($publicSkill.Contains("cleanup <task-id>")) "The public skill does not expose per-task cleanup."
    $rejectSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\reject-task.ps1") -Raw
    Assert-True ($rejectSource.Contains("worktree remove --force")) "Task rejection does not remove abandoned worktrees."
    Assert-True ($publicSkill.Contains('reject <task-id> [reason] [--yes|--keep]')) "The public skill does not expose final discard semantics."
    Assert-True ($publicSkill.Contains('do not substitute')) "The public skill does not distinguish reject from cleanup."
    $taskActionSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\task-action.ps1") -Raw
    Assert-True ($taskActionSource.Contains("State-only rejection now requires")) "Legacy task-action reject still bypasses final discard semantics."
    $syncSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\sync-task.ps1") -Raw
    Assert-True ($syncSource.Contains("rebase --onto")) "Task sync does not rebase the task commit."
    Assert-True ($publicSkill.Contains("sync <task-id>")) "The public skill does not expose task sync."

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    & git init --bare $remote 1> $null
    & git init $repository 1> $null
    & git -C $repository config user.email "factory-tests@example.test"
    & git -C $repository config user.name "Factory Tests"
    & git -C $repository config commit.gpgsign false
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
    Add-Type -Path (Join-Path $PSScriptRoot "FakeClaude.cs") -OutputAssembly $fakeClaude -OutputType ConsoleApplication

    $env:CLAUDE_FACTORY_HOME = $runtime
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository -Initialize) |
        ConvertFrom-Json
    Assert-Equal 3 ((Read-FactoryJson -Path $context.configPath).version) "Config migration failed."
    Assert-Equal 3 ((Read-FactoryJson -Path $context.statePath).version) "State migration failed."

    $orchestratorArgv = Join-Path $testRoot "orchestrator-argv.txt"
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $orchestratorArgv
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "start-factory.ps1") -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Fresh orchestrator launcher fixture failed." }
    $firstOrchestratorArgs = @([IO.File]::ReadAllLines($orchestratorArgv, [Text.Encoding]::UTF8))
    $newSessionIndex = [Array]::IndexOf($firstOrchestratorArgs, "--session-id")
    Assert-True ($newSessionIndex -ge 0 -and $newSessionIndex + 1 -lt $firstOrchestratorArgs.Count) "Fresh launcher did not assign an orchestrator session ID."
    $orchestratorSessionId = $firstOrchestratorArgs[$newSessionIndex + 1]
    $parsedOrchestratorSessionId = [Guid]::Empty
    Assert-True ([Guid]::TryParse($orchestratorSessionId, [ref]$parsedOrchestratorSessionId)) "Launcher assigned an invalid orchestrator UUID."
    $orchestratorIdentityPath = Join-Path ([string]$context.projectData) "orchestrator-session.json"
    $orchestratorIdentity = Read-FactoryJson -Path $orchestratorIdentityPath
    Assert-Equal $orchestratorSessionId ([string]$orchestratorIdentity.sessionId) "Launcher did not persist the orchestrator UUID."

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "start-factory.ps1") -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Stored orchestrator resume fixture failed." }
    $resumedOrchestratorArgs = @([IO.File]::ReadAllLines($orchestratorArgv, [Text.Encoding]::UTF8))
    $resumeIndex = [Array]::IndexOf($resumedOrchestratorArgs, "--resume")
    Assert-True ($resumeIndex -ge 0 -and $resumeIndex + 1 -lt $resumedOrchestratorArgs.Count) "Repeated launcher did not resume the stored orchestrator."
    Assert-Equal $orchestratorSessionId $resumedOrchestratorArgs[$resumeIndex + 1] "Repeated launcher resumed a different conversation."

    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = $repository
    $env:CLAUDE_FACTORY_TEST_ORCHESTRATOR_SESSION_ID = $orchestratorSessionId
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "start-factory.ps1") -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Background orchestrator attach fixture failed." }
    $attachedOrchestratorArgs = @([IO.File]::ReadAllLines($orchestratorArgv, [Text.Encoding]::UTF8))
    Assert-Equal "attach" $attachedOrchestratorArgs[0] "Launcher did not attach the existing background orchestrator."
    Assert-Equal "orch1234" $attachedOrchestratorArgs[1] "Launcher attached the wrong background orchestrator."
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ORCHESTRATOR_SESSION_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_CWD -ErrorAction SilentlyContinue

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "start-factory.ps1") -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -New 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Explicit new orchestrator fixture failed." }
    $newOrchestratorArgs = @([IO.File]::ReadAllLines($orchestratorArgv, [Text.Encoding]::UTF8))
    $replacementSessionIndex = [Array]::IndexOf($newOrchestratorArgs, "--session-id")
    Assert-True ($replacementSessionIndex -ge 0 -and $replacementSessionIndex + 1 -lt $newOrchestratorArgs.Count) "-New did not create a replacement orchestrator identity."
    Assert-True ($newOrchestratorArgs[$replacementSessionIndex + 1] -ne $orchestratorSessionId) "-New reused the previous orchestrator UUID."
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ARGV_FILE -ErrorAction SilentlyContinue

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
                brief = ("Change README with `"quotes`", 'apostrophes', ampersand &, pipe |, percent %,`nand non-ASCII em dash " + [char]0x2014 + " intact.")
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
    Assert-True ($null -ne $migratedState.PSObject.Properties["agentResolutionCache"]) "Legacy state agent resolution cache field was not added."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["planRecordedAt"]) "Legacy task plan timestamp field was not added."


    $argvCapture = Join-Path $testRoot "launch-argv.txt"
    $promptCopy = Join-Path $testRoot "prompt-copy.txt"
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $argvCapture
    $env:CLAUDE_FACTORY_TEST_PROMPT_COPY = $promptCopy
    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = $repository
    $launch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "test-task" -Mode "auto" -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-Equal "test1234" ([string]$launch.backgroundSession.id) "Background ID was not captured."
    Assert-Equal $fakeSessionId ([string]$launch.backgroundSession.sessionId) "Launcher did not bind the authoritative session UUID."
    Assert-Equal "plugin" ([string]$launch.backgroundSession.agentResolution) "Native agent success was not audited."
    $launchMetadata = Read-FactoryJson -Path (Join-Path $context.sessionsPath "test-task.json")
    Assert-True ([string]$launchMetadata.launchOutput -match 'benign background-launch warning') "Benign stderr warning was not captured."
    Assert-Equal "plugin" ([string]$launchMetadata.agentResolution) "Launch metadata did not record native agent resolution."
    Assert-True (Test-Path -LiteralPath $launchMetadata.promptPath) "Durable worker prompt was not written."
    Assert-True (Test-Path -LiteralPath $promptCopy) "Fake Claude could not read the prompt file."
    Assert-Equal (Get-FactoryFileSha256 -Path $launchMetadata.promptPath) (Get-FactoryFileSha256 -Path $promptCopy) "Fake Claude did not read byte-identical prompt content."
    Assert-Equal ([string]$launchMetadata.promptSha256) (Get-FactoryFileSha256 -Path $launchMetadata.promptPath) "Prompt audit hash is wrong."
    $capturedArgv = Get-Content -LiteralPath $argvCapture -Raw
    Assert-True ($capturedArgv.Contains("FACTORY_PROMPT_FILE=")) "Worker argv did not contain the prompt pointer."
    Assert-True (-not $capturedArgv.Contains("Change README with")) "Raw task payload leaked into worker argv."
    Assert-True (-not $capturedArgv.Contains("--agents")) "Native agent success unexpectedly used an inline definition."
    $nativeLaunchState = Read-FactoryJson -Path $context.statePath
    Assert-Equal "plugin" ([string]$nativeLaunchState.agentResolutionCache.preferredResolution) "Native capability was not cached."
    Assert-True (Test-Path -LiteralPath $launch.worktree) "Worker worktree was not created."

    $guardScript = Join-Path $pluginRoot "scripts\worker-git-guard.ps1"
    $previousGuardErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $malformedGuardOutput = @('{not-json' | & powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript 2>&1 | ForEach-Object { [string]$_ })
        $malformedGuardExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousGuardErrorAction
    }
    Assert-Equal 2 $malformedGuardExit "Malformed Git guard input did not fail closed."
    Assert-True (($malformedGuardOutput -join "`n") -match 'safety check failed') "Malformed Git guard failure was not explicit."
    $blockedGuardPayload = [ordered]@{
        cwd = [string]$launch.worktree
        tool_input = [ordered]@{ command = "git push origin HEAD" }
    } | ConvertTo-Json -Depth 5 -Compress
    $blockedGuardResult = ($blockedGuardPayload | & powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript) | ConvertFrom-Json
    Assert-Equal "deny" ([string]$blockedGuardResult.hookSpecificOutput.permissionDecision) "Worker Git push was not denied."
    $harmlessGuardPayload = [ordered]@{
        cwd = [string]$launch.worktree
        tool_input = [ordered]@{ command = "git status --short" }
    } | ConvertTo-Json -Depth 5 -Compress
    $harmlessGuardOutput = @($harmlessGuardPayload | & powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript)
    Assert-Equal 0 $LASTEXITCODE "Harmless worker Git command failed the guard."
    Assert-Equal 0 $harmlessGuardOutput.Count "Harmless worker Git command emitted a denial."

    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = [string]$launch.worktree
    $sessionReconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    $sessionState = Read-FactoryJson -Path $context.statePath
    Assert-Equal $fakeSessionId ([string]$sessionState.tasks[0].backgroundSession.sessionId) "Current Claude agents schema was not reconciled."
    Assert-Equal "working" ([string]$sessionState.tasks[0].backgroundSession.state) "Current Claude status field was not captured."
    Assert-Equal "live-transcript" ([string]$sessionState.tasks[0].backgroundSession.transcriptPath) "A stale same-shape agent row overwrote authoritative metadata."

    $env:CLAUDE_FACTORY_TEST_AGENT_STATUS = "stopped"
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $machineHeldState = Read-FactoryJson -Path $context.statePath
    Assert-Equal "held" ([string]$machineHeldState.tasks[0].status) "Stopped worker was not machine-held."
    Assert-Equal "background session stopped without a FACTORY_RESULT" ([string]$machineHeldState.tasks[0].holdReason) "Machine hold reason was not recorded."
    $retried = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") -Repository $repository -Action retry -TaskId "test-task") | ConvertFrom-Json
    Assert-Equal "queued" ([string]$retried.status) "Machine-held task was not retryable."
    Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_STATUS -ErrorAction SilentlyContinue
    $launch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "test-task" -Mode "auto" -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $retryState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 2 ([int]$retryState.tasks[0].attempts) "Retry did not advance exactly one attempt."

    $answers = "Use the existing worktree.`nKeep the special payload intact."
    $answered = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\answer-task.ps1") -Repository $repository -TaskId "test-task" -Text $answers -Mode auto -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal "queued" ([string]$answered.status) "Answer did not queue the retained worker task."
    Assert-Equal $answers ([IO.File]::ReadAllText([string]$answered.decisionsPath, [Text.Encoding]::UTF8)) "Answer file content changed."
    $answeredState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 3 ([int]$answeredState.tasks[0].attempts) "Answer did not prepare exactly one new attempt."
    Assert-Equal 1 ([regex]::Matches([string]$answeredState.tasks[0].brief, '<!-- FACTORY_DECISIONS_START -->').Count) "Answer pointer was duplicated."
    $answeredAgain = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\answer-task.ps1") -Repository $repository -TaskId "test-task" -Text $answers -Mode auto -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-True ([bool]$answeredAgain.idempotent) "Repeated answer was not reported as idempotent."
    $answeredAgainState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 3 ([int]$answeredAgainState.tasks[0].attempts) "Repeated answer advanced attempts again."
    Assert-Equal 1 ([regex]::Matches([string]$answeredAgainState.tasks[0].brief, '<!-- FACTORY_DECISIONS_START -->').Count) "Repeated answer duplicated the brief pointer."
    $commonGitDir = (& git -C $repository rev-parse --git-common-dir).Trim()
    if (-not [IO.Path]::IsPathRooted($commonGitDir)) { $commonGitDir = Join-Path $repository $commonGitDir }
    $excludeLines = @([IO.File]::ReadAllLines((Join-Path ([IO.Path]::GetFullPath($commonGitDir)) "info\exclude")))
    Assert-Equal 1 (@($excludeLines | Where-Object { $_ -eq '/FACTORY-DECISIONS.md' }).Count) "Shared exclude entry was missing or duplicated."
    $launch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "test-task" -Mode "auto" -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $answerLaunchState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 3 ([int]$answerLaunchState.tasks[0].attempts) "Prepared answer attempt was incremented twice by launcher."
    Assert-True (Test-Path -LiteralPath (Join-Path $launch.worktree "FACTORY-DECISIONS.md")) "Decisions file did not survive relaunch."
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
        sessionId = $fakeSessionId
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

    $syncState = Read-FactoryJson -Path $context.statePath
    $syncState.tasks[0].backgroundSession.state = "done"
    Write-FactoryJsonAtomic -Path $context.statePath -Value $syncState
    [IO.File]::WriteAllText(
        (Join-Path $repository "BASE.md"),
        "new development base`n",
        (New-Object Text.UTF8Encoding($false))
    )
    & git -C $repository add BASE.md
    & git -C $repository commit -m "chore: advance development" 1> $null
    & git -C $repository push origin develop 1> $null
    $sync = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\sync-task.ps1") -Repository $repository -TaskId "test-task" -Action prepare) |
        ConvertFrom-Json
    Assert-Equal "syncing" ([string]$sync.status) "Task sync did not require fresh validation."
    Assert-True ([string]$sync.commit -ne $commit) "Task sync did not replace the old commit SHA."
    Assert-True (Test-Path -LiteralPath (Join-Path $launch.worktree "BASE.md")) "Worker worktree did not receive the latest development base."
    $commit = [string]$sync.commit
    $syncReportPath = Join-Path $context.sessionsPath "test-task.sync-tests.json"
    Write-FactoryJsonAtomic -Path $syncReportPath -Value ([pscustomobject]@{
        tests = @([pscustomobject]@{
            command = "git diff --check"
            status = "passed"
            summary = "No whitespace errors."
        })
        notes = "Synchronized test fixture."
    })
    $syncFinal = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\sync-task.ps1") -Repository $repository -TaskId "test-task" -Action finalize -TestsPath $syncReportPath) |
        ConvertFrom-Json
    Assert-Equal "awaiting-review" ([string]$syncFinal.status) "Task sync did not return to review."
    Assert-Equal $commit ([string]$syncFinal.commit) "Task sync finalized the wrong commit."
    Assert-True (-not (Test-Path -LiteralPath $syncReportPath)) "Task sync did not remove its temporary test report."

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

    $externalSentinel = Join-Path $testRoot "external-sentinel"
    New-Item -ItemType Directory -Path $externalSentinel -Force | Out-Null
    $sentinelFile = Join-Path $externalSentinel "keep.txt"
    [IO.File]::WriteAllText($sentinelFile, "keep", (New-Object Text.UTF8Encoding($false)))
    $commonGitDir = (& git -C $repository rev-parse --git-common-dir).Trim()
    if (-not [IO.Path]::IsPathRooted($commonGitDir)) { $commonGitDir = Join-Path $repository $commonGitDir }
    $excludePath = Join-Path ([IO.Path]::GetFullPath($commonGitDir)) "info\exclude"
    [IO.File]::AppendAllText($excludePath, "/node_modules/" + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $junctionPath = Join-Path $launch.worktree "node_modules"
    New-Item -ItemType Junction -Path $junctionPath -Target $externalSentinel | Out-Null
    Assert-True ((Get-Item -LiteralPath $junctionPath).Attributes -band [IO.FileAttributes]::ReparsePoint) "Junction fixture was not created."

    $agentSessionRemoval = Join-Path $testRoot "removed-agent-session.txt"
    $env:CLAUDE_FACTORY_TEST_RM_FILE = $agentSessionRemoval
    $cleanup = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\cleanup-task.ps1") -Repository $repository -TaskId "test-task" -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-Equal "done" ([string]$cleanup.status) "Task cleanup did not mark the task done."
    Assert-True (-not (Test-Path -LiteralPath $launch.worktree)) "Task cleanup did not remove the worker worktree."
    $remainingWorkerBranch = @(& git -C $repository branch --list ([string]$launch.branch))
    Assert-Equal 0 $remainingWorkerBranch.Count "Task cleanup did not remove the local worker branch."
    Assert-True (Test-Path -LiteralPath $sentinelFile) "Cleanup traversed the external junction target."
    Assert-Equal 1 (@($cleanup.removedReparsePoints).Count) "Cleanup did not audit the removed junction."
    Assert-True ([bool]$cleanup.removedAgentSession) "Cleanup did not report Agent View session removal."
    Assert-Equal "test1234" ((Get-Content -LiteralPath $agentSessionRemoval -Raw).Trim()) "Cleanup removed the wrong Agent View session."
    $cleanedState = Read-FactoryJson -Path $context.statePath
    Assert-Equal "done" ([string]$cleanedState.tasks[0].status) "Task cleanup state was not persisted."


    $rejectState = Read-FactoryJson -Path $context.statePath
    $rejectState.tasks = @($rejectState.tasks) + @(
        [pscustomobject]@{
            id = "keep-task"
            title = "Rejected but retained"
            brief = "Keep this task inspectable."
            status = "held"
            backgroundSession = $null
            branch = $null
            commit = $null
            worktree = $null
            approval = $null
            createdAt = $now
            updatedAt = $now
        },
        [pscustomobject]@{
            id = "discard-task"
            url = $null
            title = "Discard unique work"
            brief = "This abandoned work may be dirty and unpublished."
            acceptanceCriteria = @("discard succeeds")
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
            error = $null
            createdAt = $now
            updatedAt = $now
        }
    )
    Write-FactoryJsonAtomic -Path $context.statePath -Value $rejectState

    $kept = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "keep-task" -Reason "Needs an audit trail" -Keep -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-Equal "rejected" ([string]$kept.status) "Reject --keep did not retain a rejected task."
    $keptState = Read-FactoryJson -Path $context.statePath
    $keptTask = @($keptState.tasks | Where-Object { [string]$_.id -eq "keep-task" })[0]
    Assert-Equal "Needs an audit trail" ([string]$keptTask.rejectionReason) "Reject --keep did not record its reason."

    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = $repository
    $discardLaunch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "discard-task" -Mode auto -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    [IO.File]::AppendAllText(
        (Join-Path $discardLaunch.worktree "README.md"),
        "unpublished dirty work`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $discardSentinel = Join-Path $testRoot "reject-external-sentinel"
    New-Item -ItemType Directory -Path $discardSentinel -Force | Out-Null
    $discardSentinelFile = Join-Path $discardSentinel "keep.txt"
    [IO.File]::WriteAllText($discardSentinelFile, "keep", (New-Object Text.UTF8Encoding($false)))
    $discardJunction = Join-Path $discardLaunch.worktree "node_modules"
    New-Item -ItemType Junction -Path $discardJunction -Target $discardSentinel | Out-Null

    $discardMetadata = Join-Path $context.sessionsPath "discard-task.json"
    $discardPrompt = @(
        Get-ChildItem -LiteralPath $context.sessionsPath -File |
            Where-Object { $_.Name.StartsWith("discard-task-a") }
    )[0].FullName
    $discardEvents = Join-Path $context.eventsPath "discard-task"
    Assert-True (Test-Path -LiteralPath $discardMetadata) "Discard fixture has no session metadata."
    Assert-True (Test-Path -LiteralPath $discardPrompt) "Discard fixture has no durable prompt."
    Assert-True (Test-Path -LiteralPath $discardEvents) "Discard fixture has no event directory."

    $preview = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "discard-task" -Reason "Duplicate" -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-True ([bool]$preview.confirmationRequired) "Reject did not preview potentially unique work."
    Assert-Equal ([string]$discardLaunch.worktree) ([string]$preview.worktree) "Reject preview named the wrong worktree."
    Assert-True (Test-Path -LiteralPath $discardLaunch.worktree) "Reject preview mutated the worktree."
    $previewState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 1 (@($previewState.tasks | Where-Object { [string]$_.id -eq "discard-task" }).Count) "Reject preview removed the task."

    $stopCapture = Join-Path $testRoot "stopped-session.txt"
    $env:CLAUDE_FACTORY_TEST_STOP_FILE = $stopCapture
    $discarded = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "discard-task" -Reason "Duplicate" -Yes -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FAIL -ErrorAction SilentlyContinue
    Assert-True ([bool]$discarded.removedFromState) "Confirmed reject did not forget the task."
    Assert-True ([bool]$discarded.stoppedSession) "Confirmed reject did not stop the session."
    Assert-Equal "test1234" ((Get-Content -LiteralPath $stopCapture -Raw).Trim()) "Reject stopped the wrong session."
    Assert-True (-not (Test-Path -LiteralPath $discardLaunch.worktree)) "Confirmed reject did not remove the dirty worktree."
    Assert-Equal 0 (@(& git -C $repository branch --list ([string]$discardLaunch.branch))).Count "Confirmed reject did not remove the branch."
    Assert-True (-not (Test-Path -LiteralPath $discardMetadata)) "Confirmed reject retained session metadata."
    Assert-True (-not (Test-Path -LiteralPath $discardPrompt)) "Confirmed reject retained the durable prompt."
    Assert-True (-not (Test-Path -LiteralPath $discardEvents)) "Confirmed reject retained event metadata."
    Assert-True (Test-Path -LiteralPath $discardSentinelFile) "Reject traversed the external junction target."
    Assert-Equal 1 (@($discarded.removedReparsePoints).Count) "Reject did not audit the removed junction."
    $discardedState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 0 (@($discardedState.tasks | Where-Object { [string]$_.id -eq "discard-task" }).Count) "Confirmed reject persisted the task."

    $fallbackState = Read-FactoryJson -Path $context.statePath
    $fallbackState.agentResolutionCache = $null
    $fallbackState.tasks = @($fallbackState.tasks) + @(
        New-FactoryTestTask -Id "fallback-task" -Title "Inline fallback" -Now $now
    )
    Write-FactoryJsonAtomic -Path $context.statePath -Value $fallbackState
    $fallbackCount = Join-Path $testRoot "fallback-launch-count.txt"
    $fallbackArgv = Join-Path $testRoot "fallback-argv.txt"
    $fallbackStops = Join-Path $testRoot "fallback-stops.txt"
    $env:CLAUDE_FACTORY_TEST_AGENT_BEHAVIOR = "fallback-once"
    $env:CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE = $fallbackCount
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $fallbackArgv
    $env:CLAUDE_FACTORY_TEST_STOP_FILE = $fallbackStops
    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = $repository
    $fallbackLaunch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "fallback-task" -Mode auto -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-Equal 2 ([int](Get-Content -LiteralPath $fallbackCount -Raw)) "Native fallback did not relaunch exactly once."
    Assert-Equal "inline-fallback" ([string]$fallbackLaunch.backgroundSession.agentResolution) "Inline fallback was not audited."
    Assert-Equal "fallback1" ((Get-Content -LiteralPath $fallbackStops -Raw).Trim()) "The native default-template session was not stopped."
    $fallbackLaunchState = Read-FactoryJson -Path $context.statePath
    $fallbackTask = @($fallbackLaunchState.tasks | Where-Object { [string]$_.id -eq "fallback-task" })[0]
    Assert-Equal 1 ([int]$fallbackTask.attempts) "Two process launches consumed two factory attempts."
    Assert-Equal "inline-fallback" ([string]$fallbackLaunchState.agentResolutionCache.preferredResolution) "Inline capability was not cached."
    $fallbackArguments = @([IO.File]::ReadAllLines($fallbackArgv, [Text.Encoding]::UTF8))
    $agentsIndex = [Array]::IndexOf($fallbackArguments, "--agents")
    Assert-True ($agentsIndex -ge 0 -and $agentsIndex + 1 -lt $fallbackArguments.Count) "Inline launch did not pass --agents JSON."
    $inlineDefinition = $fallbackArguments[$agentsIndex + 1] | ConvertFrom-Json
    $workerAgentRaw = [IO.File]::ReadAllText((Join-Path $pluginRoot "agents\worker.md"), (New-Object Text.UTF8Encoding($false, $true)))
    $workerAgentParts = [regex]::Match($workerAgentRaw, '\A---\r?\n(?<frontmatter>[\s\S]*?)\r?\n---\r?\n(?<body>[\s\S]*)\z')
    Assert-True $workerAgentParts.Success "Test fixture could not independently parse worker.md."
    $expectedDescription = [regex]::Match($workerAgentParts.Groups["frontmatter"].Value, '(?m)^description:\s*(?<value>.+?)\s*$').Groups["value"].Value
    $expectedPrompt = $workerAgentParts.Groups["body"].Value
    Assert-Equal $expectedDescription ([string]$inlineDefinition.worker.description) "Inline agent description changed in argv."
    Assert-Equal $expectedPrompt ([string]$inlineDefinition.worker.prompt) "Inline agent prompt was truncated or mangled in argv."
    $fallbackMetadata = Read-FactoryJson -Path (Join-Path $context.sessionsPath "fallback-task.json")
    Assert-Equal "inline-fallback" ([string]$fallbackMetadata.agentResolution) "Fallback metadata did not record its resolution path."
    Assert-True ([bool]$fallbackMetadata.inlineAgentSha256) "Fallback metadata has no inline definition hash."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "fallback-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json

    $cachedState = Read-FactoryJson -Path $context.statePath
    $cachedState.tasks = @($cachedState.tasks) + @(
        New-FactoryTestTask -Id "cached-fallback-task" -Title "Cached inline fallback" -Now $now
    )
    Write-FactoryJsonAtomic -Path $context.statePath -Value $cachedState
    $cachedCount = Join-Path $testRoot "cached-launch-count.txt"
    $cachedArgv = Join-Path $testRoot "cached-argv.txt"
    $cachedStops = Join-Path $testRoot "cached-stops.txt"
    $env:CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE = $cachedCount
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $cachedArgv
    $env:CLAUDE_FACTORY_TEST_STOP_FILE = $cachedStops
    $cachedLaunch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "cached-fallback-task" -Mode auto -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-Equal 1 ([int](Get-Content -LiteralPath $cachedCount -Raw)) "Cached fallback still created a native stray session."
    Assert-Equal "inline-fallback" ([string]$cachedLaunch.backgroundSession.agentResolution) "Cached fallback did not use inline resolution."
    Assert-True (-not (Test-Path -LiteralPath $cachedStops)) "Cached fallback stopped an unexpected stray session."
    $cachedArguments = @([IO.File]::ReadAllLines($cachedArgv, [Text.Encoding]::UTF8))
    Assert-True ([Array]::IndexOf($cachedArguments, "--agents") -ge 0) "Cached fallback omitted its inline definition."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "cached-fallback-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json

    $doubleState = Read-FactoryJson -Path $context.statePath
    $doubleState.agentResolutionCache = $null
    $doubleState.tasks = @($doubleState.tasks) + @(
        New-FactoryTestTask -Id "double-fallback-task" -Title "Double fallback failure" -Now $now
    )
    Write-FactoryJsonAtomic -Path $context.statePath -Value $doubleState
    $doubleCount = Join-Path $testRoot "double-launch-count.txt"
    $doubleStops = Join-Path $testRoot "double-stops.txt"
    $env:CLAUDE_FACTORY_TEST_AGENT_BEHAVIOR = "fallback-always"
    $env:CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE = $doubleCount
    $env:CLAUDE_FACTORY_TEST_STOP_FILE = $doubleStops
    $previousFallbackErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $doubleOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "double-fallback-task" -Mode auto -ClaudeCommand $fakeClaude 2>&1 | ForEach-Object { [string]$_ })
        $doubleExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousFallbackErrorAction
    }
    Assert-True ($doubleExitCode -ne 0) "A second default-template fallback was accepted as a worker."
    Assert-Equal 2 ([int](Get-Content -LiteralPath $doubleCount -Raw)) "Double fallback did not stop after one inline retry."
    Assert-Equal "fallback2" ((Get-Content -LiteralPath $doubleStops -Raw).Trim()) "The second stray fallback session was not stopped."
    $doubleFailedState = Read-FactoryJson -Path $context.statePath
    $doubleTask = @($doubleFailedState.tasks | Where-Object { [string]$_.id -eq "double-fallback-task" })[0]
    Assert-Equal "failed" ([string]$doubleTask.status) "Double fallback failure was not persisted."
    Assert-Equal 1 ([int]$doubleTask.attempts) "Double fallback failure consumed two factory attempts."
    Assert-True ($null -eq $doubleTask.backgroundSession) "Double fallback retained a stray background session."
    Assert-Equal "inline-fallback" ([string]$doubleFailedState.agentResolutionCache.preferredResolution) "Native failure capability was not cached after inline failure."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "double-fallback-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json

    Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_BEHAVIOR -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FILE -ErrorAction SilentlyContinue
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $argvCapture
    $doctor = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-doctor.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-True ([bool]$doctor.healthy) "Factory doctor reported required failures in the valid fixture."
    $doctorChecks = @($doctor.checks)
    $runtimeCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "powershellRuntime" })[0]
    $agentDefinitionCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "workerAgentDefinition" })[0]
    $resolutionCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "workerAgentResolution" })[0]
    Assert-True ([bool]$runtimeCheck.passed) "Factory doctor did not verify PowerShell dependencies."
    Assert-True ([bool]$agentDefinitionCheck.passed) "Factory doctor did not verify the inline worker definition."
    Assert-Equal "info" ([string]$resolutionCheck.severity) "Factory doctor did not report the resolution workaround."
    Assert-True ([string]$resolutionCheck.detail -match 'inline-fallback') "Factory doctor hid the active inline fallback."

    $missingAgentState = Read-FactoryJson -Path $context.statePath
    $missingAgentState.tasks = @($missingAgentState.tasks) + @([pscustomobject]@{
        id = "missing-agent-task"
        url = $null
        title = "Missing agent task"
        brief = "Must not run with a fallback agent."
        acceptanceCriteria = @("launch fails")
        sourceNotes = @()
        startMode = "auto"
        status = "queued"
        attempts = 0
        agentId = $null
        backgroundSession = $null
        branch = $null
        commit = $null
        worktree = $null
        workerResult = $null
        error = $null
        createdAt = $now
        updatedAt = $now
    })
    Write-FactoryJsonAtomic -Path $context.statePath -Value $missingAgentState
    $env:CLAUDE_FACTORY_TEST_MISSING_AGENT = "1"
    $previousTestErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $missingAgentOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "missing-agent-task" -Mode auto -ClaudeCommand $fakeClaude 2>&1 | ForEach-Object { [string]$_ })
        $missingAgentExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousTestErrorAction
    }
    $missingAgentFailed = $missingAgentExitCode -ne 0
    Remove-Item Env:\CLAUDE_FACTORY_TEST_MISSING_AGENT -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ORCHESTRATOR_SESSION_ID -ErrorAction SilentlyContinue
    Assert-True $missingAgentFailed "Missing-agent warning did not abort launch."
    $failedAgentState = Read-FactoryJson -Path $context.statePath
    $failedAgentTask = @($failedAgentState.tasks | Where-Object { [string]$_.id -eq 'missing-agent-task' })[0]
    Assert-Equal "failed" ([string]$failedAgentTask.status) "Missing-agent launch was not recorded as failed."
    Assert-True ([string]$failedAgentTask.error -match 'did not resolve the inline worker agent') "Missing-agent failure was not explicit."

    Write-Host "All factory runtime tests passed." -ForegroundColor Green
} finally {
    Remove-Item Env:\CLAUDE_FACTORY_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_CWD -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_NO_AGENTS -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_BEHAVIOR -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FAIL -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ARGV_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_PROMPT_COPY -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_MISSING_AGENT -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_PROMPT_PATH -ErrorAction SilentlyContinue
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
