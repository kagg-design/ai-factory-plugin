[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

function Test-FactoryPathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    return $fullPath.StartsWith(
        $fullRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-FactoryRegisteredWorktreePaths {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $paths = @()
    foreach ($line in @(& git -C $RepositoryRoot worktree list --porcelain)) {
        if ($line -like "worktree *") {
            $paths += [IO.Path]::GetFullPath($line.Substring(9))
        }
    }
    return @($paths)
}

function Remove-FactoryReparsePointsInTree {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [IO.Path]::GetFullPath($Path)
    $removed = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            $itemPath = [IO.Path]::GetFullPath($item.FullName)
            if (-not (Test-FactoryPathInsideRoot -Path $itemPath -Root $root)) {
                throw "Refusing to inspect cleanup entry outside worker root: $itemPath"
            }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                # Delete the link itself. Never recurse into or delete its resolved target,
                # which may intentionally live outside the worker worktree.
                if ($item.PSIsContainer) {
                    [IO.Directory]::Delete($itemPath, $false)
                } else {
                    [IO.File]::Delete($itemPath)
                }
                $removed.Add($itemPath)
            } elseif ($item.PSIsContainer) {
                $pending.Push($itemPath)
            }
        }
    }
    return @($removed)
}

function Remove-FactoryLongPathDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath)) { return }

    try {
        Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction Stop
    } catch {
        $extendedPath = if ($fullPath.StartsWith("\\")) {
            "\\?\UNC\" + $fullPath.Substring(2)
        } else {
            "\\?\" + $fullPath
        }
        [IO.Directory]::Delete($extendedPath, $true)
    }

    if (Test-Path -LiteralPath $fullPath) {
        throw "Failed to remove residual worker directory '$fullPath'."
    }
}

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$mutex = $null
$removedReparsePoints = @()

try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId

    if ([string]$task.status -in @(
        "queued", "starting", "planning", "running", "approved",
        "integrating", "production", "syncing"
    )) {
        throw "Task '$TaskId' is '$($task.status)' and cannot be cleaned up while active."
    }
    if (
        $null -ne $task.backgroundSession -and
        [string]$task.backgroundSession.state -eq "working"
    ) {
        throw "Task '$TaskId' still has a working background session."
    }

    $repositoryRoot = [IO.Path]::GetFullPath([string]$context.repositoryRoot)
    $worktreeRoot = [IO.Path]::GetFullPath([string]$context.worktreeRoot)
    $worktree = if ([string]$task.worktree) {
        [IO.Path]::GetFullPath([string]$task.worktree)
    } else {
        $null
    }
    $branch = [string]$task.branch
    $commit = [string]$task.commit

    if (-not $commit) {
        throw "Task '$TaskId' has no recorded commit. Cleanup refuses to discard unpublished work."
    }
    if ($branch -and $branch -notlike "factory-worker/*") {
        throw "Task '$TaskId' uses unsafe branch '$branch'."
    }
    if ($worktree -and -not (Test-FactoryPathInsideRoot -Path $worktree -Root $worktreeRoot)) {
        throw "Worker path '$worktree' is outside '$worktreeRoot'."
    }

    & git -C $repositoryRoot rev-parse --verify "$commit^{commit}" 1> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Recorded commit '$commit' is not available locally."
    }

    $remote = if ([string]$config.remote) { [string]$config.remote } else { "origin" }
    $requiredBranches = @(
        [string]$config.developmentBranch,
        [string]$config.productionBranch
    ) | Where-Object { $_ } | Select-Object -Unique
    if ($requiredBranches.Count -eq 0) {
        throw "No development or production branch is configured."
    }

    & git -C $repositoryRoot fetch $remote @requiredBranches 1> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to refresh required branches from '$remote'."
    }
    foreach ($requiredBranch in $requiredBranches) {
        $remoteRef = "$remote/$requiredBranch"
        & git -C $repositoryRoot merge-base --is-ancestor $commit $remoteRef
        if ($LASTEXITCODE -ne 0) {
            throw "Commit '$commit' is not reachable from '$remoteRef'. Cleanup refuses to discard it."
        }
    }

    if ($branch) {
        $branchRef = "refs/heads/$branch"
        & git -C $repositoryRoot show-ref --verify --quiet $branchRef
        if ($LASTEXITCODE -eq 0) {
            $branchHead = (& git -C $repositoryRoot rev-parse $branchRef).Trim()
            if ($branchHead -ne $commit) {
                throw "Worker branch '$branch' moved to '$branchHead'; expected '$commit'."
            }
        }
    }

    $registeredPaths = @(Get-FactoryRegisteredWorktreePaths -RepositoryRoot $repositoryRoot)
    $isRegistered = $false
    if ($worktree) {
        $isRegistered = @(
            $registeredPaths | Where-Object {
                $_.Equals($worktree, [StringComparison]::OrdinalIgnoreCase)
            }
        ).Count -gt 0
    }

    $removedWorktree = $false
    if ($worktree -and (Test-Path -LiteralPath $worktree)) {
        if (-not $isRegistered) {
            throw "Residual worker directory '$worktree' is not a registered worktree. Inspect it manually before cleanup."
        }

        $head = (& git -C $worktree rev-parse HEAD 2>$null).Trim()
        if ($head -ne $commit) {
            throw "Worker HEAD '$head' differs from recorded commit '$commit'."
        }
        $dirty = @(& git -C $worktree status --porcelain 2>$null)
        if ($dirty.Count -gt 0) {
            throw "Worker worktree has uncommitted changes. Cleanup refuses to remove it."
        }

        $removedReparsePoints = @(Remove-FactoryReparsePointsInTree -Path $worktree)

        & git -c core.longpaths=true -C $repositoryRoot worktree remove $worktree
        $removeExitCode = $LASTEXITCODE
        $stillRegistered = @(
            Get-FactoryRegisteredWorktreePaths -RepositoryRoot $repositoryRoot |
                Where-Object {
                    $_.Equals($worktree, [StringComparison]::OrdinalIgnoreCase)
                }
        ).Count -gt 0
        if ($removeExitCode -ne 0 -and $stillRegistered) {
            throw "Git failed to unregister worker worktree '$worktree'."
        }
        if (Test-Path -LiteralPath $worktree) {
            # The worktree was verified clean immediately before Git began
            # removal. Finish deletion if Git unregistered it but Windows left
            # long-path residue behind.
            Remove-FactoryLongPathDirectory -Path $worktree
        }
        $removedWorktree = $true
    } elseif ($isRegistered) {
        & git -C $repositoryRoot worktree prune
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to prune stale worktree metadata for '$worktree'."
        }
        $removedWorktree = $true
    }

    $deletedBranch = $false
    if ($branch) {
        $branchRef = "refs/heads/$branch"
        & git -C $repositoryRoot show-ref --verify --quiet $branchRef
        if ($LASTEXITCODE -eq 0) {
            & git -C $repositoryRoot branch -D $branch 1> $null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to delete local worker branch '$branch'."
            }
            $deletedBranch = $true
        }
    }
    & git -C $repositoryRoot worktree prune
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to prune worktree metadata."
    }

    $now = Get-FactoryUtcTimestamp
    Set-FactoryProperty -Target $task -Name "approval" -Value $null
    Set-FactoryProperty -Target $task -Name "status" -Value "done"
    Set-FactoryProperty -Target $task -Name "error" -Value $null
    Set-FactoryProperty -Target $task -Name "updatedAt" -Value $now
    Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state

    [ordered]@{
        taskId = $TaskId
        status = "done"
        commit = $commit
        removedWorktree = $removedWorktree
        deletedBranch = $deletedBranch
        removedReparsePoints = @($removedReparsePoints)
        preservedSession = if ($null -ne $task.backgroundSession) {
            [string]$task.backgroundSession.id
        } else {
            $null
        }
    } | ConvertTo-Json -Depth 10
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
