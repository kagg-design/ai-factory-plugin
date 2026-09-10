[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$ClaudeCommand = "",
    [string]$CodexCommand = "",
    [Alias("FinalizeProduction")][switch]$FinalizePublication
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
$cleanupStarted = $false
$attemptId = [Guid]::NewGuid().ToString("N")
$attemptStartedAt = Get-FactoryUtcTimestamp
$self = Get-Process -Id $PID
$processStartTimeUtc = $self.StartTime.ToUniversalTime().ToString("o", [Globalization.CultureInfo]::InvariantCulture)
$firstStartedAt = $attemptStartedAt
$startedFromStatus = ""
$resumingCleanup = $false
$repositoryRoot = ""
$worktreeRoot = ""
$worktree = $null
$branch = ""
$commit = ""
$backgroundId = ""
$testDatabaseName = ""
$previewCleanup = [pscustomobject]@{ stopped = $false }
$sessionCleanup = [pscustomobject]@{
    stoppedAgentSessions = @()
    removedAgentSessions = @()
    stopFailures = @()
    warnings = @()
}
$testDatabaseCleanup = [pscustomobject]@{ removed = $false }
$removedReparsePoints = @()
$unregisteredWorktree = $false
$removedWorktree = $false
$deletedBranch = $false

try {
    # Phase 1: claim cleanup under the state mutex, then release it before any
    # process, database, Git, or filesystem I/O. The explicit `cleaning` state
    # replaces the exclusion that the former minutes-long mutex hold provided.
    try {
        $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
        $state = Read-FactoryJson -Path $context.statePath
        $task = Get-FactoryTask -State $state -TaskId $TaskId
        $taskStatus = [string]$task.status
        $existingCleanup = Get-FactoryNestedValue -Target $task -Name "cleanup"
        $existingCleanupStatus = [string](Get-FactoryNestedValue -Target $existingCleanup -Name "status" -Default "")
        $existingCleanupCommit = [string](Get-FactoryNestedValue -Target $existingCleanup -Name "taskCommit" -Default "")
        $commit = [string]$task.commit
        $resumingCleanup = (
            $existingCleanupStatus -in @("running", "failed") -and
            $existingCleanupCommit -and
            $existingCleanupCommit -eq $commit -and
            $taskStatus -in @("cleaning", "blocked")
        )
        if ($taskStatus -eq "cleaning" -and -not $resumingCleanup) {
            throw "Task '$TaskId' has an invalid in-progress cleanup record. Inspect it before retrying."
        }
        if (
            $taskStatus -eq "cleaning" -and
            $existingCleanupStatus -eq "running" -and
            (Test-FactoryRecordedProcess -ProcessRecord $existingCleanup)
        ) {
            throw "Task '$TaskId' cleanup is already running in PID $([int]$existingCleanup.pid)."
        }

        $integrationStatus = [string](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name "integration") -Name "status" -Default "")
        $productionStatus = [string](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name "production") -Name "status" -Default "")
        $developmentOnly = -not [bool](([string]$config.productionBranch).Trim())
        $finalizablePublication = (
            $FinalizePublication -and
            $integrationStatus -eq "published" -and
            (($developmentOnly -and $taskStatus -eq "integrating") -or (-not $developmentOnly -and $taskStatus -eq "production" -and $productionStatus -eq "published"))
        )
        if ($taskStatus -in @(
            "queued", "starting", "planning", "running", "approved",
            "integrating", "syncing", "production"
        ) -and -not $finalizablePublication) {
            throw "Task '$TaskId' is '$taskStatus' and has not completed the native publication pipeline."
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

        $startedFromStatus = if ($resumingCleanup) {
            [string](Get-FactoryNestedValue -Target $existingCleanup -Name "startedFromStatus" -Default "blocked")
        } else {
            $taskStatus
        }
        $firstStartedAt = if ($resumingCleanup) {
            [string](Get-FactoryNestedValue -Target $existingCleanup -Name "firstStartedAt" -Default (
                Get-FactoryNestedValue -Target $existingCleanup -Name "startedAt" -Default $attemptStartedAt
            ))
        } else {
            $attemptStartedAt
        }
        $cleanupClaim = [pscustomobject][ordered]@{
            status = "running"
            stage = "cleanup"
            taskCommit = $commit
            attemptId = $attemptId
            pid = $PID
            processStartTimeUtc = $processStartTimeUtc
            startedFromStatus = $startedFromStatus
            firstStartedAt = $firstStartedAt
            startedAt = $attemptStartedAt
            resumed = $resumingCleanup
        }
        Set-FactoryProperty -Target $task -Name "status" -Value "cleaning"
        Set-FactoryProperty -Target $task -Name "error" -Value $null
        Set-FactoryProperty -Target $task -Name "cleanup" -Value $cleanupClaim
        Set-FactoryProperty -Target $task -Name "updatedAt" -Value $attemptStartedAt
        Set-FactoryProperty -Target $state -Name "updatedAt" -Value $attemptStartedAt
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
        $cleanupStarted = $true
    } finally {
        Exit-FactoryMutex -Mutex $mutex
        $mutex = $null
    }

    if ($env:CLAUDE_FACTORY_TEST_FAIL_CLEANUP -eq $TaskId) {
        throw "Synthetic cleanup failure for '$TaskId'."
    }

    # Phase 2: all slow validation and destructive I/O runs without the global
    # state mutex. The task's `cleaning` state excludes every normal actor.
    & git -C $repositoryRoot rev-parse --verify "$commit^{commit}" 1> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Recorded commit '$commit' is not available locally."
    }

    $remote = if ([string]$config.remote) { [string]$config.remote } else { "origin" }
    $requiredBranches = @(
        @(
            [string]$config.developmentBranch,
            [string]$config.productionBranch
        ) | Where-Object { $_ } | Select-Object -Unique
    )
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
    # A retry may encounter an unregistered residual directory left after Git
    # successfully removed its metadata but the original process was killed.
    if ($worktree -and (Test-Path -LiteralPath $worktree)) {
        if (-not $isRegistered -and -not $resumingCleanup) {
            throw "Residual worker directory '$worktree' is not a registered worktree. Inspect it manually before cleanup."
        }
        if ($isRegistered) {
            $head = (& git -C $worktree rev-parse HEAD 2>$null).Trim()
            if ($head -ne $commit) {
                throw "Worker HEAD '$head' differs from recorded commit '$commit'."
            }
            $dirty = @(& git -C $worktree status --porcelain 2>$null)
            if ($dirty.Count -gt 0) {
                throw "Worker worktree has uncommitted changes. Cleanup refuses to remove it."
            }
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

    if ($worktree -and (Test-Path -LiteralPath $worktree)) {
        $removedReparsePoints = @(Remove-FactoryReparsePointsInTree -Path $worktree)
        if ($isRegistered) {
            if ($env:CLAUDE_FACTORY_TEST_FAIL_WORKTREE_REMOVAL -eq $TaskId) {
                throw "Synthetic worktree removal failure for '$TaskId'."
            }
            & git -c core.longpaths=true -C $repositoryRoot worktree remove $worktree
            $removeExitCode = $LASTEXITCODE
            $stillRegistered = @(
                Get-FactoryRegisteredWorktreePaths -RepositoryRoot $repositoryRoot |
                    Where-Object {
                        $_.Equals($worktree, [StringComparison]::OrdinalIgnoreCase)
                    }
            ).Count -gt 0
            $unregisteredWorktree = -not $stillRegistered
            if ($removeExitCode -ne 0 -and $stillRegistered) {
                throw "Git failed to unregister worker worktree '$worktree'."
            }
        }
        $cleanupDelayMilliseconds = 0
        if ([int]::TryParse([string]$env:CLAUDE_FACTORY_TEST_CLEANUP_REMOVAL_DELAY_MILLISECONDS, [ref]$cleanupDelayMilliseconds) -and $cleanupDelayMilliseconds -gt 0) {
            if ([string]$env:CLAUDE_FACTORY_TEST_CLEANUP_REMOVAL_READY_FILE) {
                [IO.File]::WriteAllText([string]$env:CLAUDE_FACTORY_TEST_CLEANUP_REMOVAL_READY_FILE, $attemptId, (New-Object Text.UTF8Encoding($false)))
            }
            Start-Sleep -Milliseconds $cleanupDelayMilliseconds
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
        $unregisteredWorktree = $true
        $removedWorktree = $true
    }

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

    $finalizeDelayMilliseconds = 0
    if ([int]::TryParse([string]$env:CLAUDE_FACTORY_TEST_CLEANUP_FINALIZE_DELAY_MILLISECONDS, [ref]$finalizeDelayMilliseconds) -and $finalizeDelayMilliseconds -gt 0) {
        if ([string]$env:CLAUDE_FACTORY_TEST_CLEANUP_FINALIZE_READY_FILE) {
            [IO.File]::WriteAllText([string]$env:CLAUDE_FACTORY_TEST_CLEANUP_FINALIZE_READY_FILE, $attemptId, (New-Object Text.UTF8Encoding($false)))
        }
        Start-Sleep -Milliseconds $finalizeDelayMilliseconds
    }

    # Phase 3: publish the terminal audit under a fresh short state lock. A
    # mismatched attempt means another recovery process took ownership, so this
    # process must not overwrite it.
    $now = Get-FactoryUtcTimestamp
    try {
        $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
        $state = Read-FactoryJson -Path $context.statePath
        $task = Get-FactoryTask -State $state -TaskId $TaskId
        $currentAttemptId = [string](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name "cleanup") -Name "attemptId" -Default "")
        if ($currentAttemptId -ne $attemptId) {
            throw "Task '$TaskId' cleanup ownership changed before final state could be recorded."
        }
        Set-FactoryProperty -Target $task -Name "approval" -Value $null
        Set-FactoryProperty -Target $task -Name "status" -Value "done"
        Set-FactoryProperty -Target $task -Name "error" -Value $null
        Set-FactoryProperty -Target $task -Name "cleanup" -Value ([pscustomobject][ordered]@{
            status = "completed"
            stage = "cleanup"
            taskCommit = $commit
            attemptId = $attemptId
            firstStartedAt = $firstStartedAt
            startedAt = $attemptStartedAt
            completedAt = $now
            resumed = $resumingCleanup
            artifacts = [pscustomobject][ordered]@{
                stoppedPreview = [bool](Get-FactoryNestedValue -Target $previewCleanup -Name "stopped" -Default $false)
                stoppedAgentSessions = @($sessionCleanup.stoppedAgentSessions)
                removedAgentSessions = @($sessionCleanup.removedAgentSessions)
                removedTestDatabase = [bool]$testDatabaseCleanup.removed
                removedReparsePoints = @($removedReparsePoints)
                unregisteredWorktree = $unregisteredWorktree
                removedWorktree = $removedWorktree
                deletedBranch = $deletedBranch
            }
        })
        Set-FactoryProperty -Target $task -Name "testDatabase" -Value $null
        Set-FactoryProperty -Target $task -Name "updatedAt" -Value $now
        Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
    } finally {
        Exit-FactoryMutex -Mutex $mutex
        $mutex = $null
    }

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
        unregisteredWorktree = $unregisteredWorktree
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
} catch {
    $failure = $_.Exception.Message
    if ($cleanupStarted) {
        $failureAt = Get-FactoryUtcTimestamp
        try {
            $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
            $failureState = Read-FactoryJson -Path $context.statePath
            $failureTask = Get-FactoryTask -State $failureState -TaskId $TaskId
            $failureCleanup = Get-FactoryNestedValue -Target $failureTask -Name "cleanup"
            if ([string](Get-FactoryNestedValue -Target $failureCleanup -Name "attemptId" -Default "") -eq $attemptId) {
                Set-FactoryProperty -Target $failureTask -Name "status" -Value "blocked"
                Set-FactoryProperty -Target $failureTask -Name "error" -Value $failure
                Set-FactoryProperty -Target $failureTask -Name "cleanup" -Value ([pscustomobject][ordered]@{
                    status = "failed"
                    stage = "cleanup"
                    taskCommit = $commit
                    attemptId = $attemptId
                    startedFromStatus = $startedFromStatus
                    firstStartedAt = $firstStartedAt
                    startedAt = $attemptStartedAt
                    failedAt = $failureAt
                    resumed = $resumingCleanup
                    error = $failure
                    artifacts = [pscustomobject][ordered]@{
                        stoppedPreview = [bool](Get-FactoryNestedValue -Target $previewCleanup -Name "stopped" -Default $false)
                        stoppedAgentSessions = @($sessionCleanup.stoppedAgentSessions)
                        removedAgentSessions = @($sessionCleanup.removedAgentSessions)
                        removedTestDatabase = [bool]$testDatabaseCleanup.removed
                        removedReparsePoints = @($removedReparsePoints)
                        unregisteredWorktree = $unregisteredWorktree
                        removedWorktree = $removedWorktree
                        deletedBranch = $deletedBranch
                    }
                })
                Set-FactoryProperty -Target $failureTask -Name "updatedAt" -Value $failureAt
                Set-FactoryProperty -Target $failureState -Name "updatedAt" -Value $failureAt
                Write-FactoryJsonAtomic -Path $context.statePath -Value $failureState
            }
        } catch {
            $failure = "$failure State update also failed: $($_.Exception.Message)"
        } finally {
            Exit-FactoryMutex -Mutex $mutex
            $mutex = $null
        }
    }
    throw $failure
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
