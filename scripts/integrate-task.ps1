[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$ClaudeCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
if (-not $ClaudeCommand) {
    $ClaudeCommand = if ($env:CLAUDE_FACTORY_CLAUDE_COMMAND) { $env:CLAUDE_FACTORY_CLAUDE_COMMAND } else { "claude" }
}

function Invoke-PipelineGit {
    param([string]$WorkingDirectory, [string[]]$Arguments, [string]$Failure)

    $result = Invoke-FactoryNativeProcess -Command "git" -Arguments (@("-C", $WorkingDirectory) + @($Arguments))
    if ([int]$result.exitCode -ne 0) {
        $detail = ([string]$result.output -replace '[\r\n\t]+', ' ').Trim()
        $suffix = if ($detail) { ": $detail" } else { "" }
        throw "$Failure$suffix"
    }
    return ([string]$result.stdout).Trim()
}

function Test-PipelineAncestor {
    param([string]$RepositoryRoot, [string]$Ancestor, [string]$Descendant)

    $result = Invoke-FactoryNativeProcess -Command "git" -Arguments @("-C", $RepositoryRoot, "merge-base", "--is-ancestor", $Ancestor, $Descendant)
    return [int]$result.exitCode -eq 0
}

function Copy-PipelineIgnoredFiles {
    param($Config, [string]$RepositoryRoot, [string]$Destination)

    foreach ($relative in @($Config.copyIgnoredFiles)) {
        if (-not [string]$relative) { continue }
        $source = Join-Path $RepositoryRoot ([string]$relative)
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $ignored = Invoke-FactoryNativeProcess -Command "git" -Arguments @("-C", $RepositoryRoot, "check-ignore", "-q", "--", [string]$relative)
        if ([int]$ignored.exitCode -ne 0) { continue }
        $target = Join-Path $Destination ([string]$relative)
        $parent = Split-Path -Parent $target
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    }
}

function Reset-PipelineWorktree {
    param(
        [string]$RepositoryRoot,
        [string]$WorktreeRoot,
        [ValidateSet("integrator", "release")][string]$Scope,
        [string]$BaseCommit,
        $Config
    )

    $path = [IO.Path]::GetFullPath((Join-Path $WorktreeRoot "factory-$Scope"))
    $expectedRoot = [IO.Path]::GetFullPath($WorktreeRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to prepare $Scope worktree outside '$WorktreeRoot'."
    }
    $registered = @(& git -C $RepositoryRoot worktree list --porcelain 2>$null | Where-Object { $_ -like "worktree *" } | ForEach-Object { [IO.Path]::GetFullPath($_.Substring(9)) })
    $isRegistered = @($registered | Where-Object { Test-FactorySamePath -Left $_ -Right $path }).Count -gt 0
    if ($isRegistered) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "Registered $Scope worktree is missing: $path"
        }
        $actualRoot = Invoke-PipelineGit -WorkingDirectory $path -Arguments @("rev-parse", "--show-toplevel") -Failure "Cannot inspect $Scope worktree"
        if (-not (Test-FactorySamePath -Left $actualRoot -Right $path)) {
            throw "Refusing to reset unexpected $Scope checkout '$actualRoot'."
        }
        $null = Invoke-PipelineGit -WorkingDirectory $path -Arguments @("reset", "--hard", $BaseCommit) -Failure "Could not reset $Scope worktree"
        $null = Invoke-PipelineGit -WorkingDirectory $path -Arguments @("clean", "-fd") -Failure "Could not clean $Scope worktree"
    } else {
        if (Test-Path -LiteralPath $path) {
            throw "Unregistered directory blocks the $Scope worktree path: $path"
        }
        $null = Invoke-PipelineGit -WorkingDirectory $RepositoryRoot -Arguments @("worktree", "add", "--detach", $path, $BaseCommit) -Failure "Could not create $Scope worktree"
    }
    Copy-PipelineIgnoredFiles -Config $Config -RepositoryRoot $RepositoryRoot -Destination $path
    return $path
}

function Invoke-PipelineMerge {
    param([string]$Worktree, [string]$Commit, [string]$Label)

    $merge = Invoke-FactoryNativeProcess -Command "git" -Arguments @(
        "-c", "commit.gpgsign=false", "-C", $Worktree,
        "merge", "--no-ff", "--no-edit", $Commit
    )
    if ([int]$merge.exitCode -ne 0) {
        $conflicts = [string](Invoke-FactoryNativeProcess -Command "git" -Arguments @("-C", $Worktree, "diff", "--name-only", "--diff-filter=U")).stdout
        $null = Invoke-FactoryNativeProcess -Command "git" -Arguments @("-C", $Worktree, "merge", "--abort")
        $detail = if ($conflicts) { " Conflicts: $($conflicts -replace '[\r\n]+', ', ')." } else { " $([string]$merge.output)" }
        throw "$Label merge failed.$detail"
    }
    return Invoke-PipelineGit -WorkingDirectory $Worktree -Arguments @("rev-parse", "HEAD") -Failure "Cannot resolve $Label merge commit"
}

function Invoke-PipelineChecks {
    param([ValidateSet("integrator", "release")][string]$Scope, [string]$Worktree, [object[]]$Commands)

    $results = New-Object Collections.Generic.List[object]
    foreach ($commandValue in @($Commands)) {
        $command = [string]$commandValue
        $started = Get-FactoryUtcTimestamp
        $run = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "run-isolated-test-command.ps1"),
            "-Repository", [string]$context.repositoryRoot,
            "-Scope", $Scope,
            "-WorkingDirectory", $Worktree,
            "-Command", $command
        )
        $result = [pscustomobject]@{
            command = $command
            status = if ([int]$run.exitCode -eq 0) { "passed" } else { "failed" }
            summary = if ([int]$run.exitCode -eq 0) { "Exited successfully." } else { ([string]$run.output -replace '[\r\n\t]+', ' ').Trim() }
            startedAt = $started
            completedAt = Get-FactoryUtcTimestamp
        }
        $results.Add($result)
        if ([int]$run.exitCode -ne 0) {
            $script:LastCheckResults = $results.ToArray()
            throw "$Scope check failed: $command. $($result.summary)"
        }
    }
    $script:LastCheckResults = $results.ToArray()
    return $results.ToArray()
}

function Update-PipelineTask {
    param(
        [string]$Status,
        [string]$ErrorText,
        $IntegrationValue,
        $ProductionValue,
        [bool]$ClearApproval = $false,
        [string[]]$ExpectedStatuses = @(),
        [string]$ExpectedPlanHash = ""
    )

    $lock = $null
    try {
        $lock = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
        $currentState = Read-FactoryJson -Path ([string]$context.statePath)
        $currentTask = Get-FactoryTask -State $currentState -TaskId $TaskId
        if ([string]$currentTask.commit -ne $taskCommit) {
            throw "Task '$TaskId' commit changed while its native pipeline was running."
        }
        if ($ExpectedStatuses.Count -gt 0 -and [string]$currentTask.status -notin $ExpectedStatuses) {
            throw "Task '$TaskId' moved to '$($currentTask.status)' before the native pipeline could claim it."
        }
        if ($ExpectedPlanHash) {
            $currentApproval = Get-FactoryNestedValue -Target $currentTask -Name "approval"
            if ($null -eq $currentApproval -or [string]$currentApproval.planHash -ne $ExpectedPlanHash) {
                throw "Task '$TaskId' approval changed before the native pipeline could claim it."
            }
        }
        if ($Status) { Set-FactoryProperty -Target $currentTask -Name "status" -Value $Status }
        Set-FactoryProperty -Target $currentTask -Name "error" -Value $(if ($ErrorText) { $ErrorText } else { $null })
        if ($null -ne $IntegrationValue) { Set-FactoryProperty -Target $currentTask -Name "integration" -Value $IntegrationValue }
        if ($null -ne $ProductionValue) { Set-FactoryProperty -Target $currentTask -Name "production" -Value $ProductionValue }
        if ($ClearApproval) { Set-FactoryProperty -Target $currentTask -Name "approval" -Value $null }
        $now = Get-FactoryUtcTimestamp
        Set-FactoryProperty -Target $currentTask -Name "updatedAt" -Value $now
        Set-FactoryProperty -Target $currentState -Name "updatedAt" -Value $now
        Write-FactoryJsonAtomic -Path ([string]$context.statePath) -Value $currentState
    } finally {
        Exit-FactoryMutex -Mutex $lock
    }
}

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path ([string]$context.configPath)
$initialState = Read-FactoryJson -Path ([string]$context.statePath)
$task = Get-FactoryTask -State $initialState -TaskId $TaskId
$taskCommit = [string]$task.commit
$currentStage = "validation"
$developmentPublished = $false
$integrationAudit = $null
$productionAudit = $null
$script:LastCheckResults = @()
$mayUpdateState = [string]$task.status -eq "approved"
$claimAttempted = $false
$pipelineClaimed = $false

try {
    if ([string]$task.status -ne "approved") { throw "Task '$TaskId' is '$($task.status)', not approved." }
    $review = Get-FactoryNestedValue -Target $task -Name "review"
    $approval = Get-FactoryNestedValue -Target $task -Name "approval"
    $plan = Get-FactoryNestedValue -Target $review -Name "integrationPlan"
    if (Test-FactoryTaskRequiresFreshReview -Task $task) {
        throw "Task '$TaskId' has a failed publication attempt. Run review again before go."
    }
    if ($null -eq $review -or [string]$review.verdict -ne "approved" -or [string]$review.commit -ne $taskCommit) {
        throw "Task '$TaskId' has no approved review for '$taskCommit'."
    }
    $planHash = Assert-FactoryIntegrationPlan -Plan $plan -TaskId $TaskId -Commit $taskCommit
    if ($null -eq $approval -or [string]$approval.commit -ne $taskCommit -or [string]$approval.planHash -ne $planHash) {
        throw "Task '$TaskId' approval does not match its immutable review plan."
    }
    if (-not [bool]$plan.autoPushDevelopment -or -not [bool]$plan.autoPromoteToProduction) {
        throw "Task '$TaskId' plan does not authorize both configured publication stages."
    }
    if (-not (Test-Path -LiteralPath ([string]$task.worktree) -PathType Container)) { throw "Worker worktree is missing." }
    $workerHead = Invoke-PipelineGit -WorkingDirectory ([string]$task.worktree) -Arguments @("rev-parse", "HEAD") -Failure "Cannot inspect worker HEAD"
    $workerBranch = Invoke-PipelineGit -WorkingDirectory ([string]$task.worktree) -Arguments @("branch", "--show-current") -Failure "Cannot inspect worker branch"
    $workerDirty = [string](Invoke-FactoryNativeProcess -Command "git" -Arguments @("-C", [string]$task.worktree, "status", "--porcelain")).stdout
    if ($workerHead -ne $taskCommit -or $workerBranch -ne [string]$task.branch -or $workerDirty) {
        throw "Worker checkout no longer matches the approved commit and branch."
    }

    $currentStage = "integration"
    $claimAttempted = $true
    Update-PipelineTask `
        -Status "integrating" `
        -ErrorText "" `
        -IntegrationValue ([pscustomobject]@{
            status = "running"; taskCommit = $taskCommit; baseCommit = [string]$plan.developmentBase; startedAt = Get-FactoryUtcTimestamp
        }) `
        -ProductionValue $null `
        -ExpectedStatuses @("approved") `
        -ExpectedPlanHash $planHash
    $pipelineClaimed = $true

    $remote = [string]$plan.remote
    $developmentBranch = [string]$plan.developmentBranch
    $productionBranch = [string]$plan.productionBranch
    $repositoryRoot = [string]$context.repositoryRoot
    $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $developmentBranch, $productionBranch) -Failure "Could not fetch pipeline branches"
    $remoteDevelopment = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$developmentBranch") -Failure "Cannot resolve development branch"
    $remoteProduction = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$productionBranch") -Failure "Cannot resolve production branch"
    if ($remoteDevelopment -ne [string]$plan.developmentBase -or $remoteProduction -ne [string]$plan.productionBase) {
        throw "Remote branch tips moved after review. Run sync and review again before go."
    }

    $integrator = Reset-PipelineWorktree -RepositoryRoot $repositoryRoot -WorktreeRoot ([string]$context.worktreeRoot) -Scope integrator -BaseCommit $remoteDevelopment -Config $config
    $integrationMerge = Invoke-PipelineMerge -Worktree $integrator -Commit $taskCommit -Label "Development"
    $integrationTests = @(Invoke-PipelineChecks -Scope integrator -Worktree $integrator -Commands @($plan.integrationTestCommands))
    $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $developmentBranch) -Failure "Could not refresh development before push"
    $developmentBeforePush = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$developmentBranch") -Failure "Cannot resolve development before push"
    if ($developmentBeforePush -ne $remoteDevelopment) {
        throw "Development moved while integration checks were running. Run sync and review again."
    }
    $null = Invoke-PipelineGit -WorkingDirectory $integrator -Arguments @("push", $remote, "HEAD:$developmentBranch") -Failure "Development push was rejected"
    $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $developmentBranch) -Failure "Could not verify development push"
    $publishedDevelopment = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$developmentBranch") -Failure "Cannot resolve published development"
    if (-not (Test-PipelineAncestor -RepositoryRoot $repositoryRoot -Ancestor $taskCommit -Descendant "$remote/$developmentBranch")) {
        throw "Approved commit is not reachable from published development."
    }
    $developmentPublished = $true
    $integrationAudit = [pscustomobject]@{
        status = "published"
        taskCommit = $taskCommit
        baseCommit = $remoteDevelopment
        mergeCommit = $publishedDevelopment
        tests = @($integrationTests)
        publishedAt = Get-FactoryUtcTimestamp
    }
    Update-PipelineTask -Status "production" -ErrorText "" -IntegrationValue $integrationAudit -ProductionValue ([pscustomobject]@{
        status = "running"; taskCommit = $taskCommit; baseCommit = $remoteProduction; startedAt = Get-FactoryUtcTimestamp
    })

    $currentStage = "production"
    $productionPublished = $false
    for ($attempt = 1; $attempt -le 3 -and -not $productionPublished; $attempt++) {
        $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $developmentBranch, $productionBranch) -Failure "Could not refresh production inputs"
        $testedDevelopment = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$developmentBranch") -Failure "Cannot resolve production development input"
        $testedProduction = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$productionBranch") -Failure "Cannot resolve production base"
        if (-not (Test-PipelineAncestor -RepositoryRoot $repositoryRoot -Ancestor $taskCommit -Descendant "$remote/$developmentBranch")) {
            throw "Approved commit disappeared from remote development."
        }
        $release = Reset-PipelineWorktree -RepositoryRoot $repositoryRoot -WorktreeRoot ([string]$context.worktreeRoot) -Scope release -BaseCommit $testedProduction -Config $config
        $productionSource = if ([string]$plan.productionMode -eq "task-only") { $taskCommit } else { $testedDevelopment }
        $releaseMerge = Invoke-PipelineMerge -Worktree $release -Commit $productionSource -Label "Production"
        $releaseTests = @(Invoke-PipelineChecks -Scope release -Worktree $release -Commands @($plan.releaseTestCommands))
        $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $developmentBranch, $productionBranch) -Failure "Could not refresh branches before production push"
        $developmentAfterTests = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$developmentBranch") -Failure "Cannot recheck development"
        $productionAfterTests = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$productionBranch") -Failure "Cannot recheck production"
        $developmentStable = [string]$plan.productionMode -eq "task-only" -or $developmentAfterTests -eq $testedDevelopment
        if (-not $developmentStable -or $productionAfterTests -ne $testedProduction) {
            if ($attempt -eq 3) { throw "Production inputs kept moving during release checks; retry limit reached." }
            continue
        }
        $push = Invoke-FactoryNativeProcess -Command "git" -Arguments @("-C", $release, "push", $remote, "HEAD:$productionBranch")
        if ([int]$push.exitCode -ne 0) {
            if ($attempt -eq 3) { throw "Production push was rejected after three tested rebuilds: $($push.output)" }
            continue
        }
        $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $productionBranch) -Failure "Could not verify production push"
        if (-not (Test-PipelineAncestor -RepositoryRoot $repositoryRoot -Ancestor $taskCommit -Descendant "$remote/$productionBranch")) {
            throw "Approved commit is not reachable from published production."
        }
        $publishedProduction = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$productionBranch") -Failure "Cannot resolve published production"
        $productionAudit = [pscustomobject]@{
            status = "published"
            mode = [string]$plan.productionMode
            taskCommit = $taskCommit
            baseCommit = $testedProduction
            sourceCommit = $productionSource
            mergeCommit = $publishedProduction
            tests = @($releaseTests)
            attempts = $attempt
            publishedAt = Get-FactoryUtcTimestamp
            summary = "Approved commit was published to $remote/$developmentBranch and $remote/$productionBranch."
        }
        $productionPublished = $true
    }

    Update-PipelineTask -Status "production" -ErrorText "" -IntegrationValue $integrationAudit -ProductionValue $productionAudit
    $cleanup = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "cleanup-task.ps1") `
        -Repository $repositoryRoot -TaskId $TaskId -ClaudeCommand $ClaudeCommand -FinalizeProduction) | ConvertFrom-Json
    [ordered]@{
        taskId = $TaskId
        status = [string]$cleanup.status
        commit = $taskCommit
        integration = $integrationAudit
        production = $productionAudit
        cleanup = $cleanup
    } | ConvertTo-Json -Depth 40
} catch {
    $failure = $_.Exception.Message
    $failureAudit = [pscustomobject]@{
        status = "failed"
        taskCommit = $taskCommit
        stage = $currentStage
        tests = @($script:LastCheckResults)
        error = $failure
        failedAt = Get-FactoryUtcTimestamp
    }
    try {
        if ($mayUpdateState -and (-not $claimAttempted -or $pipelineClaimed)) {
            if ($currentStage -eq "production") {
                Update-PipelineTask -Status $(if ($developmentPublished) { "blocked" } else { "awaiting-review" }) -ErrorText $failure -IntegrationValue $integrationAudit -ProductionValue $failureAudit -ClearApproval $true
            } else {
                Update-PipelineTask -Status "awaiting-review" -ErrorText $failure -IntegrationValue $failureAudit -ProductionValue $null -ClearApproval $true
            }
        }
    } catch {
        $failure = "$failure State update also failed: $($_.Exception.Message)"
    }
    throw $failure
}
