param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$CodexCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "codex-runtime.ps1")

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$CodexCommand = Resolve-FactoryCodexCommand -Config $config -ExplicitCommand $CodexCommand
$state = Read-FactoryJson -Path $context.statePath
$task = Get-FactoryTask -State $state -TaskId $TaskId
$session = $task.backgroundSession
if ($null -eq $session -or [string]$session.runtime -ne "codex") { throw "Task '$TaskId' has no Codex worker session." }
$threadId = [string]$session.sessionId
if (-not $threadId) { throw "Codex thread ID is not available yet. Run 'factory status' and retry." }
$worktree = [string]$task.worktree
if (-not $worktree -or -not (Test-Path -LiteralPath $worktree -PathType Container)) { throw "Task '$TaskId' has no usable worktree." }
$shimDirectory = [string]$session.shimDirectory
if (-not $shimDirectory -or -not (Test-Path -LiteralPath (Join-Path $shimDirectory "git.cmd") -PathType Leaf)) {
    throw "Task '$TaskId' has no verified Codex Git safety proxy. Retry the worker before resuming it."
}

$realGit = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$resumeEnvironment = @{
    CLAUDE_FACTORY_PLUGIN_ROOT = [string]$context.pluginRoot
    CLAUDE_FACTORY_REAL_GIT = [string]$realGit.Source
    CLAUDE_FACTORY_WORKTREE = [IO.Path]::GetFullPath($worktree)
    PATH = "$shimDirectory;$env:PATH"
}
$databaseSettings = Get-FactoryTestDatabaseSettings -Config $config -RepositoryRoot ([string]$context.repositoryRoot)
if ($null -ne $databaseSettings -and [string]$task.testDatabase) {
    foreach ($entry in (Get-FactoryTestDatabaseProcessEnvironment -Settings $databaseSettings -DatabaseName ([string]$task.testDatabase)).GetEnumerator()) {
        $resumeEnvironment[[string]$entry.Key] = [string]$entry.Value
    }
}
$previousEnvironment = @{}
$capture = $null
try {
    foreach ($entry in $resumeEnvironment.GetEnumerator()) {
        $previousEnvironment[[string]$entry.Key] = [Environment]::GetEnvironmentVariable([string]$entry.Key, "Process")
        [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, "Process")
    }

    & $CodexCommand resume -C $worktree --sandbox workspace-write --approve-for-me $threadId
    $interactiveExit = $LASTEXITCODE
    if ($interactiveExit -ne 0) { throw "Codex interactive resume exited with code $interactiveExit." }

    $capturePrompt = @"
The operator has finished an interactive Factory worker turn. Re-read the
factory contract already present in this conversation and report the current
state only. The required task identity is {"taskId":"$TaskId"}. If
implementation is complete, verify the worktree and return the
required FACTORY_RESULT. If this remains an unapproved interactive plan,
return FACTORY_PLAN. If work cannot continue, return a blocked or failed
FACTORY_RESULT. Do not begin unrelated work in this capture turn.
"@
    $captureArguments = @("exec", "resume", "--json")
    if ([string]$session.lastMessagePath) { $captureArguments += @("--output-last-message", [string]$session.lastMessagePath) }
    if ([string]$config.codexModel -and [string]$config.codexModel -ne "inherit") { $captureArguments += @("--model", [string]$config.codexModel) }
    $captureArguments += @($threadId, $capturePrompt)
    $capture = Invoke-FactoryNativeProcess -Command $CodexCommand -Arguments $captureArguments -WorkingDirectory $worktree
    if ([int]$capture.exitCode -ne 0) { throw "Codex state capture failed: $($capture.output)" }
} finally {
    foreach ($entry in $previousEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}
if ([string]$session.transcriptPath -and [string]$capture.stdout) {
    [IO.File]::AppendAllText(
        [string]$session.transcriptPath,
        [string]$capture.stdout + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )
}

$reconciled = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "reconcile-worker-sessions.ps1") -Repository ([string]$context.repositoryRoot) -CodexCommand $CodexCommand | Out-String).Trim()
if (-not $reconciled) { throw "Factory reconciliation returned no data after Codex capture." }
$updated = Read-FactoryJson -Path $context.statePath
$updatedTask = Get-FactoryTask -State $updated -TaskId $TaskId
[ordered]@{
    taskId = $TaskId
    sessionId = $threadId
    status = [string]$updatedTask.status
    reconciled = $reconciled | ConvertFrom-Json
} | ConvertTo-Json -Depth 20
