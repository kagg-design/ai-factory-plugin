[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$ClaudeCommand = "",
    [string]$CodexCommand = "",
    [switch]$FinalizeProduction
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "codex-runtime.ps1")

if (-not $ClaudeCommand) {
    $ClaudeCommand = if ($env:CLAUDE_FACTORY_CLAUDE_COMMAND) {
        $env:CLAUDE_FACTORY_CLAUDE_COMMAND
    } else {
        "claude"
    }
}

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
$CodexCommand = Resolve-FactoryCodexCommand -Config $config -ExplicitCommand $CodexCommand
$mutex = $null
$removedReparsePoints = @()

try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId

    if ([string]$task.status -in @(
        "queued", "starting", "planning", "running", "approved",
        "integrating", "syncing"
    )) {
        throw "Task '$TaskId' is '$($task.status)' and cannot be cleaned up while active."
    }
    if ([string]$task.status -eq "production") {
        $integrationStatus = [string](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name "integration") -Name "status" -Default "")
        $productionStatus = [string](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name "production") -Name "status" -Default "")
        if (-not $FinalizeProduction -or $integrationStatus -ne "published" -or $productionStatus -ne "published") {
            throw "Task '$TaskId' is in production and has not completed the native publication pipeline."
        }
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
    $backgroundId = if ($null -ne $task.backgroundSession) {
        [string]$task.backgroundSession.id
    } else {
        ""
    }
    $testDatabaseName = if ($null -ne $task.PSObject.Properties["testDatabase"]) {
        [string]$task.testDatabase
    } else { "" }
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

    # Validate every Git/worktree safeguard before changing Agent View or disk.
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
    }

    # A terminal-looking row can still own a live process (and therefore hold
    # the worktree on Windows). Stop and verify every matching session before
    # touching the directory. Agent View rm failures remain best effort.
    $previewRun = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "factory-preview.ps1"),
        "-Action", "stop", "-Repository", $repositoryRoot, "-RuntimeHome", [string]$context.runtimeHome,
        "-TaskId", $TaskId
    )
    if ([int]$previewRun.exitCode -ne 0) {
        throw "Task cleanup could not stop its browser preview: $($previewRun.output)"
    }
    $previewCleanup = [string]$previewRun.stdout | ConvertFrom-Json

    $sessionCleanup = Close-FactoryTaskWorkerSessions `
        -Session $task.backgroundSession `
        -ClaudeCommand $ClaudeCommand `
        -CodexCommand $CodexCommand `
        -TaskId $TaskId `
        -Worktree $(if ($worktree) { $worktree } else { "" }) `
        -CodexDisposition "archive"
    if (@($sessionCleanup.stopFailures).Count -gt 0) {
        $blocked = @($sessionCleanup.stopFailures | ForEach-Object {
            "session $($_.id): $($_.warning)"
        }) -join "; "
        throw "Task cleanup stopped before removing artifacts because $blocked"
    }

    # Once no task process can reconnect, drop its isolated database before
    # removing the worktree. A database failure leaves all Git artifacts intact
    # so cleanup can be retried safely.
    $testDatabaseCleanup = Remove-FactoryTestDatabase `
        -Config $config `
        -RepositoryRoot $repositoryRoot `
        -Scope "worker" `
        -TaskId $TaskId `
        -DatabaseName $testDatabaseName

    $removedWorktree = $false
    if ($worktree -and (Test-Path -LiteralPath $worktree)) {
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
    Set-FactoryProperty -Target $task -Name "testDatabase" -Value $null
    Set-FactoryProperty -Target $task -Name "updatedAt" -Value $now
    Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state

    # Git artifacts and done state remain authoritative. Individual `claude rm`
    # failures were collected before removal and never roll finalization back.
    $stoppedAgentSession = @($sessionCleanup.stoppedAgentSessions).Count -gt 0
    $removedAgentSession = @($sessionCleanup.removedAgentSessions).Count -gt 0
    $agentSessionWarning = if (@($sessionCleanup.warnings).Count -gt 0) {
        "Task cleanup succeeded, but " + (@($sessionCleanup.warnings) -join "; ")
    } else { $null }

    [ordered]@{
        taskId = $TaskId
        status = "done"
        commit = $commit
        removedWorktree = $removedWorktree
        deletedBranch = $deletedBranch
        removedReparsePoints = @($removedReparsePoints)
        agentSessionId = if ($backgroundId) { $backgroundId } else { $null }
        stoppedAgentSession = $stoppedAgentSession
        removedAgentSession = $removedAgentSession
        stoppedAgentSessions = @($sessionCleanup.stoppedAgentSessions)
        removedAgentSessions = @($sessionCleanup.removedAgentSessions)
        agentSessionWarning = $agentSessionWarning
        testDatabase = if ($testDatabaseName) { $testDatabaseName } else { $null }
        removedTestDatabase = [bool]$testDatabaseCleanup.removed
        stoppedPreview = [bool](Get-FactoryNestedValue -Target $previewCleanup -Name "stopped" -Default $false)
    } | ConvertTo-Json -Depth 10
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
