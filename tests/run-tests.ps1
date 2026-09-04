[CmdletBinding()]
param(
    [switch]$KeepTemp
)

if ([string]$PSVersionTable.PSEdition -eq "Core") {
    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw "The factory runtime harness requires Windows PowerShell 5.1, but '$windowsPowerShell' was not found."
    }
    $desktopArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
    if ($KeepTemp) { $desktopArguments += "-KeepTemp" }
    & $windowsPowerShell @desktopArguments
    exit $LASTEXITCODE
}

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $pluginRoot "scripts\factory-common.ps1")
. (Join-Path $pluginRoot "scripts\worker-launch.ps1")
. (Join-Path $pluginRoot "scripts\orchestrator-session.ps1")
. (Join-Path $pluginRoot "scripts\worker-event.ps1")
$testRoot = Join-Path "C:\tmp" "claude-factory-plugin-tests-$([Guid]::NewGuid().ToString('N'))"
$repository = Join-Path $testRoot "repository"
$remote = Join-Path $testRoot "remote.git"
$runtime = Join-Path $testRoot "runtime"
$fakeClaude = Join-Path $testRoot "claude-fake.exe"
$fakeCodex = Join-Path $testRoot "codex-fake.exe"
$fakePsql = Join-Path $testRoot "psql-fake.exe"

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

function Invoke-FactoryHookWithUtf8Input {
    param(
        [Parameter(Mandatory = $true)][string]$HookPath,
        [Parameter(Mandatory = $true)][string]$InputText
    )

    $powerShellPath = [string](Get-Command powershell -ErrorAction Stop).Source
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + (ConvertTo-FactoryWindowsArgument -Value $HookPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start UTF-8 hook fixture." }
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "UTF-8 hook fixture failed with exit $($process.ExitCode): $stderr $stdout"
        }
    } finally {
        $process.Dispose()
    }
}

function New-FactoryTestTask {
    param([string]$Id, [string]$Title, [string]$Now)
    return [pscustomobject]@{
        id = $Id
        url = $null
        source = $null
        title = $Title
        brief = "Test worker launch behavior."
        acceptanceCriteria = @("launch behavior is verified")
        sourceNotes = @()
        startMode = "auto"
        status = "queued"
        attempts = 0
        attemptPrepared = $false
        launchStartedAt = $null
        launchCompletedAt = $null
        launchFailedAt = $null
        launchProcessId = $null
        launchProcessStartTimeUtc = $null
        agentId = $null
        backgroundSession = $null
        branch = $null
        commit = $null
        worktree = $null
        plan = $null
        workerResult = $null
        review = $null
        approval = $null
        syncPreparation = $null
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
    Assert-True (@($bundleManifest.files) -contains "factory") "The plugin manifest omits the Bash-compatible factory launcher."
    $bashLauncher = Get-Content -LiteralPath (Join-Path $pluginRoot "factory") -Raw
    Assert-True ($bashLauncher.StartsWith("#!/usr/bin/env bash")) "The cross-shell factory launcher is not a Bash script."
    Assert-True ($bashLauncher.Contains('factory.ps1')) "The cross-shell factory launcher does not delegate to the PowerShell entry point."
    Assert-True ($bashLauncher.Contains('command -v pwsh.exe')) "The cross-shell factory launcher does not prefer PowerShell 7 on Windows."
    Assert-True ($bashLauncher.Contains('command -v wslpath')) "The cross-shell factory launcher does not translate WSL paths for Windows PowerShell."
    Assert-True (@($bundleManifest.files) -contains "scripts/approve-direct.ps1") "The plugin manifest omits native direct approval."
    Assert-True (@($bundleManifest.files) -contains "scripts/run-pipeline-check-set.ps1") "The plugin manifest omits the parallel pipeline check runner."
    Assert-True (@($bundleManifest.files) -contains "scripts/codex-runtime.ps1") "The plugin manifest omits the Codex worker adapter."
    Assert-True (@($bundleManifest.files) -contains "scripts/codex-orchestrator.ps1") "The plugin manifest omits the Codex orchestrator adapter."
    Assert-True (@($bundleManifest.files) -contains ".codex-plugin/plugin.json") "The bundle manifest omits the Codex plugin manifest."
    Assert-True (@($bundleManifest.files) -contains "skills/factory/SKILL.md") "The bundle manifest omits the Codex factory skill."
    Assert-True (@($bundleManifest.files) -contains "scripts/factory-preview.ps1") "The plugin manifest omits browser preview lifecycle management."
    Assert-True (@($bundleManifest.files) -contains "scripts/test-lease.ps1") "The plugin manifest omits the serialized test-lane lease."
    Assert-True (@($bundleManifest.files) -contains "scripts/wait-factory.ps1") "The plugin manifest omits the native operator wait command."
    Assert-True (@($bundleManifest.files) -contains "scripts/migrate-runtime.ps1") "The plugin manifest omits safe runtime migration."
    Assert-True (Test-Path -LiteralPath (Join-Path $pluginRoot "AGENTS.md")) "The repository omits the Codex runtime-cleanup guard."
    Assert-True (Test-Path -LiteralPath (Join-Path $pluginRoot "CLAUDE.md")) "The repository omits the Claude runtime-cleanup guard."

    $publicSkill = Get-Content -LiteralPath (Join-Path $pluginRoot "standalone\.claude\skills\factory\SKILL.md") -Raw
    Assert-True ($publicSkill -match '(?m)^name: factory\s*$') "The /factory standalone skill is missing or misnamed."
    Assert-True (-not $publicSkill.Contains("Skill(factory:tick)")) "The public skill still delegates approved publication to an AI tick."
    Assert-True ($publicSkill.Contains("factory-scheduler.ps1")) "The public skill does not use the native scheduler."
    Assert-True ($publicSkill.Contains("record-review.ps1")) "The public skill does not persist a formal review plan."
    Assert-True ($publicSkill.Contains("prepare-intake.ps1")) "The public skill does not use native URL preparation."
    Assert-True ($publicSkill.Contains("enqueue-task.ps1")) "The public skill still owns queue mutation."
    Assert-True (-not $publicSkill.Contains('Write state atomically beside `statePath`')) "The public skill still tells AI to edit queue state directly."
    Assert-True ($publicSkill.Contains("!factory add --file")) "The public skill does not advertise source-neutral native intake."
    Assert-True ($publicSkill.Contains("!factory new [text]")) "The public skill does not advertise native local task intake."
    Assert-True ($publicSkill.Contains('### `new [--auto] [text]`')) "The public skill does not document native local task intake."
    Assert-True ($publicSkill.Contains('pass the complete text verbatim')) "The public skill may drop a local task title during native handoff."
    Assert-True ($publicSkill.Contains('Bash-compatible `factory` launcher')) "The public skill advertises direct shell mode without documenting its launcher."
    Assert-True ($publicSkill.Contains('Source: local / SOURCE_ID')) "The public skill does not distinguish local task identity in status output."
    Assert-True (-not $publicSkill.Contains("CronCreate")) "The public skill still provisions an AI cron scheduler."
    Assert-True ($publicSkill.Contains("conversationLanguage")) "The public skill does not honor the configured conversation language."
    Assert-True ($publicSkill.Contains('argument-hint: "help | <command>"')) "The public skill still has an overflowing argument hint."
    Assert-True ($publicSkill.Contains('### `help [command]`')) "The public skill does not expose factory help."
    Assert-True ($publicSkill.Contains('Details: /factory help <command>')) "Factory help does not advertise command-specific help."
    Assert-True ($publicSkill.Contains('!factory reject <id>')) "Factory help does not advertise the native reject path."
    Assert-True ($publicSkill.Contains('!factory concurrency [N]')) "Factory help does not advertise native concurrency control."
    Assert-True ($publicSkill.Contains('!factory go <id> [--direct]')) "Factory help does not advertise direct approval."
    Assert-True ($publicSkill.Contains('!factory preview <id>')) "Factory help does not advertise native browser preview."
    Assert-True ($publicSkill.Contains('!factory rotate')) "Factory help does not advertise safe orchestrator rotation."
    Assert-True ($publicSkill.Contains('### `rotate`')) "The public skill does not define orchestrator rotation semantics."
    Assert-True ($publicSkill.Contains('### `go <task-id> [--direct]`')) "The public skill does not document direct approval safeguards."
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
    Assert-True ($workerAgentSource.Contains("Run targeted tests freely while coding")) "The Claude worker contract serializes targeted coding tests."
    Assert-True ($workerAgentSource.Contains("testLeaseScript")) "The Claude worker contract omits the full-suite lease."
    $codexWorkerSource = Get-Content -LiteralPath (Join-Path $pluginRoot "resources\codex-worker-instructions.md") -Raw
    Assert-True ($codexWorkerSource.Contains("Run targeted tests freely while coding")) "The Codex worker contract serializes targeted coding tests."
    Assert-True ($codexWorkerSource.Contains("testLeaseScript")) "The Codex worker contract omits the full-suite lease."

    $launcherSource = Get-Content -LiteralPath (Join-Path $pluginRoot "start-factory.ps1") -Raw
    Assert-True ($launcherSource.Contains('[string]$Repository = (Get-Location).Path')) "Launcher does not default to the current directory."
    Assert-True ($launcherSource.Contains('[string]$Name = "Claude Factory Orchestrator"')) "Launcher does not use the orchestrator display name by default."
    Assert-True ($launcherSource.Contains('"--name", $Name')) "Launcher does not set the Claude session display name."
    Assert-True ($launcherSource.Contains('"--add-dir", $standaloneRoot')) "Launcher does not load the /factory standalone skill."
    Assert-True ($launcherSource.Contains('"--session-id", $newSessionId')) "Launcher does not assign a durable orchestrator session ID."
    Assert-True ($launcherSource.Contains('@("--resume", $storedSessionId)')) "Launcher does not resume the stored orchestrator conversation."
    Assert-True ($launcherSource.Contains('"-Action", "start"')) "Launcher does not start the native scheduler."
    $tickSkillSource = Get-Content -LiteralPath (Join-Path $pluginRoot "skills\tick\SKILL.md") -Raw
    Assert-True (-not $tickSkillSource.Contains("CronCreate")) "The internal tick still owns an AI cron scheduler."
    Assert-True ($tickSkillSource.Contains("factory-scheduler.ps1")) "The integration tick does not return capacity to the native scheduler."
    Assert-True (-not $tickSkillSource.Contains("Resolve only obvious mechanical conflicts")) "The legacy tick still asks AI to resolve integration conflicts."
    Assert-True ($launcherSource.Contains('& $ClaudeCommand attach $backgroundId')) "Launcher does not attach an existing background orchestrator."
    Assert-True ($launcherSource.Contains('Start-FactoryCodexOrchestrator')) "Launcher cannot start a Codex orchestrator."
    Assert-True ($launcherSource.Contains('$selectedAgent = if ($Agent) { $Agent } else { "claude" }')) "Launcher does not default the full runtime to Claude."
    Assert-True ($launcherSource.Contains('Get-FactoryPendingOrchestratorRotation')) "Launcher does not consume pending orchestrator rotation."
    Assert-True ($launcherSource.Contains('Complete-FactoryOrchestratorRotation')) "Launcher does not finalize orchestrator rotation after assigning a new session."

    $readableLocalSession = Get-FactoryWorkerSessionName -TaskId "local:20260816-210251-fe35a8dc" -Title "Fix the profile export"
    Assert-Equal "factory-local-fe35a8dc-fix-the-profile-export" $readableLocalSession "Local session name is not readable."
    Assert-True ($readableLocalSession.Length -le 64) "Readable local session name exceeds the CLI limit."
    $unicodeLocalTitle = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JjRgdC/0YDQsNCy0LjRgtGMINGN0LrRgdC/0L7RgNGCINC/0YDQvtGE0LjQu9GP"))
    $unicodeLocalSlug = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0LjRgdC/0YDQsNCy0LjRgtGMLdGN0LrRgdC/0L7RgNGCLdC/0YDQvtGE0LjQu9GP"))
    $unicodeLocalSession = Get-FactoryWorkerSessionName -TaskId "local:20260816-210251-fe35a8dc" -Title $unicodeLocalTitle
    Assert-True ($unicodeLocalSession.Contains($unicodeLocalSlug)) "Local session name discarded a Unicode title."

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
    Assert-True ($workerLauncherSource.Contains("Sync-FactoryWorktreeDependencies")) "Worker worktree creation does not align dependencies before launch."
    Assert-True (-not $workerLauncherSource.Contains("Get-FileHash")) "Worker launcher still depends on ambient PowerShell utility modules for hashing."
    Assert-True ((Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\worker-git-guard.ps1") -Raw).Contains("exit 2")) "Worker Git guard does not fail closed."

    $cleanupSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\cleanup-task.ps1") -Raw
    Assert-True ($cleanupSource.Contains("core.longpaths=true")) "Task cleanup does not enable Git long-path support."
    Assert-True ($cleanupSource.Contains("Close-FactoryTaskWorkerSessions")) "Task cleanup does not close the selected worker runtime session."
    Assert-True ($publicSkill.Contains("cleanup <task-id>")) "The public skill does not expose per-task cleanup."
    $rejectSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\reject-task.ps1") -Raw
    Assert-True ($rejectSource.Contains("worktree remove --force")) "Task rejection does not remove abandoned worktrees."
    Assert-True ($publicSkill.Contains('reject <task-id> [reason] [--yes|--keep]')) "The public skill does not expose final discard semantics."
    Assert-True ($publicSkill.Contains('do not substitute')) "The public skill does not distinguish reject from cleanup."
    $taskActionSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\task-action.ps1") -Raw
    Assert-True ($taskActionSource.Contains("State-only rejection now requires")) "Legacy task-action reject still bypasses final discard semantics."
    Assert-True ($taskActionSource.Contains("Assert-FactoryIntegrationPlan")) "Native go does not validate the formal integration plan."
    Assert-True ($taskActionSource.Contains('"operator-direct"')) "Native go does not audit direct approval mode."
    $directApprovalSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\approve-direct.ps1") -Raw
    Assert-True ($directApprovalSource.Contains('"-Mode", "operator-direct"')) "Direct approval does not use the trusted native review mode."
    $nativeCliSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\factory-cli.ps1") -Raw
    Assert-True ($nativeCliSource.Contains("Publication runs asynchronously; monitor: factory inspect")) "Native go does not explain how to monitor asynchronous publication."
    $integrationSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\integrate-task.ps1") -Raw
    Assert-True ($integrationSource.Contains('"merge", "--no-ff", "--no-edit", "-F", $messagePath, $Commit')) "Native integration does not merge the immutable approved SHA with a file-backed message."
    Assert-True ($integrationSource.Contains('New-Object Text.UTF8Encoding($false)')) "Pipeline merge messages are not written as UTF-8 without a BOM."
    Assert-True (-not $integrationSource.Contains('"merge", "--no-ff", "--no-edit", "-m"')) "Pipeline merge message text is exposed through native argv."
    Assert-True ($integrationSource.Contains('"push", $remote, "HEAD:$developmentBranch"')) "Native integration does not use an explicit development refspec."
    Assert-True (-not $integrationSource.Contains("--force")) "Native integration contains a force operation."
    Assert-True ($integrationSource.Contains('"-Phase", "integration"')) "Native publication does not acquire the priority test lease."
    Assert-True ([regex]::Matches($integrationSource, 'Sync-FactoryWorktreeDependencies').Count -ge 3) "Pipeline reset and merged candidates do not align their dependencies."
    $syncSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\sync-task.ps1") -Raw
    Assert-True ($syncSource.Contains("rebase --onto")) "Task sync does not rebase the task commit."
    Assert-True ($syncSource.Contains("Sync-FactoryWorktreeDependencies")) "Task sync does not align dependencies after rebase."
    $createWorktreeSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\create-worktree.ps1") -Raw
    Assert-True ($createWorktreeSource.Contains("Sync-FactoryWorktreeDependencies")) "Hook-created worktrees do not align dependencies."
    Assert-True ($publicSkill.Contains("sync <task-id>")) "The public skill does not expose task sync."
    Assert-True ($publicSkill.Contains("release <task-id>")) "The public skill does not expose stale-session release."
    Assert-True ($publicSkill.Contains("queues a new attempt")) "The public skill still describes rework as an undelivered chat continuation."
    $commonSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\factory-common.ps1") -Raw
    Assert-True ($commonSource.Contains("[IO.File]::Replace")) "Factory JSON writes do not use atomic replacement."
    Assert-True ($commonSource.Contains("RetryCount")) "Factory JSON reads do not retry transient replacement races."

    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $laravelInferenceRoot = Join-Path $testRoot "laravel-inference"
    New-Item -ItemType Directory -Path (Join-Path $laravelInferenceRoot "vendor\bin") -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $laravelInferenceRoot "vendor\bin\pint") -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $laravelInferenceRoot "artisan") -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $laravelInferenceRoot "composer.json") -Force | Out-Null
    $laravelInferredCommands = @(Get-FactoryInferredReviewCommands -RepositoryRoot $laravelInferenceRoot)
    Assert-Equal "composer install --no-interaction --no-progress" ([string]$laravelInferredCommands[0]) "Laravel inference did not install Composer dependencies first."
    Assert-True ($laravelInferredCommands -contains "vendor/bin/pint --test") "Laravel inference omitted Pint check mode."
    $inferredParallelCommand = @($laravelInferredCommands | Where-Object { $_ -like "php artisan test --parallel --processes=*" })[0]
    Assert-True ([bool]$inferredParallelCommand) "Laravel inference did not emit an explicit bounded parallel full suite."
    $inferredProcesses = 0
    [void][int]::TryParse(($inferredParallelCommand -replace '^.*--processes=', ''), [ref]$inferredProcesses)
    Assert-True ($inferredProcesses -ge 1 -and $inferredProcesses -le 5) "Laravel inference emitted an unsafe process count: $inferredProcesses."

    $verbatimCommand = "  php artisan test  "
    $resolvedVerbatimCommands = @(Resolve-FactoryReviewCommands -ConfigValue @($verbatimCommand))
    Assert-Equal $verbatimCommand ([string]$resolvedVerbatimCommands[0]) "A configured check command was not preserved byte-for-byte."
    Assert-True (-not ([string]$resolvedVerbatimCommands[0]).Contains("--parallel")) "A configured single-process test command was rewritten."

    $dependencyRoot = Join-Path $testRoot "dependency-sync"
    New-Item -ItemType Directory -Path $dependencyRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $dependencyRoot "composer.json"), '{"require":{"example/package":"1.0.0"}}', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $dependencyRoot "composer.lock"), '{"packages":[{"name":"example/package","version":"1.0.0"}],"packages-dev":[]}', (New-Object Text.UTF8Encoding($false)))
    $dependencyInvocations = New-Object Collections.Generic.List[string]
    $dependencyInvoker = {
        param([string]$Command, [object[]]$Arguments, [string]$WorkingDirectory)
        $dependencyInvocations.Add("$Command $($Arguments -join ' ')")
        $installedDirectory = Join-Path $WorkingDirectory "vendor\composer"
        New-Item -ItemType Directory -Path $installedDirectory -Force | Out-Null
        $lock = Read-FactoryJson -Path (Join-Path $WorkingDirectory "composer.lock")
        Write-FactoryJsonAtomic -Path (Join-Path $installedDirectory "installed.json") -Value ([pscustomobject]@{ packages = @($lock.packages) })
        return [pscustomobject]@{ exitCode = 0; output = "installed" }
    }
    $dependencyInstall = @(Sync-FactoryWorktreeDependencies -Worktree $dependencyRoot -Invoker $dependencyInvoker)
    Assert-Equal 1 $dependencyInstall.Count "A stale Composer worktree did not install dependencies."
    Assert-Equal "composer install --no-interaction --no-progress" ([string]$dependencyInvocations[0]) "Composer dependency installation used the wrong command."
    $null = @(Sync-FactoryWorktreeDependencies -Worktree $dependencyRoot -Invoker $dependencyInvoker)
    Assert-Equal 1 $dependencyInvocations.Count "An unchanged Composer worktree reinstalled dependencies."
    [IO.File]::WriteAllText((Join-Path $dependencyRoot "composer.lock"), '{"packages":[{"name":"example/package","version":"2.0.0"}],"packages-dev":[]}', (New-Object Text.UTF8Encoding($false)))
    $liveDependencyTask = [pscustomobject]@{
        id = "live-dependency-task"
        backgroundSession = [pscustomobject]@{ id = "live"; state = "working" }
    }
    $liveDependencyRefused = $false
    try {
        $null = @(Sync-FactoryWorktreeDependencies -Worktree $dependencyRoot -Task $liveDependencyTask -Invoker $dependencyInvoker)
    } catch {
        $liveDependencyRefused = $_.Exception.Message -match "live worker session"
    }
    Assert-True $liveDependencyRefused "A batch-style dependency install was allowed in a live worker worktree."
    Assert-Equal 1 $dependencyInvocations.Count "A refused live-worktree install still invoked Composer."

    $npmDependencyRoot = Join-Path $testRoot "npm-dependency-sync"
    New-Item -ItemType Directory -Path $npmDependencyRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $npmDependencyRoot "package-lock.json"), '{"name":"fixture","lockfileVersion":3,"packages":{}}', (New-Object Text.UTF8Encoding($false)))
    $npmInvocations = New-Object Collections.Generic.List[string]
    $npmInvoker = {
        param([string]$Command, [object[]]$Arguments, [string]$WorkingDirectory)
        $npmInvocations.Add("$Command $($Arguments -join ' ')")
        New-Item -ItemType Directory -Path (Join-Path $WorkingDirectory "node_modules") -Force | Out-Null
        return [pscustomobject]@{ exitCode = 0; output = "installed" }
    }
    $null = @(Sync-FactoryWorktreeDependencies -Worktree $npmDependencyRoot -Invoker $npmInvoker)
    $null = @(Sync-FactoryWorktreeDependencies -Worktree $npmDependencyRoot -Invoker $npmInvoker)
    Assert-Equal 1 $npmInvocations.Count "An npm worktree did not use its lock stamp to skip a no-op install."
    Assert-Equal "npm ci" ([string]$npmInvocations[0]) "npm dependency installation did not use npm ci."
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
    [IO.File]::WriteAllText((Join-Path $repository ".gitignore"), ".env`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText(
        (Join-Path $repository ".env"),
        "DB_HOST=127.0.0.1`nDB_PORT=5432`nDB_USERNAME=factory_test`nDB_PASSWORD=fake-secret`nDB_DATABASE=shared_test`n",
        (New-Object Text.UTF8Encoding($false))
    )
    & git -C $repository add README.md .gitignore
    & git -C $repository commit -m "initial" 1> $null
    & git -C $repository branch -M develop
    & git -C $repository branch master
    & git -C $repository remote add origin $remote
    & git -C $repository push -u origin develop 1> $null
    & git -C $repository push -u origin master 1> $null

    $fakeSessionId = "11111111-2222-4333-8444-555555555555"
    Add-Type -Path (Join-Path $PSScriptRoot "FakeClaude.cs") -OutputAssembly $fakeClaude -OutputType ConsoleApplication
    Add-Type -Path (Join-Path $PSScriptRoot "FakeCodex.cs") -OutputAssembly $fakeCodex -OutputType ConsoleApplication
    Add-Type -Path (Join-Path $PSScriptRoot "FakePsql.cs") -OutputAssembly $fakePsql -OutputType ConsoleApplication

    $unicodeFixture = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0KLQtdGB0YIg0LrQuNGA0LjQu9C70LjRhtGLIOKAlCDQs9C+0YLQvtCy0L4="))
    $utf8Probe = Invoke-FactoryNativeProcess -Command $fakeClaude -Arguments @("utf8-probe")
    Assert-Equal 0 ([int]$utf8Probe.exitCode) "UTF-8 native-process probe failed."
    Assert-Equal $unicodeFixture ([string]$utf8Probe.stdout) "Native process output was decoded through an OEM code page."

    $markerResultNotes = "The operator asked me to emit FACTORY_RESULT again; braces in prose are safe: {example}."
    $markerResultMessage = "Preamble mentioning FACTORY_RESULT is not the envelope.`nFACTORY_RESULT`n" + ([ordered]@{
        status = "completed"
        taskId = "marker-result-task"
        branch = "factory-worker/marker-result-task-a1"
        commit = "0123456789012345678901234567890123456789"
        worktree = "C:\fixture"
        notes = $markerResultNotes
    } | ConvertTo-Json -Depth 10)
    $markerResult = ConvertFrom-FactoryWorkerMarkerMessage -Message $markerResultMessage
    Assert-Equal "result" ([string]$markerResult.kind) "A result whose notes mention FACTORY_RESULT was misclassified."
    Assert-Equal $markerResultNotes ([string]$markerResult.payload.notes) "The result payload containing FACTORY_RESULT was not parsed intact."

    $markerPlanUnderstanding = "The implementation will preserve the FACTORY_PLAN contract."
    $markerPlanMessage = "FACTORY_PLAN`n" + ([ordered]@{
        taskId = "marker-plan-task"
        understanding = $markerPlanUnderstanding
        plan = @("Implement", "Verify")
        questions = @()
        readyToImplement = $true
    } | ConvertTo-Json -Depth 10)
    $markerPlan = ConvertFrom-FactoryWorkerMarkerMessage -Message $markerPlanMessage
    Assert-Equal "plan" ([string]$markerPlan.kind) "A plan whose prose mentions FACTORY_PLAN was misclassified."
    Assert-Equal $markerPlanUnderstanding ([string]$markerPlan.payload.understanding) "The plan payload containing FACTORY_PLAN was not parsed intact."

    $invalidMarker = ConvertFrom-FactoryWorkerMarkerMessage -Message "FACTORY_RESULT`n{`"status`":`"completed`", broken}"
    Assert-Equal "invalid-marker" ([string]$invalidMarker.kind) "Malformed marker JSON was treated as an ordinary message."
    Assert-True ([string]$invalidMarker.payload.error -match "invalid JSON") "Malformed marker classification omitted the parse reason."

    $asanaUrl = Resolve-FactoryAsanaTaskUrl -Url "https://app.asana.com/1/14748072439266/project/1215506997644941/task/1217516118946154?focus=true"
    Assert-Equal "1217516118946154" ([string]$asanaUrl.taskId) "Asana URL parser extracted the wrong task ID."
    Assert-Equal "https://app.asana.com/0/0/1217516118946154" ([string]$asanaUrl.canonicalUrl) "Asana URL parser did not canonicalize the URL."
    $invalidAsanaHostRejected = $false
    try { $null = Resolve-FactoryAsanaTaskUrl -Url "https://example.com/task/1217516118946154" } catch { $invalidAsanaHostRejected = $true }
    Assert-True $invalidAsanaHostRejected "Asana URL parser accepted an unrelated host."
    Assert-Equal "1217516118946154" (ConvertTo-FactoryTaskArtifactName -TaskId "1217516118946154") "Numeric Asana artifact names changed."
    $adapterArtifactName = ConvertTo-FactoryTaskArtifactName -TaskId "linear:ENG-123"
    Assert-True ($adapterArtifactName -match '^linear-eng-123-[0-9a-f]{12}$') "Source-qualified task ID did not receive a safe hashed artifact name."
    Assert-True ($adapterArtifactName -ne (ConvertTo-FactoryTaskArtifactName -TaskId "linear/ENG-123")) "Distinct source task IDs collided after artifact-name normalization."

    $env:CLAUDE_FACTORY_HOME = $runtime
    $env:CLAUDE_FACTORY_CODEX_SKILL_HOME = Join-Path $testRoot "codex-skills"
    $env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE = Join-Path $testRoot "agent-session-events.tsv"
    $env:CLAUDE_FACTORY_TEST_PSQL_REGISTRY_FILE = Join-Path $testRoot "test-database-events.tsv"
    $env:CLAUDE_FACTORY_TEST_PSQL_AUDIT_FILE = Join-Path $testRoot "test-database-audit.tsv"
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository -Initialize) |
        ConvertFrom-Json

    $env:CLAUDE_FACTORY_LOCK_SLOW_MILLISECONDS = "1"
    try {
        $diagnosticMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
        $lockOwnerPath = Join-Path ([string]$context.projectData) "factory-lock-owner.json"
        Assert-True (Test-Path -LiteralPath $lockOwnerPath -PathType Leaf) "Factory mutex did not publish its current owner."
        Start-Sleep -Milliseconds 20
        Exit-FactoryMutex -Mutex $diagnosticMutex
        $diagnosticMutex = $null
        Assert-True (-not (Test-Path -LiteralPath $lockOwnerPath)) "Factory mutex retained a stale owner record after release."
        $lockDiagnosticLog = Join-Path ([string]$context.projectData) "factory-locks.jsonl"
        Assert-True ((Test-Path -LiteralPath $lockDiagnosticLog) -and (Get-Content -LiteralPath $lockDiagnosticLog -Raw).Contains('"event":"released"')) "Factory mutex omitted its slow-hold diagnostic."

        $holderMarker = Join-Path $testRoot "mutex-holder-ready.marker"
        $holderJob = Start-Job -ScriptBlock {
            param($CommonScript, $RuntimeHome, $ProjectKey, $MarkerPath)
            $env:CLAUDE_FACTORY_HOME = $RuntimeHome
            . $CommonScript
            $heldMutex = $null
            try {
                $heldMutex = Enter-FactoryMutex -ProjectKey $ProjectKey
                [IO.File]::WriteAllText($MarkerPath, "ready", (New-Object Text.UTF8Encoding($false)))
                Start-Sleep -Seconds 2
            } finally {
                Exit-FactoryMutex -Mutex $heldMutex
            }
        } -ArgumentList (Join-Path $pluginRoot "scripts\factory-common.ps1"), $runtime, ([string]$context.projectKey), $holderMarker
        try {
            $holderDeadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not (Test-Path -LiteralPath $holderMarker) -and [DateTime]::UtcNow -lt $holderDeadline) {
                Start-Sleep -Milliseconds 50
            }
            Assert-True (Test-Path -LiteralPath $holderMarker) "Synthetic mutex holder did not acquire the factory lock."
            $timeoutAttributed = $false
            try {
                $unexpectedMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey) -TimeoutMilliseconds 100
                Exit-FactoryMutex -Mutex $unexpectedMutex
            } catch {
                $timeoutAttributed = $_.Exception.Message -match "Current holder: PID" -and $_.Exception.Message -match "acquired"
            }
            Assert-True $timeoutAttributed "Factory mutex timeout did not identify its current owner."
            Assert-True ((Get-Content -LiteralPath $lockDiagnosticLog -Raw).Contains('"event":"timeout"')) "Factory mutex timeout was not appended to its audit log."
        } finally {
            $null = Wait-Job -Job $holderJob -Timeout 5
            if ($holderJob.State -eq "Running") { Stop-Job -Job $holderJob }
            $null = Receive-Job -Job $holderJob -ErrorAction SilentlyContinue
            Remove-Job -Job $holderJob -Force
        }
    } finally {
        if ($null -ne $diagnosticMutex) { Exit-FactoryMutex -Mutex $diagnosticMutex }
        Remove-Item Env:\CLAUDE_FACTORY_LOCK_SLOW_MILLISECONDS -ErrorAction SilentlyContinue
    }

    $savedFactoryHome = [string]$env:CLAUDE_FACTORY_HOME
    $savedLocalAppData = [string]$env:LOCALAPPDATA
    try {
        Remove-Item Env:\CLAUDE_FACTORY_HOME -ErrorAction SilentlyContinue
        $env:LOCALAPPDATA = Join-Path $testRoot "synthetic-local-app-data"
        $freshDefaultContext = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository) | ConvertFrom-Json
        Assert-Equal "external-default" ([string]$freshDefaultContext.runtimeSource) "A fresh factory did not default outside the plugin checkout."
        Assert-True ([string]$freshDefaultContext.runtimeHome -eq [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "ClaudeFactory"))) "Fresh runtime default did not use LocalAppData."
    } finally {
        $env:CLAUDE_FACTORY_HOME = $savedFactoryHome
        $env:LOCALAPPDATA = $savedLocalAppData
    }

    $migratedRuntimeHome = Join-Path $testRoot "migrated-runtime"
    $runtimeSessionMutex = New-Object Threading.Mutex($false, "Local\ClaudeFactorySession-$([string]$context.projectKey)")
    $ownsRuntimeSessionMutex = $false
    try {
        try {
            $ownsRuntimeSessionMutex = $runtimeSessionMutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $ownsRuntimeSessionMutex = $true
        }
        Assert-True $ownsRuntimeSessionMutex "Synthetic runtime migration test could not own the orchestrator mutex."
        $liveRuntimeMigration = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $pluginRoot "scripts\migrate-runtime.ps1"),
            "-Repository", $repository, "-RuntimeHome", $runtime, "-DestinationRuntimeHome", $migratedRuntimeHome,
            "-ClaudeCommand", $fakeClaude
        )
        Assert-True ([int]$liveRuntimeMigration.exitCode -ne 0 -and [string]$liveRuntimeMigration.output -match "Exit the active factory orchestrator") "Runtime migration did not refuse an active orchestrator."
    } finally {
        if ($ownsRuntimeSessionMutex) { $runtimeSessionMutex.ReleaseMutex() }
        $runtimeSessionMutex.Dispose()
    }
    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = $repository
    $env:CLAUDE_FACTORY_TEST_ORCHESTRATOR_SESSION_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    try {
        $listedRuntimeMigration = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $pluginRoot "scripts\migrate-runtime.ps1"),
            "-Repository", $repository, "-RuntimeHome", $runtime, "-DestinationRuntimeHome", $migratedRuntimeHome,
            "-ClaudeCommand", $fakeClaude
        )
        Assert-True (
            [int]$listedRuntimeMigration.exitCode -ne 0 -and
            [string]$listedRuntimeMigration.output -match "orch1234" -and
            [string]$listedRuntimeMigration.output -match "claude stop orch1234"
        ) "Runtime migration did not identify a live Claude orchestrator and its stop command."
    } finally {
        Remove-Item Env:\CLAUDE_FACTORY_TEST_ORCHESTRATOR_SESSION_ID -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_CWD -ErrorAction SilentlyContinue
    }
    $runtimeMigration = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\migrate-runtime.ps1") `
        -Repository $repository -RuntimeHome $runtime -DestinationRuntimeHome $migratedRuntimeHome -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-True ([bool]$runtimeMigration.migrated -and [bool]$runtimeMigration.verified) "Synthetic runtime migration did not copy and verify the project."
    Assert-True ([bool]$runtimeMigration.sourceRetained -and (Test-Path -LiteralPath ([string]$context.projectData))) "Runtime migration removed its source copy."
    Assert-True (Test-Path -LiteralPath (Join-Path ([string]$runtimeMigration.destination) "runtime-migration.json")) "Runtime migration omitted its receipt."
    Assert-Equal 8 ((Read-FactoryJson -Path $context.configPath).version) "Config migration failed."
    Assert-Equal 9 ((Read-FactoryJson -Path $context.statePath).version) "State migration failed."
    $initialFactoryConfig = Read-FactoryJson -Path $context.configPath
    Assert-Equal 8 ([int]$initialFactoryConfig.codingConcurrency) "A fresh factory did not default to eight coding slots."
    Assert-True ($null -eq $initialFactoryConfig.PSObject.Properties["concurrency"]) "A fresh config still writes the deprecated concurrency alias."
    $launcherTestConfig = Read-FactoryJson -Path $context.configPath
    $launcherTestConfig.nativeScheduler.startWithOrchestrator = $false
    $launcherTestConfig.testLease.heartbeatSeconds = 1
    Write-FactoryJsonAtomic -Path $context.configPath -Value $launcherTestConfig

    $testLeaseScript = Join-Path $pluginRoot "scripts\test-lease.ps1"
    $dateTimeHeartbeat = [DateTime]::SpecifyKind([DateTime]::UtcNow.AddMinutes(-2), [DateTimeKind]::Utc)
    $parsedDateTimeHeartbeat = ConvertFrom-FactoryRoundtripTimestamp -Value $dateTimeHeartbeat
    Assert-True ([bool]$parsedDateTimeHeartbeat.success) "A DateTime-valued lease heartbeat was not accepted."
    Assert-True ([Math]::Abs(([DateTime]$parsedDateTimeHeartbeat.value - $dateTimeHeartbeat).TotalMilliseconds) -lt 1) "A DateTime-valued lease heartbeat changed during normalization."

    $cultureLeaseTimestamp = [DateTime]::UtcNow.AddMinutes(-2).ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    $cultureAges = New-Object Collections.Generic.List[int]
    $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        foreach ($cultureName in @("en-GB", "en-US", "ru-RU")) {
            [Threading.Thread]::CurrentThread.CurrentCulture = New-Object Globalization.CultureInfo($cultureName)
            Write-FactoryJsonAtomic -Path ([string]$context.testLeasePath) -Value ([pscustomobject]@{
                version = 1
                holder = [pscustomobject]@{
                    taskId = "culture-holder"; phase = "review"; pid = $PID
                    acquiredAt = $cultureLeaseTimestamp; heartbeatAt = $cultureLeaseTimestamp
                    priority = 10; token = "culture-token"
                }
                queue = @(); lastReclaim = $null; updatedAt = Get-FactoryUtcTimestamp
            })
            $cultureStatus = (& $testLeaseScript -Action status -Repository $repository) | ConvertFrom-Json
            $cultureAges.Add([int]$cultureStatus.holderAgeSeconds)
        }
    } finally {
        [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    }
    Assert-True ((($cultureAges | Measure-Object -Maximum).Maximum - ($cultureAges | Measure-Object -Minimum).Minimum) -le 2) "Lease age changed with the current culture: $($cultureAges -join ', ')."

    Write-FactoryJsonAtomic -Path ([string]$context.testLeasePath) -Value ([pscustomobject]@{
        version = 1
        holder = [pscustomobject]@{
            taskId = "unreadable-holder"; phase = "review"; pid = 999999
            acquiredAt = Get-FactoryUtcTimestamp; heartbeatAt = "not-a-timestamp"
            priority = 10; token = "unreadable-token"
        }
        queue = @(); lastReclaim = $null; updatedAt = Get-FactoryUtcTimestamp
    })
    $unreadableStatus = (& $testLeaseScript -Action status -Repository $repository 2>$null) | ConvertFrom-Json
    Assert-Equal $false ([bool]$unreadableStatus.heartbeatReadable) "An unreadable lease heartbeat was accepted."
    Assert-Equal $false ([bool]$unreadableStatus.stale) "An unreadable lease heartbeat failed open as stale."
    $unreadableReclaim = (& $testLeaseScript -Action reclaim -Repository $repository -TtlSeconds 1) | ConvertFrom-Json
    Assert-Equal $false ([bool]$unreadableReclaim.reclaimed) "An unreadable lease heartbeat was reclaimed."
    $unreadableDoctor = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-doctor.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $unreadableLeaseCheck = @($unreadableDoctor.checks | Where-Object { [string]$_.name -eq "testLaneLease" })[0]
    Assert-True (-not [bool]$unreadableLeaseCheck.passed -and [string]$unreadableLeaseCheck.detail -match "unreadable") "Factory doctor did not surface an unreadable lease heartbeat."

    $oldLiveTimestamp = [DateTime]::UtcNow.AddDays(-1).ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    Write-FactoryJsonAtomic -Path ([string]$context.testLeasePath) -Value ([pscustomobject]@{
        version = 1
        holder = [pscustomobject]@{
            taskId = "live-old-holder"; phase = "review"; pid = $PID
            acquiredAt = $oldLiveTimestamp; heartbeatAt = $oldLiveTimestamp
            priority = 10; token = "live-old-token"
        }
        queue = @(); lastReclaim = $null; updatedAt = Get-FactoryUtcTimestamp
    })
    $liveOldReclaim = (& $testLeaseScript -Action reclaim -Repository $repository -TtlSeconds 1) | ConvertFrom-Json
    Assert-Equal $false ([bool]$liveOldReclaim.reclaimed) "A lease owned by a live PID was reclaimed from an old timestamp."

    $freshDeadTimestamp = Get-FactoryUtcTimestamp
    Write-FactoryJsonAtomic -Path ([string]$context.testLeasePath) -Value ([pscustomobject]@{
        version = 1
        holder = [pscustomobject]@{
            taskId = "fresh-dead-holder"; phase = "integration"; pid = 999999; heartbeatPid = 999998
            acquiredAt = $freshDeadTimestamp; heartbeatAt = $freshDeadTimestamp
            priority = 100; token = "fresh-dead-token"
        }
        queue = @(); lastReclaim = $null; updatedAt = Get-FactoryUtcTimestamp
    })
    $freshDeadReclaim = (& $testLeaseScript -Action reclaim -Repository $repository -TtlSeconds 1800) | ConvertFrom-Json
    Assert-True ([bool]$freshDeadReclaim.reclaimed) "A provably dead test-lane holder waited for the full heartbeat TTL."
    Assert-True ([string]$freshDeadReclaim.abandonedHolder.reason -match "before TTL") "Early dead-holder reclaim did not explain why TTL was bypassed."

    Write-FactoryJsonAtomic -Path ([string]$context.testLeasePath) -Value ([pscustomobject]@{
        version = 1; holder = $null
        queue = @(
            [pscustomobject]@{ taskId = "dead-waiter"; phase = "review"; requestedAt = Get-FactoryUtcTimestamp; priority = 10; token = "dead-waiter-token"; waiterPid = 999999 },
            [pscustomobject]@{ taskId = "live-waiter"; phase = "review"; requestedAt = Get-FactoryUtcTimestamp; priority = 10; token = "live-waiter-token"; waiterPid = $PID }
        )
        lastReclaim = $null; updatedAt = Get-FactoryUtcTimestamp
    })
    $cleanedWaiterStatus = (& $testLeaseScript -Action status -Repository $repository) | ConvertFrom-Json
    Assert-Equal 1 ([int]$cleanedWaiterStatus.removedWaiters) "Test-lane status did not remove the phantom waiter."
    Assert-Equal 1 @($cleanedWaiterStatus.queue).Count "Test-lane status still displayed a phantom waiter."
    $persistedCleanedLease = Read-FactoryJson -Path ([string]$context.testLeasePath)
    Assert-Equal 1 @($persistedCleanedLease.queue).Count "Test-lane status did not persist waiter cleanup."
    Assert-Equal "live-waiter" ([string]$persistedCleanedLease.queue[0].taskId) "Test-lane status removed the live waiter instead of the dead one."
    Remove-Item -LiteralPath ([string]$context.testLeasePath) -Force

    $heartbeatLease = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
        -Action acquire -Repository $repository -TaskId "heartbeat-start" -Phase review -OwnerPid $PID) | ConvertFrom-Json
    $heartbeatStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript -Action status -Repository $repository) | ConvertFrom-Json
    Assert-True ([int]$heartbeatLease.heartbeatPid -gt 0 -and [bool]$heartbeatStatus.heartbeatPidAlive) "Lease acquire did not start and record a live heartbeat process."
    $heartbeatRelease = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript -Action release -Repository $repository -Token ([string]$heartbeatLease.token)) | ConvertFrom-Json
    Assert-True ([bool]$heartbeatRelease.released) "Heartbeat lease could not be released."

    $laneHolder = $null
    $ordinaryWaiter = $null
    $publicationWaiter = $null
    $ordinaryLease = $null
    $publicationLease = $null
    try {
        $laneHolder = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
            -Action acquire -Repository $repository -TaskId "lane-holder" -Phase verify -OwnerPid $PID -NoHeartbeat) |
            ConvertFrom-Json

        $ordinaryOut = Join-Path $testRoot "test-lease-ordinary.stdout.json"
        $ordinaryErr = Join-Path $testRoot "test-lease-ordinary.stderr.txt"
        $ordinaryWaiter = Start-Process -FilePath "powershell" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $testLeaseScript,
            "-Action", "acquire", "-Repository", $repository, "-TaskId", "ordinary-verification",
            "-Phase", "verify", "-OwnerPid", [string]$PID, "-NoHeartbeat"
        ) -RedirectStandardOutput $ordinaryOut -RedirectStandardError $ordinaryErr -WindowStyle Hidden -PassThru

        $ordinaryQueuedDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 100
            $laneStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript -Action status -Repository $repository) | ConvertFrom-Json
        } while (@($laneStatus.queue | Where-Object { [string]$_.taskId -eq "ordinary-verification" }).Count -eq 0 -and [DateTime]::UtcNow -lt $ordinaryQueuedDeadline)
        Assert-Equal "lane-holder" ([string]$laneStatus.holder.taskId) "The test lane did not expose its current holder."
        Assert-Equal 1 @($laneStatus.queue).Count "A second full-suite run did not wait behind the holder."

        $publicationOut = Join-Path $testRoot "test-lease-publication.stdout.json"
        $publicationErr = Join-Path $testRoot "test-lease-publication.stderr.txt"
        $publicationWaiter = Start-Process -FilePath "powershell" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $testLeaseScript,
            "-Action", "acquire", "-Repository", $repository, "-TaskId", "publication-priority",
            "-Phase", "integration", "-OwnerPid", [string]$PID, "-NoHeartbeat"
        ) -RedirectStandardOutput $publicationOut -RedirectStandardError $publicationErr -WindowStyle Hidden -PassThru

        $publicationQueuedDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 100
            $laneStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript -Action status -Repository $repository) | ConvertFrom-Json
        } while (@($laneStatus.queue).Count -lt 2 -and [DateTime]::UtcNow -lt $publicationQueuedDeadline)
        Assert-Equal 2 @($laneStatus.queue).Count "The test-lane queue did not expose both waiting full-suite runs."
        Assert-Equal "publication-priority" ([string]$laneStatus.queue[0].taskId) "Publication was not promoted ahead of ordinary verification."

        $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
            -Action release -Repository $repository -Token ([string]$laneHolder.token)) | ConvertFrom-Json
        $laneHolder = $null
        Assert-True ($publicationWaiter.WaitForExit(10000)) "The priority publication waiter did not acquire the released test lane."
        $publicationLease = (Get-Content -LiteralPath $publicationOut -Raw) | ConvertFrom-Json
        Assert-Equal 0 ([int]$publicationWaiter.ExitCode) "The priority publication waiter failed: $(Get-Content -LiteralPath $publicationErr -Raw)"
        Assert-Equal $false ([bool]$ordinaryWaiter.HasExited) "FIFO won over publication priority in the test lane."
        $publicationLaneStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript -Action status -Repository $repository) | ConvertFrom-Json
        Assert-Equal "publication-priority" ([string]$publicationLaneStatus.holder.taskId) "The priority publication waiter did not become the visible holder."

        $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
            -Action release -Repository $repository -Token ([string]$publicationLease.token)) | ConvertFrom-Json
        $publicationLease = $null
        Assert-True ($ordinaryWaiter.WaitForExit(10000)) "Ordinary verification did not acquire the lane after publication released it."
        $ordinaryLease = (Get-Content -LiteralPath $ordinaryOut -Raw) | ConvertFrom-Json
        Assert-Equal 0 ([int]$ordinaryWaiter.ExitCode) "The ordinary verification waiter failed: $(Get-Content -LiteralPath $ordinaryErr -Raw)"
    } finally {
        foreach ($leaseToRelease in @($ordinaryLease, $publicationLease, $laneHolder)) {
            if ($null -ne $leaseToRelease -and [string]$leaseToRelease.token) {
                $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
                    -Action release -Repository $repository -Token ([string]$leaseToRelease.token) 2>$null)
            }
        }
        foreach ($waiter in @($ordinaryWaiter, $publicationWaiter)) {
            if ($null -ne $waiter) {
                if (-not $waiter.HasExited) { Stop-Process -Id $waiter.Id -Force -ErrorAction SilentlyContinue }
                $waiter.Dispose()
            }
        }
    }

    $staleLease = [pscustomobject][ordered]@{
        version = 1
        holder = [pscustomobject][ordered]@{
            taskId = "abandoned-full-suite"; phase = "review"; pid = 999999
            acquiredAt = [DateTime]::UtcNow.AddMinutes(-10).ToString("o")
            heartbeatAt = [DateTime]::UtcNow.AddMinutes(-10).ToString("o")
            priority = 10; token = "abandoned-token"
        }
        queue = @()
        lastReclaim = $null
        updatedAt = Get-FactoryUtcTimestamp
    }
    Write-FactoryJsonAtomic -Path ([string]$context.testLeasePath) -Value $staleLease
    $reclaimedLease = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
        -Action reclaim -Repository $repository -TtlSeconds 1) | ConvertFrom-Json
    Assert-True ([bool]$reclaimedLease.reclaimed) "A stale test-lane holder was not reclaimed."
    $reclaimLog = Get-Content -LiteralPath (Join-Path ([string]$context.projectData) "test-lease.reclaims.jsonl") -Raw
    Assert-True ($reclaimLog.Contains('"taskId":"abandoned-full-suite"')) "The stale-lease reclaim log omitted the abandoned holder."

    $failureLease = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
        -Action acquire -Repository $repository -TaskId "finally-release" -Phase review -OwnerPid $PID -NoHeartbeat) |
        ConvertFrom-Json
    try {
        throw "Synthetic full-suite failure."
    } catch {
        Assert-True ($_.Exception.Message -match "Synthetic full-suite failure") "The release-on-failure fixture caught the wrong error."
    } finally {
        $failureRelease = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
            -Action release -Repository $repository -Token ([string]$failureLease.token)) | ConvertFrom-Json
    }
    Assert-True ([bool]$failureRelease.released) "A failing full-suite path did not release its test lease in finally."
    $freeLaneStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript -Action status -Repository $repository) | ConvertFrom-Json
    Assert-True ([bool]$freeLaneStatus.free) "The test lane remained held after failure cleanup."

    $queuedHoldState = Read-FactoryJson -Path $context.statePath
    $queuedHoldState.tasks = @(New-FactoryTestTask -Id "queued-hold-task" -Title "Hold queued work" -Now (Get-FactoryUtcTimestamp))
    $queuedHoldState.active = $true
    $queuedHoldState.paused = $true
    Write-FactoryJsonAtomic -Path $context.statePath -Value $queuedHoldState
    $queuedHeld = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") `
        -Repository $repository -Action hold -TaskId "queued-hold-task") | ConvertFrom-Json
    Assert-Equal "held" ([string]$queuedHeld.status) "A queued task could not be held before launch."
    Assert-Equal "queued" ([string]$queuedHeld.heldFromStatus) "Queued hold did not preserve its resumable state."
    $queuedReleased = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") `
        -Repository $repository -Action release -TaskId "queued-hold-task") | ConvertFrom-Json
    Assert-Equal "queued" ([string]$queuedReleased.status) "Release did not return an unstarted held task to the queue."
    Assert-Equal $true ([bool](Read-FactoryJson -Path $context.statePath).paused) "Releasing a queued task implicitly resumed the paused factory."

    $pausedConcurrency = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\set-concurrency.ps1") `
        -Repository $repository -Value 9) | ConvertFrom-Json
    Assert-Equal 8 ([int]$pausedConcurrency.previous) "The coding-concurrency fixture started from the wrong default."
    Assert-Equal 9 ([int]$pausedConcurrency.current) "Coding concurrency did not increase."
    Assert-Equal $true ([bool](Read-FactoryJson -Path $context.statePath).paused) "Increasing coding concurrency resumed a paused factory."

    $capacityConfig = Read-FactoryJson -Path $context.configPath
    $capacityConfig.codingConcurrency = 1
    Write-FactoryJsonAtomic -Path $context.configPath -Value $capacityConfig
    $capacityState = Read-FactoryJson -Path $context.statePath
    $waitingTask = New-FactoryTestTask -Id "slot-awaiting-input" -Title "Consumes a coding slot" -Now (Get-FactoryUtcTimestamp)
    $waitingTask.status = "awaiting-input"
    $waitingTask.backgroundSession = [pscustomobject]@{
        runtime = "codex"; id = "capacity-worker"; sessionId = "capacity-worker-session"
        name = "factory-slot-awaiting-input"; state = "working"; lastSeenAt = (Get-FactoryUtcTimestamp)
        processId = $PID; processStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
        transcriptPath = $null; lastMessagePath = $null; stderrPath = $null
    }
    $queuedTask = New-FactoryTestTask -Id "slot-stays-queued" -Title "Must wait for a coding slot" -Now (Get-FactoryUtcTimestamp)
    $capacityState.tasks = @($waitingTask, $queuedTask)
    $capacityState.active = $true
    $capacityState.paused = $false
    Write-FactoryJsonAtomic -Path $context.statePath -Value $capacityState
    $capacityTick = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-scheduler.ps1") `
        -Action tick -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-Equal 0 ([int]$capacityTick.launchedCount) "The scheduler exceeded codingConcurrency while a worker awaited input."
    Assert-Equal "queued" ([string](Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "slot-stays-queued").status) "The coding cap did not preserve queued work."

    $orphanLaunchState = Read-FactoryJson -Path $context.statePath
    $orphanLaunch = New-FactoryTestTask -Id "orphan-launch" -Title "Launcher exited before session creation" -Now ([DateTime]::UtcNow.AddMinutes(-10).ToString("o"))
    $orphanLaunch.status = "starting"
    $orphanLaunch.attempts = 1
    $orphanLaunch.launchStartedAt = [DateTime]::UtcNow.AddMinutes(-10).ToString("o")
    $orphanLaunch.launchProcessId = 999999
    $orphanLaunchState.tasks = @($orphanLaunch)
    $orphanLaunchState.active = $true
    $orphanLaunchState.paused = $true
    Write-FactoryJsonAtomic -Path $context.statePath -Value $orphanLaunchState
    Assert-Equal 0 (Get-FactoryLaunchedWorkerCount -State $orphanLaunchState) "A sessionless starting task permanently consumed coding capacity."
    $orphanConfig = Read-FactoryJson -Path $context.configPath
    $orphanConfig.workerLaunchTimeoutSeconds = 1
    Write-FactoryJsonAtomic -Path $context.configPath -Value $orphanConfig
    $orphanReconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") `
        -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $orphanAfter = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "orphan-launch"
    Assert-Equal "failed" ([string]$orphanAfter.status) "A stale sessionless launch was not failed by reconciliation."
    Assert-True ([string]$orphanAfter.error -match "did not record a background session") "The stale launch failure did not explain the missing session."
    Assert-True ([string]$orphanAfter.launchFailedAt -ne "") "The stale launch failure did not record its detection time."
    Assert-True (@($orphanReconcile.transitions | Where-Object { [string]$_.taskId -eq "orphan-launch" }).Count -eq 1) "The stale launch transition was not reported."
    $orphanRetry = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") `
        -Repository $repository -Action retry -TaskId "orphan-launch" -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal "queued" ([string]$orphanRetry.status) "Native retry did not requeue a failed worker launch."
    $orphanRetriedTask = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "orphan-launch"
    Assert-True ($null -eq $orphanRetriedTask.launchStartedAt -and $null -eq $orphanRetriedTask.launchFailedAt) "Retry retained stale launch ownership metadata."

    $postLaneConfig = Read-FactoryJson -Path $context.configPath
    $postLaneConfig.codingConcurrency = 8
    $postLaneConfig.workerLaunchTimeoutSeconds = 300
    Write-FactoryJsonAtomic -Path $context.configPath -Value $postLaneConfig
    $postLaneState = Read-FactoryJson -Path $context.statePath
    $postLaneState.tasks = @()
    $postLaneState.active = $false
    $postLaneState.paused = $false
    Write-FactoryJsonAtomic -Path $context.statePath -Value $postLaneState

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

    $safeLauncherProjectKey = ([string]$context.projectKey) -replace '[^A-Za-z0-9_.-]', '-'
    $liveLauncherMutex = New-Object Threading.Mutex($false, "Local\ClaudeFactorySession-$safeLauncherProjectKey")
    $ownsLiveLauncherMutex = $false
    try {
        $ownsLiveLauncherMutex = $liveLauncherMutex.WaitOne(0)
        Assert-True $ownsLiveLauncherMutex "Could not establish the live-orchestrator mutation guard fixture."
        $guardedConfig = Read-FactoryJson -Path $context.configPath
        $guardedConfig.workerAgent = "claude"
        Write-FactoryJsonAtomic -Path $context.configPath -Value $guardedConfig
        $previousGuardErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "start-factory.ps1") -Repository $repository -Agent codex -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex -RuntimeHome $runtime 2>&1)
            $guardedStartExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousGuardErrorAction
        }
        Assert-True ($guardedStartExitCode -ne 0) "Launcher ignored an already-live orchestrator lock."
        $guardedConfigAfter = Read-FactoryJson -Path $context.configPath
        Assert-Equal "claude" ([string]$guardedConfigAfter.workerAgent) "A rejected runtime switch retargeted the live factory's workers."
    } finally {
        if ($ownsLiveLauncherMutex) { try { $liveLauncherMutex.ReleaseMutex() } catch {} }
        $liveLauncherMutex.Dispose()
    }

    $cliScriptPath = Join-Path $pluginRoot "factory.ps1"
    $schedulerScript = Join-Path $pluginRoot "scripts\factory-scheduler.ps1"
    $schedulerStart = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2) | ConvertFrom-Json
    Assert-True ([bool]$schedulerStart.started) "Native scheduler did not start."
    Assert-True ([int]$schedulerStart.scheduler.pid -gt 0) "Native scheduler did not report its PID."
    $schedulerStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action status -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-True ([bool]$schedulerStatus.running) "Native scheduler status did not find the live process."
    Assert-True (Test-Path -LiteralPath ([string]$schedulerStatus.stdoutPath)) "Scheduler stdout log was not created by the transient launcher."
    Assert-True (Test-Path -LiteralPath ([string]$schedulerStatus.stderrPath)) "Scheduler stderr log was not created by the transient launcher."
    & powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action run -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2
    if ($LASTEXITCODE -ne 0) { throw "Duplicate scheduler run probe failed." }
    $schedulerAfterDuplicateRun = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action status -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-True ([bool]$schedulerAfterDuplicateRun.running) "A losing scheduler process cleared the winner's identity."
    Assert-Equal ([int]$schedulerStart.scheduler.pid) ([int]$schedulerAfterDuplicateRun.pid) "Duplicate scheduler run replaced the active process."
    $schedulerSecondStart = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2) | ConvertFrom-Json
    Assert-True ([bool]$schedulerSecondStart.alreadyRunning) "Native scheduler allowed a duplicate process."
    $schedulerStop = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-True ([bool]$schedulerStop.stopped) "Native scheduler did not stop gracefully."
    Assert-Equal $false ([bool]$schedulerStop.scheduler.paused) "Scheduler stop implicitly paused the factory."

    $pausedRestartState = Read-FactoryJson -Path $context.statePath
    $pausedRestartTask = New-FactoryTestTask -Id "paused-restart-task" -Title "Paused scheduler restart" -Now (Get-FactoryUtcTimestamp)
    $pausedRestartState.tasks = @($pausedRestartState.tasks) + @($pausedRestartTask)
    $pausedRestartState.active = $true
    $pausedRestartState.paused = $false
    Write-FactoryJsonAtomic -Path $context.statePath -Value $pausedRestartState
    $pausedFactoryResult = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action pause -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-Equal $true ([bool]$pausedFactoryResult.scheduler.paused) "Explicit pause did not suspend the factory."

    $pausedInitialStart = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2) | ConvertFrom-Json
    Assert-True ([bool]$pausedInitialStart.started) "Scheduler could not start while the factory was explicitly paused."
    Assert-True ([string]$pausedInitialStart.warning -match "factory resume") "Scheduler start did not warn that the explicit pause remained in effect."
    $pausedProcessStop = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-True ([bool]$pausedProcessStop.stopped) "Paused scheduler process did not stop."
    Assert-Equal $true ([bool]$pausedProcessStop.scheduler.paused) "Scheduler stop cleared an explicit operator pause."
    Assert-Equal $true ([bool]$pausedProcessStop.scheduler.active) "Scheduler stop changed the factory active flag."

    $pausedRestart = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2) | ConvertFrom-Json
    Assert-True ([bool]$pausedRestart.started) "Scheduler did not restart after stop."
    Assert-Equal $true ([bool]$pausedRestart.scheduler.paused) "Scheduler start cleared an explicit operator pause."
    Assert-True ([string]$pausedRestart.warning -match "factory resume") "Stopped/started scheduler did not return an explicit paused warning."
    Assert-Equal $true ([bool]$pausedRestart.scheduler.actionRequired) "Paused scheduler with queued work was not actionable in the returned object."
    Assert-Equal 1 ([int]$pausedRestart.scheduler.runnableTaskCount) "Paused scheduler status reported the wrong runnable task count."
    Assert-True ([string]$pausedRestart.scheduler.problem -match "factory resume") "Paused scheduler problem did not name the recovery command."
    $pausedRestartTaskState = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "paused-restart-task"
    Assert-Equal "queued" ([string]$pausedRestartTaskState.status) "Paused scheduler launched queued work."
    $pausedSchedulerCli = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath scheduler status -Repository $repository -ClaudeCommand $fakeClaude | Out-String)
    Assert-True ($pausedSchedulerCli.Contains("Problem:") -and $pausedSchedulerCli.Contains("factory resume")) "Factory scheduler output rendered paused runnable work as healthy. Output: $pausedSchedulerCli"
    $pausedFactoryCli = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($pausedFactoryCli.Contains("NEEDS YOUR ACTION") -and $pausedFactoryCli.Contains("SCHEDULER") -and $pausedFactoryCli.Contains("paused") -and $pausedFactoryCli.Contains("factory resume")) "Factory status did not surface paused runnable work as actionable."
    $pausedRestartFinalStop = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-Equal $true ([bool]$pausedRestartFinalStop.scheduler.paused) "Final scheduler stop changed the explicit pause state."
    $pausedRestartCleanup = Read-FactoryJson -Path $context.statePath
    $pausedRestartCleanup.tasks = @($pausedRestartCleanup.tasks | Where-Object { [string]$_.id -ne "paused-restart-task" })
    $pausedRestartCleanup.active = $false
    $pausedRestartCleanup.paused = $false
    Write-FactoryJsonAtomic -Path $context.statePath -Value $pausedRestartCleanup

    $idleHeartbeatBefore = [string](Get-FactoryNestedValue -Target (Read-FactoryJson -Path $context.statePath).scheduler -Name "heartbeatAt" -Default "")
    Start-Sleep -Milliseconds 25
    $idleSchedulerTick = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action tick -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    $idleSchedulerState = (Read-FactoryJson -Path $context.statePath).scheduler
    Assert-Equal 0 ([int]$idleSchedulerTick.launchedCount) "Idle scheduler tick unexpectedly launched work."
    Assert-True ([string]$idleSchedulerState.heartbeatAt -and [string]$idleSchedulerState.heartbeatAt -ne $idleHeartbeatBefore) "A no-op scheduler tick did not refresh its heartbeat."
    Assert-True ([string]$idleSchedulerState.lastTickAt -ne "") "A no-op scheduler tick did not record its completion time."
    $schedulerTickLog = [IO.File]::ReadAllText([string]$schedulerStatus.stdoutPath, [Text.Encoding]::UTF8)
    Assert-True ($schedulerTickLog.Contains('"event":"tick"') -and $schedulerTickLog.Contains('"event":"process-exit"')) "Scheduler stdout log omitted a tick or final exit reason."

    $schedulerFailureState = Read-FactoryJson -Path $context.statePath
    $schedulerFailureTask = New-FactoryTestTask -Id "scheduler-failure-task" -Title "Runnable scheduler failure" -Now (Get-FactoryUtcTimestamp)
    $schedulerFailureTask.status = "approved"
    $schedulerFailureState.tasks = @($schedulerFailureState.tasks) + @($schedulerFailureTask)
    $schedulerFailureState.active = $true
    $schedulerFailureState.paused = $false
    Write-FactoryJsonAtomic -Path $context.statePath -Value $schedulerFailureState
    $env:CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ON_TICK = "1"
    try {
        $schedulerFailureStart = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2) | ConvertFrom-Json
        Assert-True ([bool]$schedulerFailureStart.started) "Synthetic failing scheduler did not start."
        $schedulerFailureStatus = $null
        $schedulerFailureDeadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            Start-Sleep -Milliseconds 100
            $schedulerFailureStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action status -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
        } while ([string]$schedulerFailureStatus.status -ne "failed" -and [DateTime]::UtcNow -lt $schedulerFailureDeadline)
        Assert-Equal "failed" ([string]$schedulerFailureStatus.status) "A throwing scheduler loop was reported as sleeping or stopped."
        Assert-True ([string]$schedulerFailureStatus.lastError -match "Synthetic scheduler loop failure") "A throwing scheduler loop did not persist lastError."
        $schedulerFailureLog = [IO.File]::ReadAllText([string]$schedulerFailureStatus.stderrPath, [Text.Encoding]::UTF8)
        Assert-True ($schedulerFailureLog.Contains('"event":"tick-exception"') -and $schedulerFailureLog.Contains("Synthetic scheduler loop failure")) "Scheduler stderr log omitted the tick failure reason."
        $failedSchedulerCli = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
        Assert-True ($failedSchedulerCli.Contains("native failed") -and $failedSchedulerCli.Contains("retrying")) "Factory status hid a live scheduler's retrying failure."
        Assert-True (-not ($failedSchedulerCli.Contains("SCHEDULER") -and $failedSchedulerCli.Contains("runnable work is not being processed"))) "Factory status requested manual recovery for a live retrying scheduler."
        $failedSchedulerDoctor = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-doctor.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
        $failedSchedulerDoctorCheck = @($failedSchedulerDoctor.checks | Where-Object { [string]$_.name -eq "scheduler" })[0]
        Assert-True (-not [bool]$failedSchedulerDoctorCheck.passed -and [string]$failedSchedulerDoctorCheck.detail -match "failed") "Factory doctor did not diagnose the failed scheduler."
    } finally {
        Remove-Item Env:\CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ON_TICK -ErrorAction SilentlyContinue
        $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    }
    $schedulerFailureCleanup = Read-FactoryJson -Path $context.statePath
    $schedulerFailureCleanup.tasks = @($schedulerFailureCleanup.tasks | Where-Object { [string]$_.id -ne "scheduler-failure-task" })
    $schedulerFailureCleanup.active = $false
    $schedulerFailureCleanup.paused = $false
    Write-FactoryJsonAtomic -Path $context.statePath -Value $schedulerFailureCleanup

    $schedulerOneShotMarker = Join-Path $testRoot "scheduler-fail-once.marker"
    [IO.File]::WriteAllText($schedulerOneShotMarker, "fail once", (New-Object Text.UTF8Encoding($false)))
    $env:CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ONCE_MARKER = $schedulerOneShotMarker
    try {
        $schedulerRecoveryStart = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2) | ConvertFrom-Json
        Assert-True ([bool]$schedulerRecoveryStart.started) "One-shot scheduler recovery fixture did not start."
        $schedulerTransientFailure = $null
        $schedulerTransientDeadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            Start-Sleep -Milliseconds 100
            $schedulerTransientFailure = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action status -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
        } while ([string]$schedulerTransientFailure.status -ne "failed" -and [DateTime]::UtcNow -lt $schedulerTransientDeadline)
        Assert-Equal "failed" ([string]$schedulerTransientFailure.status) "The one-shot scheduler failure was not observed."
        $transientFailureAt = [string]$schedulerTransientFailure.lastFailureAt
        $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action resume -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
        $schedulerRecovered = $null
        $schedulerRecoveryDeadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            Start-Sleep -Milliseconds 100
            $schedulerRecovered = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action status -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
        } while ([string]$schedulerRecovered.status -ne "running" -and [DateTime]::UtcNow -lt $schedulerRecoveryDeadline)
        Assert-Equal "running" ([string]$schedulerRecovered.status) "Scheduler remained failed after a successful retry tick."
        Assert-True (-not [string]$schedulerRecovered.lastError) "Scheduler retained a transient error after recovery."
        Assert-Equal $transientFailureAt ([string]$schedulerRecovered.lastFailureAt) "Scheduler rewrote or discarded the original failure time after recovery."
    } finally {
        Remove-Item Env:\CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ONCE_MARKER -ErrorAction SilentlyContinue
        $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    }

    $schedulerBusyState = Read-FactoryJson -Path $context.statePath
    $schedulerBusyTask = New-FactoryTestTask -Id "scheduler-busy-task" -Title "Long scheduler integration" -Now (Get-FactoryUtcTimestamp)
    $schedulerBusyTask.status = "approved"
    $schedulerBusyState.tasks = @($schedulerBusyState.tasks) + @($schedulerBusyTask)
    $schedulerBusyState.active = $true
    $schedulerBusyState.paused = $false
    Write-FactoryJsonAtomic -Path $context.statePath -Value $schedulerBusyState
    $env:CLAUDE_FACTORY_TEST_SCHEDULER_BUSY_MILLISECONDS = "15000"
    try {
        $schedulerBusyStart = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2) | ConvertFrom-Json
        Assert-True ([bool]$schedulerBusyStart.started) "Synthetic busy scheduler did not start."
        $schedulerBusyStatus = $null
        $schedulerBusyDeadline = [DateTime]::UtcNow.AddSeconds(8)
        do {
            Start-Sleep -Milliseconds 100
            $schedulerBusyStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action status -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
        } while ([string]$schedulerBusyStatus.activity -ne "integrating" -and [DateTime]::UtcNow -lt $schedulerBusyDeadline)
        Assert-Equal "busy" ([string]$schedulerBusyStatus.status) "Long integration was not reported as scheduler busy."
        Assert-Equal "scheduler-busy-task" ([string]$schedulerBusyStatus.activityTaskId) "Busy scheduler status omitted the task id."
        Assert-Equal "Long scheduler integration" ([string]$schedulerBusyStatus.activityTaskTitle) "Busy scheduler status omitted the task title."
        Assert-True ([string]$schedulerBusyStatus.activitySince -ne "") "Busy scheduler status omitted the activity start time."
        $busyHeartbeatBefore = [string]$schedulerBusyStatus.activityHeartbeatAt
        Start-Sleep -Milliseconds 700
        $schedulerBusyHeartbeat = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action status -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
        Assert-True ([string]$schedulerBusyHeartbeat.activityHeartbeatAt -ne $busyHeartbeatBefore) "Long integration did not refresh the activity heartbeat."
        $schedulerBusyResume = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action resume -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
        Assert-Equal $false ([bool]$schedulerBusyResume.resumed) "Resume started or ticked another scheduler during in-flight work."
        Assert-True ([string]$schedulerBusyResume.reason -match "busy integrating") "Resume refusal did not explain the in-flight scheduler work."
        Assert-Equal ([int]$schedulerBusyStatus.pid) ([int]$schedulerBusyResume.scheduler.pid) "Resume replaced the busy scheduler process."
    } finally {
        Remove-Item Env:\CLAUDE_FACTORY_TEST_SCHEDULER_BUSY_MILLISECONDS -ErrorAction SilentlyContinue
        $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    }
    $schedulerBusyCleanup = Read-FactoryJson -Path $context.statePath
    $schedulerBusyCleanup.tasks = @($schedulerBusyCleanup.tasks | Where-Object { [string]$_.id -ne "scheduler-busy-task" })
    $schedulerBusyCleanup.active = $false
    $schedulerBusyCleanup.paused = $false
    Write-FactoryJsonAtomic -Path $context.statePath -Value $schedulerBusyCleanup

    $waitState = Read-FactoryJson -Path $context.statePath
    $waitTask = New-FactoryTestTask -Id "wait-for-worker-close" -Title "Result captured while worker closes" -Now (Get-FactoryUtcTimestamp)
    $waitTask.status = "awaiting-review"
    $waitTask.backgroundSession = [pscustomobject]@{
        runtime = "claude"; id = "wait-worker"; sessionId = "wait-worker-session"
        name = "factory-wait-for-worker-close"; state = "working"; lastSeenAt = (Get-FactoryUtcTimestamp)
    }
    $waitState.tasks = @($waitTask)
    $waitState.active = $true
    $waitState.paused = $false
    $waitState.scheduler = [pscustomobject][ordered]@{
        mode = "native"; status = "running"; pid = $PID
        processStartTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
        startedAt = (Get-FactoryUtcTimestamp); heartbeatAt = (Get-FactoryUtcTimestamp)
        lastTickAt = (Get-FactoryUtcTimestamp); lastTransitionAt = $null; lastFailureAt = $null
        lastError = $null; failureCount = 0; activity = "idle"; activityTaskId = $null
        activityTaskTitle = $null; activitySince = $null; activityHeartbeatAt = $null; lastExitReason = $null
    }
    Write-FactoryJsonAtomic -Path $context.statePath -Value $waitState
    Assert-Equal 1 (Get-FactoryLaunchedWorkerCount -State $waitState) "An awaiting-review task released its slot before its worker session closed."
    $waitWhileClosing = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\wait-factory.ps1") `
        -Repository $repository -TimeoutSeconds 1 -PollMilliseconds 100) | ConvertFrom-Json
    Assert-True (-not [bool]$waitWhileClosing.signaled -and [bool]$waitWhileClosing.timedOut) "Factory wait treated awaiting-review with a live worker as actionable."
    $waitReadyState = Read-FactoryJson -Path $context.statePath
    $waitReadyTask = Get-FactoryTask -State $waitReadyState -TaskId "wait-for-worker-close"
    $waitReadyTask.backgroundSession.state = "done"
    $waitReadyTask.updatedAt = Get-FactoryUtcTimestamp
    Write-FactoryJsonAtomic -Path $context.statePath -Value $waitReadyState
    $waitReady = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\wait-factory.ps1") `
        -Repository $repository -TimeoutSeconds 1 -PollMilliseconds 100) | ConvertFrom-Json
    Assert-True ([bool]$waitReady.signaled -and -not [bool]$waitReady.timedOut) "Factory wait did not return when review became actionable."
    $waitReadyAction = @($waitReady.actions)[0]
    Assert-Equal "awaiting-review" ([string]$waitReadyAction.kind) "Factory wait returned the wrong operator event."
    $reviewedWaitState = Read-FactoryJson -Path $context.statePath
    $reviewedWaitTask = Get-FactoryTask -State $reviewedWaitState -TaskId "wait-for-worker-close"
    $reviewedWaitTask.review = [pscustomobject]@{
        verdict = "approved"; commit = "reviewed-wait-commit"; summary = "ready"
        integrationPlan = [pscustomobject]@{ planHash = "reviewed-wait-plan" }
    }
    $reviewedWaitTask.commit = "reviewed-wait-commit"
    $reviewedWaitTask.approval = $null
    $reviewedWaitTask.updatedAt = Get-FactoryUtcTimestamp
    Write-FactoryJsonAtomic -Path $context.statePath -Value $reviewedWaitState
    $reviewedEvents = @(Get-FactoryOperatorActionEvents -State $reviewedWaitState -Config (Read-FactoryJson -Path $context.configPath))
    $approvalEvent = @($reviewedEvents | Where-Object { [string]$_.taskId -eq "wait-for-worker-close" })[0]
    Assert-Equal "awaiting-approval" ([string]$approvalEvent.kind) "Factory did not distinguish completed review from review work."
    Assert-Equal "human" ([string]$approvalEvent.audience) "Reviewed task was assigned to the orchestrator instead of the human operator."
    Assert-Equal "factory go wait-for-worker-close" ([string]$approvalEvent.command) "Reviewed task did not name the operator go command."
    $waitAfterReview = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\wait-factory.ps1") `
        -Repository $repository -TimeoutSeconds 1 -PollMilliseconds 100) | ConvertFrom-Json
    Assert-True (-not [bool]$waitAfterReview.signaled -and [bool]$waitAfterReview.timedOut) "Factory wait woke the orchestrator for a task already waiting on human go."
    $waitIncludingApproval = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\wait-factory.ps1") `
        -Repository $repository -TimeoutSeconds 1 -PollMilliseconds 100 -IncludeOperatorApproval) | ConvertFrom-Json
    Assert-Equal "awaiting-approval" ([string]@($waitIncludingApproval.actions)[0].kind) "Explicit human-approval wait did not expose the go decision."

    $liveFailedSchedulerState = Read-FactoryJson -Path $context.statePath
    $liveFailedSchedulerState.tasks = @($liveFailedSchedulerState.tasks) + @(New-FactoryTestTask -Id "live-retrying-scheduler-task" -Title "Queued during scheduler retry" -Now (Get-FactoryUtcTimestamp))
    $liveFailedSchedulerState.scheduler.status = "failed"
    $liveFailedSchedulerState.scheduler.lastError = "transient tick error"
    $liveFailedSchedulerState.scheduler.lastFailureAt = Get-FactoryUtcTimestamp
    Write-FactoryJsonAtomic -Path $context.statePath -Value $liveFailedSchedulerState
    $liveFailedActions = @(Get-FactoryOperatorActionEvents -State $liveFailedSchedulerState -Config (Read-FactoryJson -Path $context.configPath))
    Assert-Equal 0 @($liveFailedActions | Where-Object { [string]$_.kind -eq "scheduler" }).Count "A live retrying scheduler was reported as dead."
    $waitCleanup = Read-FactoryJson -Path $context.statePath
    $waitCleanup.tasks = @()
    $waitCleanup.active = $false
    $waitCleanup.scheduler.status = "stopped"
    $waitCleanup.scheduler.pid = $null
    $waitCleanup.scheduler.processStartTimeUtc = $null
    Write-FactoryJsonAtomic -Path $context.statePath -Value $waitCleanup

    $legacyConfig = Read-FactoryJson -Path $context.configPath
    $legacyConfig.version = 2
    $legacyConfig.autoPushDevelopment = $false
    $legacyConfig.PSObject.Properties.Remove("codingConcurrency")
    Set-FactoryProperty -Target $legacyConfig -Name "concurrency" -Value 3
    $legacyConfig.PSObject.Properties.Remove("maxConcurrency")
    $legacyConfig.PSObject.Properties.Remove("defaultStartMode")
    $legacyConfig.PSObject.Properties.Remove("conversationLanguage")
    $legacyConfig.PSObject.Properties.Remove("workerLaunchTimeoutSeconds")
    $legacyConfig.PSObject.Properties.Remove("testDatabaseIsolation")
    Write-FactoryJsonAtomic -Path $context.configPath -Value $legacyConfig
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository -Initialize) | ConvertFrom-Json
    $migratedConfig = Read-FactoryJson -Path $context.configPath
    Assert-Equal 8 ([int]$migratedConfig.version) "Legacy config version was not migrated."
    Assert-Equal 3 ([int]$migratedConfig.codingConcurrency) "The deprecated concurrency alias was not migrated into codingConcurrency."
    Assert-True ((Get-FactoryCodingConcurrencySource -Config $migratedConfig) -match "deprecated concurrency is present but ignored") "Config diagnostics do not identify the retained deprecated alias."
    Assert-Equal 20 ([int]$migratedConfig.maxConcurrency) "Missing config defaults were not added."
    Assert-Equal 300 ([int]$migratedConfig.workerLaunchTimeoutSeconds) "Worker launch timeout default was not migrated."
    Assert-Equal "English" ([string]$migratedConfig.conversationLanguage) "Conversation language default was not migrated."
    Assert-Equal $false ([bool]$migratedConfig.autoPushDevelopment) "Migration overwrote a repository-specific config value."
    Assert-Equal $false ([bool]$migratedConfig.testDatabaseIsolation.enabled) "Test database isolation was not migrated safely as opt-in."
    Assert-Equal $false ([bool]$migratedConfig.nativeScheduler.startWithOrchestrator) "Migration overwrote a repository-specific scheduler setting."
    $migratedConfig.testDatabaseIsolation.enabled = $true
    $migratedConfig.testDatabaseIsolation.databasePrefix = "factory_test"
    $migratedConfig.testDatabaseIsolation.clientCommand = $fakePsql
    Write-FactoryJsonAtomic -Path $context.configPath -Value $migratedConfig
    $databaseSettings = Get-FactoryTestDatabaseSettings -Config $migratedConfig -RepositoryRoot $repository
    $firstWorkerDatabase = Get-FactoryTestDatabaseName -Settings $databaseSettings -Scope worker -TaskId "task-one"
    $secondWorkerDatabase = Get-FactoryTestDatabaseName -Settings $databaseSettings -Scope worker -TaskId "task-two"
    Assert-True ($firstWorkerDatabase -ne $secondWorkerDatabase) "Different tasks resolved to the same test database."

    $integratorWorktree = Join-Path ([string]$context.worktreeRoot) "factory-integrator"
    New-Item -ItemType Directory -Path $integratorWorktree -Force | Out-Null
    $integratorDatabaseCapture = Join-Path $testRoot "integrator-test-database.txt"
    $captureLiteral = $integratorDatabaseCapture.Replace("'", "''")
    $isolatedCommand = "[IO.File]::WriteAllText('$captureLiteral', `$env:DB_DATABASE)"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\run-isolated-test-command.ps1") `
        -Repository $repository `
        -Scope integrator `
        -WorkingDirectory $integratorWorktree `
        -Command $isolatedCommand
    if ($LASTEXITCODE -ne 0) { throw "Isolated integrator command fixture failed." }
    Assert-Equal "factory_test_integrator" ([IO.File]::ReadAllText($integratorDatabaseCapture)) "Integrator checks did not receive their own database."

    $ansiFailureCommand = '$escape=[char]27; [Console]::Out.Write($escape + ''[31m'' + (''X'' * 20000) + ''FAILURE_TAIL'' + $escape + ''[0m''); exit 7'
    $ansiCommandsPath = Join-Path ([string]$context.sessionsPath) "ansi-output-checks.json"
    Write-FactoryJsonAtomic -Path $ansiCommandsPath -Value ([pscustomobject][ordered]@{
        version = 1
        taskId = "ansi-output-task"
        scope = "integrator"
        commands = @($ansiFailureCommand)
    })
    try {
        $ansiCheckResult = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\run-pipeline-check-set.ps1") -Repository $repository -Scope integrator -WorkingDirectory $integratorWorktree -CommandsPath $ansiCommandsPath) | ConvertFrom-Json
    } finally {
        Remove-Item -LiteralPath $ansiCommandsPath -Force -ErrorAction SilentlyContinue
    }
    Assert-Equal $false ([bool]$ansiCheckResult.success) "ANSI failure fixture unexpectedly passed."
    $ansiTestResult = @($ansiCheckResult.tests)[0]
    Assert-Equal $ansiFailureCommand ([string]$ansiTestResult.command) "Pipeline state changed the test command instead of preserving it verbatim."
    Assert-Equal 7 ([int]$ansiTestResult.exitCode) "Pipeline state omitted or changed the native exit code."
    Assert-True ([string]$ansiTestResult.summary -and ([string]$ansiTestResult.summary).Length -le 8192) "Pipeline failure summary was not bounded."
    Assert-True ([string]$ansiTestResult.summary -match "FAILURE_TAIL") "Pipeline failure summary did not retain the useful output tail."
    Assert-True (-not ([string]$ansiTestResult.summary).Contains([string][char]27)) "Pipeline failure summary retained ANSI escape bytes."
    Assert-True (Test-Path -LiteralPath ([string]$ansiTestResult.outputPath)) "Pipeline test row points to a missing full-output artifact."
    $ansiEventRoot = [IO.Path]::GetFullPath((Join-Path ([string]$context.eventsPath) (ConvertTo-FactoryTaskArtifactName -TaskId "ansi-output-task"))).TrimEnd('\') + [IO.Path]::DirectorySeparatorChar
    Assert-True ([IO.Path]::GetFullPath([string]$ansiTestResult.outputPath).StartsWith($ansiEventRoot, [StringComparison]::OrdinalIgnoreCase)) "Pipeline full output was not stored next to the task events."
    $ansiFullOutput = [IO.File]::ReadAllText([string]$ansiTestResult.outputPath, [Text.Encoding]::UTF8)
    Assert-True ($ansiFullOutput.Length -gt 15000 -and $ansiFullOutput.Contains("FAILURE_TAIL")) "Pipeline full-output artifact was truncated."
    Assert-True (-not $ansiFullOutput.Contains([string][char]27)) "Pipeline full-output artifact retained ANSI escape bytes."
    Remove-Item -LiteralPath $integratorWorktree -Recurse -Force
    $dropFailureTask = "drop-failure-task"
    $dropFailureDatabase = Initialize-FactoryTestDatabase -Config $migratedConfig -RepositoryRoot $repository -Scope worker -TaskId $dropFailureTask
    $env:CLAUDE_FACTORY_TEST_PSQL_FAIL_DROP = [string]$dropFailureDatabase.name
    $dropFailureObserved = $false
    try {
        $null = Remove-FactoryTestDatabase `
            -Config $migratedConfig `
            -RepositoryRoot $repository `
            -Scope worker `
            -TaskId $dropFailureTask `
            -DatabaseName ([string]$dropFailureDatabase.name)
    } catch {
        $dropFailureObserved = $true
    } finally {
        Remove-Item Env:\CLAUDE_FACTORY_TEST_PSQL_FAIL_DROP -ErrorAction SilentlyContinue
    }
    Assert-True $dropFailureObserved "A PostgreSQL drop failure was silently accepted."
    $null = Remove-FactoryTestDatabase `
        -Config $migratedConfig `
        -RepositoryRoot $repository `
        -Scope worker `
        -TaskId $dropFailureTask `
        -DatabaseName ([string]$dropFailureDatabase.name)

    $intakeTaskId = "1217000000000001"
    $intakeUrl = "https://app.asana.com/1/14748072439266/project/1215506997644941/task/$($intakeTaskId)?focus=true"
    $preparedIntake = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\prepare-intake.ps1") -Repository $repository -Url $intakeUrl -Mode interactive) | ConvertFrom-Json
    Assert-True ([bool]$preparedIntake.prepared) "Native intake did not prepare a new Asana task."
    Assert-Equal $intakeTaskId ([string]$preparedIntake.taskId) "Native intake prepared the wrong Asana task."
    Assert-True (Test-Path -LiteralPath ([string]$preparedIntake.requestPath)) "Native intake did not persist its request."
    Assert-True (Test-Path -LiteralPath ([string]$preparedIntake.normalizationPath)) "Native intake did not create its normalized draft."
    $intakeDraft = Read-FactoryJson -Path ([string]$preparedIntake.normalizationPath)
    Assert-Equal "asana" ([string]$intakeDraft.source.adapter) "Native intake draft lost its source adapter."
    Assert-Equal $intakeTaskId ([string]$intakeDraft.source.id) "Native intake draft lost its immutable source ID."
    $intakeDraft.title = "Native intake task"
    $intakeDraft.brief = "Verify native URL handling, deduplication, queue mutation, and scheduler wakeup."
    $intakeDraft.acceptanceCriteria = @("The task is launched once.")
    $intakeDraft.sourceNotes = @("Normalized by the synthetic test.")
    Write-FactoryJsonAtomic -Path ([string]$preparedIntake.normalizationPath) -Value $intakeDraft
    $enqueuedIntake = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\enqueue-task.ps1") -Repository $repository -RequestPath ([string]$preparedIntake.requestPath) -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal $intakeTaskId ([string]$enqueuedIntake.taskId) "Native enqueue returned the wrong task."
    Assert-Equal "queued" ([string]$enqueuedIntake.status) "Native enqueue waited for worker launch instead of returning its atomic queue result."
    Assert-True ([bool]$enqueuedIntake.scheduler.wakeRequested -and $null -eq $enqueuedIntake.scheduler.tick) "Native enqueue ran an inline scheduler tick instead of requesting an asynchronous wake."
    Assert-True (-not [bool]$enqueuedIntake.duplicate) "Native enqueue treated a fresh task as a duplicate."
    Assert-True (-not (Test-Path -LiteralPath ([string]$preparedIntake.requestPath))) "Native enqueue retained the consumed request."
    Assert-True (-not (Test-Path -LiteralPath ([string]$preparedIntake.normalizationPath))) "Native enqueue retained the consumed draft."
    Assert-True (-not [string]$enqueuedIntake.schedulerError) "Native enqueue could not wake the scheduler: $($enqueuedIntake.schedulerError)"
    $intakeLaunchDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $intakeState = Read-FactoryJson -Path $context.statePath
        $intakeTask = @($intakeState.tasks | Where-Object { [string]$_.id -eq $intakeTaskId })[0]
        if ([string]$intakeTask.status -in @("starting", "planning", "running", "awaiting-input")) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $intakeLaunchDeadline)
    Assert-True ([string]$intakeTask.status -in @("starting", "planning", "running", "awaiting-input")) "Native enqueue did not wake the scheduler and launch the task."
    Assert-Equal "asana" ([string]$intakeTask.source.adapter) "Native enqueue did not persist source identity."
    $duplicateIntake = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\prepare-intake.ps1") -Repository $repository -Url "https://app.asana.com/0/0/$intakeTaskId" -Mode auto) | ConvertFrom-Json
    Assert-True ([bool]$duplicateIntake.duplicate) "Native intake did not deduplicate the same Asana task ID."

    $tamperedIntakeTaskId = "1217000000000002"
    $tamperedIntake = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\prepare-intake.ps1") -Repository $repository -Url "https://app.asana.com/0/0/$tamperedIntakeTaskId" -Mode auto) | ConvertFrom-Json
    $tamperedDraft = Read-FactoryJson -Path ([string]$tamperedIntake.normalizationPath)
    $tamperedDraft.source.id = "1217000000000099"
    $tamperedDraft.title = "Tampered identity"
    $tamperedDraft.brief = "This envelope must not enter state."
    Write-FactoryJsonAtomic -Path ([string]$tamperedIntake.normalizationPath) -Value $tamperedDraft
    $previousIntakeErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\enqueue-task.ps1") -Repository $repository -RequestPath ([string]$tamperedIntake.requestPath) -ClaudeCommand $fakeClaude 2>&1)
        $tamperedIntakeExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousIntakeErrorAction
    }
    Assert-True ($tamperedIntakeExit -ne 0) "Native enqueue accepted an AI-modified source identity."
    Assert-Equal 0 (@((Read-FactoryJson -Path $context.statePath).tasks | Where-Object { [string]$_.id -in @($tamperedIntakeTaskId, "1217000000000099") }).Count) "Rejected intake identity entered state."
    Remove-Item -LiteralPath ([string]$tamperedIntake.requestPath), ([string]$tamperedIntake.normalizationPath) -Force

    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    $discardedIntake = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId $intakeTaskId -ClaudeCommand $fakeClaude -Yes) | ConvertFrom-Json
    Assert-True ([bool]$discardedIntake.removedFromState) "Native intake fixture was not discarded after verification."

    $manualIntakePath = Join-Path $testRoot "manual-intake.json"
    Write-FactoryJsonAtomic -Path $manualIntakePath -Value ([pscustomobject][ordered]@{
        version = 1
        source = [pscustomobject][ordered]@{ adapter = "linear"; id = "ENG-123"; url = "https://linear.app/acme/issue/ENG-123/native-intake"; suppliedUrl = $null }
        startMode = "auto"
        title = "Future adapter task"
        brief = "Connector data is unavailable in this synthetic import."
        acceptanceCriteria = @()
        sourceNotes = @()
        sourceError = "Synthetic source is intentionally unavailable."
    })
    $nativeAddOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") add --file $manualIntakePath -Repository $repository -ClaudeCommand $fakeClaude | Out-String)
    Assert-True ($nativeAddOutput.Contains("linear:ENG-123")) "factory add --file did not import a source-neutral task ID."
    Assert-True ($nativeAddOutput.Contains("Saved as blocked")) "factory add --file did not report source failure state."
    Assert-True (Test-Path -LiteralPath $manualIntakePath) "factory add --file consumed the operator's source file."
    $manualState = Read-FactoryJson -Path $context.statePath
    $manualTask = @($manualState.tasks | Where-Object { [string]$_.id -eq "linear:ENG-123" })[0]
    Assert-Equal "blocked" ([string]$manualTask.status) "Source-neutral native intake did not persist the blocked task."
    Assert-Equal "linear" ([string]$manualTask.source.adapter) "Source-neutral native intake lost the adapter identity."
    $manualDuplicateOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") add --file $manualIntakePath -Repository $repository -ClaudeCommand $fakeClaude | Out-String)
    Assert-True ($manualDuplicateOutput.Contains("Already saved")) "factory add --file did not deduplicate a repeated import."
    $discardedManual = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "linear:ENG-123" -ClaudeCommand $fakeClaude -Yes) | ConvertFrom-Json
    Assert-True ([bool]$discardedManual.removedFromState) "Manual intake fixture was not removed after verification."

    $emptyLocalOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") new -Repository $repository -ClaudeCommand $fakeClaude | Out-String)
    $emptyLocalId = [regex]::Match($emptyLocalOutput, 'local:[0-9]{8}-[0-9]{6}-[0-9a-f]{8}').Value
    Assert-True ([bool]$emptyLocalId) "factory new did not return a native local task ID."
    Assert-True ($emptyLocalOutput.Contains("The worker will ask what you want implemented.")) "Empty factory new did not explain its worker handoff."
    Assert-True ($emptyLocalOutput.Contains("factory chat $emptyLocalId")) "factory new did not print the exact chat command."
    Assert-True ($emptyLocalOutput.Contains("No JSON file or AI intake was used.")) "factory new obscured its native intake boundary."
    $emptyLocalDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $emptyLocalTask = @((Read-FactoryJson -Path $context.statePath).tasks | Where-Object { [string]$_.id -eq $emptyLocalId })[0]
        if ($null -ne $emptyLocalTask.backgroundSession -or [string]$emptyLocalTask.status -in @("awaiting-input", "held", "failed")) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $emptyLocalDeadline)
    Assert-Equal "local" ([string]$emptyLocalTask.source.adapter) "Empty local task lost its native source adapter."
    Assert-Equal "interactive" ([string]$emptyLocalTask.startMode) "Empty local task was not interactive."
    Assert-Equal "Untitled local task" ([string]$emptyLocalTask.title) "Empty local task received the wrong title."
    Assert-True ([string]$emptyLocalTask.brief -match 'Ask the user what they want implemented') "Empty local task did not require a user handoff."
    Assert-True ([string]$emptyLocalTask.status -in @("starting", "planning", "awaiting-input", "held")) "Empty local task did not leave the native scheduler queue."
    Assert-True ($null -ne $emptyLocalTask.backgroundSession) "Empty local task did not record a worker session."
    $emptyLocalSourceId = [string]$emptyLocalTask.source.id
    $emptyLocalStatusOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") status -NoReconcile -Repository $repository -ClaudeCommand $fakeClaude | Out-String)
    Assert-True ($emptyLocalStatusOutput.Contains("Source: local / $emptyLocalSourceId")) "Factory status did not identify a local task source."
    Assert-True (-not $emptyLocalStatusOutput.Contains("factory://local/")) "Factory status exposed an internal local identity URI as an operator URL."
    $discardedEmptyLocal = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId $emptyLocalId -ClaudeCommand $fakeClaude -Yes) | ConvertFrom-Json
    Assert-True ([bool]$discardedEmptyLocal.removedFromState) "Empty local task fixture was not removed."

    $localText = "Update the personal dashboard navigation"
    $automaticLocalOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") new $localText --auto -Repository $repository -ClaudeCommand $fakeClaude | Out-String)
    $automaticLocalId = [regex]::Match($automaticLocalOutput, 'local:[0-9]{8}-[0-9]{6}-[0-9a-f]{8}').Value
    Assert-True ([bool]$automaticLocalId) "factory new --auto did not return a native local task ID."
    $automaticLocalDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $automaticLocalTask = @((Read-FactoryJson -Path $context.statePath).tasks | Where-Object { [string]$_.id -eq $automaticLocalId })[0]
        if ($null -ne $automaticLocalTask.backgroundSession -or [string]$automaticLocalTask.status -in @("awaiting-review", "held", "failed")) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $automaticLocalDeadline)
    Assert-Equal "auto" ([string]$automaticLocalTask.startMode) "Automatic local task lost its launch mode."
    Assert-Equal $localText ([string]$automaticLocalTask.title) "Local task title was not derived from operator text."
    Assert-Equal $localText ([string]$automaticLocalTask.brief) "Local task brief did not preserve operator text."
    $localTaskNonce = [regex]::Match($automaticLocalId, '([0-9a-f]{8})$').Groups[1].Value
    $expectedLocalSessionPrefix = "factory-local-$localTaskNonce-update-the-personal-"
    Assert-True ([string]$automaticLocalTask.backgroundSession.name -like "$expectedLocalSessionPrefix*") "Quoted local task text was not retained in the worker session name."
    Assert-True ([string]$automaticLocalTask.backgroundSession.name -notmatch '-[0-9a-f]{12}-update-') "Local worker session still contains an unreadable artifact hash."
    Assert-True ([string]$automaticLocalTask.status -in @("starting", "running", "awaiting-review", "held")) "Automatic local task was not launched."
    $discardedAutomaticLocal = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId $automaticLocalId -ClaudeCommand $fakeClaude -Yes) | ConvertFrom-Json
    Assert-True ([bool]$discardedAutomaticLocal.removedFromState) "Automatic local task fixture was not removed."

    $taskCountBeforeInvalidLocal = @((Read-FactoryJson -Path $context.statePath).tasks).Count
    $previousLocalErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") new --auto -Repository $repository -ClaudeCommand $fakeClaude 2>&1)
        $invalidEmptyAutoExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousLocalErrorAction
    }
    Assert-True ($invalidEmptyAutoExit -ne 0) "factory new --auto accepted an empty task."
    Assert-Equal $taskCountBeforeInvalidLocal (@((Read-FactoryJson -Path $context.statePath).tasks).Count) "Rejected empty automatic intake mutated state."

    $reservedLocalPath = Join-Path $testRoot "reserved-local-intake.json"
    Write-FactoryJsonAtomic -Path $reservedLocalPath -Value ([pscustomobject][ordered]@{
        version = 1
        source = [pscustomobject][ordered]@{ adapter = "local"; id = "20260816-120000-deadbeef"; url = "factory://local/20260816-120000-deadbeef"; suppliedUrl = $null }
        startMode = "interactive"
        title = "Spoofed local task"
        brief = "This file must not impersonate native local intake."
        acceptanceCriteria = @()
        sourceNotes = @()
        sourceError = $null
    })
    try {
        $ErrorActionPreference = "Continue"
        $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\enqueue-task.ps1") -Repository $repository -IntakePath $reservedLocalPath -ClaudeCommand $fakeClaude 2>&1)
        $reservedLocalExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousLocalErrorAction
    }
    Assert-True ($reservedLocalExit -ne 0) "File intake impersonated the reserved local adapter."
    Assert-Equal 0 (@((Read-FactoryJson -Path $context.statePath).tasks | Where-Object { [string]$_.id -eq "local:20260816-120000-deadbeef" }).Count) "Reserved local file intake entered state."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json

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
                cleanup = $null
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
    foreach ($propertyName in @("source", "startMode", "backgroundSession", "plan", "review", "approval", "syncPreparation", "cleanup", "reworkRequestedAt", "planRecordedAt", "resultRecordedAt", "pendingInstructions")) {
        $state.tasks[0].PSObject.Properties.Remove($propertyName)
    }
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository -Initialize) | ConvertFrom-Json
    $migratedState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 9 ([int]$migratedState.version) "Legacy state version was not migrated."
    Assert-True ($null -ne $migratedState.scheduler) "Native scheduler state was not migrated."
    Assert-Equal "idle" ([string]$migratedState.scheduler.activity) "Legacy scheduler activity state was not migrated."
    Assert-True ($null -ne $migratedState.scheduler.PSObject.Properties["lastExitReason"]) "Legacy scheduler exit diagnostics were not migrated."
    Assert-True ($null -ne $migratedState.scheduler.PSObject.Properties["lastFailureAt"]) "Legacy scheduler failure timestamp was not migrated."
    Assert-Equal "auto" ([string]$migratedState.tasks[0].startMode) "Legacy task start mode was not defaulted."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["backgroundSession"]) "Legacy task session field was not added."
    Assert-True ($null -ne $migratedState.PSObject.Properties["agentResolutionCache"]) "Legacy state agent resolution cache field was not added."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["planRecordedAt"]) "Legacy task plan timestamp field was not added."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["source"]) "Legacy task source field was not added."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["cleanup"]) "Legacy task cleanup audit field was not added."
    foreach ($launchField in @("launchStartedAt", "launchCompletedAt", "launchFailedAt", "launchProcessId", "launchProcessStartTimeUtc")) {
        Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties[$launchField]) "Legacy task launch field '$launchField' was not added."
    }

    $cliScriptPath = Join-Path $pluginRoot "factory.ps1"
    $cliSource = Get-Content -LiteralPath $cliScriptPath -Raw
    Assert-True ($cliSource.Contains('[ValidateSet(') -and $cliSource.Contains('"completion"')) "Factory CLI does not expose native command completion."
    Assert-True ($cliSource.Contains('"go"')) "Factory CLI does not expose native go."
    Assert-True ($cliSource.Contains('"add"') -and $cliSource.Contains('[string]$File')) "Factory CLI does not expose native file intake."
    Assert-True ($cliSource.Contains('"new"') -and $cliSource.Contains('[switch]$Auto')) "Factory CLI does not expose native local task intake."
    Assert-True ($cliSource.Contains('[switch]$Direct')) "Factory CLI does not expose direct approval."
    Assert-True ($cliSource.Contains('"preview"') -and $cliSource.Contains('[switch]$NoOpen')) "Factory CLI does not expose native browser preview."
    Assert-True ($cliSource.Contains('"rotate"')) "Factory CLI does not expose native orchestrator rotation."
    Assert-True ($cliSource.Contains('"wait"') -and $cliSource.Contains('"retry"')) "Factory CLI does not expose native wait and retry commands."
    Assert-True ($cliSource.Contains('"runtime"')) "Factory CLI does not expose runtime safety diagnostics."
    Assert-True ($cliSource.Contains("[ArgumentCompleter({")) "Factory CLI does not expose contextual argument completion."

    $cliState = Read-FactoryJson -Path $context.statePath
    $heldCliTask = New-FactoryTestTask -Id "held-cli-task" -Title "Held CLI task with a complete readable title" -Now $now
    $heldCliTask.url = "https://app.asana.com/0/0/held-cli-task"
    $heldCliTask.status = "held"
    $mojibakeFixture = [Text.Encoding]::GetEncoding(437).GetString([Text.Encoding]::UTF8.GetBytes($unicodeFixture))
    Set-FactoryProperty -Target $heldCliTask -Name "holdReason" -Value $mojibakeFixture
    Set-FactoryProperty -Target $heldCliTask -Name "backgroundSession" -Value ([pscustomobject]@{
        id = "held1234"
        sessionId = "held1234-1111-4222-8333-444444444444"
        name = "factory-held-cli-task-readable"
        state = "blocked"
    })
    $doneCliTask = New-FactoryTestTask -Id "done-cli-task" -Title "Completed CLI history task" -Now $now
    $doneCliTask.url = "https://app.asana.com/0/0/done-cli-task"
    $doneCliTask.status = "done"
    $doneCliTask.workerResult = [pscustomobject]@{ notes = "Published and cleaned."; tests = @(); changedFiles = @() }
    $staleQuestion = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0KHRgtCw0YDRi9C5INCy0L7Qv9GA0L7RgSDQtNC70Y8g0L/Qu9Cw0L3QsA=="))
    $reviewCliTask = New-FactoryTestTask -Id "review-cli-task" -Title "Review CLI task without a stale reason" -Now $now
    $reviewCliTask.url = "https://app.asana.com/0/0/review-cli-task"
    $reviewCliTask.status = "awaiting-review"
    $reviewCliTask.commit = "1234567890abcdef1234567890abcdef12345678"
    $reviewCliTask.plan = [pscustomobject]@{ questions = @([Text.Encoding]::GetEncoding(437).GetString([Text.Encoding]::UTF8.GetBytes($staleQuestion))) }
    $reviewCliTask.workerResult = [pscustomobject]@{
        commit = $reviewCliTask.commit
        notes = "Ready."
        tests = @([pscustomobject]@{ command = "git diff --check"; status = "passed"; summary = "Clean diff." })
        changedFiles = @()
    }
    $closingReviewCliTask = New-FactoryTestTask -Id "closing-review-cli-task" -Title "Worker is still closing" -Now $now
    $closingReviewCliTask.status = "awaiting-review"
    $closingReviewCliTask.backgroundSession = [pscustomobject]@{
        runtime = "claude"; id = "closing-review"; sessionId = "closing-review-session"
        name = "factory-closing-review-cli-task"; state = "working"; lastSeenAt = $now
    }
    $approvalCliTask = New-FactoryTestTask -Id "approval-cli-task" -Title "Reviewed task waiting for operator go" -Now $now
    $approvalCliTask.status = "awaiting-review"
    $approvalCliTask.commit = "abcdef1234567890abcdef1234567890abcdef12"
    $approvalCliTask.review = [pscustomobject]@{
        verdict = "approved"; commit = $approvalCliTask.commit; summary = "Approved"
        integrationPlan = [pscustomobject]@{ planHash = "approval-cli-plan" }
    }
    $approvalCliTask.approval = $null
    $rejectCliTask = New-FactoryTestTask -Id "reject-cli-task" -Title "Disposable CLI task without artifacts" -Now $now
    $cliState.tasks = @($cliState.tasks) + @($heldCliTask, $reviewCliTask, $closingReviewCliTask, $approvalCliTask, $doneCliTask, $rejectCliTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $cliState

    $cliHelp = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath help | Out-String)
    Assert-True ($cliHelp.Contains("!factory status")) "Factory CLI help does not explain direct orchestrator shell mode."
    Assert-True ($cliHelp.Contains("no AI interpretation")) "Factory CLI help hides its deterministic execution model."
    Assert-True ($cliHelp.Contains("factory go <task-id> [--direct]")) "Factory CLI help omits direct approval."
    Assert-True ($cliHelp.Contains("factory rotate [status|cancel]")) "Factory CLI help omits orchestrator rotation."
    Assert-True ($cliHelp.Contains("factory wait [timeout-seconds]") -and $cliHelp.Contains("factory retry <task-id>")) "Factory CLI help omits native wait or retry."
    Assert-True ($cliHelp.Contains("factory runtime [status|migrate]")) "Factory CLI help omits runtime safety and migration."
    $cliGoHelp = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath help go | Out-String)
    Assert-True ($cliGoHelp.Contains("skips independent AI code review")) "Factory go help hides direct approval semantics."
    $cliRotateHelp = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath help rotate | Out-String)
    Assert-True ($cliRotateHelp.Contains("fresh orchestrator conversation") -and $cliRotateHelp.Contains("previous resumable conversation")) "Factory rotate help hides its rollover or retention semantics."

    $claudeIdentityPath = Join-Path ([string]$context.projectData) "orchestrator-session.json"
    $preRotationIdentity = Read-FactoryJson -Path $claudeIdentityPath
    $preRotationTaskCount = @((Read-FactoryJson -Path $context.statePath).tasks).Count
    $cliRotate = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath rotate -Repository $repository | Out-String)
    Assert-True ($cliRotate.Contains("Orchestrator rotation prepared") -and $cliRotate.Contains("factory start")) "Factory rotate did not prepare the handoff or print the next command."
    $claudePendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $context -Runtime "claude"
    Assert-True (Test-Path -LiteralPath $claudePendingPath -PathType Leaf) "Factory rotate did not write a private pending marker."
    $claudePendingRotation = Read-FactoryJson -Path $claudePendingPath
    Assert-Equal ([string]$preRotationIdentity.sessionId) ([string]$claudePendingRotation.previousSessionId) "Factory rotate lost the previous Claude session UUID."
    Assert-True (Test-Path -LiteralPath ([string]$claudePendingRotation.handoffPath) -PathType Leaf) "Factory rotate did not write its deterministic handoff."
    $claudeHandoff = Get-Content -LiteralPath ([string]$claudePendingRotation.handoffPath) -Raw
    Assert-True ($claudeHandoff.Contains("Held CLI task with a complete readable title") -and $claudeHandoff.Contains("held-cli-task | held")) "Factory handoff omitted unfinished task identity."
    Assert-True ($claudeHandoff.Contains("Native config and state are authoritative")) "Factory handoff did not define native state as authoritative."
    Assert-Equal $preRotationTaskCount @((Read-FactoryJson -Path $context.statePath).tasks).Count "Preparing orchestrator rotation mutated the task queue."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath rotate -Repository $repository | Out-String)
    Assert-Equal ([string]$claudePendingRotation.rotationId) ([string](Read-FactoryJson -Path $claudePendingPath).rotationId) "Repeating factory rotate replaced an already-pending handoff."
    $cliRotateStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath rotate status -Repository $repository | Out-String)
    Assert-True ($cliRotateStatus.Contains([string]$claudePendingRotation.rotationId)) "Factory rotate status did not show the pending request."

    $rotationArgv = Join-Path $testRoot "rotation-orchestrator-argv.txt"
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $rotationArgv
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "start-factory.ps1") -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime 1> $null
    Assert-Equal 0 $LASTEXITCODE "Pending Claude orchestrator rotation could not be activated."
    $rotatedClaudeArgs = @([IO.File]::ReadAllLines($rotationArgv, [Text.Encoding]::UTF8))
    $rotatedSessionIndex = [Array]::IndexOf($rotatedClaudeArgs, "--session-id")
    Assert-True ($rotatedSessionIndex -ge 0 -and $rotatedSessionIndex + 1 -lt $rotatedClaudeArgs.Count) "Claude rotation did not create a new session UUID."
    $rotatedClaudeSessionId = $rotatedClaudeArgs[$rotatedSessionIndex + 1]
    Assert-True ($rotatedClaudeSessionId -ne [string]$preRotationIdentity.sessionId) "Claude rotation resumed the context-heavy session."
    Assert-True ([Array]::IndexOf($rotatedClaudeArgs, "--append-system-prompt") -ge 0) "Claude rotation did not inject its private handoff into bootstrap."
    Assert-True ($rotatedClaudeArgs -contains [string]$context.projectData) "Claude rotation did not grant the new session access to private handoff state."
    Assert-True (-not (Test-Path -LiteralPath $claudePendingPath)) "Claude rotation left a pending marker that would rotate every subsequent start."
    $activatedClaudeRotation = Read-FactoryJson -Path ([string]$claudePendingRotation.recordPath)
    Assert-Equal "activated" ([string]$activatedClaudeRotation.status) "Claude rotation audit was not finalized."
    Assert-Equal $rotatedClaudeSessionId ([string]$activatedClaudeRotation.newSessionId) "Claude rotation audit recorded the wrong replacement UUID."
    Assert-Equal $preRotationTaskCount @((Read-FactoryJson -Path $context.statePath).tasks).Count "Activating orchestrator rotation mutated the task queue."

    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath rotate -Repository $repository | Out-String)
    Assert-True (Test-Path -LiteralPath $claudePendingPath -PathType Leaf) "Second rotation request was not prepared for cancellation testing."
    $cancelledRotationRecordPath = [string](Read-FactoryJson -Path $claudePendingPath).recordPath
    $cliRotateCancel = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath rotate cancel -Repository $repository | Out-String)
    Assert-True ($cliRotateCancel.Contains("Cancelled claude orchestrator rotation")) "Factory rotate cancel did not report cancellation."
    Assert-True (-not (Test-Path -LiteralPath $claudePendingPath)) "Factory rotate cancel left the pending marker behind."
    Assert-Equal "cancelled" ([string](Read-FactoryJson -Path $cancelledRotationRecordPath).status) "Factory rotate cancel did not preserve a cancelled audit."
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ARGV_FILE -ErrorAction SilentlyContinue

    $cliStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliStatus.Contains(([char]0x256D).ToString() + ([char]0x2500).ToString() + " Factory")) "Factory CLI status does not use the continuous Unicode tree."
    Assert-True ($cliStatus.Contains("held-cli-task")) "Factory CLI status omitted an unfinished task."
    Assert-True ($cliStatus.Contains("Held CLI task with a complete readable title")) "Factory CLI status omitted the full title."
    Assert-True ($cliStatus.Contains("https://app.asana.com/0/0/held-cli-task")) "Factory CLI status omitted the canonical URL."
    Assert-True ($cliStatus.Contains($unicodeFixture)) "Factory CLI status did not repair legacy OEM-decoded UTF-8 for display."
    Assert-True (-not $cliStatus.Contains($mojibakeFixture)) "Factory CLI status printed raw mojibake."
    Assert-True (-not $cliStatus.Contains($staleQuestion)) "Factory CLI status presented a stale plan question as the review reason."
    Assert-True ($cliStatus.Contains("/factory inspect held-cli-task")) "Factory CLI status omitted the exact next orchestrator command."
    Assert-True (-not $cliStatus.Contains("!factory go review-cli-task --direct")) "Factory CLI status advertised direct approval while publication was not configured."
    Assert-True ($cliStatus.Contains("History: factory status done")) "Factory CLI status does not collapse completed history."
    Assert-True (-not $cliStatus.Contains("Completed CLI history task")) "Factory CLI default status expanded completed history."
    Assert-True ($cliStatus.Contains("coding slots") -and $cliStatus.Contains("test lane free")) "Factory CLI status does not expose both coding capacity and the serialized test lane."
    Assert-True ($cliStatus.Contains("WAITING") -and $cliStatus.Contains("FINISHING") -and $cliStatus.Contains("closing-review-cli-task")) "Factory status presented an awaiting-review task with a live worker as actionable review."
    Assert-True (-not $cliStatus.Contains("/factory review closing-review-cli-task")) "Factory status offered review before the worker session closed."
    Assert-True ($cliStatus.Contains("GO") -and $cliStatus.Contains("approval-cli-task") -and $cliStatus.Contains("approved review is waiting for your go decision")) "Factory status did not distinguish human go from AI review."

    $previousDirectPreflightErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $directPreflightOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath go review-cli-task --direct -Repository $repository -ClaudeCommand $fakeClaude 2>&1 | ForEach-Object { [string]$_ })
        $directPreflightExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousDirectPreflightErrorAction
    }
    $directPreflightText = $directPreflightOutput -join "`n"
    Assert-True ($directPreflightExit -ne 0) "Direct approval preflight accepted disabled publication."
    Assert-True ($directPreflightText.Contains("autoPushDevelopment=false")) "Direct approval preflight did not name the disabled setting."
    Assert-True ($directPreflightText.Contains("factory config edit")) "Direct approval preflight omitted the corrective command."
    Assert-True (-not $directPreflightText.Contains("record-review.ps1 exited")) "Direct approval failure still leaked a nested review-script error."

    $cliHeld = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status held -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliHeld.Contains("held-cli-task")) "Factory CLI held filter omitted the held task."
    Assert-True (-not $cliHeld.Contains("test-task")) "Factory CLI held filter leaked a queued task."
    $cliDone = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status done -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliDone.Contains("done-cli-task")) "Factory CLI done history omitted the completed task."
    Assert-True ($cliDone.Contains("https://app.asana.com/0/0/done-cli-task")) "Factory CLI done history omitted the canonical URL."
    Assert-True (-not $cliDone.Contains("held-cli-task")) "Factory CLI done history leaked an unfinished task."

    $cliInspect = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath inspect held-cli-task -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliInspect.Contains("Task held-cli-task")) "Factory CLI inspect omitted task identity."
    Assert-True ($cliInspect.Contains($unicodeFixture)) "Factory CLI inspect omitted or corrupted the hold reason."
    Assert-True ($cliInspect.Contains("claude attach held1234")) "Factory CLI inspect omitted the attach command."

    $cliChat = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath chat held-cli-task -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliChat.Contains("claude attach held1234")) "Factory CLI chat did not resolve the exact task session."
    Assert-True ($cliChat.Contains("run the printed PowerShell command outside the orchestrator")) "Factory CLI chat did not explain its safe non-nested behavior."

    $cliRejectPreview = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath reject held-cli-task -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliRejectPreview.Contains("Reject preview")) "Factory CLI reject skipped its destructive preview."
    Assert-True ($cliRejectPreview.Contains("factory reject held-cli-task -Yes")) "Factory CLI reject preview omitted the confirmation command."
    Assert-Equal "held" ([string](Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "held-cli-task").status) "Reject preview mutated task state."

    $cliRejectKeep = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath reject held-cli-task -Keep -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliRejectKeep.Contains("Rejected and retained")) "Factory CLI -Keep did not render state-only rejection."
    Assert-Equal "rejected" ([string](Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "held-cli-task").status) "Factory CLI -Keep did not retain the task as rejected."

    $cliRejectDiscard = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath reject reject-cli-task --yes "duplicate task" -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliRejectDiscard.Contains("Rejected and forgotten")) "Factory CLI did not accept --yes or render final rejection."
    Assert-Equal 0 (@((Read-FactoryJson -Path $context.statePath).tasks | Where-Object { [string]$_.id -eq "reject-cli-task" }).Count) "Factory CLI reject did not remove the artifact-free task."

    $cliHold = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath hold review-cli-task -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliHold.Contains("Held")) "Factory CLI hold did not render its transition."
    Assert-Equal "held" ([string](Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "review-cli-task").status) "Factory CLI hold did not update state."

    $cliConcurrency = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath concurrency 3 -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliConcurrency.Contains("Factory coding concurrency: 3")) "Factory CLI concurrency did not call the deterministic setter."
    Assert-Equal 3 ([int](Read-FactoryJson -Path $context.configPath).codingConcurrency) "Factory CLI concurrency wrote an unexpected value."

    $cliCompletion = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath completion status | Out-String)
    Assert-True ($cliCompletion.Contains("Factory completion: available")) "Factory CLI completion diagnostics are unavailable."

    $cliPaths = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath paths -Repository $repository | Out-String)
    Assert-True ($cliPaths.Contains([string]$context.configPath)) "Factory CLI paths omitted the private config path."
    Assert-True ($cliPaths.Contains("factory runtime")) "Factory CLI paths hid runtime placement diagnostics."
    $cliRuntime = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath runtime status -Repository $repository | Out-String)
    Assert-True ($cliRuntime.Contains([string]$context.projectData) -and $cliRuntime.Contains("Resolution: explicit")) "Factory runtime diagnostics omitted active placement or resolution."
    Assert-True ($cliRuntime.Contains("Project mapping is automatic")) "Factory runtime diagnostics implied manual project-directory mapping."
    $cliScheduler = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath scheduler status -Repository $repository -ClaudeCommand $fakeClaude | Out-String)
    Assert-True ($cliScheduler.Contains("Native scheduler: stopped")) "Factory CLI did not render native scheduler status."
    $cliPurgePreview = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath purge -Repository $repository | Out-String)
    Assert-True ($cliPurgePreview.Contains("Project purge preview")) "Factory CLI purge did not require an explicit preview."
    Assert-True (Test-Path -LiteralPath $context.statePath) "Factory CLI purge preview changed private state."

    $previousPath = $env:PATH
    try {
        $env:PATH = "$pluginRoot;$previousPath"
        Push-Location $repository
        try {
            $commandCompletion = @((TabExpansion2 "factory " 8).CompletionMatches | ForEach-Object { [string]$_.CompletionText })
            Assert-True ($commandCompletion -contains "reject" -and $commandCompletion -contains "completion") "PowerShell did not complete the phase-2 factory commands."
            Assert-True ($commandCompletion -contains "start" -and $commandCompletion -contains "rotate" -and $commandCompletion -contains "scheduler" -and $commandCompletion -contains "purge" -and $commandCompletion -contains "preview" -and $commandCompletion -contains "wait" -and $commandCompletion -contains "retry" -and $commandCompletion -contains "runtime") "PowerShell did not complete the unified native commands."
            Assert-True (-not ($commandCompletion -contains "d")) "PowerShell completion still exposes noisy one-letter aliases."
            $statusCompletion = @((TabExpansion2 "factory status h" 16).CompletionMatches | ForEach-Object { [string]$_.CompletionText })
            Assert-True ($statusCompletion -contains "held") "PowerShell did not complete a factory status filter."
            $taskCompletion = @((TabExpansion2 "factory inspect held" 20).CompletionMatches | ForEach-Object { [string]$_.CompletionText })
            Assert-True ($taskCompletion -contains "held-cli-task") "PowerShell did not complete a saved factory task ID. Returned: $($taskCompletion -join ', ')"
            $holdCompletion = @((TabExpansion2 "factory hold review" 19).CompletionMatches | ForEach-Object { [string]$_.CompletionText })
            Assert-True ($holdCompletion -contains "review-cli-task") "PowerShell did not complete task IDs for a phase-2 action."
        } finally {
            Pop-Location
        }
    } finally {
        $env:PATH = $previousPath
    }

    Write-FactoryJsonAtomic -Path $context.statePath -Value $migratedState

    $argvCapture = Join-Path $testRoot "launch-argv.txt"
    $promptCopy = Join-Path $testRoot "prompt-copy.txt"
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $argvCapture
    $env:CLAUDE_FACTORY_TEST_PROMPT_COPY = $promptCopy
    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = $repository
    $databaseEnvironmentCapture = Join-Path $testRoot "worker-test-database.txt"
    $env:CLAUDE_FACTORY_TEST_DB_ENV_FILE = $databaseEnvironmentCapture
    $nativeTick = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action tick -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) |
        ConvertFrom-Json
    Assert-Equal 1 ([int]$nativeTick.launchedCount) "Native scheduler tick did not fill available capacity."
    $launch = @($nativeTick.launched)[0]
    Assert-Equal "test1234" ([string]$launch.backgroundSession.id) "Background ID was not captured."
    Assert-Equal $fakeSessionId ([string]$launch.backgroundSession.sessionId) "Launcher did not bind the authoritative session UUID."
    Assert-Equal "plugin" ([string]$launch.backgroundSession.agentResolution) "Native agent success was not audited."
    Assert-Equal "factory_test_worker_test_task" ([string]$launch.testDatabase) "Worker did not receive its deterministic isolated database."
    Assert-Equal "factory_test_worker_test_task" ((Get-Content -LiteralPath $databaseEnvironmentCapture | Select-Object -Last 1).Trim()) "Claude worker process did not inherit its isolated database."
    $databaseEvents = @(Get-Content -LiteralPath $env:CLAUDE_FACTORY_TEST_PSQL_REGISTRY_FILE)
    Assert-Equal 1 (@($databaseEvents | Where-Object { $_ -eq "create`tfactory_test_worker_test_task" }).Count) "Worker database was not created exactly once."
    Assert-True (@(Get-Content -LiteralPath $env:CLAUDE_FACTORY_TEST_PSQL_AUDIT_FILE | Where-Object { $_ -match 'password-present$' }).Count -gt 0) "PostgreSQL maintenance did not receive the password through process environment."
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

    $previewConfigState = Read-FactoryJson -Path $context.configPath
    $previewConfigState.preview.openBrowser = $false
    $previewConfigState.preview.startupTimeoutSeconds = 10
    $previewConfigState.preview.dependencyLinks = @("shared_dependencies")
    $fakePreviewArguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $pluginRoot "tests\FakePreviewServer.ps1"),
        "-HostName", "{host}", "-Port", "{appPort}"
    )
    $previewConfigState.preview.app.command = "powershell"
    $previewConfigState.preview.app.arguments = $fakePreviewArguments
    $previewConfigState.preview.assets.command = "powershell"
    $previewConfigState.preview.assets.arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $pluginRoot "tests\FakePreviewServer.ps1"),
        "-HostName", "{host}", "-Port", "{assetPort}"
    )
    Write-FactoryJsonAtomic -Path $context.configPath -Value $previewConfigState

    $previewCommonGitDir = (& git -C $repository rev-parse --git-common-dir).Trim()
    if (-not [IO.Path]::IsPathRooted($previewCommonGitDir)) { $previewCommonGitDir = Join-Path $repository $previewCommonGitDir }
    [IO.File]::AppendAllText(
        (Join-Path ([IO.Path]::GetFullPath($previewCommonGitDir)) "info\exclude"),
        "/shared_dependencies/" + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )
    $sharedPreviewDependencies = Join-Path $repository "shared_dependencies"
    New-Item -ItemType Directory -Path $sharedPreviewDependencies -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $sharedPreviewDependencies "fixture.txt"), "shared", (New-Object Text.UTF8Encoding($false)))

    $previewSwitchWorktree = Join-Path ([string]$context.worktreeRoot) "preview-switch-task"
    $previewSwitchBranch = "factory-worker/preview-switch-task"
    & git -C $repository worktree add -b $previewSwitchBranch $previewSwitchWorktree develop 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not create the preview switch worktree fixture." }
    $previewStateFixture = Read-FactoryJson -Path $context.statePath
    $previewSwitchTask = New-FactoryTestTask -Id "preview-switch-task" -Title "Preview switch task" -Now $now
    $previewSwitchTask.status = "held"
    $previewSwitchTask.worktree = $previewSwitchWorktree
    $previewSwitchTask.branch = $previewSwitchBranch
    $previewStateFixture.tasks = @($previewStateFixture.tasks) + @($previewSwitchTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $previewStateFixture

    $previewEligibleStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status -NoReconcile -Repository $repository | Out-String)
    Assert-True ($previewEligibleStatus.Contains("View in browser: factory preview test-task")) "Factory status omitted the worktree browser-preview action."
    $previewEligibleInspect = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath inspect preview-switch-task -NoReconcile -Repository $repository | Out-String)
    Assert-True ($previewEligibleInspect.Contains("Browser preview: factory preview preview-switch-task")) "Factory inspect omitted the worktree browser-preview action."

    $firstPreviewOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath preview test-task -NoOpen -Repository $repository | Out-String)
    Assert-True ($firstPreviewOutput.Contains("Preview") -and $firstPreviewOutput.Contains("factory preview stop")) "Factory CLI did not render a started browser preview."
    $firstPreview = Read-FactoryJson -Path ([string]$context.previewPath)
    Assert-Equal "test-task" ([string]$firstPreview.taskId) "Preview started for the wrong task."
    Assert-True ([int]$firstPreview.app.pid -gt 0 -and [int]$firstPreview.assets.pid -gt 0) "Preview did not record both process identities."
    $firstPreviewDependency = Join-Path ([string]$launch.worktree) "shared_dependencies"
    Assert-True ((Get-Item -LiteralPath $firstPreviewDependency).Attributes -band [IO.FileAttributes]::ReparsePoint) "Preview did not create its temporary dependency junction."

    $previousPreviewErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath preview missing-preview-task -NoOpen -Repository $repository 2>&1)
        $missingPreviewExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreviewErrorAction
    }
    Assert-True ($missingPreviewExit -ne 0) "Preview accepted an unknown task ID."
    $previewAfterInvalidSwitch = Read-FactoryJson -Path ([string]$context.previewPath)
    Assert-Equal "test-task" ([string]$previewAfterInvalidSwitch.taskId) "An invalid preview switch stopped the current task."
    Assert-Equal ([int]$firstPreview.app.pid) ([int]$previewAfterInvalidSwitch.app.pid) "An invalid preview switch replaced the current Laravel process."
    Assert-Equal ([int]$firstPreview.assets.pid) ([int]$previewAfterInvalidSwitch.assets.pid) "An invalid preview switch replaced the current Vite process."

    $secondPreviewOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath preview preview-switch-task --no-open -Repository $repository | Out-String)
    Assert-True ($secondPreviewOutput.Contains("Switched: stopped preview test-task")) "Starting another preview did not report automatic switching."
    $secondPreview = Read-FactoryJson -Path ([string]$context.previewPath)
    Assert-Equal "preview-switch-task" ([string]$secondPreview.taskId) "Preview switch retained the old task."
    Assert-True (-not (Test-Path -LiteralPath $firstPreviewDependency)) "Preview switch retained the previous task's dependency junction."
    $secondPreviewDependency = Join-Path $previewSwitchWorktree "shared_dependencies"
    Assert-True ((Get-Item -LiteralPath $secondPreviewDependency).Attributes -band [IO.FileAttributes]::ReparsePoint) "Preview switch did not create the new task's dependency junction."
    foreach ($oldPid in @([int]$firstPreview.app.pid, [int]$firstPreview.assets.pid)) {
        $oldAlive = $true
        try { $null = Get-Process -Id $oldPid -ErrorAction Stop } catch { $oldAlive = $false }
        Assert-Equal $false $oldAlive "Automatic preview switching left PID $oldPid running."
    }

    $reusedPreviewOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath preview preview-switch-task -NoOpen -Repository $repository | Out-String)
    Assert-True ($reusedPreviewOutput.Contains("Reused the existing preview processes")) "Repeated preview start did not reuse the active task."
    $reusedPreview = Read-FactoryJson -Path ([string]$context.previewPath)
    Assert-Equal ([int]$secondPreview.app.pid) ([int]$reusedPreview.app.pid) "Repeated preview start replaced the Laravel process."
    Assert-Equal ([int]$secondPreview.assets.pid) ([int]$reusedPreview.assets.pid) "Repeated preview start replaced the Vite process."
    $previewStatusOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath preview -Repository $repository | Out-String)
    Assert-True ($previewStatusOutput.Contains("preview-switch-task") -and $previewStatusOutput.Contains([string]$secondPreview.url)) "Preview status omitted active task identity or URL."
    $previewWorktreeLiteral = $previewSwitchWorktree.Replace("'", "''")
    $residualPreviewProcess = Start-Process powershell -ArgumentList @(
        "-NoProfile", "-Command", "`$factoryPreviewWorktree='$previewWorktreeLiteral'; Start-Sleep -Seconds 120"
    ) -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 250
    $residualAliveAfterStop = $true
    try {
        $previewStopOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath preview stop -Repository $repository | Out-String)
        try { $null = Get-Process -Id $residualPreviewProcess.Id -ErrorAction Stop } catch { $residualAliveAfterStop = $false }
    } finally {
        if ($residualAliveAfterStop) {
            & taskkill /PID ([string]$residualPreviewProcess.Id) /T /F 1> $null 2> $null
        }
        $residualPreviewProcess.Dispose()
    }
    Assert-True ($previewStopOutput.Contains("Factory preview stopped: preview-switch-task")) "Factory preview stop did not report the stopped task."
    Assert-Equal $false $residualAliveAfterStop "Factory preview stop left an unrecorded process that referenced the worktree."
    Assert-True (-not (Test-Path -LiteralPath ([string]$context.previewPath))) "Factory preview stop retained active metadata."
    Assert-True (-not (Test-Path -LiteralPath $secondPreviewDependency)) "Factory preview stop retained its dependency junction."
    foreach ($stoppedPid in @([int]$secondPreview.app.pid, [int]$secondPreview.assets.pid)) {
        $stoppedAlive = $true
        try { $null = Get-Process -Id $stoppedPid -ErrorAction Stop } catch { $stoppedAlive = $false }
        Assert-Equal $false $stoppedAlive "Factory preview stop left PID $stoppedPid running."
    }
    & git -C $repository worktree remove --force $previewSwitchWorktree 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not remove the preview switch worktree fixture." }
    & git -C $repository branch -D $previewSwitchBranch 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not remove the preview switch branch fixture." }
    $previewStateFixture = Read-FactoryJson -Path $context.statePath
    $previewStateFixture.tasks = @($previewStateFixture.tasks | Where-Object { [string]$_.id -ne "preview-switch-task" })
    Write-FactoryJsonAtomic -Path $context.statePath -Value $previewStateFixture

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
    foreach ($allowedGuardCommand in @(
        "git status --short",
        "git merge-base A B",
        "git merge-tree A B",
        "git log --merges --oneline",
        "git diff A B",
        "git cherry-pick deadbeef",
        "git revert deadbeef"
    )) {
        $allowedGuardPayload = [ordered]@{
            cwd = [string]$launch.worktree
            tool_input = [ordered]@{ command = $allowedGuardCommand }
        } | ConvertTo-Json -Depth 5 -Compress
        $allowedGuardOutput = @($allowedGuardPayload | & powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript)
        Assert-Equal 0 $LASTEXITCODE "Allowed worker command failed the guard: $allowedGuardCommand"
        Assert-Equal 0 $allowedGuardOutput.Count "Allowed worker command emitted a denial: $allowedGuardCommand"
    }
    foreach ($blockedGuardFixture in @(
        [pscustomobject]@{ command = "git push origin HEAD"; name = "git push" },
        [pscustomobject]@{ command = "git merge feature"; name = "git merge" },
        [pscustomobject]@{ command = "git rebase origin/develop"; name = "git rebase" }
    )) {
        $blockedGuardPayload = [ordered]@{
            cwd = [string]$launch.worktree
            tool_input = [ordered]@{ command = [string]$blockedGuardFixture.command }
        } | ConvertTo-Json -Depth 5 -Compress
        $blockedGuardResult = ($blockedGuardPayload | & powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript) | ConvertFrom-Json
        Assert-Equal "deny" ([string]$blockedGuardResult.hookSpecificOutput.permissionDecision) "Worker command was not denied: $($blockedGuardFixture.command)"
        Assert-True ([string]$blockedGuardResult.hookSpecificOutput.permissionDecisionReason -match [regex]::Escape([string]$blockedGuardFixture.name)) "Git guard denial did not name '$($blockedGuardFixture.name)'."
    }

    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = [string]$launch.worktree
    $sessionReconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    $sessionState = Read-FactoryJson -Path $context.statePath
    Assert-Equal $fakeSessionId ([string]$sessionState.tasks[0].backgroundSession.sessionId) "Current Claude agents schema was not reconciled."
    Assert-Equal "working" ([string]$sessionState.tasks[0].backgroundSession.state) "Current Claude status field was not captured."
    Assert-Equal "live-transcript" ([string]$sessionState.tasks[0].backgroundSession.transcriptPath) "A stale same-shape agent row overwrote authoritative metadata."

    $blockedSessionTask = New-FactoryTestTask -Id "blocked-session-task" -Title "Surface a blocked worker" -Now (Get-FactoryUtcTimestamp)
    $blockedSessionTask.status = "running"
    $blockedSessionWorktree = Join-Path $testRoot "blocked-session-worktree"
    New-Item -ItemType Directory -Path $blockedSessionWorktree -Force | Out-Null
    $blockedSessionTask.worktree = $blockedSessionWorktree
    $blockedSessionTask.backgroundSession = [pscustomobject]@{
        runtime = "claude"; id = "blocked123"; sessionId = "blocked123-session"
        name = "factory-blocked-session-task"; state = "working"; lastSeenAt = (Get-FactoryUtcTimestamp)
    }
    $blockedFixtureState = Read-FactoryJson -Path $context.statePath
    $blockedFixtureState.tasks = @($blockedFixtureState.tasks) + @($blockedSessionTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $blockedFixtureState
    [IO.File]::AppendAllText(
        $env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE,
        "launch`tblocked123`t$blockedSessionWorktree`tfactory-blocked-session-task`tblocked" + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )
    $blockedFixtureConfig = Read-FactoryJson -Path $context.configPath
    $blockedFixtureConfig.blockedSessionTimeoutMinutes = 60
    Write-FactoryJsonAtomic -Path $context.configPath -Value $blockedFixtureConfig
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $blockedVisibleTask = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "blocked-session-task"
    Assert-Equal "running" ([string]$blockedVisibleTask.status) "A newly observed blocked session timed out immediately."
    Assert-Equal "blocked" ([string]$blockedVisibleTask.backgroundSession.state) "Blocked session state was not persisted."
    Assert-True ([bool][string]$blockedVisibleTask.backgroundSession.blockedAt) "Blocked session did not record when the stall began."
    Assert-True ([string]$blockedVisibleTask.backgroundSession.blockedReason -match "lastAssistantMessage") "Blocked session did not carry an actionable wait reason."
    $blockedStatusOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status blocked -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($blockedStatusOutput.Contains("SESSION BLOCKED") -and $blockedStatusOutput.Contains("blocked-session-task")) "Factory status hid a blocked runtime session behind the task state."
    $blockedDoctor = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-doctor.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $blockedDoctorCheck = @($blockedDoctor.checks | Where-Object { [string]$_.name -eq "blockedWorkerSessions" })[0]
    Assert-True (-not [bool]$blockedDoctorCheck.passed -and [string]$blockedDoctorCheck.detail -match "blocked-session-task") "Factory doctor did not report a blocked worker session."

    $blockedTimeoutState = Read-FactoryJson -Path $context.statePath
    $blockedTimeoutTask = Get-FactoryTask -State $blockedTimeoutState -TaskId "blocked-session-task"
    $blockedTimeoutTask.backgroundSession.blockedAt = [DateTime]::UtcNow.AddMinutes(-2).ToString("o", [Globalization.CultureInfo]::InvariantCulture)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $blockedTimeoutState
    $blockedFixtureConfig.blockedSessionTimeoutMinutes = 1
    Write-FactoryJsonAtomic -Path $context.configPath -Value $blockedFixtureConfig
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $blockedTimedOutTask = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "blocked-session-task"
    Assert-Equal "blocked" ([string]$blockedTimedOutTask.status) "A long-blocked session continued consuming a coding slot."
    Assert-True ([string]$blockedTimedOutTask.holdReason -match "remained blocked") "Blocked-session timeout omitted the stall reason."
    $blockedCleanupState = Read-FactoryJson -Path $context.statePath
    $blockedCleanupState.tasks = @($blockedCleanupState.tasks | Where-Object { [string]$_.id -ne "blocked-session-task" })
    Write-FactoryJsonAtomic -Path $context.statePath -Value $blockedCleanupState
    $blockedFixtureConfig.blockedSessionTimeoutMinutes = 30
    Write-FactoryJsonAtomic -Path $context.configPath -Value $blockedFixtureConfig

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
    $answerTranscript = Join-Path $testRoot "answer-transcript.jsonl"
    [IO.File]::WriteAllText($answerTranscript, "transcript survives", (New-Object Text.UTF8Encoding($false)))
    $answerRmCapture = Join-Path $testRoot "answer-rm.txt"
    $env:CLAUDE_FACTORY_TEST_TRANSCRIPT_PATH = $answerTranscript
    $env:CLAUDE_FACTORY_TEST_RM_FILE = $answerRmCapture
    $answered = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\answer-task.ps1") -Repository $repository -TaskId "test-task" -Text $answers -Mode auto -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal "queued" ([string]$answered.status) "Answer did not queue the retained worker task."
    Assert-Equal 2 (@($answered.removedAgentSessions).Count) "Answer did not remove every previous task row."
    Assert-True (Test-Path -LiteralPath $answerTranscript) "Removing Agent View rows deleted the retained transcript."
    $answerRemovedIds = @(Get-Content -LiteralPath $answerRmCapture | Where-Object { $_ })
    Assert-True ($answerRemovedIds -contains "stale000" -and $answerRemovedIds -contains "test1234") "Answer removed the wrong session rows."
    Assert-True ($answerRemovedIds -notcontains "other999" -and $answerRemovedIds -notcontains "orchestrator-static") "Answer touched another task or the orchestrator."
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FILE -ErrorAction SilentlyContinue
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

    $invalidHookInput = [ordered]@{
        session_id = $fakeSessionId
        transcript_path = (Join-Path $testRoot "invalid-marker-transcript.jsonl")
        cwd = [string]$launch.worktree
        hook_event_name = "Stop"
        last_assistant_message = "FACTORY_RESULT`n{`"status`":`"completed`", broken}"
    } | ConvertTo-Json -Depth 20
    Invoke-FactoryHookWithUtf8Input `
        -HookPath (Join-Path $pluginRoot "scripts\capture-worker-stop.ps1") `
        -InputText $invalidHookInput
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $invalidMarkerState = Read-FactoryJson -Path $context.statePath
    Assert-Equal "failed" ([string]$invalidMarkerState.tasks[0].status) "Malformed marker JSON did not fail the active task explicitly."
    Assert-True ([string]$invalidMarkerState.tasks[0].error -match "Invalid FACTORY_RESULT payload:.*invalid JSON") "Malformed marker parse reason did not reach the task error."
    $invalidMarkerState.tasks[0].status = "running"
    $invalidMarkerState.tasks[0].error = $null
    Write-FactoryJsonAtomic -Path $context.statePath -Value $invalidMarkerState

    [IO.File]::AppendAllText(
        (Join-Path $launch.worktree "README.md"),
        "changed`n",
        (New-Object Text.UTF8Encoding($false))
    )
    & git -C $launch.worktree add README.md
    & git -C $launch.worktree commit -m "fix(test-task): change README" 1> $null
    $commit = (& git -C $launch.worktree rev-parse HEAD).Trim()

    $resultNotesWithMarker = "$unicodeFixture | FACTORY_RESULT emitted again."
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
        notes = $resultNotesWithMarker
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
    Invoke-FactoryHookWithUtf8Input `
        -HookPath (Join-Path $pluginRoot "scripts\capture-worker-stop.ps1") `
        -InputText $hookInput

    $reconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-True ($reconcile.changed -ge 1) "Reconciliation recorded no transition."

    $state = Read-FactoryJson -Path $context.statePath
    $task = $state.tasks[0]
    Assert-Equal "awaiting-review" ([string]$task.status) "Completed worker bypassed or missed the review gate."
    Assert-Equal $commit ([string]$task.commit) "Validated commit was not recorded."
    Assert-Equal $resultNotesWithMarker ([string]$task.workerResult.notes) "Stop-hook input corrupted UTF-8 worker output or selected a marker inside notes."
    Assert-True (-not [string]$task.approval) "Task was approved automatically."

    $renameTaskId = "rename-result-task"
    $renameBranch = "factory-worker/$renameTaskId-a1"
    $renameWorktree = Join-Path ([string]$context.worktreeRoot) "worker-$renameTaskId-a1"
    & git -C $repository worktree add -b $renameBranch $renameWorktree origin/develop 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not create the rename validation worktree fixture." }
    & git -C $renameWorktree mv README.md RENAMED-README.md
    if ($LASTEXITCODE -ne 0) { throw "Could not stage the rename validation fixture." }
    & git -C $renameWorktree commit -m "test: rename README fixture" 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not commit the rename validation fixture." }
    $renameCommit = (& git -C $renameWorktree rev-parse HEAD).Trim()
    $renameSessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    $renameTask = New-FactoryTestTask -Id $renameTaskId -Title "Rename result validation" -Now (Get-FactoryUtcTimestamp)
    $renameTask.status = "running"
    $renameTask.attempts = 1
    $renameTask.branch = $renameBranch
    $renameTask.worktree = $renameWorktree
    $renameTask.backgroundSession = [pscustomobject]@{
        runtime = "claude"
        id = "rename-bg"
        sessionId = $renameSessionId
        name = "factory-$renameTaskId"
        state = "done"
        lastSeenAt = (Get-FactoryUtcTimestamp)
    }
    $renameFixtureState = Read-FactoryJson -Path $context.statePath
    $renameFixtureState.tasks = @($renameFixtureState.tasks) + @($renameTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $renameFixtureState

    $renameReportedResult = [ordered]@{
        status = "completed"
        taskId = $renameTaskId
        branch = $renameBranch
        commit = $renameCommit
        worktree = $renameWorktree
        changedFiles = @("RENAMED-README.md", "reported-only.txt")
        tests = @([ordered]@{ command = "git diff --check"; status = "passed"; summary = "clean" })
        notes = "The reported list is deliberately incomplete."
        blockingReason = ""
    }
    $null = Publish-FactoryWorkerEvent `
        -Context $context `
        -Task $renameTask `
        -SessionId $renameSessionId `
        -Worktree $renameWorktree `
        -Message ("FACTORY_RESULT`n" + ($renameReportedResult | ConvertTo-Json -Depth 20)) `
        -EventName "RenameFixture"
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $renameValidatedState = Read-FactoryJson -Path $context.statePath
    $renameValidatedTask = Get-FactoryTask -State $renameValidatedState -TaskId $renameTaskId
    Assert-Equal "awaiting-review" ([string]$renameValidatedTask.status) "A valid git mv commit was rejected by changed-files validation."
    Assert-True (@($renameValidatedTask.workerResult.changedFiles) -contains "README.md") "Derived changedFiles omitted the deleted side of a rename."
    Assert-True (@($renameValidatedTask.workerResult.changedFiles) -contains "RENAMED-README.md") "Derived changedFiles omitted the added side of a rename."
    Assert-True (-not [string]$renameValidatedTask.error) "A diagnostic changed-files mismatch failed the task."
    $renameEventPath = Join-Path (Join-Path ([string]$context.eventsPath) (ConvertTo-FactoryTaskArtifactName -TaskId $renameTaskId)) "latest-result.json"
    $renameResultEvent = Read-FactoryJson -Path $renameEventPath
    $renameDiagnostic = [string]$renameResultEvent.changedFilesDiagnostic.error
    Assert-True ($renameDiagnostic.Contains("Missing from report: 'README.md'")) "Changed-files diagnostics did not name the missing path."
    Assert-True ($renameDiagnostic.Contains("Extra in report: 'reported-only.txt'")) "Changed-files diagnostics did not name the extra path."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId $renameTaskId -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json

    $operatorState = Read-FactoryJson -Path $context.statePath
    $operatorStateTask = New-FactoryTestTask -Id "operator-state-task" -Title "Operator-owned input state" -Now $now
    $operatorStateTask.status = "awaiting-input"
    Set-FactoryProperty -Target $operatorStateTask -Name "reworkRequestedAt" -Value (Get-FactoryUtcTimestamp)
    Set-FactoryProperty -Target $operatorStateTask -Name "backgroundSession" -Value ([pscustomobject]@{
        runtime = "claude"; id = "test1234"; sessionId = $fakeSessionId
        name = "factory-operator-state-task"; state = "working"; lastSeenAt = (Get-FactoryUtcTimestamp)
    })
    $operatorStateTask.worktree = [string]$launch.worktree
    $operatorState.tasks = @($operatorState.tasks) + @($operatorStateTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $operatorState
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $operatorStateAfter = Read-FactoryJson -Path $context.statePath
    Assert-Equal "awaiting-input" ([string](Get-FactoryTask -State $operatorStateAfter -TaskId "operator-state-task").status) "A working row overrode an operator-owned awaiting-input state."
    $operatorStateAfter.tasks = @($operatorStateAfter.tasks | Where-Object { [string]$_.id -ne "operator-state-task" })
    Write-FactoryJsonAtomic -Path $context.statePath -Value $operatorStateAfter

    $beforeMissingState = Read-FactoryJson -Path $context.statePath
    $beforeMissingTask = Get-FactoryTask -State $beforeMissingState -TaskId "test-task"
    $lastSeenBeforeMissing = [string]$beforeMissingTask.backgroundSession.lastSeenAt
    $env:CLAUDE_FACTORY_TEST_NO_AGENTS = "1"
    $missingReconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Remove-Item Env:\CLAUDE_FACTORY_TEST_NO_AGENTS -ErrorAction SilentlyContinue
    $missingState = Read-FactoryJson -Path $context.statePath
    $missingTask = Get-FactoryTask -State $missingState -TaskId "test-task"
    Assert-Equal "stopped" ([string]$missingTask.backgroundSession.state) "A vanished worker session was not recorded as stopped."
    Assert-Equal "awaiting-review" ([string]$missingTask.status) "A vanished session downgraded a validated awaiting-review task."
    Assert-Equal $lastSeenBeforeMissing ([string]$missingTask.backgroundSession.lastSeenAt) "A missing session falsely refreshed lastSeenAt."

    $missingTask.status = "running"
    $missingTask.backgroundSession = [pscustomobject]@{
        runtime = "claude"; id = "missing-release"; sessionId = "missing-release-session"
        name = "factory-test-task-missing-release"; state = "working"; lastSeenAt = $lastSeenBeforeMissing
    }
    Write-FactoryJsonAtomic -Path $context.statePath -Value $missingState
    $released = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") -Repository $repository -Action release -TaskId "test-task" -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal "awaiting-review" ([string]$released.status) "Explicit stale-session release did not restore the artifact-derived review state."
    $releasedState = Read-FactoryJson -Path $context.statePath
    Assert-True ($null -eq $releasedState.tasks[0].backgroundSession) "Explicit stale-session release retained the missing session identity."

    $syncState = Read-FactoryJson -Path $context.statePath
    Write-FactoryJsonAtomic -Path $context.statePath -Value $syncState
    [IO.File]::WriteAllText(
        (Join-Path $repository "BASE.md"),
        "new development base`n",
        (New-Object Text.UTF8Encoding($false))
    )
    & git -C $repository add BASE.md
    & git -C $repository commit -m "chore: advance development" 1> $null
    & git -C $repository push origin develop 1> $null
    $syncLease = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
        -Action acquire -Repository $repository -TaskId "test-task" -Phase verify -OwnerPid $PID -NoHeartbeat) | ConvertFrom-Json
    $syncDelayMarker = Join-Path $testRoot "sync-outside-state-lock.marker"
    $syncStdout = Join-Path $testRoot "sync-outside-state-lock.stdout"
    $syncStderr = Join-Path $testRoot "sync-outside-state-lock.stderr"
    $env:CLAUDE_FACTORY_TEST_SYNC_DELAY_MILLISECONDS = "4000"
    $env:CLAUDE_FACTORY_TEST_SYNC_DELAY_MARKER = $syncDelayMarker
    $syncArguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $pluginRoot "scripts\sync-task.ps1"),
        "-Repository", $repository, "-TaskId", "test-task", "-Action", "prepare", "-LeaseToken", ([string]$syncLease.token)
    ) | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }
    $syncProcess = Start-Process -FilePath (Get-Command powershell -ErrorAction Stop).Source `
        -ArgumentList ($syncArguments -join " ") -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $syncStdout -RedirectStandardError $syncStderr
    try {
        $syncMarkerDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $syncDelayMarker) -and [DateTime]::UtcNow -lt $syncMarkerDeadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $syncDelayMarker) "Long sync fixture did not reach its unlocked work phase."
        $stateMutexProbe = $null
        try {
            $stateMutexProbe = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey) -TimeoutMilliseconds 2000
        } finally {
            Exit-FactoryMutex -Mutex $stateMutexProbe
        }
        Assert-True ($syncProcess.WaitForExit(30000)) "Long sync fixture did not complete."
        Assert-Equal 0 ([int]$syncProcess.ExitCode) "Sync outside-lock fixture failed: $(Get-Content -LiteralPath $syncStderr -Raw)"
        $sync = (Get-Content -LiteralPath $syncStdout -Raw) | ConvertFrom-Json
    } finally {
        Remove-Item Env:\CLAUDE_FACTORY_TEST_SYNC_DELAY_MILLISECONDS -ErrorAction SilentlyContinue
        Remove-Item Env:\CLAUDE_FACTORY_TEST_SYNC_DELAY_MARKER -ErrorAction SilentlyContinue
        if (-not $syncProcess.HasExited) { Stop-Process -Id $syncProcess.Id -Force -ErrorAction SilentlyContinue }
        $syncProcess.Dispose()
    }
    Assert-Equal "syncing" ([string]$sync.status) "Task sync did not require fresh validation."
    Assert-True ([string]$sync.commit -ne $commit) "Task sync did not replace the old commit SHA."
    Assert-True (Test-Path -LiteralPath (Join-Path $launch.worktree "BASE.md")) "Worker worktree did not receive the latest development base."
    $commit = [string]$sync.commit
    [IO.File]::WriteAllText(
        (Join-Path $repository "BASE-SECOND.md"),
        "development moved after prepare`n",
        (New-Object Text.UTF8Encoding($false))
    )
    & git -C $repository add BASE-SECOND.md
    & git -C $repository commit -m "chore: advance development after sync prepare" 1> $null
    & git -C $repository push origin develop 1> $null
    $syncReprepared = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\sync-task.ps1") `
        -Repository $repository -TaskId "test-task" -Action prepare -LeaseToken ([string]$syncLease.token)) | ConvertFrom-Json
    Assert-Equal "syncing" ([string]$syncReprepared.status) "A prepared task did not remain in sync validation after the base moved."
    Assert-True (-not [bool]$syncReprepared.alreadyPrepared) "Sync prepare reused a marker for an older development base."
    Assert-True ([string]$syncReprepared.commit -ne $commit) "Sync prepare did not re-rebase after development moved."
    Assert-True (Test-Path -LiteralPath (Join-Path $launch.worktree "BASE-SECOND.md")) "Re-prepared worker worktree did not receive the second development base."
    $commit = [string]$syncReprepared.commit
    $syncPreparationState = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "test-task"
    Assert-Equal ([string]$syncReprepared.baseCommit) ([string]$syncPreparationState.syncPreparation.baseCommit) "Sync preparation marker did not record the current development base."
    $syncReportPath = Join-Path $context.sessionsPath "test-task.sync-tests.json"
    Write-FactoryJsonAtomic -Path $syncReportPath -Value ([pscustomobject]@{
        tests = @([pscustomobject]@{
            command = "git diff --check"
            status = "passed"
            summary = "No whitespace errors."
        })
    })
    $syncFinal = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\sync-task.ps1") `
        -Repository $repository -TaskId "test-task" -Action finalize -TestsPath $syncReportPath -LeaseToken ([string]$syncLease.token)) | ConvertFrom-Json
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
        -Action release -Repository $repository -Token ([string]$syncLease.token)) | ConvertFrom-Json
    Assert-Equal "awaiting-review" ([string]$syncFinal.status) "Task sync did not return to review."
    Assert-Equal $commit ([string]$syncFinal.commit) "Task sync finalized the wrong commit."
    Assert-True (-not (Test-Path -LiteralPath $syncReportPath)) "Task sync did not remove its temporary test report."
    $syncFinalState = Read-FactoryJson -Path $context.statePath
    Assert-Equal "Rebased onto the configured development branch and revalidated." ([string]$syncFinalState.tasks[0].workerResult.notes) "Sync finalize did not default an omitted optional notes field under StrictMode."

    $phaseFourConfig = Read-FactoryJson -Path $context.configPath
    $phaseFourConfig.autoPushDevelopment = $true
    $phaseFourConfig.autoPromoteToProduction = $true
    Write-FactoryJsonAtomic -Path $context.configPath -Value $phaseFourConfig
    $reviewPath = Join-Path $context.sessionsPath "test-task.review.json"
    Write-FactoryJsonAtomic -Path $reviewPath -Value ([pscustomobject]@{
        commit = $commit
        verdict = "approved"
        summary = "The synchronized fixture is safe to publish."
        riskNotes = @("Synthetic README-only change.")
        integrationTestCommands = @("git diff --check")
        releaseTestCommands = @("git diff --check")
    })
    $recordedReview = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\record-review.ps1") -Repository $repository -TaskId "test-task" -ReviewPath $reviewPath) |
        ConvertFrom-Json
    Assert-Equal "approved" ([string]$recordedReview.verdict) "Formal review verdict was not recorded."
    Assert-Equal 64 ([string]$recordedReview.planHash).Length "Formal review plan was not hashed."
    Assert-True (-not (Test-Path -LiteralPath $reviewPath)) "Formal review input was not removed from private sessions."

    $reworkWorktree = Join-Path ([string]$context.worktreeRoot) "worker-rework-task"
    $reworkBranch = "factory-worker/rework-task"
    & git -C $repository fetch origin develop 1> $null
    & git -C $repository worktree add -b $reworkBranch $reworkWorktree origin/develop 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not create rework delivery fixture worktree." }
    [IO.File]::WriteAllText((Join-Path $reworkWorktree "REWORK.md"), "first version`n", (New-Object Text.UTF8Encoding($false)))
    & git -C $reworkWorktree add REWORK.md
    & git -C $reworkWorktree commit -m "test: rework delivery" 1> $null
    $reworkCommit = (& git -C $reworkWorktree rev-parse HEAD).Trim()
    $reworkState = Read-FactoryJson -Path $context.statePath
    $reworkTask = New-FactoryTestTask -Id "rework-task" -Title "Deliver review findings" -Now (Get-FactoryUtcTimestamp)
    $reworkTask.status = "awaiting-review"
    $reworkTask.attempts = 1
    $reworkTask.branch = $reworkBranch
    $reworkTask.commit = $reworkCommit
    $reworkTask.worktree = $reworkWorktree
    $reworkTask.workerResult = [pscustomobject]@{
        status = "completed"; taskId = "rework-task"; branch = $reworkBranch; commit = $reworkCommit
        worktree = $reworkWorktree; changedFiles = @("REWORK.md")
        tests = @([pscustomobject]@{ command = "git diff --check"; status = "passed"; summary = "Clean diff." })
        notes = "Initial result."; blockingReason = ""
    }
    $reworkTask.review = [pscustomobject]@{
        verdict = "changes-required"; commit = $reworkCommit; summary = "Compatibility must be retained."
        riskNotes = @("Preserve the legacy field."); reviewedAt = Get-FactoryUtcTimestamp
    }
    $reworkTask.approval = [pscustomobject]@{ commit = $reworkCommit; approvedAt = Get-FactoryUtcTimestamp }
    $reworkTask.backgroundSession = [pscustomobject]@{
        runtime = "claude"; id = "rework-old"; sessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        name = "factory-rework-task-old"; state = "stopped"; lastSeenAt = Get-FactoryUtcTimestamp
    }
    $reworkState.tasks = @($reworkState.tasks) + @($reworkTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $reworkState
    [IO.File]::AppendAllText(
        [string]$env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE,
        "launch`trework-old`t$reworkWorktree`tfactory-rework-task-old`tstopped`n",
        (New-Object Text.UTF8Encoding($false))
    )

    $reworkFindings = "Keep the exact legacy response field and add its regression test."
    $reworked = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") -Repository $repository -Action rework -TaskId "rework-task" -Instructions $reworkFindings -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal "queued" ([string]$reworked.status) "Rework did not queue a deliverable worker attempt."
    $reworkedState = Read-FactoryJson -Path $context.statePath
    $reworkedTask = Get-FactoryTask -State $reworkedState -TaskId "rework-task"
    Assert-Equal $reworkCommit ([string]$reworkedTask.commit) "Rework discarded the validated commit."
    Assert-Equal $reworkCommit ([string]$reworkedTask.workerResult.commit) "Rework discarded the prior worker result."
    Assert-True ($null -eq $reworkedTask.review -and $null -eq $reworkedTask.approval) "Rework retained review or approval."
    Assert-True ($null -eq $reworkedTask.backgroundSession) "Rework retained the old session identity."
    Assert-Equal $reworkFindings ([string]$reworkedTask.pendingInstructions) "Rework changed the requested findings."

    $postCommitAnswer = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\answer-task.ps1") -Repository $repository -TaskId "rework-task" -Text "Apply the review findings to the retained commit." -Mode auto -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal "queued" ([string]$postCommitAnswer.status) "An explicit rework task rejected a post-commit answer."
    $reworkPromptCopy = Join-Path $testRoot "rework-prompt-copy.txt"
    $previousPromptCopy = $env:CLAUDE_FACTORY_TEST_PROMPT_COPY
    try {
        $env:CLAUDE_FACTORY_TEST_PROMPT_COPY = $reworkPromptCopy
        $reworkTick = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action tick -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    } finally {
        $env:CLAUDE_FACTORY_TEST_PROMPT_COPY = $previousPromptCopy
    }
    Assert-Equal 1 ([int]$reworkTick.launchedCount) "Rework was not relaunched within one scheduler tick."
    $relaunchedState = Read-FactoryJson -Path $context.statePath
    $relaunchedTask = Get-FactoryTask -State $relaunchedState -TaskId "rework-task"
    Assert-True ($null -ne $relaunchedTask.backgroundSession -and [string]$relaunchedTask.backgroundSession.id -ne "rework-old") "Rework reused the previous session identity."
    Assert-True ($null -eq $relaunchedTask.pendingInstructions) "Rework instructions were not cleared after prompt delivery."
    Assert-True ($null -eq $relaunchedTask.review -and $null -eq $relaunchedTask.approval) "Relaunch restored a stale review or approval."
    $reworkPromptText = [IO.File]::ReadAllText($reworkPromptCopy, [Text.Encoding]::UTF8)
    Assert-True ($reworkPromptText.Contains($reworkFindings)) "Relaunched worker prompt omitted the review findings."
    Assert-True ($reworkPromptText.Contains($reworkCommit)) "Relaunched worker prompt omitted the retained commit."
    Assert-True ($reworkPromptText.Contains("exactly one task commit")) "Relaunched worker prompt omitted the amend/single-commit invariant."
    $reworkRows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $fakeClaude)
    Assert-Equal 0 (@($reworkRows | Where-Object {
        $null -ne $_.PSObject.Properties["id"] -and [string]$_.id -eq "rework-old"
    }).Count) "Rework left the previous Agent View row alive."
    $reworkDiscard = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "rework-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-True ([bool]$reworkDiscard.removedFromState) "Rework fixture could not be discarded after relaunch."

    $publicationReadyState = Read-FactoryJson -Path $context.statePath
    $readyDirectCliTask = New-FactoryTestTask -Id "ready-direct-cli-task" -Title "Ready direct CLI task" -Now $now
    $readyDirectCliTask.status = "held"
    $readyDirectCliTask.commit = "abcdef1234567890abcdef1234567890abcdef12"
    $readyDirectCliTask.workerResult = [pscustomobject]@{
        commit = $readyDirectCliTask.commit
        notes = "Ready."
        tests = @([pscustomobject]@{ command = "git diff --check"; status = "passed"; summary = "Clean diff." })
        changedFiles = @()
    }
    $publicationReadyState.tasks = @($publicationReadyState.tasks) + @($readyDirectCliTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $publicationReadyState
    $publicationReadyStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status held -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($publicationReadyStatus.Contains("!factory go ready-direct-cli-task --direct")) "Factory CLI status omitted direct approval after publication became ready."
    $publicationReadyState = Read-FactoryJson -Path $context.statePath
    $publicationReadyState.tasks = @($publicationReadyState.tasks | Where-Object { [string]$_.id -ne "ready-direct-cli-task" })
    Write-FactoryJsonAtomic -Path $context.statePath -Value $publicationReadyState

    $tamperedState = Read-FactoryJson -Path $context.statePath
    $savedReview = $tamperedState.tasks[0].review | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $tamperedState.tasks[0].review.integrationPlan.integrationTestCommands = @("git diff --check", "git status --short")
    Write-FactoryJsonAtomic -Path $context.statePath -Value $tamperedState
    $previousTamperErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") -Repository $repository -Action go -TaskId "test-task" 2>&1)
        $tamperedGoExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousTamperErrorAction
    }
    Assert-True ($tamperedGoExit -ne 0) "Native go accepted a tampered integration plan."
    $restoredReviewState = Read-FactoryJson -Path $context.statePath
    $restoredReviewState.tasks[0].review = $savedReview
    Write-FactoryJsonAtomic -Path $context.statePath -Value $restoredReviewState

    $approvalPreviewOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath preview test-task -NoOpen -Repository $repository | Out-String)
    Assert-True ($approvalPreviewOutput.Contains([string]$launch.worktree)) "Approval preview fixture did not start from the task worktree."
    $approvalPreview = Read-FactoryJson -Path ([string]$context.previewPath)
    $decision = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") -Repository $repository -Action go -TaskId "test-task") |
        ConvertFrom-Json
    Assert-Equal "approved" ([string]$decision.status) "Explicit go did not approve the task."
    Assert-Equal $commit ([string]$decision.approvedCommit) "Approval did not pin the exact commit."
    Assert-Equal ([string]$recordedReview.planHash) ([string]$decision.approvedPlanHash) "Approval did not pin the formal plan hash."
    Assert-True ([bool]$decision.stoppedPreview) "Approval did not stop the task's active browser preview."
    Assert-True (-not (Test-Path -LiteralPath ([string]$context.previewPath))) "Approval retained active preview metadata."
    foreach ($approvalPreviewPid in @([int]$approvalPreview.app.pid, [int]$approvalPreview.assets.pid)) {
        $approvalPreviewAlive = $true
        try { $null = Get-Process -Id $approvalPreviewPid -ErrorAction Stop } catch { $approvalPreviewAlive = $false }
        Assert-Equal $false $approvalPreviewAlive "Approval left preview PID $approvalPreviewPid running."
    }

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
    $cleanupSessionState = Read-FactoryJson -Path $context.statePath
    $cleanupSessionState.tasks[0].backgroundSession = $launch.backgroundSession
    $cleanupSessionState.tasks[0].backgroundSession.state = "done"
    Write-FactoryJsonAtomic -Path $context.statePath -Value $cleanupSessionState
    [IO.File]::AppendAllText(
        [string]$env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE,
        "launch`ttest1234`t$($launch.worktree)`t$([string]$launch.backgroundSession.name)`tworking`n",
        (New-Object Text.UTF8Encoding($false))
    )

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

    $env:CLAUDE_FACTORY_TEST_LIVE_TERMINAL_ID = "test1234"
    $env:CLAUDE_FACTORY_TEST_STOP_FAIL_ID = "test1234"
    $previousCleanupErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $blockedCleanupOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\cleanup-task.ps1") -Repository $repository -TaskId "test-task" -ClaudeCommand $fakeClaude 2>&1 | ForEach-Object { [string]$_ })
        $blockedCleanupExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousCleanupErrorAction
        Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FAIL_ID -ErrorAction SilentlyContinue
    }
    Assert-True ($blockedCleanupExitCode -ne 0) "Cleanup continued after a task session failed to stop."
    Assert-True (Test-Path -LiteralPath $launch.worktree) "Cleanup touched the worktree after a session stop failure."
    Assert-True (@(& git -C $repository branch --list ([string]$launch.branch)).Count -gt 0) "Cleanup deleted the branch after a session stop failure."
    Assert-Equal 0 (@(Get-Content -LiteralPath $env:CLAUDE_FACTORY_TEST_PSQL_REGISTRY_FILE | Where-Object {
        $_ -eq "drop`tfactory_test_worker_test_task"
    }).Count) "Cleanup dropped the test database before the worker session stopped."

    $agentSessionRemoval = Join-Path $testRoot "removed-agent-session.txt"
    $cleanupStopCapture = Join-Path $testRoot "cleanup-stopped-session.txt"
    $env:CLAUDE_FACTORY_TEST_RM_FILE = $agentSessionRemoval
    $env:CLAUDE_FACTORY_TEST_STOP_FILE = $cleanupStopCapture
    $env:CLAUDE_FACTORY_TEST_LIVE_TERMINAL_ID = "test1234"
    $env:CLAUDE_FACTORY_TEST_EXPECT_PATH_EXISTS_ON_RM = [string]$launch.worktree
    $cleanupPreviewOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath preview test-task -NoOpen -Repository $repository | Out-String)
    Assert-True ($cleanupPreviewOutput.Contains([string]$launch.worktree)) "Cleanup preview fixture did not start from the task worktree."
    $cleanupPreview = Read-FactoryJson -Path ([string]$context.previewPath)
    $cleanup = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\cleanup-task.ps1") -Repository $repository -TaskId "test-task" -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Remove-Item Env:\CLAUDE_FACTORY_TEST_LIVE_TERMINAL_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_EXPECT_PATH_EXISTS_ON_RM -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FILE -ErrorAction SilentlyContinue
    Assert-Equal "done" ([string]$cleanup.status) "Task cleanup did not mark the task done."
    Assert-True (-not (Test-Path -LiteralPath $launch.worktree)) "Task cleanup did not remove the worker worktree."
    $remainingWorkerBranch = @(& git -C $repository branch --list ([string]$launch.branch))
    Assert-Equal 0 $remainingWorkerBranch.Count "Task cleanup did not remove the local worker branch."
    Assert-True (Test-Path -LiteralPath $sentinelFile) "Cleanup traversed the external junction target."
    Assert-Equal 1 (@($cleanup.removedReparsePoints).Count) "Cleanup did not audit the removed junction."
    Assert-True ([bool]$cleanup.removedAgentSession) "Cleanup did not report Agent View session removal."
    Assert-Equal 1 (@($cleanup.removedAgentSessions).Count) "Cleanup did not report all removed Agent View sessions."
    Assert-Equal "test1234" (@(Get-Content -LiteralPath $agentSessionRemoval | Where-Object { $_ })[0]) "Cleanup removed the wrong Agent View session."
    Assert-Equal "test1234" ((Get-Content -LiteralPath $cleanupStopCapture -Raw).Trim()) "Cleanup did not stop a terminal-looking live process before removal."
    Assert-True (Test-Path -LiteralPath $answerTranscript) "Cleanup deleted the transcript retained by answer."
    Assert-True ([bool]$cleanup.removedTestDatabase) "Cleanup did not remove the worker test database."
    Assert-True ([bool]$cleanup.stoppedPreview) "Task cleanup did not stop its active browser preview."
    Assert-True (-not (Test-Path -LiteralPath ([string]$context.previewPath))) "Task cleanup retained active preview metadata."
    foreach ($cleanupPreviewPid in @([int]$cleanupPreview.app.pid, [int]$cleanupPreview.assets.pid)) {
        $cleanupPreviewAlive = $true
        try { $null = Get-Process -Id $cleanupPreviewPid -ErrorAction Stop } catch { $cleanupPreviewAlive = $false }
        Assert-Equal $false $cleanupPreviewAlive "Task cleanup left preview PID $cleanupPreviewPid running."
    }
    Assert-Equal "factory_test_worker_test_task" ([string]$cleanup.testDatabase) "Cleanup reported the wrong test database."
    $cleanedState = Read-FactoryJson -Path $context.statePath
    Assert-Equal "done" ([string]$cleanedState.tasks[0].status) "Task cleanup state was not persisted."
    Assert-True ($null -eq $cleanedState.tasks[0].testDatabase) "Cleanup retained a removed test database in task state."
    Assert-Equal 1 (@(Get-Content -LiteralPath $env:CLAUDE_FACTORY_TEST_PSQL_REGISTRY_FILE | Where-Object {
        $_ -eq "drop`tfactory_test_worker_test_task"
    }).Count) "Cleanup did not drop the worker database exactly once."
    $rowsAfterCleanup = @(Get-FactoryClaudeAgentRows -ClaudeCommand $fakeClaude)
    Assert-Equal 0 (@($rowsAfterCleanup | Where-Object {
        $null -ne $_.PSObject.Properties["name"] -and [string]$_.name -like "factory-test-task-*"
    }).Count) "Answer followed by cleanup left a task background row behind."
    Assert-Equal 1 (@($rowsAfterCleanup | Where-Object {
        $null -ne $_.PSObject.Properties["id"] -and [string]$_.id -eq "other999"
    }).Count) "Answer or cleanup removed another task's row."
    Assert-Equal 1 (@($rowsAfterCleanup | Where-Object { [string]$_.kind -eq "interactive" }).Count) "Answer or cleanup removed the id-less interactive row."

    & git -C $repository fetch origin develop 1> $null
    & git -C $repository merge --ff-only origin/develop 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not fast-forward the conflict fixture repository." }
    $conflictWorktree = Join-Path ([string]$context.worktreeRoot) "worker-sync-conflict-task"
    $conflictBranch = "factory-worker/sync-conflict-task"
    & git -C $repository worktree add -b $conflictBranch $conflictWorktree origin/develop 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not create conflicting sync fixture worktree." }
    [IO.File]::WriteAllText((Join-Path $conflictWorktree "SYNC-CONFLICT.md"), "worker version`n", (New-Object Text.UTF8Encoding($false)))
    & git -C $conflictWorktree add SYNC-CONFLICT.md
    & git -C $conflictWorktree commit -m "test: worker side of sync conflict" 1> $null
    $conflictOriginalCommit = (& git -C $conflictWorktree rev-parse HEAD).Trim()
    $conflictState = Read-FactoryJson -Path $context.statePath
    $conflictTask = New-FactoryTestTask -Id "sync-conflict-task" -Title "Recover a conflicting sync" -Now (Get-FactoryUtcTimestamp)
    $conflictTask.status = "awaiting-review"
    $conflictTask.branch = $conflictBranch
    $conflictTask.commit = $conflictOriginalCommit
    $conflictTask.worktree = $conflictWorktree
    $conflictTask.workerResult = [pscustomobject]@{
        status = "completed"; taskId = "sync-conflict-task"; branch = $conflictBranch; commit = $conflictOriginalCommit
        worktree = $conflictWorktree; changedFiles = @("SYNC-CONFLICT.md")
        tests = @([pscustomobject]@{ command = "git diff --check"; status = "passed"; summary = "Clean diff." })
        notes = "Ready before development changed."; blockingReason = ""
    }
    $conflictState.tasks = @($conflictState.tasks) + @($conflictTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $conflictState

    [IO.File]::WriteAllText((Join-Path $repository "SYNC-CONFLICT.md"), "development version`n", (New-Object Text.UTF8Encoding($false)))
    & git -C $repository add SYNC-CONFLICT.md
    & git -C $repository commit -m "test: development side of sync conflict" 1> $null
    & git -C $repository push origin develop 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not publish the conflicting development fixture." }
    $previousConflictErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $conflictLease = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
            -Action acquire -Repository $repository -TaskId "sync-conflict-task" -Phase review -OwnerPid $PID -NoHeartbeat) | ConvertFrom-Json
        $conflictPrepareOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\sync-task.ps1") `
            -Repository $repository -TaskId "sync-conflict-task" -Action prepare -LeaseToken ([string]$conflictLease.token) 2>&1 | ForEach-Object { [string]$_ })
        $conflictPrepareExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousConflictErrorAction
    }
    Assert-True ($conflictPrepareExit -ne 0 -and ($conflictPrepareOutput -join "`n") -match "Conflicts: SYNC-CONFLICT.md") "Conflicting sync did not report the conflicted path."
    $conflictAfterPrepare = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId "sync-conflict-task"
    Assert-Equal "awaiting-review" ([string]$conflictAfterPrepare.status) "Failed sync changed the task into an unrecoverable state."
    Assert-Equal $conflictOriginalCommit ([string]$conflictAfterPrepare.commit) "Failed sync replaced the recorded commit."

    & git -C $conflictWorktree reset --hard origin/develop 1> $null
    [IO.File]::WriteAllText((Join-Path $conflictWorktree "SYNC-CONFLICT.md"), "development version`nworker behavior retained`n", (New-Object Text.UTF8Encoding($false)))
    & git -C $conflictWorktree add SYNC-CONFLICT.md
    & git -C $conflictWorktree commit -m "test: resolved sync conflict" 1> $null
    $conflictResolvedCommit = (& git -C $conflictWorktree rev-parse HEAD).Trim()
    $conflictReportPath = Join-Path $context.sessionsPath "sync-conflict-task.sync-tests.json"
    Write-FactoryJsonAtomic -Path $conflictReportPath -Value ([pscustomobject]@{
        tests = @([pscustomobject]@{ command = "git diff --check"; status = "passed"; summary = "Resolved tree is clean." })
    })
    $conflictFinal = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\sync-task.ps1") `
        -Repository $repository -TaskId "sync-conflict-task" -Action finalize -TestsPath $conflictReportPath -LeaseToken ([string]$conflictLease.token)) | ConvertFrom-Json
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File $testLeaseScript `
        -Action release -Repository $repository -Token ([string]$conflictLease.token)) | ConvertFrom-Json
    Assert-Equal "awaiting-review" ([string]$conflictFinal.status) "Manually resolved sync did not return to review."
    Assert-Equal $conflictResolvedCommit ([string]$conflictFinal.commit) "Sync finalize did not adopt the resolved HEAD."
    Assert-True ([bool]$conflictFinal.adoptedResolvedHead) "Sync finalize did not audit adoption of an operator-resolved HEAD."
    $conflictCount = (& git -C $conflictWorktree rev-list --count "origin/develop..$conflictResolvedCommit").Trim()
    Assert-Equal 1 ([int]$conflictCount) "Resolved sync violated the one-task-commit invariant."
    $conflictDiscard = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "sync-conflict-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-True ([bool]$conflictDiscard.removedFromState) "Resolved sync fixture could not be discarded safely."

    $pipelineState = Read-FactoryJson -Path $context.statePath
    $pipelineWorktree = Join-Path ([string]$context.worktreeRoot) "worker-pipeline-task"
    $pipelineBranch = "factory-worker/pipeline-task"
    & git -C $repository fetch origin develop master 1> $null
    & git -C $repository worktree add -b $pipelineBranch $pipelineWorktree origin/develop 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not create native pipeline fixture worktree." }
    [IO.File]::WriteAllText((Join-Path $pipelineWorktree "PIPELINE.md"), "native pipeline`n", (New-Object Text.UTF8Encoding($false)))
    & git -C $pipelineWorktree add PIPELINE.md
    & git -C $pipelineWorktree commit -m "test: native integration pipeline" 1> $null
    $pipelineCommit = (& git -C $pipelineWorktree rev-parse HEAD).Trim()
    $pipelineMergeTitle = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("0JrQvtC80LDQvdC00LAgwqvQntGC0YfRkdGC0YvCuzog0L/RgNC+0LLQtdGA0LrQsCBPJ0JyaWVu"))
    $pipelineSuppliedUrl = "https://app.asana.com/1/14748072439266/project/1215506997644941/task/1217866656111884"
    $pipelineTask = New-FactoryTestTask -Id "pipeline-task" -Title $pipelineMergeTitle -Now (Get-FactoryUtcTimestamp)
    $pipelineTask.url = "https://app.asana.com/0/0/1217866656111884"
    $pipelineTask.source = [pscustomobject][ordered]@{
        adapter = "asana"
        id = "1217866656111884"
        suppliedUrl = $pipelineSuppliedUrl
    }
    $pipelineTask.status = "awaiting-review"
    $pipelineTask.branch = $pipelineBranch
    $pipelineTask.commit = $pipelineCommit
    $pipelineTask.worktree = $pipelineWorktree
    $pipelineTask.workerResult = [pscustomobject]@{
        status = "completed"; taskId = "pipeline-task"; branch = $pipelineBranch; commit = $pipelineCommit
        worktree = $pipelineWorktree; changedFiles = @("PIPELINE.md")
        tests = @([pscustomobject]@{ command = "git diff --check"; status = "passed"; summary = "Clean diff." })
        notes = "Ready for native publication."; blockingReason = ""
    }
    $pipelineTask.backgroundSession = [pscustomobject]@{ id = ""; state = "done"; name = "factory-pipeline-task" }
    $pipelineState.tasks = @($pipelineState.tasks) + @($pipelineTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $pipelineState
    $knownIssueState = Read-FactoryJson -Path $context.statePath
    $knownIssueTask = @($knownIssueState.tasks | Where-Object { [string]$_.id -eq "pipeline-task" })[0]
    $knownIssueTask.review = [pscustomobject]@{
        verdict = "changes-required"; commit = $pipelineCommit; summary = "Known issue."; riskNotes = @("Must be fixed.")
        reviewedAt = Get-FactoryUtcTimestamp; mode = "ai"; integrationPlan = $null
    }
    Write-FactoryJsonAtomic -Path $context.statePath -Value $knownIssueState
    $previousDirectErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\approve-direct.ps1") -Repository $repository -TaskId "pipeline-task" 2>&1)
        $knownIssueDirectExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousDirectErrorAction
    }
    Assert-True ($knownIssueDirectExit -ne 0) "Direct approval overrode a changes-required review."
    $directReadyState = Read-FactoryJson -Path $context.statePath
    $directReadyTask = @($directReadyState.tasks | Where-Object { [string]$_.id -eq "pipeline-task" })[0]
    Assert-Equal "changes-required" ([string]$directReadyTask.review.verdict) "Rejected direct approval mutated the known review."
    $directReadyTask.review = $null
    Write-FactoryJsonAtomic -Path $context.statePath -Value $directReadyState

    $pipelineGo = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\approve-direct.ps1") -Repository $repository -TaskId "pipeline-task") | ConvertFrom-Json
    Assert-Equal "approved" ([string]$pipelineGo.status) "Direct approval did not approve the native pipeline fixture."
    Assert-Equal "operator-direct" ([string]$pipelineGo.reviewMode) "Direct approval did not audit its review mode."
    Assert-Equal "operator-direct" ([string]$pipelineGo.approvalMode) "Direct approval did not audit its approval mode."
    Assert-Equal 64 ([string]$pipelineGo.approvedPlanHash).Length "Direct approval did not pin a hashed integration plan."
    $directApprovedState = Read-FactoryJson -Path $context.statePath
    $directApprovedTask = @($directApprovedState.tasks | Where-Object { [string]$_.id -eq "pipeline-task" })[0]
    Assert-True ([string]$directApprovedTask.review.summary -match "skipped") "Direct approval did not preserve its review warning."

    $directApprovedTask.status = "awaiting-review"
    $directApprovedTask.approval = $null
    $directApprovedTask.error = "integrator check failed: invalid command fixture"
    $directApprovedTask.integration = [pscustomobject]@{
        status = "failed"
        taskCommit = $pipelineCommit
        stage = "integration"
        tests = @([pscustomobject]@{ command = "invalid command fixture"; status = "failed"; summary = "Synthetic failure." })
        error = $directApprovedTask.error
        failedAt = Get-FactoryUtcTimestamp
    }
    Write-FactoryJsonAtomic -Path $context.statePath -Value $directApprovedState

    $failedPipelineStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status awaiting-review -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($failedPipelineStatus.Contains("Next in orchestrator: /factory review pipeline-task")) "Status offered stale go after a failed publication attempt."
    Assert-True (-not $failedPipelineStatus.Contains("go pipeline-task --direct")) "Status offered direct approval over a failed publication attempt."

    $previousFailedPlanErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $failedPlanGoOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") -Repository $repository -Action go -TaskId "pipeline-task" 2>&1 | ForEach-Object { [string]$_ })
        $failedPlanGoExit = $LASTEXITCODE
        $failedPlanDirectOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\approve-direct.ps1") -Repository $repository -TaskId "pipeline-task" 2>&1 | ForEach-Object { [string]$_ })
        $failedPlanDirectExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousFailedPlanErrorAction
    }
    Assert-True ($failedPlanGoExit -ne 0 -and ($failedPlanGoOutput -join "`n") -match "Run review again") "Native go reused a failed publication plan."
    Assert-True ($failedPlanDirectExit -ne 0 -and ($failedPlanDirectOutput -join "`n") -match "fresh review") "Direct approval reused a failed publication plan."

    $parallelIntegratorMarker = Join-Path $testRoot "parallel-integrator.ready"
    $parallelReleaseMarker = Join-Path $testRoot "parallel-release.ready"
    $parallelIntegratorLiteral = $parallelIntegratorMarker.Replace("'", "''")
    $parallelReleaseLiteral = $parallelReleaseMarker.Replace("'", "''")
    $parallelIntegrationCommand = "`$self='$parallelIntegratorLiteral'; `$peer='$parallelReleaseLiteral'; [IO.File]::WriteAllText(`$self, 'ready'); `$deadline=[DateTime]::UtcNow.AddSeconds(30); while (-not (Test-Path -LiteralPath `$peer) -and [DateTime]::UtcNow -lt `$deadline) { Start-Sleep -Milliseconds 50 }; if (-not (Test-Path -LiteralPath `$peer)) { exit 9 }; git diff --check"
    $parallelReleaseCommand = "`$self='$parallelReleaseLiteral'; `$peer='$parallelIntegratorLiteral'; [IO.File]::WriteAllText(`$self, 'ready'); `$deadline=[DateTime]::UtcNow.AddSeconds(30); while (-not (Test-Path -LiteralPath `$peer) -and [DateTime]::UtcNow -lt `$deadline) { Start-Sleep -Milliseconds 50 }; if (-not (Test-Path -LiteralPath `$peer)) { exit 9 }; git diff --check"
    $retryReviewPath = Join-Path $context.sessionsPath "pipeline-task.retry-review.json"
    Write-FactoryJsonAtomic -Path $retryReviewPath -Value ([pscustomobject]@{
        commit = $pipelineCommit
        verdict = "approved"
        summary = "Fresh review replaced the failed publication plan."
        riskNotes = @("Synthetic retry after a failed plan.")
        integrationTestCommands = @($parallelIntegrationCommand)
        releaseTestCommands = @($parallelReleaseCommand)
    })
    $retryReview = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\record-review.ps1") -Repository $repository -TaskId "pipeline-task" -ReviewPath $retryReviewPath) | ConvertFrom-Json
    Assert-Equal "approved" ([string]$retryReview.verdict) "Fresh review was not recorded after publication failure."
    $reviewedRetryState = Read-FactoryJson -Path $context.statePath
    $reviewedRetryTask = @($reviewedRetryState.tasks | Where-Object { [string]$_.id -eq "pipeline-task" })[0]
    Assert-True ($null -eq $reviewedRetryTask.integration -and $null -eq $reviewedRetryTask.production) "Fresh review retained failed publication audit as an active blocker."
    Assert-True (-not [string]$reviewedRetryTask.error) "Fresh review retained the previous publication error."
    $pipelineRetryGo = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\task-action.ps1") -Repository $repository -Action go -TaskId "pipeline-task") | ConvertFrom-Json
    Assert-Equal "approved" ([string]$pipelineRetryGo.status) "Freshly reviewed publication plan could not be approved."

    $env:CLAUDE_FACTORY_TEST_FAIL_CLEANUP = "pipeline-task"
    try {
        $pipelineTick = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action tick -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    } finally {
        Remove-Item Env:\CLAUDE_FACTORY_TEST_FAIL_CLEANUP -ErrorAction SilentlyContinue
    }
    $pipelineTickErrors = @($pipelineTick.errors | ForEach-Object { [string]$_ })
    Assert-Equal 1 $pipelineTickErrors.Count "Synthetic cleanup failure was not reported exactly once."
    Assert-True (($pipelineTickErrors -join "`n") -match "Cleanup failed after both branch pushes were verified") "Pipeline hid the cleanup stage failure."
    Assert-Equal 0 ([int]$pipelineTick.integratedCount) "Scheduler reported a cleanup-failed task as fully integrated."
    $cleanupFailedState = Read-FactoryJson -Path $context.statePath
    $cleanupFailedTask = @($cleanupFailedState.tasks | Where-Object { [string]$_.id -eq "pipeline-task" })[0]
    Assert-Equal "blocked" ([string]$cleanupFailedTask.status) "Cleanup failure did not leave the published task recoverable."
    Assert-Equal "published" ([string]$cleanupFailedTask.integration.status) "Cleanup failure rewrote development publication as failed."
    Assert-Equal "published" ([string]$cleanupFailedTask.production.status) "Cleanup failure rewrote production publication as failed."
    Assert-Equal "failed" ([string]$cleanupFailedTask.cleanup.status) "Cleanup failure was not audited as its own stage."
    Assert-Equal "cleanup" ([string]$cleanupFailedTask.cleanup.stage) "Cleanup failure audit names the wrong pipeline stage."
    Assert-True (Test-Path -LiteralPath $pipelineWorktree) "Cleanup failure unexpectedly removed the retained worktree."
    $cleanupFailedInspect = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath inspect pipeline-task -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cleanupFailedInspect.Contains("cleanup: failed") -and $cleanupFailedInspect.Contains("/factory cleanup pipeline-task")) "Factory inspect did not offer the cleanup-only retry."
    $pipelineCleanupRetry = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\cleanup-task.ps1") -Repository $repository -TaskId "pipeline-task" -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal "done" ([string]$pipelineCleanupRetry.status) "Manual cleanup-only retry did not finish the published task."
    $pipelineFinalState = Read-FactoryJson -Path $context.statePath
    $pipelineFinalTask = @($pipelineFinalState.tasks | Where-Object { [string]$_.id -eq "pipeline-task" })[0]
    Assert-Equal "done" ([string]$pipelineFinalTask.status) "Native pipeline did not finish cleanup."
    Assert-Equal "published" ([string]$pipelineFinalTask.integration.status) "Native pipeline did not audit development publication."
    Assert-Equal "published" ([string]$pipelineFinalTask.production.status) "Native pipeline did not audit production publication."
    Assert-Equal "completed" ([string]$pipelineFinalTask.cleanup.status) "Cleanup retry did not replace the failed cleanup audit."
    $pipelineShortCommit = $pipelineCommit.Substring(0, [Math]::Min(7, $pipelineCommit.Length))
    $pipelineDevelopmentMessage = [string](Invoke-FactoryNativeProcess -Command "git" -Arguments @(
        "-C", $repository, "log", "-1", "--format=%B", [string]$pipelineFinalTask.integration.mergeCommit
    )).stdout
    $pipelineProductionMessage = [string](Invoke-FactoryNativeProcess -Command "git" -Arguments @(
        "-C", $repository, "log", "-1", "--format=%B", [string]$pipelineFinalTask.production.mergeCommit
    )).stdout
    $expectedPipelineDevelopmentMessage = @(
        "Merge task pipeline-task into develop",
        "",
        $pipelineMergeTitle,
        "",
        "Task:    $pipelineSuppliedUrl",
        "Commit:  $pipelineShortCommit"
    ) -join "`n"
    $expectedPipelineProductionMessage = @(
        "Merge task pipeline-task into master",
        "",
        $pipelineMergeTitle,
        "",
        "Promoting: develop (may include commits from other tasks)",
        "Task:      $pipelineSuppliedUrl",
        "Commit:    $pipelineShortCommit"
    ) -join "`n"
    Assert-Equal $expectedPipelineDevelopmentMessage ($pipelineDevelopmentMessage.Replace("`r`n", "`n")) "Development merge message lost task identity, title, supplied URL, or UTF-8 text."
    Assert-Equal $expectedPipelineProductionMessage ($pipelineProductionMessage.Replace("`r`n", "`n")) "Merge-develop production message did not describe the promoted development branch."
    Assert-Equal ([string]$pipelineFinalTask.integration.mergeCommit) ((& git -C $repository rev-parse ([string]$pipelineFinalTask.integration.mergeCommit)).Trim()) "Development merge SHA did not remain resolvable from its audit."
    Assert-Equal ([string]$pipelineFinalTask.production.mergeCommit) ((& git -C $repository rev-parse ([string]$pipelineFinalTask.production.mergeCommit)).Trim()) "Production merge SHA did not remain resolvable from its audit."
    foreach ($pipelineTestRow in @($pipelineFinalTask.integration.tests) + @($pipelineFinalTask.production.tests)) {
        Assert-True ($null -ne $pipelineTestRow.PSObject.Properties["exitCode"]) "Persisted pipeline test row omitted its exit code."
        Assert-True ([string]$pipelineTestRow.outputPath -and (Test-Path -LiteralPath ([string]$pipelineTestRow.outputPath))) "Persisted pipeline test row omitted its full-output artifact path."
    }
    Assert-True ([bool]$pipelineFinalTask.integration.checksParallel -and [bool]$pipelineFinalTask.production.checksParallel) "Native pipeline did not audit parallel candidate checks."
    Assert-True ((Test-Path -LiteralPath $parallelIntegratorMarker) -and (Test-Path -LiteralPath $parallelReleaseMarker)) "Integration and release checks did not overlap."
    Assert-True (-not (Test-Path -LiteralPath $pipelineWorktree)) "Native pipeline left its worker worktree behind."
    & git -C $repository fetch origin develop master 1> $null
    & git -C $repository merge-base --is-ancestor $pipelineCommit origin/develop
    Assert-Equal 0 $LASTEXITCODE "Native pipeline commit is absent from remote development."
    & git -C $repository merge-base --is-ancestor $pipelineCommit origin/master
    Assert-Equal 0 $LASTEXITCODE "Native pipeline commit is absent from remote production."

    $taskOnlyConfig = Read-FactoryJson -Path $context.configPath
    $taskOnlyConfig.productionMode = "task-only"
    $taskOnlyConfig.allowUnrelatedDevelopCommitsToProduction = $false
    $taskOnlyConfig.integrationTestCommands = @("git diff --check")
    $taskOnlyConfig.releaseTestCommands = @("git diff --check")
    Write-FactoryJsonAtomic -Path $context.configPath -Value $taskOnlyConfig
    $localMergeSourceId = "20260827-142830-0f64896c"
    $localMergeTaskId = "local:$localMergeSourceId"
    $localMergeBranch = "factory-worker/local-merge-message-task"
    $localMergeWorktree = Join-Path ([string]$context.worktreeRoot) "worker-local-merge-message-task"
    & git -C $repository fetch origin develop master 1> $null
    & git -C $repository worktree add -b $localMergeBranch $localMergeWorktree origin/develop 1> $null
    if ($LASTEXITCODE -ne 0) { throw "Could not create local task-only merge-message fixture worktree." }
    [IO.File]::WriteAllText((Join-Path $localMergeWorktree "LOCAL-MERGE.md"), "local task-only merge`n", (New-Object Text.UTF8Encoding($false)))
    & git -C $localMergeWorktree add LOCAL-MERGE.md
    & git -C $localMergeWorktree commit -m "test: local task-only merge message" 1> $null
    $localMergeCommit = (& git -C $localMergeWorktree rev-parse HEAD).Trim()
    $localMergeState = Read-FactoryJson -Path $context.statePath
    $localMergeTask = New-FactoryTestTask -Id $localMergeTaskId -Title "" -Now (Get-FactoryUtcTimestamp)
    $localMergeTask.status = "awaiting-review"
    $localMergeTask.url = "factory://local/$localMergeSourceId"
    $localMergeTask.source = [pscustomobject][ordered]@{
        adapter = "local"
        id = $localMergeSourceId
        suppliedUrl = $null
    }
    $localMergeTask.branch = $localMergeBranch
    $localMergeTask.commit = $localMergeCommit
    $localMergeTask.worktree = $localMergeWorktree
    $localMergeTask.workerResult = [pscustomobject]@{
        status = "completed"; taskId = $localMergeTaskId; branch = $localMergeBranch; commit = $localMergeCommit
        worktree = $localMergeWorktree; changedFiles = @("LOCAL-MERGE.md")
        tests = @([pscustomobject]@{ command = "git diff --check"; status = "passed"; summary = "Clean diff." })
        notes = "Ready for task-only publication."; blockingReason = ""
    }
    $localMergeTask.backgroundSession = [pscustomobject]@{ id = ""; state = "done"; name = "factory-local-merge-message-task" }
    $localMergeState.tasks = @($localMergeState.tasks) + @($localMergeTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $localMergeState
    $localMergeApproval = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\approve-direct.ps1") -Repository $repository -TaskId $localMergeTaskId) | ConvertFrom-Json
    Assert-Equal "approved" ([string]$localMergeApproval.status) "Local task-only merge-message fixture could not be approved."
    $localMergeTick = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action tick -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-Equal 0 (@($localMergeTick.errors).Count) "Local task-only merge-message publication failed: $(@($localMergeTick.errors) -join ' | ')"
    Assert-Equal 1 ([int]$localMergeTick.integratedCount) "Local task-only merge-message fixture was not published."
    $localMergeFinalTask = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId $localMergeTaskId
    Assert-Equal "done" ([string]$localMergeFinalTask.status) "Local task-only merge-message fixture did not finish."
    $localMergeShortCommit = $localMergeCommit.Substring(0, [Math]::Min(7, $localMergeCommit.Length))
    $localDevelopmentMessage = [string](Invoke-FactoryNativeProcess -Command "git" -Arguments @(
        "-C", $repository, "log", "-1", "--format=%B", [string]$localMergeFinalTask.integration.mergeCommit
    )).stdout
    $localProductionMessage = [string](Invoke-FactoryNativeProcess -Command "git" -Arguments @(
        "-C", $repository, "log", "-1", "--format=%B", [string]$localMergeFinalTask.production.mergeCommit
    )).stdout
    $expectedLocalDevelopmentMessage = @(
        "Merge task $localMergeTaskId into develop",
        "",
        "Source:  local / $localMergeSourceId",
        "Commit:  $localMergeShortCommit"
    ) -join "`n"
    $expectedLocalProductionMessage = @(
        "Merge task $localMergeTaskId into master",
        "",
        "Promoting: this task's commit only",
        "Source:  local / $localMergeSourceId",
        "Commit:    $localMergeShortCommit"
    ) -join "`n"
    Assert-Equal $expectedLocalDevelopmentMessage ($localDevelopmentMessage.Replace("`r`n", "`n")) "Empty-title local development merge contains a stray paragraph or wrong source identity."
    Assert-Equal $expectedLocalProductionMessage ($localProductionMessage.Replace("`r`n", "`n")) "Task-only production merge did not describe the promoted task commit."
    Assert-True (-not $localDevelopmentMessage.Contains("factory://") -and -not $localProductionMessage.Contains("factory://")) "Local merge message exposed an internal factory URI."
    & git -C $repository fetch origin develop master 1> $null
    & git -C $repository merge-base --is-ancestor $localMergeCommit origin/develop
    Assert-Equal 0 $LASTEXITCODE "Local task-only commit is absent from remote development."
    & git -C $repository merge-base --is-ancestor $localMergeCommit origin/master
    Assert-Equal 0 $LASTEXITCODE "Local task-only commit is absent from remote production."
    $restoredPipelineConfig = Read-FactoryJson -Path $context.configPath
    $restoredPipelineConfig.productionMode = "merge-develop"
    $restoredPipelineConfig.allowUnrelatedDevelopCommitsToProduction = $true
    Write-FactoryJsonAtomic -Path $context.configPath -Value $restoredPipelineConfig
    $previousDoneIntegrationErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\integrate-task.ps1") -Repository $repository -TaskId "pipeline-task" -ClaudeCommand $fakeClaude 2>&1)
        $doneIntegrationExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousDoneIntegrationErrorAction
    }
    Assert-True ($doneIntegrationExit -ne 0) "Native integrator accepted a done task."
    $stateAfterDoneIntegration = Read-FactoryJson -Path $context.statePath
    Assert-Equal "done" ([string](@($stateAfterDoneIntegration.tasks | Where-Object { [string]$_.id -eq "pipeline-task" })[0].status)) "Rejected manual integration mutated a done task."

    $registryPath = [string]$env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE
    [IO.File]::AppendAllText(
        $registryPath,
        "launch`trmfail1`t$($launch.worktree)`tfactory-test-task-old-attempt`tstopped`n" +
        "launch`trmfail2`t$($launch.worktree)`tfactory-test-task-another-attempt`tdone`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $rmFailureCapture = Join-Path $testRoot "cleanup-rm-failure.txt"
    $env:CLAUDE_FACTORY_TEST_RM_FILE = $rmFailureCapture
    $env:CLAUDE_FACTORY_TEST_RM_FAIL_ID = "rmfail1"
    $cleanupWithRmFailure = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\cleanup-task.ps1") -Repository $repository -TaskId "test-task" -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FAIL_ID -ErrorAction SilentlyContinue
    Assert-Equal "done" ([string]$cleanupWithRmFailure.status) "An Agent View rm failure rolled cleanup back."
    Assert-True ([string]$cleanupWithRmFailure.agentSessionWarning -match 'rmfail1') "Cleanup hid the failed Agent View id."
    Assert-True (@($cleanupWithRmFailure.removedAgentSessions) -contains "rmfail2") "Cleanup stopped after one Agent View rm failure."
    $cleanupFailureState = Read-FactoryJson -Path $context.statePath
    Assert-Equal "done" ([string]$cleanupFailureState.tasks[0].status) "Agent View rm failure changed finalized task state."
    [IO.File]::AppendAllText($registryPath, "rm`trmfail1`n", (New-Object Text.UTF8Encoding($false)))


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
    Assert-Equal "factory_test_worker_discard_task" ([string]$preview.testDatabase) "Reject preview omitted the isolated test database."
    Assert-True (Test-Path -LiteralPath $discardLaunch.worktree) "Reject preview mutated the worktree."
    $previewState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 1 (@($previewState.tasks | Where-Object { [string]$_.id -eq "discard-task" }).Count) "Reject preview removed the task."

    [IO.File]::AppendAllText(
        [string]$env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE,
        "launch`tdiscard-old`t$($discardLaunch.worktree)`tfactory-discard-task-old-attempt`tstopped`n",
        (New-Object Text.UTF8Encoding($false))
    )

    $stopCapture = Join-Path $testRoot "stopped-session.txt"
    $discardRmCapture = Join-Path $testRoot "discard-rm.txt"
    $env:CLAUDE_FACTORY_TEST_STOP_FILE = $stopCapture
    $env:CLAUDE_FACTORY_TEST_RM_FILE = $discardRmCapture
    $discarded = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "discard-task" -Reason "Duplicate" -Yes -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FAIL -ErrorAction SilentlyContinue
    Assert-True ([bool]$discarded.removedFromState) "Confirmed reject did not forget the task."
    Assert-True ([bool]$discarded.stoppedSession) "Confirmed reject did not stop the session."
    Assert-True ([bool]$discarded.removedTestDatabase) "Confirmed reject did not drop the isolated test database."
    Assert-Equal 1 (@(Get-Content -LiteralPath $env:CLAUDE_FACTORY_TEST_PSQL_REGISTRY_FILE | Where-Object {
        $_ -eq "drop`tfactory_test_worker_discard_task"
    }).Count) "Reject did not drop the task database exactly once."
    Assert-Equal 2 (@($discarded.removedAgentSessions).Count) "Reject did not remove every matching Agent View row."
    Assert-Equal "test1234" ((Get-Content -LiteralPath $stopCapture -Raw).Trim()) "Reject stopped the wrong session."
    $discardRemovedIds = @(Get-Content -LiteralPath $discardRmCapture | Where-Object { $_ })
    Assert-True ($discardRemovedIds -contains "test1234" -and $discardRemovedIds -contains "discard-old") "Reject did not remove current and previous attempts."
    Assert-True (-not (Test-Path -LiteralPath $discardLaunch.worktree)) "Confirmed reject did not remove the dirty worktree."
    Assert-Equal 0 (@(& git -C $repository branch --list ([string]$discardLaunch.branch))).Count "Confirmed reject did not remove the branch."
    Assert-True (-not (Test-Path -LiteralPath $discardMetadata)) "Confirmed reject retained session metadata."
    Assert-True (-not (Test-Path -LiteralPath $discardPrompt)) "Confirmed reject retained the durable prompt."
    Assert-True (-not (Test-Path -LiteralPath $discardEvents)) "Confirmed reject retained event metadata."
    Assert-True (Test-Path -LiteralPath $discardSentinelFile) "Reject traversed the external junction target."
    Assert-Equal 1 (@($discarded.removedReparsePoints).Count) "Reject did not audit the removed junction."
    $discardedState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 0 (@($discardedState.tasks | Where-Object { [string]$_.id -eq "discard-task" }).Count) "Confirmed reject persisted the task."
    $rowsAfterReject = @(Get-FactoryClaudeAgentRows -ClaudeCommand $fakeClaude)
    Assert-Equal 0 (@($rowsAfterReject | Where-Object {
        $null -ne $_.PSObject.Properties["name"] -and [string]$_.name -like "factory-discard-task-*"
    }).Count) "Reject left a background row behind."
    Assert-Equal 1 (@($rowsAfterReject | Where-Object {
        $null -ne $_.PSObject.Properties["id"] -and [string]$_.id -eq "other999"
    }).Count) "Reject removed another task's row."
    Assert-Equal 1 (@($rowsAfterReject | Where-Object { [string]$_.kind -eq "interactive" }).Count) "Reject removed the id-less interactive row."

    $fallbackState = Read-FactoryJson -Path $context.statePath
    $fallbackState.agentResolutionCache = $null
    $fallbackState.tasks = @($fallbackState.tasks) + @(
        New-FactoryTestTask -Id "fallback-task" -Title "System prompt fallback" -Now $now
    )
    Write-FactoryJsonAtomic -Path $context.statePath -Value $fallbackState
    $fallbackCount = Join-Path $testRoot "fallback-launch-count.txt"
    $fallbackArgv = Join-Path $testRoot "fallback-argv.txt"
    $fallbackStops = Join-Path $testRoot "fallback-stops.txt"
    $fallbackRemovals = Join-Path $testRoot "fallback-removals.txt"
    $systemPromptCopy = Join-Path $testRoot "system-prompt-copy.txt"
    $env:CLAUDE_FACTORY_TEST_AGENT_BEHAVIOR = "fallback-to-system"
    $env:CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE = $fallbackCount
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $fallbackArgv
    $env:CLAUDE_FACTORY_TEST_STOP_FILE = $fallbackStops
    $env:CLAUDE_FACTORY_TEST_RM_FILE = $fallbackRemovals
    $env:CLAUDE_FACTORY_TEST_SYSTEM_PROMPT_COPY = $systemPromptCopy
    $env:CLAUDE_FACTORY_TEST_AGENT_CWD = $repository
    $fallbackLaunch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "fallback-task" -Mode auto -ClaudeCommand $fakeClaude) |
        ConvertFrom-Json
    Assert-Equal 3 ([int](Get-Content -LiteralPath $fallbackCount -Raw)) "The third resolution path was not reached exactly once."
    Assert-Equal "system-prompt" ([string]$fallbackLaunch.backgroundSession.agentResolution) "System-prompt fallback was not audited."
    $fallbackStopIds = @(Get-Content -LiteralPath $fallbackStops | Where-Object { $_ })
    Assert-Equal 2 $fallbackStopIds.Count "Unexpected number of stray fallback sessions survived."
    Assert-Equal "fallback1" $fallbackStopIds[0] "The native default-template session was not stopped."
    Assert-Equal "fallback2" $fallbackStopIds[1] "The inline default-template session was not stopped."
    $fallbackRemovedIds = @(Get-Content -LiteralPath $fallbackRemovals | Where-Object { $_ })
    Assert-Equal 2 $fallbackRemovedIds.Count "Fallback launch left abandoned Agent View rows."
    Assert-True ($fallbackRemovedIds -contains "fallback1" -and $fallbackRemovedIds -contains "fallback2") "Fallback launch removed the wrong rows."
    $fallbackLaunchState = Read-FactoryJson -Path $context.statePath
    $fallbackTask = @($fallbackLaunchState.tasks | Where-Object { [string]$_.id -eq "fallback-task" })[0]
    Assert-Equal 1 ([int]$fallbackTask.attempts) "Three process launches consumed more than one factory attempt."
    Assert-Equal "system-prompt" ([string]$fallbackLaunchState.agentResolutionCache.preferredResolution) "System-prompt capability was not cached."
    Assert-Equal "working" ([string]$fallbackLaunchState.agentResolutionCache.outcomes.systemPrompt) "System-prompt success was not recorded."
    $fallbackArguments = @([IO.File]::ReadAllLines($fallbackArgv, [Text.Encoding]::UTF8))
    Assert-True ([Array]::IndexOf($fallbackArguments, "--append-system-prompt-file") -ge 0) "System launch omitted the prompt file."
    Assert-True ([Array]::IndexOf($fallbackArguments, "--plugin-dir") -ge 0) "System launch dropped the plugin directory."
    Assert-True ([Array]::IndexOf($fallbackArguments, "--agent") -lt 0) "System launch still selected an agent."
    Assert-True ([Array]::IndexOf($fallbackArguments, "--agents") -lt 0) "System launch still transported an inline agent."
    $workerAgentRaw = [IO.File]::ReadAllText((Join-Path $pluginRoot "agents\worker.md"), (New-Object Text.UTF8Encoding($false, $true)))
    $workerAgentParts = [regex]::Match($workerAgentRaw, '\A---\r?\n(?<frontmatter>[\s\S]*?)\r?\n---\r?\n(?<body>[\s\S]*)\z')
    Assert-True $workerAgentParts.Success "Test fixture could not independently parse worker.md."
    $expectedSystemBytes = [Text.Encoding]::UTF8.GetBytes($workerAgentParts.Groups["body"].Value)
    $actualSystemBytes = [IO.File]::ReadAllBytes($systemPromptCopy)
    Assert-Equal $expectedSystemBytes.Length $actualSystemBytes.Length "System prompt byte length changed."
    Assert-Equal (Get-FactorySha256Hex -Bytes $expectedSystemBytes) (Get-FactorySha256Hex -Bytes $actualSystemBytes) "System prompt body was not byte-identical."
    $fallbackMetadata = Read-FactoryJson -Path (Join-Path $context.sessionsPath "fallback-task.json")
    Assert-Equal "system-prompt" ([string]$fallbackMetadata.agentResolution) "Fallback metadata did not record its resolution path."
    Assert-Equal ([string]$fallbackMetadata.systemPromptSha256) (Get-FactoryFileSha256 -Path $fallbackMetadata.systemPromptPath) "System prompt audit hash is wrong."
    Assert-True ((@($fallbackMetadata.agentDefinitionDeviations) -join " ") -match 'maxTurns: 100') "Lost maxTurns behavior was not audited."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "fallback-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json

    $cachedState = Read-FactoryJson -Path $context.statePath
    $cachedState.tasks = @($cachedState.tasks) + @(New-FactoryTestTask -Id "cached-fallback-task" -Title "Cached system fallback" -Now $now)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $cachedState
    $cachedCount = Join-Path $testRoot "cached-launch-count.txt"
    $cachedArgv = Join-Path $testRoot "cached-argv.txt"
    $cachedStops = Join-Path $testRoot "cached-stops.txt"
    $env:CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE = $cachedCount
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $cachedArgv
    $env:CLAUDE_FACTORY_TEST_STOP_FILE = $cachedStops
    $cachedLaunch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "cached-fallback-task" -Mode auto -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal 1 ([int](Get-Content -LiteralPath $cachedCount -Raw)) "Cached system fallback retried known-bad agent paths."
    Assert-Equal "system-prompt" ([string]$cachedLaunch.backgroundSession.agentResolution) "Cached system fallback was not reused."
    Assert-True (-not (Test-Path -LiteralPath $cachedStops)) "Cached system fallback stopped an unexpected session."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "cached-fallback-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json

    $legacyState = Read-FactoryJson -Path $context.statePath
    $legacyState.agentResolutionCache = [pscustomobject]@{ claudeVersion = "2.1.218"; preferredResolution = "inline-fallback"; checkedAt = $now }
    $legacyState.tasks = @($legacyState.tasks) + @(New-FactoryTestTask -Id "legacy-fallback-task" -Title "Legacy fallback migration" -Now $now)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $legacyState
    $legacyCount = Join-Path $testRoot "legacy-launch-count.txt"
    $env:CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE = $legacyCount
    $legacyLaunch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "legacy-fallback-task" -Mode auto -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal 1 ([int](Get-Content -LiteralPath $legacyCount -Raw)) "Legacy inline cache did not migrate directly."
    Assert-Equal "system-prompt" ([string]$legacyLaunch.backgroundSession.agentResolution) "Legacy inline cache did not migrate to system-prompt."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "legacy-fallback-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json

    $doctor = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-doctor.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-True ([bool]$doctor.healthy) "Factory doctor reported required failures for the working system fallback."
    $doctorChecks = @($doctor.checks)
    $runtimeCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "powershellRuntime" })[0]
    $agentDefinitionCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "workerAgentDefinition" })[0]
    $resolutionCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "workerAgentResolution" })[0]
    $databaseIsolationCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "testDatabaseIsolation" })[0]
    $publicationCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "publicationPipeline" })[0]
    $testLaneCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "testLaneLease" })[0]
    $configCheck = @($doctorChecks | Where-Object { [string]$_.name -eq "configJson" })[0]
    Assert-True ([bool]$runtimeCheck.passed) "Factory doctor did not verify PowerShell dependencies."
    Assert-True ([bool]$agentDefinitionCheck.passed) "Factory doctor did not verify the worker definition."
    Assert-True ([string]$agentDefinitionCheck.detail -match 'additive system-prompt') "Factory doctor hid the additive fallback semantics."
    Assert-Equal "required" ([string]$resolutionCheck.severity) "Worker resolution is not a required doctor check."
    Assert-True ([string]$resolutionCheck.detail -match 'system-prompt') "Factory doctor hid the active system fallback."
    Assert-True ([bool]$databaseIsolationCheck.passed) "Factory doctor did not validate isolated database prerequisites."
    Assert-True ([bool]$publicationCheck.passed) "Factory doctor did not report the configured publication pipeline as ready."
    Assert-True ([bool]$testLaneCheck.passed -and [string]$testLaneCheck.detail -match "last reclaimed 'abandoned-full-suite'/review") "Factory doctor did not report the reclaimed test lease."
    Assert-True ([string]$configCheck.detail -match "coding concurrency" -and [string]$configCheck.detail -match "deprecated concurrency is present but ignored") "Factory doctor did not identify the effective coding-concurrency source."
    $cliDoctor = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") doctor -Repository $repository -ClaudeCommand $fakeClaude | Out-String)
    Assert-True ($cliDoctor.Contains("[OK] powershellRuntime")) "Factory CLI doctor did not render successful checks."
    Assert-True ($cliDoctor.Contains("Healthy")) "Factory CLI doctor did not render its final verdict."

    $failureState = Read-FactoryJson -Path $context.statePath
    $failureState.agentResolutionCache = $null
    $failureState.tasks = @($failureState.tasks) + @(New-FactoryTestTask -Id "all-fallbacks-fail" -Title "All fallbacks fail" -Now $now)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $failureState
    $failureCount = Join-Path $testRoot "failure-launch-count.txt"
    $failureStops = Join-Path $testRoot "failure-stops.txt"
    $failureRemovals = Join-Path $testRoot "failure-removals.txt"
    $env:CLAUDE_FACTORY_TEST_AGENT_BEHAVIOR = "fallback-all-three"
    $env:CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE = $failureCount
    $env:CLAUDE_FACTORY_TEST_STOP_FILE = $failureStops
    $env:CLAUDE_FACTORY_TEST_RM_FILE = $failureRemovals
    $previousFallbackErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $failureOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "all-fallbacks-fail" -Mode auto -ClaudeCommand $fakeClaude 2>&1 | ForEach-Object { [string]$_ })
        $failureExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousFallbackErrorAction
    }
    Assert-True ($failureExitCode -ne 0) "A failed system-prompt process was accepted as a worker."
    Assert-Equal 3 ([int](Get-Content -LiteralPath $failureCount -Raw)) "All three resolution paths were not attempted."
    $failureStopIds = @(Get-Content -LiteralPath $failureStops | Where-Object { $_ })
    Assert-Equal 3 $failureStopIds.Count "A failed resolution session survived."
    Assert-Equal "fallback3" $failureStopIds[2] "The failed system-prompt session was not stopped."
    $failureRemovedIds = @(Get-Content -LiteralPath $failureRemovals | Where-Object { $_ })
    Assert-Equal 3 $failureRemovedIds.Count "A failed resolution row survived Agent View cleanup."
    $failedState = Read-FactoryJson -Path $context.statePath
    $failedTask = @($failedState.tasks | Where-Object { [string]$_.id -eq "all-fallbacks-fail" })[0]
    Assert-Equal "failed" ([string]$failedTask.status) "All-path failure was not persisted."
    Assert-Equal 1 ([int]$failedTask.attempts) "Three resolution processes consumed more than one attempt."
    Assert-True ($null -eq $failedTask.backgroundSession) "All-path failure retained a background session."
    Assert-True (-not [string]$failedState.agentResolutionCache.preferredResolution) "A failed resolution was cached as preferred."
    Assert-Equal "failed" ([string]$failedState.agentResolutionCache.outcomes.systemPrompt) "System failure outcome was not cached."
    $failedDoctor = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-doctor.ps1") -Repository $repository -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    $failedResolutionCheck = @($failedDoctor.checks | Where-Object { [string]$_.name -eq "workerAgentResolution" })[0]
    Assert-True (-not [bool]$failedDoctor.healthy) "Doctor accepted a version with no working resolution."
    Assert-True (-not [bool]$failedResolutionCheck.passed) "Doctor did not fail the required resolution check."
    $failedCliDoctorOutput = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") doctor -Repository $repository -ClaudeCommand $fakeClaude 2>&1 | ForEach-Object { [string]$_ })
    $failedCliDoctorExit = $LASTEXITCODE
    Assert-Equal 2 $failedCliDoctorExit "Factory CLI doctor did not return the unhealthy exit code."
    Assert-True (($failedCliDoctorOutput -join "`n").Contains("Unhealthy")) "Factory CLI doctor hid its unhealthy verdict."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "all-fallbacks-fail" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json

    Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_BEHAVIOR -ErrorAction SilentlyContinue
    $fixedState = Read-FactoryJson -Path $context.statePath
    $fixedState.tasks = @($fixedState.tasks) + @(New-FactoryTestTask -Id "fixed-version-task" -Title "Fixed native version" -Now $now)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $fixedState
    $fixedCount = Join-Path $testRoot "fixed-launch-count.txt"
    $env:CLAUDE_FACTORY_TEST_VERSION = "2.1.219"
    $env:CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE = $fixedCount
    $fixedLaunch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "fixed-version-task" -Mode auto -ClaudeCommand $fakeClaude) | ConvertFrom-Json
    Assert-Equal 1 ([int](Get-Content -LiteralPath $fixedCount -Raw)) "A new CLI version reused the old negative cache."
    Assert-Equal "plugin" ([string]$fixedLaunch.backgroundSession.agentResolution) "A fixed CLI version did not retry the native agent."
    $null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "fixed-version-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude) | ConvertFrom-Json

    Remove-Item Env:\CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FILE -ErrorAction SilentlyContinue
    $env:CLAUDE_FACTORY_TEST_ARGV_FILE = $argvCapture

    $codexConfig = Read-FactoryJson -Path $context.configPath
    $codexConfig.codexCommand = $fakeCodex
    $codexConfig.codexModel = "inherit"
    $codexConfig.codexReasoningEffort = "inherit"
    Write-FactoryJsonAtomic -Path $context.configPath -Value $codexConfig
    $codexLog = Join-Path $testRoot "codex-events.tsv"
    $env:CLAUDE_FACTORY_TEST_CODEX_LOG = $codexLog
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") start -Agent codex -Repository $repository -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex 1> $null
    Assert-Equal 0 $LASTEXITCODE "Public factory start could not select the Codex worker runtime."
    $codexConfig = Read-FactoryJson -Path $context.configPath
    Assert-Equal "codex" ([string]$codexConfig.workerAgent) "Public factory start did not persist the private Codex selection."
    $codexOrchestratorIdentity = Read-FactoryJson -Path (Join-Path ([string]$context.projectData) "codex-orchestrator-session.json")
    Assert-Equal "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff" ([string]$codexOrchestratorIdentity.sessionId) "Codex orchestrator thread UUID was not persisted."
    Assert-True (Test-Path -LiteralPath (Join-Path $env:CLAUDE_FACTORY_CODEX_SKILL_HOME "factory")) "Codex factory skill was not linked into the private test skill home."
    Assert-True (@(Get-Content -LiteralPath $codexLog | Where-Object { $_ -match '^exec\t--json\t' }).Count -eq 1) "First Codex startup did not bootstrap exactly one orchestrator thread."
    Assert-True (@(Get-Content -LiteralPath $codexLog | Where-Object { $_ -match '^resume\t.*bbbbbbbb-' }).Count -eq 1) "First Codex startup did not resume the bootstrapped orchestrator."
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") start -Agent codex -Repository $repository -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex 1> $null
    Assert-Equal 0 $LASTEXITCODE "Stored Codex orchestrator resume failed."
    Assert-True (@(Get-Content -LiteralPath $codexLog | Where-Object { $_ -match '^exec\t--json\t' }).Count -eq 1) "Repeated Codex startup created a duplicate orchestrator thread."
    Assert-True (@(Get-Content -LiteralPath $codexLog | Where-Object { $_ -match '^resume\t.*bbbbbbbb-' }).Count -eq 2) "Repeated Codex startup did not resume the stored thread."
    $codexRotate = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") rotate -Repository $repository | Out-String)
    Assert-True ($codexRotate.Contains("Orchestrator rotation prepared") -and $codexRotate.Contains("factory start -Agent codex")) "Codex rotation did not print its runtime-specific restart command."
    $codexPendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $context -Runtime "codex"
    $codexPendingRotation = Read-FactoryJson -Path $codexPendingPath
    Assert-Equal "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff" ([string]$codexPendingRotation.previousSessionId) "Codex rotation lost the previous thread UUID."
    $env:CLAUDE_FACTORY_TEST_CODEX_THREAD_ID = "cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") start -Agent codex -Repository $repository -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex 1> $null
    Assert-Equal 0 $LASTEXITCODE "Pending Codex orchestrator rotation could not be activated."
    $rotatedCodexIdentity = Read-FactoryJson -Path (Join-Path ([string]$context.projectData) "codex-orchestrator-session.json")
    Assert-Equal "cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa" ([string]$rotatedCodexIdentity.sessionId) "Codex rotation resumed the context-heavy thread."
    Assert-True (@(Get-Content -LiteralPath $codexLog | Where-Object { $_ -match '^exec\t--json\t' }).Count -eq 2) "Codex rotation did not bootstrap exactly one replacement thread."
    Assert-True (@(Get-Content -LiteralPath $codexLog | Where-Object { $_ -match 'freshly rotated Factory Orchestrator' }).Count -ge 1) "Codex replacement bootstrap did not receive the deterministic handoff directive."
    Assert-True (-not (Test-Path -LiteralPath $codexPendingPath)) "Codex rotation left a pending marker that would rotate every subsequent start."
    $activatedCodexRotation = Read-FactoryJson -Path ([string]$codexPendingRotation.recordPath)
    Assert-Equal "activated" ([string]$activatedCodexRotation.status) "Codex rotation audit was not finalized."
    Assert-Equal "cccccccc-dddd-4eee-8fff-aaaaaaaaaaaa" ([string]$activatedCodexRotation.newSessionId) "Codex rotation audit recorded the wrong replacement UUID."
    Remove-Item Env:\CLAUDE_FACTORY_TEST_CODEX_THREAD_ID -ErrorAction SilentlyContinue
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") start -Repository $repository -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex 1> $null
    Assert-Equal 0 $LASTEXITCODE "Default Claude orchestrator startup failed after Codex selection."
    $defaultRuntimeConfig = Read-FactoryJson -Path $context.configPath
    Assert-Equal "claude" ([string]$defaultRuntimeConfig.workerAgent) "Agent omission did not restore the default full Claude runtime."
    $defaultRuntimeConfig.workerAgent = "codex"
    Write-FactoryJsonAtomic -Path $context.configPath -Value $defaultRuntimeConfig
    $codexState = Read-FactoryJson -Path $context.statePath
    $codexTask = New-FactoryTestTask -Id "codex-task" -Title "Codex interactive worker" -Now $now
    $codexTask.startMode = "interactive"
    $codexState.tasks = @($codexState.tasks) + @($codexTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $codexState
    $codexLaunch = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\start-worker-session.ps1") -Repository $repository -TaskId "codex-task" -Mode interactive -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex) | ConvertFrom-Json
    Assert-Equal "codex" ([string]$codexLaunch.runtime) "Codex worker launch did not report its runtime."
    Assert-Equal "codex" ([string]$codexLaunch.backgroundSession.runtime) "Codex worker session lost its runtime identity."
    Assert-True ([int]$codexLaunch.backgroundSession.processId -gt 0) "Codex worker did not record a process ID."
    $codexDeadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 100
        try { $codexAlive = $null -ne (Get-Process -Id ([int]$codexLaunch.backgroundSession.processId) -ErrorAction Stop) } catch { $codexAlive = $false }
    } while ($codexAlive -and [DateTime]::UtcNow -lt $codexDeadline)
    Assert-True (-not $codexAlive) "Fake Codex worker did not finish."
    $codexReconcile = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reconcile-worker-sessions.ps1") -Repository $repository -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex) | ConvertFrom-Json
    Assert-Equal 1 ([int]$codexReconcile.codexSessionsSeen) "Codex reconciliation did not inspect the saved session."
    $codexRecordedState = Read-FactoryJson -Path $context.statePath
    $codexRecordedTask = @($codexRecordedState.tasks | Where-Object { [string]$_.id -eq "codex-task" })[0]
    Assert-Equal "awaiting-input" ([string]$codexRecordedTask.status) "Codex FACTORY_PLAN did not reach awaiting-input."
    Assert-Equal "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" ([string]$codexRecordedTask.backgroundSession.sessionId) "Codex thread UUID was not captured from JSONL."
    Assert-True ([string]$codexRecordedTask.backgroundSession.attachCommand -match 'resume-codex-worker\.ps1') "Codex attach command did not use the capture-aware wrapper."
    Assert-True ([string]$codexRecordedTask.backgroundSession.nativeResumeCommand -match '^codex resume -C .*aaaaaaaa-') "Codex native resume command did not target the exact thread."
    Assert-Equal "Inspect the requested change" ([string]$codexRecordedTask.plan.understanding) "Codex plan payload was not recorded."
    $codexStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") status -NoReconcile -Repository $repository -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex | Out-String)
    Assert-True ($codexStatus.Contains("runtime codex") -and $codexStatus.Contains("factory chat codex-task")) "Factory status hid the selected Codex runtime or printed Claude prompt syntax."
    $codexChat = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "factory.ps1") chat codex-task -NoReconcile -Repository $repository -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex | Out-String)
    Assert-True ($codexChat.Contains("resume-codex-worker.ps1")) "Factory chat did not resolve the capture-aware Codex session command."
    $codexResume = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\resume-codex-worker.ps1") -Repository $repository -TaskId "codex-task" -CodexCommand $fakeCodex) | ConvertFrom-Json
    Assert-Equal "awaiting-input" ([string]$codexResume.status) "Capture-aware Codex resume changed a still-pending plan incorrectly."
    Assert-True (@(Get-Content -LiteralPath $codexLog | Where-Object { $_ -match '^resume\t-C.*aaaaaaaa-' }).Count -eq 1) "Codex worker wrapper did not open the exact interactive thread."
    Assert-True (@(Get-Content -LiteralPath $codexLog | Where-Object { $_ -match '^exec\tresume\t--json.*aaaaaaaa-' }).Count -eq 1) "Codex worker wrapper did not capture the post-chat state."
    $codexDoctor = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-doctor.ps1") -Repository $repository -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex) | ConvertFrom-Json
    $codexDoctorCheck = @($codexDoctor.checks | Where-Object { [string]$_.name -eq "codexWorkerRuntime" })[0]
    Assert-True ([bool]$codexDoctorCheck.passed) "Doctor rejected the supported Codex CLI contract."
    $env:CLAUDE_FACTORY_REAL_GIT = [string](Get-Command git -CommandType Application | Select-Object -First 1).Source
    $env:CLAUDE_FACTORY_WORKTREE = [string]$codexRecordedTask.worktree
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\codex-git-proxy.ps1") status --porcelain 1> $null
    Assert-Equal 0 $LASTEXITCODE "Codex Git proxy blocked a harmless status command."
    $previousCodexProxyErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $codexProxyDenied = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\codex-git-proxy.ps1") push origin HEAD 2>&1)
        $codexProxyExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousCodexProxyErrorAction
    }
    Assert-Equal 2 $codexProxyExit "Codex Git proxy allowed a worker push."
    Remove-Item Env:\CLAUDE_FACTORY_REAL_GIT -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_WORKTREE -ErrorAction SilentlyContinue
    $codexDiscard = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\reject-task.ps1") -Repository $repository -TaskId "codex-task" -Reason "test fixture" -Yes -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex) | ConvertFrom-Json
    Assert-True ([bool]$codexDiscard.removedFromState) "Codex task rejection did not forget the task."
    Assert-True (-not (Test-Path -LiteralPath ([string]$codexRecordedTask.backgroundSession.shimDirectory))) "Codex task rejection left its private Git shim directory behind."
    Assert-True (@(Get-Content -LiteralPath $codexLog | Where-Object { $_ -match '^delete\t--force\taaaaaaaa-' }).Count -eq 1) "Confirmed rejection did not delete the Codex session."
    Remove-Item Env:\CLAUDE_FACTORY_TEST_CODEX_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_REAL_GIT -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_WORKTREE -ErrorAction SilentlyContinue
    $codexConfig = Read-FactoryJson -Path $context.configPath
    $codexConfig.workerAgent = "claude"
    Write-FactoryJsonAtomic -Path $context.configPath -Value $codexConfig

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
    Remove-Item Env:\CLAUDE_FACTORY_TEST_CODEX_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ORCHESTRATOR_SESSION_ID -ErrorAction SilentlyContinue
    Assert-True $missingAgentFailed "Missing-agent warning did not abort launch."
    $failedAgentState = Read-FactoryJson -Path $context.statePath
    $failedAgentTask = @($failedAgentState.tasks | Where-Object { [string]$_.id -eq 'missing-agent-task' })[0]
    Assert-Equal "failed" ([string]$failedAgentTask.status) "Missing-agent launch was not recorded as failed."
    Assert-True ([string]$failedAgentTask.error -match 'system-prompt launch failed') "Missing-agent failure was not explicit."

    Write-Host "All factory runtime tests passed." -ForegroundColor Green
} finally {
    try {
        if (Test-Path -LiteralPath $repository) {
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-preview.ps1") -Action stop -Repository $repository -RuntimeHome $runtime 1> $null 2> $null
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-scheduler.ps1") -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime 1> $null 2> $null
        }
    } catch {}
    Remove-Item Env:\CLAUDE_FACTORY_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_CWD -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_NO_AGENTS -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_AGENT_BEHAVIOR -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_LAUNCH_COUNT_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FAIL -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_RM_FAIL_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_STOP_FAIL_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_PSQL_REGISTRY_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_PSQL_AUDIT_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_PSQL_FAIL_DROP -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_FAIL_CLEANUP -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ON_TICK -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ONCE_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_SCHEDULER_BUSY_MILLISECONDS -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_LOCK_SLOW_MILLISECONDS -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_SYNC_DELAY_MILLISECONDS -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_SYNC_DELAY_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_DB_ENV_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_TRANSCRIPT_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_LIVE_TERMINAL_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_EXPECT_PATH_EXISTS_ON_RM -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_ARGV_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_PROMPT_COPY -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_SYSTEM_PROMPT_COPY -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_VERSION -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_TEST_MISSING_AGENT -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_PROMPT_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_FACTORY_CODEX_SKILL_HOME -ErrorAction SilentlyContinue
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
