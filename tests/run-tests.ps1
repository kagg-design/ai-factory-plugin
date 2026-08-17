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
    Assert-True (@($bundleManifest.files) -contains "factory") "The plugin manifest omits the Bash-compatible factory launcher."
    $bashLauncher = Get-Content -LiteralPath (Join-Path $pluginRoot "factory") -Raw
    Assert-True ($bashLauncher.StartsWith("#!/usr/bin/env bash")) "The cross-shell factory launcher is not a Bash script."
    Assert-True ($bashLauncher.Contains('factory.ps1')) "The cross-shell factory launcher does not delegate to the PowerShell entry point."
    Assert-True ($bashLauncher.Contains('command -v pwsh.exe')) "The cross-shell factory launcher does not prefer PowerShell 7 on Windows."
    Assert-True ($bashLauncher.Contains('command -v wslpath')) "The cross-shell factory launcher does not translate WSL paths for Windows PowerShell."
    Assert-True (@($bundleManifest.files) -contains "scripts/approve-direct.ps1") "The plugin manifest omits native direct approval."
    Assert-True (@($bundleManifest.files) -contains "scripts/codex-runtime.ps1") "The plugin manifest omits the Codex worker adapter."
    Assert-True (@($bundleManifest.files) -contains "scripts/codex-orchestrator.ps1") "The plugin manifest omits the Codex orchestrator adapter."
    Assert-True (@($bundleManifest.files) -contains ".codex-plugin/plugin.json") "The bundle manifest omits the Codex plugin manifest."
    Assert-True (@($bundleManifest.files) -contains "skills/factory/SKILL.md") "The bundle manifest omits the Codex factory skill."
    Assert-True (@($bundleManifest.files) -contains "scripts/factory-preview.ps1") "The plugin manifest omits browser preview lifecycle management."

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

    $readableLocalSession = Get-FactoryWorkerSessionName -TaskId "local:20260816-210251-fe35a8dc" -Title "Fix the profile export"
    Assert-Equal "factory-local-20260816-210251-fe35a8dc-fix-the-profile-export" $readableLocalSession "Local session name is not readable."
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
    $integrationSource = Get-Content -LiteralPath (Join-Path $pluginRoot "scripts\integrate-task.ps1") -Raw
    Assert-True ($integrationSource.Contains('"merge", "--no-ff", "--no-edit", $Commit')) "Native integration does not merge the immutable approved SHA."
    Assert-True ($integrationSource.Contains('"push", $remote, "HEAD:$developmentBranch"')) "Native integration does not use an explicit development refspec."
    Assert-True (-not $integrationSource.Contains("--force")) "Native integration contains a force operation."
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
    Assert-Equal 7 ((Read-FactoryJson -Path $context.configPath).version) "Config migration failed."
    Assert-Equal 7 ((Read-FactoryJson -Path $context.statePath).version) "State migration failed."
    $launcherTestConfig = Read-FactoryJson -Path $context.configPath
    $launcherTestConfig.nativeScheduler.startWithOrchestrator = $false
    Write-FactoryJsonAtomic -Path $context.configPath -Value $launcherTestConfig

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

    $schedulerScript = Join-Path $pluginRoot "scripts\factory-scheduler.ps1"
    $schedulerStart = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2) | ConvertFrom-Json
    Assert-True ([bool]$schedulerStart.started) "Native scheduler did not start."
    Assert-True ([int]$schedulerStart.scheduler.pid -gt 0) "Native scheduler did not report its PID."
    $schedulerStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action status -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-True ([bool]$schedulerStatus.running) "Native scheduler status did not find the live process."
    & powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action run -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2
    if ($LASTEXITCODE -ne 0) { throw "Duplicate scheduler run probe failed." }
    $schedulerAfterDuplicateRun = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action status -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-True ([bool]$schedulerAfterDuplicateRun.running) "A losing scheduler process cleared the winner's identity."
    Assert-Equal ([int]$schedulerStart.scheduler.pid) ([int]$schedulerAfterDuplicateRun.pid) "Duplicate scheduler run replaced the active process."
    $schedulerSecondStart = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime -IntervalSeconds 2) | ConvertFrom-Json
    Assert-True ([bool]$schedulerSecondStart.alreadyRunning) "Native scheduler allowed a duplicate process."
    $schedulerStop = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-True ([bool]$schedulerStop.stopped) "Native scheduler did not stop gracefully."

    $legacyConfig = Read-FactoryJson -Path $context.configPath
    $legacyConfig.version = 2
    $legacyConfig.autoPushDevelopment = $false
    $legacyConfig.PSObject.Properties.Remove("maxConcurrency")
    $legacyConfig.PSObject.Properties.Remove("defaultStartMode")
    $legacyConfig.PSObject.Properties.Remove("conversationLanguage")
    $legacyConfig.PSObject.Properties.Remove("testDatabaseIsolation")
    Write-FactoryJsonAtomic -Path $context.configPath -Value $legacyConfig
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository -Initialize) | ConvertFrom-Json
    $migratedConfig = Read-FactoryJson -Path $context.configPath
    Assert-Equal 7 ([int]$migratedConfig.version) "Legacy config version was not migrated."
    Assert-Equal 20 ([int]$migratedConfig.maxConcurrency) "Missing config defaults were not added."
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
        if ([string]$automaticLocalTask.status -ne "queued") { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $automaticLocalDeadline)
    Assert-Equal "auto" ([string]$automaticLocalTask.startMode) "Automatic local task lost its launch mode."
    Assert-Equal $localText ([string]$automaticLocalTask.title) "Local task title was not derived from operator text."
    Assert-Equal $localText ([string]$automaticLocalTask.brief) "Local task brief did not preserve operator text."
    $expectedLocalSessionPrefix = "factory-$($automaticLocalId.Replace(':', '-'))-update-the-personal-"
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
    foreach ($propertyName in @("source", "startMode", "backgroundSession", "plan", "review", "approval", "reworkRequestedAt", "planRecordedAt", "resultRecordedAt", "pendingInstructions")) {
        $state.tasks[0].PSObject.Properties.Remove($propertyName)
    }
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $repository -Initialize) | ConvertFrom-Json
    $migratedState = Read-FactoryJson -Path $context.statePath
    Assert-Equal 7 ([int]$migratedState.version) "Legacy state version was not migrated."
    Assert-True ($null -ne $migratedState.scheduler) "Native scheduler state was not migrated."
    Assert-Equal "auto" ([string]$migratedState.tasks[0].startMode) "Legacy task start mode was not defaulted."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["backgroundSession"]) "Legacy task session field was not added."
    Assert-True ($null -ne $migratedState.PSObject.Properties["agentResolutionCache"]) "Legacy state agent resolution cache field was not added."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["planRecordedAt"]) "Legacy task plan timestamp field was not added."
    Assert-True ($null -ne $migratedState.tasks[0].PSObject.Properties["source"]) "Legacy task source field was not added."

    $cliScriptPath = Join-Path $pluginRoot "factory.ps1"
    $cliSource = Get-Content -LiteralPath $cliScriptPath -Raw
    Assert-True ($cliSource.Contains('[ValidateSet(') -and $cliSource.Contains('"completion"')) "Factory CLI does not expose native command completion."
    Assert-True ($cliSource.Contains('"go"')) "Factory CLI does not expose native go."
    Assert-True ($cliSource.Contains('"add"') -and $cliSource.Contains('[string]$File')) "Factory CLI does not expose native file intake."
    Assert-True ($cliSource.Contains('"new"') -and $cliSource.Contains('[switch]$Auto')) "Factory CLI does not expose native local task intake."
    Assert-True ($cliSource.Contains('[switch]$Direct')) "Factory CLI does not expose direct approval."
    Assert-True ($cliSource.Contains('"preview"') -and $cliSource.Contains('[switch]$NoOpen')) "Factory CLI does not expose native browser preview."
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
    $reviewCliTask.commit = "1234567890abcdef"
    $reviewCliTask.plan = [pscustomobject]@{ questions = @([Text.Encoding]::GetEncoding(437).GetString([Text.Encoding]::UTF8.GetBytes($staleQuestion))) }
    $reviewCliTask.workerResult = [pscustomobject]@{ commit = "1234567890abcdef"; notes = "Ready."; tests = @(); changedFiles = @() }
    $rejectCliTask = New-FactoryTestTask -Id "reject-cli-task" -Title "Disposable CLI task without artifacts" -Now $now
    $cliState.tasks = @($cliState.tasks) + @($heldCliTask, $reviewCliTask, $doneCliTask, $rejectCliTask)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $cliState

    $cliHelp = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath help | Out-String)
    Assert-True ($cliHelp.Contains("!factory status")) "Factory CLI help does not explain direct orchestrator shell mode."
    Assert-True ($cliHelp.Contains("no AI interpretation")) "Factory CLI help hides its deterministic execution model."
    Assert-True ($cliHelp.Contains("factory go <task-id> [--direct]")) "Factory CLI help omits direct approval."
    $cliGoHelp = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath help go | Out-String)
    Assert-True ($cliGoHelp.Contains("skips independent AI code review")) "Factory go help hides direct approval semantics."

    $cliStatus = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath status -Repository $repository -ClaudeCommand $fakeClaude -NoReconcile | Out-String)
    Assert-True ($cliStatus.Contains(([char]0x256D).ToString() + ([char]0x2500).ToString() + " Factory")) "Factory CLI status does not use the continuous Unicode tree."
    Assert-True ($cliStatus.Contains("held-cli-task")) "Factory CLI status omitted an unfinished task."
    Assert-True ($cliStatus.Contains("Held CLI task with a complete readable title")) "Factory CLI status omitted the full title."
    Assert-True ($cliStatus.Contains("https://app.asana.com/0/0/held-cli-task")) "Factory CLI status omitted the canonical URL."
    Assert-True ($cliStatus.Contains($unicodeFixture)) "Factory CLI status did not repair legacy OEM-decoded UTF-8 for display."
    Assert-True (-not $cliStatus.Contains($mojibakeFixture)) "Factory CLI status printed raw mojibake."
    Assert-True (-not $cliStatus.Contains($staleQuestion)) "Factory CLI status presented a stale plan question as the review reason."
    Assert-True ($cliStatus.Contains("/factory inspect held-cli-task")) "Factory CLI status omitted the exact next orchestrator command."
    Assert-True ($cliStatus.Contains("!factory go review-cli-task --direct")) "Factory CLI status omitted direct approval as a review alternative."
    Assert-True ($cliStatus.Contains("History: factory status done")) "Factory CLI status does not collapse completed history."
    Assert-True (-not $cliStatus.Contains("Completed CLI history task")) "Factory CLI default status expanded completed history."

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
    Assert-True ($cliConcurrency.Contains("Factory concurrency: 3")) "Factory CLI concurrency did not call the deterministic setter."
    Assert-Equal 3 ([int](Read-FactoryJson -Path $context.configPath).concurrency) "Factory CLI concurrency wrote an unexpected value."

    $cliCompletion = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath completion status | Out-String)
    Assert-True ($cliCompletion.Contains("Factory completion: available")) "Factory CLI completion diagnostics are unavailable."

    $cliPaths = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath paths -Repository $repository | Out-String)
    Assert-True ($cliPaths.Contains([string]$context.configPath)) "Factory CLI paths omitted the private config path."
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
            Assert-True ($commandCompletion -contains "start" -and $commandCompletion -contains "scheduler" -and $commandCompletion -contains "purge" -and $commandCompletion -contains "preview") "PowerShell did not complete the unified native commands."
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
    $previewStopOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScriptPath preview stop -Repository $repository | Out-String)
    Assert-True ($previewStopOutput.Contains("Factory preview stopped: preview-switch-task")) "Factory preview stop did not report the stopped task."
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
        notes = $unicodeFixture
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
    Assert-Equal $unicodeFixture ([string]$task.workerResult.notes) "Stop-hook input corrupted UTF-8 worker output."
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
    $pipelineTask = New-FactoryTestTask -Id "pipeline-task" -Title "Native integration pipeline" -Now (Get-FactoryUtcTimestamp)
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
    $pipelineTick = (& powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action tick -Repository $repository -ClaudeCommand $fakeClaude -RuntimeHome $runtime) | ConvertFrom-Json
    Assert-Equal 1 ([int]$pipelineTick.integratedCount) "Native scheduler did not integrate exactly one approved task."
    Assert-Equal 0 @($pipelineTick.errors).Count "Native pipeline reported an error."
    $pipelineFinalState = Read-FactoryJson -Path $context.statePath
    $pipelineFinalTask = @($pipelineFinalState.tasks | Where-Object { [string]$_.id -eq "pipeline-task" })[0]
    Assert-Equal "done" ([string]$pipelineFinalTask.status) "Native pipeline did not finish cleanup."
    Assert-Equal "published" ([string]$pipelineFinalTask.integration.status) "Native pipeline did not audit development publication."
    Assert-Equal "published" ([string]$pipelineFinalTask.production.status) "Native pipeline did not audit production publication."
    Assert-True (-not (Test-Path -LiteralPath $pipelineWorktree)) "Native pipeline left its worker worktree behind."
    & git -C $repository fetch origin develop master 1> $null
    & git -C $repository merge-base --is-ancestor $pipelineCommit origin/develop
    Assert-Equal 0 $LASTEXITCODE "Native pipeline commit is absent from remote development."
    & git -C $repository merge-base --is-ancestor $pipelineCommit origin/master
    Assert-Equal 0 $LASTEXITCODE "Native pipeline commit is absent from remote production."
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
    Assert-True ([bool]$runtimeCheck.passed) "Factory doctor did not verify PowerShell dependencies."
    Assert-True ([bool]$agentDefinitionCheck.passed) "Factory doctor did not verify the worker definition."
    Assert-True ([string]$agentDefinitionCheck.detail -match 'additive system-prompt') "Factory doctor hid the additive fallback semantics."
    Assert-Equal "required" ([string]$resolutionCheck.severity) "Worker resolution is not a required doctor check."
    Assert-True ([string]$resolutionCheck.detail -match 'system-prompt') "Factory doctor hid the active system fallback."
    Assert-True ([bool]$databaseIsolationCheck.passed) "Factory doctor did not validate isolated database prerequisites."
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
