[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$MessageFile = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository) | ConvertFrom-Json
$operationMutex = Enter-FactoryMutex -ProjectKey "$($context.projectKey)-sync-$(ConvertTo-FactoryTaskArtifactName -TaskId $TaskId)"
try {
    $stateMutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    try {
        $state = Read-FactoryJson -Path $context.statePath
        $task = Get-FactoryTask -State $state -TaskId $TaskId
        $config = Read-FactoryJson -Path $context.configPath
        if ([string]$task.status -notin @("starting", "planning", "running")) { throw "Task '$TaskId' is '$($task.status)'; amend requires an active worker." }
        $worktree = [string]$task.worktree
        if (-not $worktree -or -not (Test-Path -LiteralPath $worktree -PathType Container) -or
            -not (Test-FactoryPathInsideRoot -Path $worktree -Root ([string]$context.worktreeRoot))) { throw "Task worktree is outside the configured worktreeRoot or missing." }
        $branch = [string]$task.branch
        if ($branch -notlike "factory-worker/*" -or $branch -in @([string]$config.developmentBranch, [string]$config.productionBranch)) { throw "Task uses an unsafe worker branch '$branch'." }
        # Reject directory aliases that could escape the checked root.
        $item = Get-Item -LiteralPath $worktree -Force
        while ($null -ne $item -and -not (Test-FactorySamePath -Left $item.FullName -Right ([string]$context.worktreeRoot))) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Worker worktree path contains a reparse point." }
            $item = $item.Parent
        }
        if ($MessageFile) {
            $MessageFile = [IO.Path]::GetFullPath($MessageFile)
            if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf) -or
                (Test-FactoryPathInsideRoot -Path $MessageFile -Root $worktree)) { throw "MessageFile must be an existing file outside the worker worktree." }
            $messageItem = Get-Item -LiteralPath $MessageFile -Force
            while ($null -ne $messageItem) {
                if ($messageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "MessageFile path contains a reparse point." }
                $messageItem = if ($messageItem -is [IO.DirectoryInfo]) { $messageItem.Parent } else { $messageItem.Directory }
            }
        }
    } finally { Exit-FactoryMutex -Mutex $stateMutex }

    $git = Resolve-FactorySyncGit
    function Invoke-AmendGit {
        param([string[]]$GitArguments)
        $run = Invoke-FactoryNativeProcess -Command $git -Arguments (@("-C", $worktree) + $GitArguments)
        if ([int]$run.exitCode -ne 0) { throw "Git $($GitArguments -join ' ') failed: $($run.output)" }
        return ([string]$run.stdout).Trim()
    }
    $actualWorktree = Invoke-AmendGit @("rev-parse", "--show-toplevel")
    if (-not (Test-FactorySamePath -Left $actualWorktree -Right $worktree)) { throw "Git worktree does not equal task.worktree." }
    if ((Invoke-AmendGit @("branch", "--show-current")) -ne $branch) { throw "Worker branch differs from task.branch or HEAD is detached." }
    $oldCommit = Invoke-AmendGit @("rev-parse", "HEAD")
    $parents = (Invoke-AmendGit @("rev-list", "--parents", "-n", "1", "HEAD")) -split '\s+'
    if ($parents.Count -ne 2) { throw "Amend requires a single-parent task commit." }
    $parent = $parents[1]
    $base = "$([string]$config.remote)/$([string]$config.developmentBranch)"
    $null = Invoke-AmendGit @("merge-base", "--is-ancestor", $parent, $base)
    $published = Invoke-FactoryNativeProcess -Command $git -Arguments @("-C", $worktree, "merge-base", "--is-ancestor", $oldCommit, $base)
    if ([int]$published.exitCode -eq 0) { throw "HEAD is already part of development, not an unpublished task commit." }
    if ([int]$published.exitCode -ne 1) { throw "Could not verify that HEAD is an unpublished task commit." }
    foreach ($name in @("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer")) {
        $operationPath = Invoke-AmendGit @("rev-parse", "--path-format=absolute", "--git-path", $name)
        if (Test-Path -LiteralPath $operationPath) { throw "Cannot amend while '$name' is in progress." }
    }
    if (Invoke-AmendGit @("ls-files", "--unmerged")) { throw "Cannot amend unmerged paths." }
    $null = Invoke-AmendGit @("diff", "--quiet", "--")
    if (Invoke-AmendGit @("ls-files", "--others", "--exclude-standard")) { throw "Cannot amend with untracked paths." }
    if (-not $MessageFile) {
        $staged = Invoke-FactoryNativeProcess -Command $git -Arguments @("-C", $worktree, "diff", "--cached", "--quiet", "--")
        if ([int]$staged.exitCode -ne 1) { throw "Amend requires a non-empty staged diff (or MessageFile)." }
    }
    $arguments = @("commit", "--amend")
    if ($MessageFile) { $arguments += @("-F", $MessageFile) } else { $arguments += "--no-edit" }
    $null = Invoke-AmendGit $arguments
    $commit = Invoke-AmendGit @("rev-parse", "HEAD")
    $afterParents = (Invoke-AmendGit @("rev-list", "--parents", "-n", "1", "HEAD")) -split '\s+'
    if ($afterParents.Count -ne 2 -or $afterParents[1] -ne $parent -or
        (Invoke-AmendGit @("branch", "--show-current")) -ne $branch -or
        (Invoke-AmendGit @("status", "--porcelain"))) { throw "Amend postconditions failed: parent/branch changed or worktree is dirty." }
    $stateMutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    try {
        $state = Read-FactoryJson -Path $context.statePath
        $current = Get-FactoryTask -State $state -TaskId $TaskId
        if ([string]$current.status -notin @('starting', 'planning', 'running') -or
            -not (Test-FactorySamePath -Left ([string]$current.worktree) -Right $worktree) -or
            [string](Get-FactoryNestedValue $current 'runId') -ne [string](Get-FactoryNestedValue $task 'runId')) { throw 'Task changed while amending; the retained checkout requires inspection.' }
        foreach ($field in @('commit', 'workerResult', 'review', 'approval', 'mergeGate', 'security')) { Set-FactoryProperty -Target $current -Name $field -Value $null }
        Set-FactoryProperty -Target $current -Name 'resultInvalidatedAt' -Value (Get-FactoryUtcTimestamp)
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    } finally { Exit-FactoryMutex -Mutex $stateMutex }
    [ordered]@{ oldCommit = $oldCommit; commit = $commit; parent = $parent; next = 'Emit a fresh FACTORY_RESULT using this final HEAD.' } | ConvertTo-Json
} finally { Exit-FactoryMutex -Mutex $operationMutex }
