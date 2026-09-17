[CmdletBinding()]
param(
    [string]$Repository = (Get-Location).Path,
    [string]$Name = "Claude Factory Orchestrator",
    [switch]$Resume,
    [switch]$Continue,
    [switch]$New,
    [string]$ClaudeCommand = "claude",
    [string]$RuntimeHome = "",
    [string]$Model = "",
    [ValidateSet("claude", "codex")][string]$Agent = "",
    [string]$CodexCommand = ""
)

$ErrorActionPreference = "Stop"
$selectedModes = @(@($Resume, $Continue, $New) | Where-Object { $_ })
if ($selectedModes.Count -gt 1) {
    throw "-Resume, -Continue, and -New are mutually exclusive."
}

$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$standaloneRoot = Join-Path $pluginRoot "standalone"
. (Join-Path $pluginRoot "scripts\factory-common.ps1")
. (Join-Path $pluginRoot "scripts\worker-launch.ps1")
. (Join-Path $pluginRoot "scripts\orchestrator-session.ps1")
. (Join-Path $pluginRoot "scripts\codex-runtime.ps1")
. (Join-Path $pluginRoot "scripts\codex-orchestrator.ps1")

function Start-FactoryLauncherScheduler {
    param($Context, [string]$PluginRoot, [string]$ClaudeCommand)

    $factoryConfig = Read-FactoryJson -Path ([string]$Context.configPath)
    $nativeScheduler = if ($null -ne $factoryConfig.PSObject.Properties["nativeScheduler"]) {
        $factoryConfig.nativeScheduler
    } else { $null }
    if ($null -ne $nativeScheduler -and (-not [bool]$nativeScheduler.enabled -or -not [bool]$nativeScheduler.startWithOrchestrator)) {
        return
    }
    $schedulerResult = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PluginRoot "scripts\factory-scheduler.ps1"),
        "-Action", "start", "-Repository", [string]$Context.repositoryRoot,
        "-ClaudeCommand", $ClaudeCommand, "-RuntimeHome", [string]$Context.runtimeHome
    )
    if ([int]$schedulerResult.exitCode -eq 0) {
        $schedulerStart = [string]$schedulerResult.stdout | ConvertFrom-Json
        Write-Host "Native scheduler: PID $($schedulerStart.scheduler.pid)" -ForegroundColor Green
        if ([string](Get-FactoryNestedValue -Target $schedulerStart -Name "warning" -Default "")) {
            Write-Warning ([string]$schedulerStart.warning)
        }
    } else {
        Write-Warning "Native scheduler did not start: $($schedulerResult.output)"
    }
}
if ($RuntimeHome) { $env:CLAUDE_FACTORY_HOME = [IO.Path]::GetFullPath($RuntimeHome) }
if ($Model) {
    $env:CLAUDE_FACTORY_MODEL = $Model
}

$contextJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository -Initialize
$context = $contextJson | ConvertFrom-Json
$factoryConfig = Read-FactoryJson -Path ([string]$context.configPath)
$selectedAgent = if ($Agent) { $Agent } else { "claude" }
$resolvedCodexCommand = ""
if ($selectedAgent -eq "codex") {
    $configuredCodexCommand = Get-FactoryConfiguredCodexCommand -Config $factoryConfig -ExplicitCommand $CodexCommand
    $resolvedCodexCommand = Resolve-FactoryCodexCommand -Config $factoryConfig -ExplicitCommand $configuredCodexCommand
    $capabilities = Get-FactoryCodexCapabilities -CodexCommand $resolvedCodexCommand
    if (-not [bool]$capabilities.supported) {
        throw "Cannot start the Codex factory runtime: $($capabilities.detail)"
    }
    # Persist the portable setting, not an installer-version directory that will
    # become stale after the next Codex update.
    Set-FactoryProperty -Target $factoryConfig -Name "codexCommand" -Value $configuredCodexCommand
}
Set-FactoryProperty -Target $factoryConfig -Name "workerAgent" -Value $selectedAgent
$workerAgent = $selectedAgent

$safeProjectKey = ([string]$context.projectKey) -replace '[^A-Za-z0-9_.-]', '-'
$sessionMutex = New-Object System.Threading.Mutex($false, "Local\ClaudeFactorySession-$safeProjectKey")
$ownsMutex = $false
$orchestratorEnvironmentWasSet = Test-Path Env:\CLAUDE_FACTORY_ORCHESTRATOR
$previousOrchestratorEnvironment = [Environment]::GetEnvironmentVariable("CLAUDE_FACTORY_ORCHESTRATOR", "Process")
try {
    try {
        $ownsMutex = $sessionMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
    if (-not $ownsMutex) {
        throw "A factory session is already running for '$($context.repositoryRoot)'."
    }

    # Runtime selection changes only after this launcher owns the project's lead
    # session. A failed attempt to switch a live factory must not retarget workers.
    Write-FactoryJsonAtomic -Path ([string]$context.configPath) -Value $factoryConfig
    $pendingRotation = Get-FactoryPendingOrchestratorRotation -Context $context -Runtime $selectedAgent
    if ($null -ne $pendingRotation -and ($Resume -or $Continue)) {
        throw "A $selectedAgent orchestrator rotation is pending. Start normally to activate it, or run 'factory rotate cancel' before using -Resume/-Continue."
    }
    $startNewConversation = [bool]($New -or $null -ne $pendingRotation)

    Write-Host "Repository: $($context.repositoryRoot)" -ForegroundColor Cyan
    Write-Host "Project config: $($context.configPath)" -ForegroundColor Cyan
    Write-Host "Factory state: $($context.statePath)" -ForegroundColor Cyan
    Write-Host "Worktrees: $($context.worktreeRoot)" -ForegroundColor Cyan
    Write-Host "Orchestrator runtime: $selectedAgent" -ForegroundColor Cyan
    if ($selectedAgent -eq "claude") {
        Write-Host "Session view: background orchestrator attached in this terminal; left arrow opens Agent View" -ForegroundColor Cyan
    } else {
        Write-Host "Session view: shared Codex app-server (terminal, agents dashboard, and Remote phone)" -ForegroundColor Cyan
        Write-Host "Codex CLI: $resolvedCodexCommand" -ForegroundColor Cyan
    }
    Write-Host "Worker runtime: $workerAgent" -ForegroundColor Cyan
    Write-Host "Command: $(if ($selectedAgent -eq 'claude') { '/factory' } else { 'factory' })" -ForegroundColor Cyan
    if ($null -ne $pendingRotation) {
        Write-Host "Orchestrator rotation: $([string]$pendingRotation.rotationId)" -ForegroundColor Green
        Write-Host "Handoff: $([string]$pendingRotation.handoffPath)" -ForegroundColor Green
    }
    Write-Host ""

    if ($selectedAgent -eq "codex") {
        Start-FactoryLauncherScheduler -Context $context -PluginRoot $pluginRoot -ClaudeCommand $ClaudeCommand
        $env:CLAUDE_FACTORY_ORCHESTRATOR = "1"
        $factoryCodexExitCode = 1
        Start-FactoryCodexOrchestrator `
            -CodexCommand $resolvedCodexCommand `
            -PluginRoot $pluginRoot `
            -Context $context `
            -New:$startNewConversation `
            -Resume:$Resume `
            -Continue:$Continue `
            -Model $Model `
            -Rotation $pendingRotation `
            -ExitCodeVariableName "factoryCodexExitCode"
        exit $factoryCodexExitCode
    }

    $identityPath = Join-Path ([string]$context.projectData) "orchestrator-session.json"
    $identity = if (Test-Path -LiteralPath $identityPath) {
        try { Read-FactoryJson -Path $identityPath } catch { $null }
    } else { $null }
    $storedSessionId = if (
        -not $startNewConversation -and $null -ne $identity -and
        [string]$identity.repositoryRoot -and [string]$identity.sessionId -and
        [string]$identity.name -ceq $Name -and
        (Test-FactorySamePath -Left ([string]$identity.repositoryRoot) -Right ([string]$context.repositoryRoot))
    ) { [string]$identity.sessionId } else { "" }

    $agentRows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
    $matchingRows = @(Get-FactoryMatchingOrchestratorRows `
        -Rows $agentRows `
        -RepositoryRoot ([string]$context.repositoryRoot) `
        -Name $Name -SessionId $storedSessionId)
    $interactiveRows = @($matchingRows | Where-Object {
        [string]$_.kind -eq "interactive" -and -not (Test-FactoryTerminalAgentRow -Row $_)
    })
    if ($interactiveRows.Count -gt 0) {
        $interactiveIds = @($interactiveRows | ForEach-Object {
            if ($null -ne $_.PSObject.Properties["sessionId"]) { [string]$_.sessionId } else { "unknown" }
        }) -join ", "
        throw "An interactive factory orchestrator is already running for '$($context.repositoryRoot)' (session: $interactiveIds)."
    }

    $pendingLaunchPath = Join-Path ([string]$context.projectData) 'orchestrator-launch.json'
    $recoveredLaunch = $false
    if (Test-Path -LiteralPath $pendingLaunchPath) {
        if ($New -or $Resume -or $Continue) {
            throw "An orchestrator launch is pending. Run 'factory start' without selection flags to recover it first."
        }
        $background = Start-FactoryClaudeBackgroundOrchestrator -ClaudeCommand $ClaudeCommand -Context $context -Name $Name -Rotation $pendingRotation
        $storedSessionId = [string]$background.sessionId
        $startNewConversation = $false
        $recoveredLaunch = $true
    } else {
        $background = Select-FactoryBackgroundOrchestrator `
            -Rows $matchingRows `
            -PreferredSessionId $storedSessionId
    }
    if ($null -ne $background -and $startNewConversation) {
        $backgroundId = [string]$background.id
        throw "Cannot create a new factory orchestrator while background session '$backgroundId' still exists. Exit or stop/remove it first, then run factory start again."
    }

    if (-not $startNewConversation -and -not $Resume -and -not $Continue -and -not $recoveredLaunch) {
        $conversation = Select-FactoryOrchestratorConversation -Rows $matchingRows -PreferredSessionId $storedSessionId -IdentityUpdatedAt (Get-FactoryNestedValue $identity 'updatedAt' $null)
        if ($null -ne $conversation) {
            $storedSessionId = [string]$conversation.sessionId
            Write-FactoryOrchestratorIdentity -Path $identityPath -RepositoryRoot $context.repositoryRoot -Name $Name -SessionId $storedSessionId
        }
        if ($storedSessionId) {
            Remove-FactoryObsoleteOrchestratorRows -Rows $matchingRows -RetainedSessionId $storedSessionId -ClaudeCommand $ClaudeCommand
        }
    }

    Start-FactoryLauncherScheduler -Context $context -PluginRoot $pluginRoot -ClaudeCommand $ClaudeCommand

    if ($null -eq $background -and $storedSessionId -and -not $startNewConversation -and -not $Resume -and -not $Continue) {
        $savedRows = @($matchingRows | Where-Object {
            [string](Get-FactoryNestedValue $_ 'kind' '') -eq 'background' -and
            [string](Get-FactoryNestedValue $_ 'sessionId' '') -eq $storedSessionId -and
            [string](Get-FactoryNestedValue $_ 'id' '')
        } | Sort-Object { [long](Get-FactoryNestedValue $_ 'startedAt' 0) } -Descending)
        if ($savedRows.Count -gt 0) {
            Write-Host "Restarting saved background orchestrator: $($savedRows[0].id)" -ForegroundColor Green
            $background = Resume-FactoryClaudeBackgroundOrchestrator -ClaudeCommand $ClaudeCommand -Context $context -Row $savedRows[0] -Name $Name
        }
    }

    if ($null -ne $background) {
        $backgroundId = [string]$background.id
        $liveBackgroundRows = @($matchingRows | Where-Object {
            [string]$_.kind -eq "background" -and
            $null -ne $_.PSObject.Properties["id"] -and [string]$_.id -and
            -not (Test-FactoryTerminalAgentRow -Row $_)
        })
        if ($liveBackgroundRows.Count -gt 1) {
            $otherIds = @($liveBackgroundRows | Where-Object {
                [string]$_.id -ne $backgroundId
            } | ForEach-Object { [string]$_.id }) -join ", "
            Write-Warning "Multiple live orchestrator rows exist. Reusing '$backgroundId'; inspect obsolete rows in Agent View: $otherIds"
        }
        $backgroundSessionId = if ($null -ne $background.PSObject.Properties["sessionId"]) {
            [string]$background.sessionId
        } else { $storedSessionId }
        if ($backgroundSessionId) {
            Write-FactoryOrchestratorIdentity `
                -Path $identityPath `
                -RepositoryRoot ([string]$context.repositoryRoot) `
                -Name $Name `
                -SessionId $backgroundSessionId `
                -BackgroundId $backgroundId
        }
        Write-Host "Reusing background orchestrator: $backgroundId" -ForegroundColor Green
        Set-Location $context.repositoryRoot
        $env:CLAUDE_FACTORY_ORCHESTRATOR = "1"
        & $ClaudeCommand attach $backgroundId
        exit $LASTEXITCODE
    }

    $claudeArguments = @(
        "--plugin-dir", $pluginRoot,
        "--add-dir", $standaloneRoot,
        "--permission-mode", "auto",
        "--name", $Name,
        "--remote-control", $Name
    )
    if ($Model) {
        $claudeArguments += @("--model", $Model)
    }
    if ($null -ne $pendingRotation) {
        $claudeArguments += @(
            "--add-dir", [string]$context.projectData,
            "--append-system-prompt", (Get-FactoryOrchestratorRotationPrompt -Rotation $pendingRotation)
        )
    }
    if ($Resume) {
        # Preserve the explicit legacy picker. Normal start/restart never uses
        # it: --bg with a bare --resume may fork an unrelated conversation.
        $claudeArguments += "--resume"
    } elseif ($Continue) {
        $claudeArguments += "--continue"
    } else {
        Set-Location $context.repositoryRoot
        $env:CLAUDE_FACTORY_ORCHESTRATOR = "1"
        Write-Host "$(if ($storedSessionId) { "Resuming factory conversation in background: $storedSessionId" } else { 'Creating background factory conversation...' })" -ForegroundColor Green
        $launched = Start-FactoryClaudeBackgroundOrchestrator -ClaudeCommand $ClaudeCommand -Context $context `
            -Name $Name -Arguments $claudeArguments -SessionId $storedSessionId -Rotation $pendingRotation
        Write-Host "Attaching factory orchestrator: $($launched.id)" -ForegroundColor Green
        & $ClaudeCommand attach ([string]$launched.id)
        exit $LASTEXITCODE
    }

    Set-Location $context.repositoryRoot
    $env:CLAUDE_FACTORY_ORCHESTRATOR = "1"
    & $ClaudeCommand @claudeArguments
    exit $LASTEXITCODE
} finally {
    if ($orchestratorEnvironmentWasSet) {
        $env:CLAUDE_FACTORY_ORCHESTRATOR = $previousOrchestratorEnvironment
    } else {
        Remove-Item Env:\CLAUDE_FACTORY_ORCHESTRATOR -ErrorAction SilentlyContinue
    }
    if ($ownsMutex) {
        try { $sessionMutex.ReleaseMutex() } catch {}
    }
    $sessionMutex.Dispose()
}
