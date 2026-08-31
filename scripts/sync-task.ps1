[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [ValidateSet("prepare", "finalize")][string]$Action = "prepare",
    [string]$TestsPath = "",
    [string]$LeaseToken = ""
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

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$mutex = $null

try {
    $mutex = Enter-FactoryMutex -ProjectKey $context.projectKey
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId
    $workerVerification = $Action -eq "prepare" -and [string]$task.status -in @("starting", "planning", "running")
    $repositoryRoot = [IO.Path]::GetFullPath([string]$context.repositoryRoot)
    $worktreeRoot = [IO.Path]::GetFullPath([string]$context.worktreeRoot)
    $worktree = if ([string]$task.worktree) {
        [IO.Path]::GetFullPath([string]$task.worktree)
    } else {
        $null
    }
    $branch = [string]$task.branch
    $commit = [string]$task.commit

    if (-not $LeaseToken) {
        throw "Sync requires the exclusive test lease token. Acquire phase 'verify' or 'review' first."
    }
    if (-not (Test-Path -LiteralPath ([string]$context.testLeasePath) -PathType Leaf)) {
        throw "Sync test lease does not exist."
    }
    $leaseState = Read-FactoryJson -Path ([string]$context.testLeasePath)
    $leaseHolder = Get-FactoryNestedValue -Target $leaseState -Name "holder"
    if (
        $null -eq $leaseHolder -or
        [string](Get-FactoryNestedValue -Target $leaseHolder -Name "token" -Default "") -ne $LeaseToken -or
        [string](Get-FactoryNestedValue -Target $leaseHolder -Name "taskId" -Default "") -ne $TaskId -or
        [string](Get-FactoryNestedValue -Target $leaseHolder -Name "phase" -Default "") -notin @("verify", "review")
    ) {
        throw "Sync test lease token does not own this task's verify/review lane."
    }

    if (-not $worktree -or -not (Test-Path -LiteralPath $worktree)) {
        throw "Task '$TaskId' has no usable worker worktree."
    }
    if (-not (Test-FactoryPathInsideRoot -Path $worktree -Root $worktreeRoot)) {
        throw "Worker path '$worktree' is outside '$worktreeRoot'."
    }
    if (-not $branch -or $branch -notlike "factory-worker/*") {
        throw "Task '$TaskId' uses unsafe branch '$branch'."
    }
    if (
        $null -ne $task.backgroundSession -and
        [string]$task.backgroundSession.state -eq "working" -and
        -not $workerVerification
    ) {
        throw "Task '$TaskId' still has a working background session."
    }

    $head = (& git -C $worktree rev-parse HEAD 2>$null).Trim()
    $currentBranch = (& git -C $worktree branch --show-current 2>$null).Trim()
    $dirty = @(& git -C $worktree status --porcelain 2>$null)
    if ($currentBranch -ne $branch) {
        throw "Worker worktree is on '$currentBranch', expected '$branch'."
    }
    if ($dirty.Count -gt 0) {
        throw "Worker worktree has uncommitted changes. Sync requires a clean worktree."
    }
    if ($workerVerification) {
        $commit = $head
    } elseif (-not $commit) {
        throw "Task '$TaskId' has no validated commit to synchronize."
    }

    if ($Action -eq "finalize") {
        if ([string]$task.status -notin @("syncing", "awaiting-review", "held")) {
            throw "Task '$TaskId' is '$($task.status)'; finalize requires syncing, awaiting-review, or held."
        }
        if (-not $TestsPath) {
            throw "Finalize field 'TestsPath' requires a test-results JSON file."
        }
        $resolvedTestsPath = [IO.Path]::GetFullPath($TestsPath)
        if (-not (Test-FactoryPathInsideRoot -Path $resolvedTestsPath -Root ([string]$context.sessionsPath))) {
            throw "Test-results path must be inside '$($context.sessionsPath)'."
        }
        if (-not (Test-Path -LiteralPath $resolvedTestsPath -PathType Leaf)) {
            throw "Test-results file does not exist: $resolvedTestsPath"
        }

        $testReport = Read-FactoryJson -Path $resolvedTestsPath
        $tests = @(Get-FactoryNestedValue -Target $testReport -Name "tests" -Default @())
        if ($tests.Count -eq 0) {
            throw "Sync test report '$resolvedTestsPath' field 'tests' must contain at least one check."
        }
        $passedCount = 0
        for ($testIndex = 0; $testIndex -lt $tests.Count; $testIndex++) {
            $test = $tests[$testIndex]
            $testCommand = [string](Get-FactoryNestedValue -Target $test -Name "command" -Default "")
            $testSummary = [string](Get-FactoryNestedValue -Target $test -Name "summary" -Default "")
            $testStatus = [string](Get-FactoryNestedValue -Target $test -Name "status" -Default "")
            if (-not $testCommand -or -not $testSummary) {
                throw "Sync test report '$resolvedTestsPath' fields 'tests[$testIndex].command' and 'tests[$testIndex].summary' are required."
            }
            if ($testStatus -notin @("passed", "failed", "skipped")) {
                throw "Sync test report '$resolvedTestsPath' field 'tests[$testIndex].status' has invalid value '$testStatus'."
            }
            if ($testStatus -eq "failed") {
                throw "Sync check failed: $testCommand - $testSummary"
            }
            if ($testStatus -eq "passed") { $passedCount++ }
        }
        if ($passedCount -eq 0) {
            throw "Sync test report '$resolvedTestsPath' field 'tests' requires at least one passed check."
        }

        $remote = if ([string]$config.remote) { [string]$config.remote } else { "origin" }
        $development = if ([string]$config.developmentBranch) { [string]$config.developmentBranch } else { "develop" }
        $baseRef = "$remote/$development"
        & git -C $repositoryRoot fetch $remote $development 1> $null
        if ($LASTEXITCODE -ne 0) { throw "Failed to fetch '$baseRef' while finalizing sync." }
        $baseCommit = (& git -C $repositoryRoot rev-parse "$baseRef^{commit}" 2>$null).Trim()
        if (-not $baseCommit) { throw "Configured development branch does not exist: $baseRef" }
        & git -C $worktree merge-base --is-ancestor $baseCommit $head
        if ($LASTEXITCODE -ne 0) {
            throw "Sync candidate '$head' does not contain current development base '$baseCommit'."
        }
        $parentLine = (& git -C $worktree rev-list --parents -n 1 $head 2>$null).Trim()
        if (($parentLine -split '\s+').Count -ne 2) {
            throw "Sync candidate '$head' is not a single-parent task commit."
        }
        $commitCount = (& git -C $worktree rev-list --count "$baseRef..$head").Trim()
        if ([int]$commitCount -ne 1) {
            throw "Synchronized branch contains $commitCount task commits above '$baseRef'; expected one."
        }

        $changedFiles = @(Get-FactoryChangedFiles -Worktree $worktree -Commit $head)
        $notes = [string](Get-FactoryNestedValue -Target $testReport -Name "notes" -Default "")
        $result = [pscustomobject]@{
            status = "completed"
            taskId = $TaskId
            branch = $branch
            commit = $head
            worktree = $worktree
            changedFiles = $changedFiles
            tests = $tests
            notes = if ($notes) {
                $notes
            } else {
                "Rebased onto the configured development branch and revalidated."
            }
            blockingReason = ""
        }
        $now = Get-FactoryUtcTimestamp
        Set-FactoryProperty -Target $task -Name "commit" -Value $head
        Set-FactoryProperty -Target $task -Name "workerResult" -Value $result
        Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-review"
        Set-FactoryProperty -Target $task -Name "review" -Value $null
        Set-FactoryProperty -Target $task -Name "approval" -Value $null
        Set-FactoryProperty -Target $task -Name "pendingInstructions" -Value $null
        Set-FactoryProperty -Target $task -Name "error" -Value $null
        Set-FactoryProperty -Target $task -Name "resultRecordedAt" -Value $now
        Set-FactoryProperty -Target $task -Name "updatedAt" -Value $now
        Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
        Remove-Item -LiteralPath $resolvedTestsPath -Force

        [ordered]@{
            taskId = $TaskId
            status = "awaiting-review"
            commit = $head
            worktree = $worktree
            changedFiles = $changedFiles
            tests = $tests
            adoptedResolvedHead = ($head -ne $commit)
        } | ConvertTo-Json -Depth 20
        exit 0
    }

    if ($head -ne $commit) {
        throw "Worker HEAD '$head' differs from recorded commit '$commit'. Use sync finalize with a test report to adopt a manually resolved one-commit rebase."
    }

    if ([string]$task.status -eq "syncing") {
        [ordered]@{
            taskId = $TaskId
            status = "syncing"
            alreadyPrepared = $true
            commit = $commit
            worktree = $worktree
            changedFiles = @(Get-FactoryChangedFiles -Worktree $worktree -Commit $commit)
            previousTests = @()
        } | ConvertTo-Json -Depth 20
        exit 0
    }
    if (-not $workerVerification -and [string]$task.status -notin @("awaiting-review", "held")) {
        throw "Task '$TaskId' is '$($task.status)'; sync requires awaiting-review or held."
    }
    if (-not $workerVerification -and ($null -eq $task.workerResult -or [string]$task.workerResult.commit -ne $commit)) {
        throw "Task '$TaskId' has no worker result matching '$commit'."
    }

    $remote = if ([string]$config.remote) { [string]$config.remote } else { "origin" }
    $development = if ([string]$config.developmentBranch) {
        [string]$config.developmentBranch
    } else {
        "develop"
    }
    $baseRef = "$remote/$development"
    & git -C $repositoryRoot fetch $remote $development 1> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch '$baseRef'."
    }
    $baseCommit = (& git -C $repositoryRoot rev-parse "$baseRef^{commit}" 2>$null).Trim()
    if (-not $baseCommit) {
        throw "Configured development branch does not exist: $baseRef"
    }

    & git -C $worktree merge-base --is-ancestor $baseCommit $commit
    if ($LASTEXITCODE -eq 0) {
        [ordered]@{
            taskId = $TaskId
            status = [string]$task.status
            alreadyCurrent = $true
            commit = $commit
            baseRef = $baseRef
            baseCommit = $baseCommit
            worktree = $worktree
        } | ConvertTo-Json -Depth 10
        exit 0
    }

    $parentLine = (& git -C $worktree rev-list --parents -n 1 $commit 2>$null).Trim()
    if (($parentLine -split '\s+').Count -ne 2) {
        throw "Task commit '$commit' is not a single-parent commit and cannot be safely rebased."
    }
    $oldCommit = $commit
    $oldParent = (& git -C $worktree rev-parse "$oldCommit^" 2>$null).Trim()
    $previousTests = if ($workerVerification -or $null -eq $task.workerResult) { @() } else { @($task.workerResult.tests) }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Git writes normal rebase progress to stderr. PowerShell 5.1 wraps
        # that text as an error record even when Git succeeds, so the native
        # exit code must remain decisive.
        $ErrorActionPreference = "Continue"
        $rebaseOutput = @(& git -c core.longpaths=true -C $worktree rebase --onto $baseRef $oldParent $branch 2>&1 | ForEach-Object { [string]$_ })
        $rebaseExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($rebaseExitCode -ne 0) {
        $conflicts = @(& git -C $worktree diff --name-only --diff-filter=U 2>$null)
        & git -c core.longpaths=true -C $worktree rebase --abort 1> $null 2> $null
        $details = if ($conflicts.Count -gt 0) {
            " Conflicts: $($conflicts -join ', ')."
        } else {
            " Output: $($rebaseOutput -join ' ')"
        }
        throw "Could not synchronize task '$TaskId' with '$baseRef'.$details"
    }

    $newCommit = (& git -C $worktree rev-parse HEAD).Trim()
    $commitCount = (& git -C $worktree rev-list --count "$baseRef..$newCommit").Trim()
    if ([int]$commitCount -ne 1) {
        throw "Synchronized branch contains $commitCount task commits above '$baseRef'; expected one."
    }
    $changedFiles = @(Get-FactoryChangedFiles -Worktree $worktree -Commit $newCommit)
    $now = Get-FactoryUtcTimestamp
    if ($workerVerification) {
        Set-FactoryProperty -Target $task -Name "verificationSync" -Value ([pscustomobject][ordered]@{
            commit = $newCommit
            baseRef = $baseRef
            baseCommit = $baseCommit
            preparedAt = $now
        })
        Set-FactoryProperty -Target $task -Name "updatedAt" -Value $now
        Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
        Write-FactoryJsonAtomic -Path $context.statePath -Value $state
        [ordered]@{
            taskId = $TaskId
            status = [string]$task.status
            verificationPrepared = $true
            alreadyCurrent = $false
            oldCommit = $oldCommit
            commit = $newCommit
            baseRef = $baseRef
            baseCommit = $baseCommit
            worktree = $worktree
            changedFiles = $changedFiles
            previousTests = @()
        } | ConvertTo-Json -Depth 20
        exit 0
    }
    Set-FactoryProperty -Target $task -Name "commit" -Value $newCommit
    Set-FactoryProperty -Target $task -Name "workerResult" -Value $null
    Set-FactoryProperty -Target $task -Name "review" -Value $null
    Set-FactoryProperty -Target $task -Name "approval" -Value $null
    Set-FactoryProperty -Target $task -Name "status" -Value "syncing"
    Set-FactoryProperty -Target $task -Name "pendingInstructions" -Value "Re-run appropriate checks after synchronization with $baseRef, then finalize sync validation."
    Set-FactoryProperty -Target $task -Name "error" -Value $null
    Set-FactoryProperty -Target $task -Name "updatedAt" -Value $now
    Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state

    [ordered]@{
        taskId = $TaskId
        status = "syncing"
        alreadyCurrent = $false
        oldCommit = $oldCommit
        commit = $newCommit
        baseRef = $baseRef
        baseCommit = $baseCommit
        worktree = $worktree
        changedFiles = $changedFiles
        previousTests = $previousTests
    } | ConvertTo-Json -Depth 20
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
