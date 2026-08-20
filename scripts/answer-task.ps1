[CmdletBinding(DefaultParameterSetName = "Text")]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true, ParameterSetName = "File")][string]$File,
    [Parameter(Mandatory = $true, ParameterSetName = "Text")][string]$Text,
    [ValidateSet("auto", "interactive")][string]$Mode = "auto",
    [string]$ClaudeCommand = "",
    [string]$CodexCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "codex-runtime.ps1")
if (-not $ClaudeCommand) {
    $ClaudeCommand = if ($env:CLAUDE_FACTORY_CLAUDE_COMMAND) { $env:CLAUDE_FACTORY_CLAUDE_COMMAND } else { "claude" }
}

$answers = if ($PSCmdlet.ParameterSetName -eq "File") {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Answer file not found: $File" }
    [IO.File]::ReadAllText([IO.Path]::GetFullPath($File), [Text.Encoding]::UTF8)
} else { $Text }
if (-not $answers.Trim()) { throw "Answers cannot be empty." }

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$CodexCommand = Resolve-FactoryCodexCommand -Config $config -ExplicitCommand $CodexCommand
$answerBytes = [Text.Encoding]::UTF8.GetBytes($answers)
$sha = [Security.Cryptography.SHA256]::Create()
try { $answerHash = ([BitConverter]::ToString($sha.ComputeHash($answerBytes))).Replace("-", "").ToLowerInvariant() } finally { $sha.Dispose() }
$mutex = $null

try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId
    $isActiveRework = [string](Get-FactoryNestedValue -Target $task -Name "reworkRequestedAt" -Default "") -and
        [string]$task.status -in @("queued", "starting", "planning", "running", "awaiting-input", "blocked", "failed", "held")
    if (([string]$task.commit -or $null -ne $task.workerResult) -and -not $isActiveRework) {
        throw "Task '$TaskId' already has a validated result or commit."
    }
    $worktree = [string]$task.worktree
    if (-not $worktree -or -not (Test-Path -LiteralPath $worktree -PathType Container)) {
        throw "Task '$TaskId' has no usable retained worktree."
    }

    $backgroundId = if ($null -ne $task.backgroundSession) { [string]$task.backgroundSession.id } else { "" }
    $isSameQueuedAnswer = [string]$task.answerHash -eq $answerHash -and [string]$task.status -eq "queued"
    $sessionCleanup = [pscustomobject]@{
        stoppedAgentSessions = @()
        removedAgentSessions = @()
        stopFailures = @()
        warnings = @()
    }
    if ($backgroundId -and -not $isSameQueuedAnswer) {
        # Removing the Agent View row does not remove the JSONL transcript;
        # Claude Code 2.1.228 was verified to retain it under ~/.claude/projects.
        $sessionCleanup = Close-FactoryTaskWorkerSessions `
            -Session $task.backgroundSession `
            -ClaudeCommand $ClaudeCommand `
            -CodexCommand $CodexCommand `
            -TaskId $TaskId `
            -Worktree $worktree `
            -CodexDisposition "archive"
        if (@($sessionCleanup.stopFailures).Count -gt 0) {
            $blockedIds = @($sessionCleanup.stopFailures | ForEach-Object { [string]$_.id }) -join ", "
            throw "Failed to stop task session(s) $blockedIds; the retained worktree was not changed."
        }
    }

    $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
    $decisionsPath = Join-Path $worktree "FACTORY-DECISIONS.md"
    [IO.File]::WriteAllText($decisionsPath, $answers, $utf8WithoutBom)

    $commonGitDirText = (& git -C $context.repositoryRoot rev-parse --git-common-dir).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $commonGitDirText) { throw "Could not resolve the shared Git directory." }
    $commonGitDir = if ([IO.Path]::IsPathRooted($commonGitDirText)) { $commonGitDirText } else { Join-Path $context.repositoryRoot $commonGitDirText }
    $excludePath = Join-Path ([IO.Path]::GetFullPath($commonGitDir)) "info\exclude"
    New-Item -ItemType Directory -Path (Split-Path -Parent $excludePath) -Force | Out-Null
    $excludeLines = if (Test-Path -LiteralPath $excludePath) { @([IO.File]::ReadAllLines($excludePath)) } else { @() }
    if ($excludeLines -notcontains "/FACTORY-DECISIONS.md") {
        [IO.File]::AppendAllText($excludePath, "/FACTORY-DECISIONS.md" + [Environment]::NewLine, $utf8WithoutBom)
    }

    $pointer = "<!-- FACTORY_DECISIONS_START -->`nBefore continuing, read FACTORY-DECISIONS.md in the worker worktree and follow the operator decisions recorded there.`n<!-- FACTORY_DECISIONS_END -->"
    $brief = [string]$task.brief
    $markerPattern = '(?s)\s*<!-- FACTORY_DECISIONS_START -->.*?<!-- FACTORY_DECISIONS_END -->'
    $briefWithoutPointer = [regex]::Replace($brief, $markerPattern, "").TrimEnd()
    Set-FactoryProperty -Target $task -Name "brief" -Value ($briefWithoutPointer + "`n`n" + $pointer)

    if (-not $isSameQueuedAnswer) {
        Set-FactoryProperty -Target $task -Name "attempts" -Value (([int]$task.attempts) + 1)
        Set-FactoryProperty -Target $task -Name "attemptPrepared" -Value $true
    }
    Set-FactoryProperty -Target $task -Name "answerHash" -Value $answerHash
    Set-FactoryProperty -Target $task -Name "backgroundSession" -Value $null
    Set-FactoryProperty -Target $task -Name "agentId" -Value $null
    Set-FactoryProperty -Target $task -Name "error" -Value $null
    Set-FactoryProperty -Target $task -Name "holdReason" -Value $null
    Set-FactoryProperty -Target $task -Name "startMode" -Value $Mode
    Set-FactoryProperty -Target $task -Name "status" -Value "queued"
    Set-FactoryProperty -Target $task -Name "updatedAt" -Value (Get-FactoryUtcTimestamp)
    Set-FactoryProperty -Target $state -Name "active" -Value $true
    Set-FactoryProperty -Target $state -Name "paused" -Value $false
    Set-FactoryProperty -Target $state -Name "updatedAt" -Value (Get-FactoryUtcTimestamp)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state

    [ordered]@{
        taskId = $TaskId
        status = "queued"
        mode = $Mode
        decisionsPath = $decisionsPath
        answerHash = $answerHash
        stoppedBackgroundId = $backgroundId
        stoppedAgentSessions = @($sessionCleanup.stoppedAgentSessions)
        removedAgentSessions = @($sessionCleanup.removedAgentSessions)
        agentSessionWarning = if (@($sessionCleanup.warnings).Count -gt 0) { @($sessionCleanup.warnings) -join "; " } else { $null }
        idempotent = $isSameQueuedAnswer
    } | ConvertTo-Json -Depth 10
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
