Set-StrictMode -Version 2.0

if ($null -eq (Get-Command Invoke-FactoryNativeProcess -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "factory-common.ps1")
}

function Get-FactoryCodexSkillHome {
    if ($env:CLAUDE_FACTORY_CODEX_SKILL_HOME) {
        return [IO.Path]::GetFullPath([string]$env:CLAUDE_FACTORY_CODEX_SKILL_HOME)
    }
    return Join-Path ([Environment]::GetFolderPath("UserProfile")) ".agents\skills"
}

function Install-FactoryCodexSkillLink {
    param([Parameter(Mandatory = $true)][string]$PluginRoot)

    $source = [IO.Path]::GetFullPath((Join-Path $PluginRoot "skills\factory"))
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "The bundled Codex factory skill is missing: $source"
    }

    $skillHome = Get-FactoryCodexSkillHome
    New-Item -ItemType Directory -Path $skillHome -Force | Out-Null
    $target = Join-Path $skillHome "factory"
    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force
        $targets = @($item.Target | Where-Object { $_ })
        foreach ($candidate in $targets) {
            $candidatePath = if ([IO.Path]::IsPathRooted([string]$candidate)) {
                [IO.Path]::GetFullPath([string]$candidate)
            } else {
                [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $target) ([string]$candidate)))
            }
            if (Test-FactorySamePath -Left $candidatePath -Right $source) {
                return [pscustomobject]@{ source = $source; target = $target; created = $false }
            }
        }
        throw "Codex skill path '$target' already exists and is not linked to this factory plugin. Move or remove it manually, then retry."
    }

    $itemType = if ($env:OS -eq "Windows_NT") { "Junction" } else { "SymbolicLink" }
    New-Item -ItemType $itemType -Path $target -Target $source | Out-Null
    return [pscustomobject]@{ source = $source; target = $target; created = $true }
}

function Write-FactoryCodexOrchestratorIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    Write-FactoryJsonAtomic -Path $Path -Value ([ordered]@{
        version = 1
        runtime = "codex"
        repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
        sessionId = $SessionId
        updatedAt = Get-FactoryUtcTimestamp
    })
}

function Get-FactoryCodexThreadId {
    param([Parameter(Mandatory = $true)][string]$Jsonl)

    foreach ($line in @($Jsonl -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ([string]$event.type -eq "thread.started" -and [string]$event.thread_id) {
            return [string]$event.thread_id
        }
    }
    return ""
}

function Get-FactoryCodexOrchestratorArguments {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeHome,
        [Parameter(Mandatory = $true)][string]$WorktreeRoot,
        [string]$Model = ""
    )

    $arguments = @(
        "-C", [IO.Path]::GetFullPath($RepositoryRoot),
        "--sandbox", "workspace-write",
        "--approve-for-me",
        "--add-dir", [IO.Path]::GetFullPath($RuntimeHome),
        "--add-dir", [IO.Path]::GetFullPath($WorktreeRoot)
    )
    if ($Model) { $arguments += @("--model", $Model) }
    return $arguments
}

function Start-FactoryCodexOrchestrator {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [Parameter(Mandatory = $true)]$Context,
        [switch]$New,
        [switch]$Resume,
        [switch]$Continue,
        [string]$Model = "",
        $Rotation = $null,
        [Parameter(Mandatory = $true)][string]$ExitCodeVariableName
    )

    $skillLink = Install-FactoryCodexSkillLink -PluginRoot $PluginRoot
    if ([bool]$skillLink.created) {
        Write-Host "Codex skill linked: $($skillLink.target)" -ForegroundColor Green
    }

    $identityPath = Join-Path ([string]$Context.projectData) "codex-orchestrator-session.json"
    $identity = if (Test-Path -LiteralPath $identityPath) {
        try { Read-FactoryJson -Path $identityPath } catch { $null }
    } else { $null }
    $startNewConversation = [bool]($New -or $null -ne $Rotation)
    $storedSessionId = if (
        -not $startNewConversation -and $null -ne $identity -and
        [string]$identity.sessionId -and [string]$identity.repositoryRoot -and
        (Test-FactorySamePath -Left ([string]$identity.repositoryRoot) -Right ([string]$Context.repositoryRoot))
    ) { [string]$identity.sessionId } else { "" }

    if (($Resume -or $Continue) -and -not $storedSessionId) {
        throw "No stored Codex factory orchestrator exists for this repository. Run 'factory start -Agent codex' to create it."
    }

    $environment = @{
        CLAUDE_FACTORY_HOME = [string]$Context.runtimeHome
        CLAUDE_FACTORY_PLUGIN_ROOT = [IO.Path]::GetFullPath($PluginRoot)
        CLAUDE_FACTORY_REPOSITORY = [string]$Context.repositoryRoot
    }
    $sharedArguments = @(Get-FactoryCodexOrchestratorArguments `
        -RepositoryRoot ([string]$Context.repositoryRoot) `
        -RuntimeHome ([string]$Context.runtimeHome) `
        -WorktreeRoot ([string]$Context.worktreeRoot) `
        -Model $Model)

    if (-not $storedSessionId) {
        $bootstrapJsonlPath = Join-Path ([string]$Context.projectData) "codex-orchestrator-bootstrap.jsonl"
        $lastMessagePath = Join-Path ([string]$Context.projectData) "codex-orchestrator-bootstrap.last-message.txt"
        $rotationPrompt = if ($null -ne $Rotation) {
            " " + (Get-FactoryOrchestratorRotationPrompt -Rotation $Rotation)
        } else { "" }
        $prompt = @"
You are the Factory Orchestrator for this repository. Load the factory skill explicitly with `$factory before acting. The skill's canonical protocol is authoritative. You coordinate native factory state and isolated workers; never implement application changes directly in the main repository. Accept natural commands such as "factory status", "factory new", "review <task-id>", "go <task-id>", and "reject <task-id>" without requiring a slash or a dollar prefix. For this bootstrap turn, do not change files or task state; reply only that the Factory Orchestrator is ready.
"@.Trim()
        $prompt += $rotationPrompt
        $bootstrapArguments = @("exec", "--json") + $sharedArguments + @(
            "--output-last-message", $lastMessagePath,
            $prompt
        )
        Write-Host "Creating Codex factory conversation..." -ForegroundColor Green
        $bootstrap = Invoke-FactoryNativeProcess `
            -Command $CodexCommand `
            -Arguments $bootstrapArguments `
            -WorkingDirectory ([string]$Context.repositoryRoot) `
            -Environment $environment
        [IO.File]::WriteAllText($bootstrapJsonlPath, [string]$bootstrap.stdout + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        if ([int]$bootstrap.exitCode -ne 0) {
            throw "Codex could not create the factory orchestrator: $($bootstrap.output)"
        }
        $storedSessionId = Get-FactoryCodexThreadId -Jsonl ([string]$bootstrap.stdout)
        if (-not $storedSessionId) {
            throw "Codex created no resumable thread ID. Inspect '$bootstrapJsonlPath'."
        }
        Write-FactoryCodexOrchestratorIdentity `
            -Path $identityPath `
            -RepositoryRoot ([string]$Context.repositoryRoot) `
            -SessionId $storedSessionId
        if ($null -ne $Rotation) {
            $null = Complete-FactoryOrchestratorRotation -Context $Context -Rotation $Rotation -NewSessionId $storedSessionId
        }
    } else {
        Write-Host "Resuming Codex factory conversation: $storedSessionId" -ForegroundColor Green
    }

    $resumeArguments = @("resume") + $sharedArguments + @("--include-non-interactive", $storedSessionId)
    $previous = @{}
    try {
        foreach ($entry in $environment.GetEnumerator()) {
            $name = [string]$entry.Key
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, "Process")
        }
        Set-Location ([string]$Context.repositoryRoot)
        & $CodexCommand @resumeArguments
        Set-Variable -Scope 1 -Name $ExitCodeVariableName -Value ([int]$LASTEXITCODE)
    } finally {
        foreach ($entry in $previous.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
        }
    }
}
