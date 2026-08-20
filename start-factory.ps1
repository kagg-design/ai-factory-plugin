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
$env:CLAUDE_FACTORY_HOME = if ($RuntimeHome) {
    [IO.Path]::GetFullPath($RuntimeHome)
} else {
    Join-Path $pluginRoot "runtime"
}
if ($Model) {
    $env:CLAUDE_FACTORY_MODEL = $Model
}

$contextJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository -Initialize
$context = $contextJson | ConvertFrom-Json
$factoryConfig = Read-FactoryJson -Path ([string]$context.configPath)
$selectedAgent = if ($Agent) { $Agent } else { "claude" }
$resolvedCodexCommand = ""
if ($selectedAgent -eq "codex") {
    $resolvedCodexCommand = Resolve-FactoryCodexCommand -Config $factoryConfig -ExplicitCommand $CodexCommand
    $capabilities = Get-FactoryCodexCapabilities -CodexCommand $resolvedCodexCommand
    if (-not [bool]$capabilities.supported) {
        throw "Cannot start the Codex factory runtime: $($capabilities.detail)"
    }
    Set-FactoryProperty -Target $factoryConfig -Name "codexCommand" -Value $resolvedCodexCommand
}
Set-FactoryProperty -Target $factoryConfig -Name "workerAgent" -Value $selectedAgent
$workerAgent = $selectedAgent

$safeProjectKey = ([string]$context.projectKey) -replace '[^A-Za-z0-9_.-]', '-'
$sessionMutex = New-Object System.Threading.Mutex($false, "Local\ClaudeFactorySession-$safeProjectKey")
$ownsMutex = $false
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

    Write-Host "Repository: $($context.repositoryRoot)" -ForegroundColor Cyan
    Write-Host "Project config: $($context.configPath)" -ForegroundColor Cyan
    Write-Host "Factory state: $($context.statePath)" -ForegroundColor Cyan
    Write-Host "Worktrees: $($context.worktreeRoot)" -ForegroundColor Cyan
    Write-Host "Orchestrator runtime: $selectedAgent" -ForegroundColor Cyan
    if ($selectedAgent -eq "claude") {
        Write-Host "Session view: claude agents" -ForegroundColor Cyan
    } else {
        Write-Host "Session view: the stored Codex thread is resumed directly" -ForegroundColor Cyan
    }
    Write-Host "Worker runtime: $workerAgent" -ForegroundColor Cyan
    Write-Host "Command: $(if ($selectedAgent -eq 'claude') { '/factory' } else { 'factory' })" -ForegroundColor Cyan
    Write-Host ""

    if ($selectedAgent -eq "codex") {
        Start-FactoryLauncherScheduler -Context $context -PluginRoot $pluginRoot -ClaudeCommand $ClaudeCommand
        $factoryCodexExitCode = 1
        Start-FactoryCodexOrchestrator `
            -CodexCommand $resolvedCodexCommand `
            -PluginRoot $pluginRoot `
            -Context $context `
            -New:$New `
            -Resume:$Resume `
            -Continue:$Continue `
            -Model $Model `
            -ExitCodeVariableName "factoryCodexExitCode"
        exit $factoryCodexExitCode
    }

    $identityPath = Join-Path ([string]$context.projectData) "orchestrator-session.json"
    $identity = if (Test-Path -LiteralPath $identityPath) {
        try { Read-FactoryJson -Path $identityPath } catch { $null }
    } else { $null }
    $storedSessionId = if (
        -not $New -and $null -ne $identity -and
        [string]$identity.repositoryRoot -and [string]$identity.sessionId -and
        [string]$identity.name -ceq $Name -and
        (Test-FactorySamePath -Left ([string]$identity.repositoryRoot) -Right ([string]$context.repositoryRoot))
    ) { [string]$identity.sessionId } else { "" }

    $agentRows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
    $matchingRows = @(Get-FactoryMatchingOrchestratorRows `
        -Rows $agentRows `
        -RepositoryRoot ([string]$context.repositoryRoot) `
        -Name $Name)
    $interactiveRows = @($matchingRows | Where-Object {
        [string]$_.kind -eq "interactive" -and -not (Test-FactoryTerminalAgentRow -Row $_)
    })
    if ($interactiveRows.Count -gt 0) {
        $interactiveIds = @($interactiveRows | ForEach-Object {
            if ($null -ne $_.PSObject.Properties["sessionId"]) { [string]$_.sessionId } else { "unknown" }
        }) -join ", "
        throw "An interactive factory orchestrator is already running for '$($context.repositoryRoot)' (session: $interactiveIds)."
    }

    $background = Select-FactoryBackgroundOrchestrator `
        -Rows $matchingRows `
        -PreferredSessionId $storedSessionId
    if ($null -ne $background -and $New) {
        $backgroundId = [string]$background.id
        throw "Cannot create a new factory orchestrator while background session '$backgroundId' still exists. Attach to it or stop/remove it first."
    }

    Start-FactoryLauncherScheduler -Context $context -PluginRoot $pluginRoot -ClaudeCommand $ClaudeCommand

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
    if ($Resume) {
        $claudeArguments += "--resume"
    } elseif ($Continue) {
        $claudeArguments += "--continue"
    } elseif ($storedSessionId) {
        Write-Host "Resuming factory conversation: $storedSessionId" -ForegroundColor Green
        $claudeArguments += @("--resume", $storedSessionId)
    } else {
        $newSessionId = [Guid]::NewGuid().ToString()
        Write-FactoryOrchestratorIdentity `
            -Path $identityPath `
            -RepositoryRoot ([string]$context.repositoryRoot) `
            -Name $Name `
            -SessionId $newSessionId
        $claudeArguments += @("--session-id", $newSessionId)
    }

    Set-Location $context.repositoryRoot
    & $ClaudeCommand @claudeArguments
    exit $LASTEXITCODE
} finally {
    if ($ownsMutex) {
        try { $sessionMutex.ReleaseMutex() } catch {}
    }
    $sessionMutex.Dispose()
}
