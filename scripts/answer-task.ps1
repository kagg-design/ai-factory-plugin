[CmdletBinding(DefaultParameterSetName = "Text")]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true, ParameterSetName = "File")][string]$File,
    [Parameter(Mandatory = $true, ParameterSetName = "Text")][string]$Text,
    [ValidateSet("auto", "interactive")][string]$Mode = "auto",
    [string]$ClaudeCommand = "",
    [string]$CodexCommand = "",
    [switch]$FromAsanaSync,
    [switch]$FromRock,
    [switch]$RockOperator,
    [string]$RockId = '',
    [string]$RockQuestionId = '',
    [string]$RockActionId = ''
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
    if ($FromRock) {
        . (Join-Path $PSScriptRoot 'rock-common.ps1')
        $rockConfig = Get-FactoryRockConfiguration -Config $config
        if ($null -eq $rockConfig -or -not $RockActionId -or -not $RockQuestionId) { throw 'Direct ROCK answer requires enabled configuration and correlation IDs.' }
        $owner = Get-FactoryRockOrchestrator $rockConfig $RockId
        if (-not (Test-FactoryRockBinding $owner $TaskId ([string]$context.repositoryRoot))) { throw 'ROCK does not own this question.' }
        if ($RockActionId -cin @((Get-FactoryNestedValue $task 'rockAppliedActions' @()))) {
            @{ taskId = $TaskId; status = $task.status; idempotent = $true } | ConvertTo-Json
            return
        }
        if ([bool]$state.paused -or -not [bool]$state.active) { throw 'Deferred: factory is paused or inactive.' }
        if ([string]$task.status -eq 'held' -and -not $RockOperator) { throw 'Deferred: task is held; a ROCK answer cannot release the hold.' }
        if ([string]$task.status -notin @('blocked', 'awaiting-input', 'held') -or [string](Get-FactoryNestedValue $task.workerResult 'status') -ne 'blocked') { throw 'Deferred: waiting for the worker blocked result.' }
        if ([string]$task.commit) { throw 'ROCK answers cannot replace a post-commit review or rework decision.' }
        $question = Get-FactoryNestedValue $task 'asanaQuestion'
        if ($null -eq $question -or [string](Get-FactoryNestedValue $question 'channel') -cne 'rock' -or [string]$question.storyGid -cne $RockQuestionId -or [int]$question.attempt -ne [int]$task.attempts) { throw 'ROCK answer is stale or belongs to a different question/attempt.' }
        if ([bool](Get-FactoryNestedValue $question 'requiresHuman' $false) -and -not $RockOperator) { throw 'This question requires an operator decision.' }
        if (Test-FactoryTaskHasActiveSession -Task $task) { throw 'Deferred: worker session has not closed yet.' }
    }
    $isActiveRework = [string](Get-FactoryNestedValue -Target $task -Name "reworkRequestedAt" -Default "") -and
        [string]$task.status -in @("queued", "starting", "planning", "running", "awaiting-input", "blocked", "failed", "held")
    $pendingAsanaQuestion = ([bool](Get-FactoryNestedValue -Target $task -Name "asanaMode" -Default $false) -or
        [string](Get-FactoryNestedValue (Get-FactoryNestedValue $task 'asanaQuestion') 'channel') -eq 'rock') -and
        $null -ne (Get-FactoryNestedValue -Target $task -Name "asanaQuestion") -and
        [string]$task.status -in @("blocked", "held", "awaiting-input")
    if ($pendingAsanaQuestion -and -not $FromAsanaSync -and -not $FromRock) {
        throw "Task '$TaskId' has an Asana question. Use factory answer to post the operator's answer in Asana first."
    }
    $resumableAsanaQuestion = $pendingAsanaQuestion -and ($FromAsanaSync -or $FromRock) -and
        -not [string]$task.commit -and [string](Get-FactoryNestedValue -Target $task.workerResult -Name "status" -Default "") -eq "blocked"
    if (([string]$task.commit -or $null -ne $task.workerResult) -and -not $isActiveRework -and -not $resumableAsanaQuestion) {
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

    $attribution = if ($FromRock -and -not $RockOperator) { "ROCK $RockId supplied these task decisions. They do not grant operator approvals. Existing operator decisions take precedence." } else { 'Follow the operator decisions recorded there.' }
    $pointer = "<!-- FACTORY_DECISIONS_START -->`nBefore continuing, read FACTORY-DECISIONS.md in the worker worktree. $attribution`n<!-- FACTORY_DECISIONS_END -->"
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
    if ($FromRock) {
        Set-FactoryProperty $task 'rockAppliedActions' @(@((Get-FactoryNestedValue $task 'rockAppliedActions' @())) + @($RockActionId))
        Set-FactoryProperty $task 'rockAnswer' @{ actor = $(if ($RockOperator) { 'operator' } else { "rock:$RockId" }); questionId = $RockQuestionId; actionId = $RockActionId; text = $answers; at = Get-FactoryUtcTimestamp }
        Set-FactoryProperty $task 'asanaQuestion' $null
    } else {
        Set-FactoryProperty -Target $state -Name "active" -Value $true
        Set-FactoryProperty -Target $state -Name "paused" -Value $false
    }
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
