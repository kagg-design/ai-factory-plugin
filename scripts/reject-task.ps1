[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$Reason = "",
    [switch]$Keep,
    [switch]$Yes,
    [string]$ClaudeCommand = ""
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
                throw "Refusing to inspect reject entry outside worker root: $itemPath"
            }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
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

if (-not $ClaudeCommand) {
    $ClaudeCommand = if ($env:CLAUDE_FACTORY_CLAUDE_COMMAND) {
        $env:CLAUDE_FACTORY_CLAUDE_COMMAND
    } else {
        "claude"
    }
}

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path ([string]$context.configPath)
$mutex = $null

try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId
    if ([string]$task.status -eq "done") {
        throw "Completed task '$TaskId' is history. It cannot be rejected."
    }

    $now = Get-FactoryUtcTimestamp
    if ($Keep) {
        Set-FactoryProperty -Target $task -Name "approval" -Value $null
        Set-FactoryProperty -Target $task -Name "status" -Value "rejected"
        Set-FactoryProperty -Target $task -Name "rejectionReason" -Value $Reason
        Set-FactoryProperty -Target $task -Name "rejectedAt" -Value $now
        Set-FactoryProperty -Target $task -Name "updatedAt" -Value $now
        Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
        [ordered]@{
            taskId = $TaskId
            action = "keep"
            status = "rejected"
            reason = $Reason
            artifactsPreserved = $true
        } | ConvertTo-Json -Depth 10
        exit 0
    }

    $safeTaskId = ConvertTo-FactorySafeName -Value $TaskId
    if ($safeTaskId -ne $TaskId) {
        throw "Task ID '$TaskId' is not safe for artifact removal."
    }

    $repositoryRoot = [IO.Path]::GetFullPath([string]$context.repositoryRoot)
    $worktreeRoot = [IO.Path]::GetFullPath([string]$context.worktreeRoot)
    $worktree = if ([string]$task.worktree) {
        [IO.Path]::GetFullPath([string]$task.worktree)
    } else {
        $null
    }
    $branch = [string]$task.branch
    if ($branch -and $branch -notlike "factory-worker/*") {
        throw "Task '$TaskId' uses unsafe branch '$branch'."
    }
    if ($worktree -and -not (Test-FactoryPathInsideRoot -Path $worktree -Root $worktreeRoot)) {
        throw "Worker path '$worktree' is outside '$worktreeRoot'."
    }

    $sessionFiles = @(
        Get-ChildItem -LiteralPath ([string]$context.sessionsPath) -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq "$safeTaskId.json" -or
                $_.Name.StartsWith("$safeTaskId-a", [StringComparison]::OrdinalIgnoreCase) -or
                $_.Name -eq "$safeTaskId.sync-tests.json"
            }
    )
    $eventDirectory = Join-Path ([string]$context.eventsPath) $safeTaskId
    $sessionId = if ($null -ne $task.backgroundSession) {
        [string]$task.backgroundSession.id
    } else {
        ""
    }
    $sessionState = if ($null -ne $task.backgroundSession) {
        [string]$task.backgroundSession.state
    } else {
        ""
    }
    $testDatabaseName = if ($null -ne $task.PSObject.Properties["testDatabase"]) {
        [string]$task.testDatabase
    } else { "" }
    $branchExists = $false
    if ($branch) {
        & git -C $repositoryRoot show-ref --verify --quiet "refs/heads/$branch"
        $branchExists = $LASTEXITCODE -eq 0
    }
    $hasArtifacts = [bool](
        ($worktree -and (Test-Path -LiteralPath $worktree)) -or
        $branchExists -or
        $sessionId -or
        $sessionFiles.Count -gt 0 -or
        (Test-Path -LiteralPath $eventDirectory) -or
        [string]$task.commit -or
        $testDatabaseName
    )

    $preview = [ordered]@{
        taskId = $TaskId
        title = [string]$task.title
        status = [string]$task.status
        reason = $Reason
        confirmationRequired = $hasArtifacts
        willStopSession = [bool]($sessionId -and $sessionState -notin @("stopped", "done", "failed"))
        sessionId = if ($sessionId) { $sessionId } else { $null }
        worktree = $worktree
        branch = if ($branch) { $branch } else { $null }
        commit = if ([string]$task.commit) { [string]$task.commit } else { $null }
        testDatabase = if ($testDatabaseName) { $testDatabaseName } else { $null }
        metadataFiles = @($sessionFiles | ForEach-Object { $_.FullName })
        eventDirectory = if (Test-Path -LiteralPath $eventDirectory) { $eventDirectory } else { $null }
        result = "Task will be removed from active factory state. This cannot be undone by the factory."
    }
    if ($hasArtifacts -and -not $Yes) {
        $preview | ConvertTo-Json -Depth 10
        exit 0
    }

    $sessionCleanup = Remove-FactoryTaskAgentSessions `
        -ClaudeCommand $ClaudeCommand `
        -TaskId $TaskId `
        -Worktree $(if ($worktree) { $worktree } else { "" })
    if (@($sessionCleanup.stopFailures).Count -gt 0) {
        $blockedIds = @($sessionCleanup.stopFailures | ForEach-Object { [string]$_.id }) -join ", "
        throw "Failed to stop task session(s) $blockedIds. No artifacts were removed."
    }
    $stoppedSession = @($sessionCleanup.stoppedAgentSessions).Count -gt 0

    # Do not forget a task until its isolated database is gone. The forced drop
    # runs only after every matching worker process has been stopped.
    $testDatabaseCleanup = Remove-FactoryTestDatabase `
        -Config $config `
        -RepositoryRoot $repositoryRoot `
        -Scope "worker" `
        -TaskId $TaskId `
        -DatabaseName $testDatabaseName

    $removedReparsePoints = @()
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
        $removedReparsePoints = @(Remove-FactoryReparsePointsInTree -Path $worktree)
        if ($isRegistered) {
            & git -c core.longpaths=true -C $repositoryRoot worktree remove --force $worktree
            $stillRegistered = @(
                Get-FactoryRegisteredWorktreePaths -RepositoryRoot $repositoryRoot |
                    Where-Object { $_.Equals($worktree, [StringComparison]::OrdinalIgnoreCase) }
            ).Count -gt 0
            if ($LASTEXITCODE -ne 0 -and $stillRegistered) {
                throw "Git failed to unregister worker worktree '$worktree'."
            }
        }
        if (Test-Path -LiteralPath $worktree) {
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
    if ($branch -and $branchExists) {
        & git -C $repositoryRoot branch -D $branch 1> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete local worker branch '$branch'."
        }
        $deletedBranch = $true
    }
    & git -C $repositoryRoot worktree prune
    if ($LASTEXITCODE -ne 0) { throw "Failed to prune worktree metadata." }

    foreach ($sessionFile in $sessionFiles) {
        Remove-Item -LiteralPath $sessionFile.FullName -Force
    }
    if (Test-Path -LiteralPath $eventDirectory) {
        Remove-Item -LiteralPath $eventDirectory -Recurse -Force
    }

    $remainingTasks = @($state.tasks | Where-Object { [string]$_.id -ne $TaskId })
    Set-FactoryProperty -Target $state -Name "tasks" -Value $remainingTasks
    Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state

    [ordered]@{
        taskId = $TaskId
        action = "discard"
        reason = $Reason
        removedFromState = $true
        stoppedSession = $stoppedSession
        stoppedAgentSessions = @($sessionCleanup.stoppedAgentSessions)
        removedAgentSessions = @($sessionCleanup.removedAgentSessions)
        agentSessionWarning = if (@($sessionCleanup.warnings).Count -gt 0) { @($sessionCleanup.warnings) -join "; " } else { $null }
        removedWorktree = $removedWorktree
        deletedBranch = $deletedBranch
        removedMetadataFiles = @($sessionFiles | ForEach-Object { $_.FullName })
        removedEventDirectory = -not (Test-Path -LiteralPath $eventDirectory)
        removedReparsePoints = @($removedReparsePoints)
        testDatabase = if ($testDatabaseName) { $testDatabaseName } else { $null }
        removedTestDatabase = [bool]$testDatabaseCleanup.removed
    } | ConvertTo-Json -Depth 10
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
