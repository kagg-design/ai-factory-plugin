[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$ReviewPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

function Test-ReviewPathInsideRoot {
    param([string]$Path, [string]$Root)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $fullPath.StartsWith(
        $fullRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-ReviewCommands {
    param($InputValue, $ConfigValue, $SavedValue)

    $commands = @($InputValue | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($commands.Count -eq 0) {
        $commands = @($ConfigValue | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    if ($commands.Count -eq 0) {
        $commands = @($SavedValue | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    foreach ($command in $commands) {
        if ($command.Length -gt 4096 -or $command -match '[\r\n]') {
            throw "Review test commands must be single-line strings no longer than 4096 characters."
        }
    }
    return @($commands)
}

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$resolvedReviewPath = [IO.Path]::GetFullPath($ReviewPath)
if (-not (Test-ReviewPathInsideRoot -Path $resolvedReviewPath -Root ([string]$context.sessionsPath))) {
    throw "Review input must be inside '$($context.sessionsPath)'."
}
if (-not (Test-Path -LiteralPath $resolvedReviewPath -PathType Leaf)) {
    throw "Review input does not exist: $resolvedReviewPath"
}

$reviewInput = Read-FactoryJson -Path $resolvedReviewPath
$verdict = ([string](Get-FactoryNestedValue -Target $reviewInput -Name "verdict" -Default "")).ToLowerInvariant()
$summary = ([string](Get-FactoryNestedValue -Target $reviewInput -Name "summary" -Default "")).Trim()
$reviewCommit = ([string](Get-FactoryNestedValue -Target $reviewInput -Name "commit" -Default "")).ToLowerInvariant()
$riskNotes = @((Get-FactoryNestedValue -Target $reviewInput -Name "riskNotes" -Default @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($verdict -notin @("approved", "changes-required", "blocked")) {
    throw "Review verdict must be approved, changes-required, or blocked."
}
if (-not $summary) { throw "Review summary is required." }
if ($reviewCommit -notmatch '^[0-9a-f]{40}$') { throw "Review commit must be a full 40-character Git SHA." }

$config = Read-FactoryJson -Path ([string]$context.configPath)
$mutex = $null
try {
    $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
    $state = Read-FactoryJson -Path ([string]$context.statePath)
    $task = Get-FactoryTask -State $state -TaskId $TaskId
    if ([string]$task.status -notin @("awaiting-review", "held")) {
        throw "Task '$TaskId' is '$($task.status)', not available for review."
    }
    if (-not [string]$task.commit -or [string]$task.commit -ne $reviewCommit) {
        throw "Review commit '$reviewCommit' does not match task commit '$($task.commit)'."
    }
    if ($null -eq $task.workerResult -or [string]$task.workerResult.commit -ne $reviewCommit) {
        throw "Task '$TaskId' has no validated worker result for '$reviewCommit'."
    }
    if ($null -ne $task.backgroundSession -and [string]$task.backgroundSession.state -eq "working") {
        throw "Task '$TaskId' still has a working background session."
    }
    $worktree = [IO.Path]::GetFullPath([string]$task.worktree)
    if (-not (Test-ReviewPathInsideRoot -Path $worktree -Root ([string]$context.worktreeRoot))) {
        throw "Worker worktree is outside '$($context.worktreeRoot)'."
    }
    if ([string]$task.branch -notlike "factory-worker/*") {
        throw "Task '$TaskId' uses unsafe worker branch '$($task.branch)'."
    }
    if (-not (Test-Path -LiteralPath $worktree -PathType Container)) {
        throw "Worker worktree is missing: $worktree"
    }
    $head = (& git -C $worktree rev-parse HEAD 2>$null).Trim()
    $branch = (& git -C $worktree branch --show-current 2>$null).Trim()
    $dirty = @(& git -C $worktree status --porcelain 2>$null)
    if ($head -ne $reviewCommit) { throw "Worker HEAD '$head' differs from review commit '$reviewCommit'." }
    if ($branch -ne [string]$task.branch) { throw "Worker branch '$branch' differs from recorded branch '$($task.branch)'." }
    if ($dirty.Count -gt 0) { throw "Worker worktree has uncommitted changes." }

    $now = Get-FactoryUtcTimestamp
    $integrationPlan = $null
    if ($verdict -eq "approved") {
        if (-not [bool]$config.autoPushDevelopment -or -not [bool]$config.autoPromoteToProduction) {
            throw "Native approval requires autoPushDevelopment and autoPromoteToProduction to be enabled."
        }
        $remote = if ([string]$config.remote) { [string]$config.remote } else { "origin" }
        $developmentBranch = [string]$config.developmentBranch
        $productionBranch = [string]$config.productionBranch
        if (-not $developmentBranch -or -not $productionBranch) {
            throw "Development and production branches must be configured."
        }
        & git -C ([string]$context.repositoryRoot) fetch $remote $developmentBranch $productionBranch 1> $null
        if ($LASTEXITCODE -ne 0) { throw "Failed to fetch '$remote' review bases." }
        $developmentBase = (& git -C ([string]$context.repositoryRoot) rev-parse "$remote/$developmentBranch").Trim()
        $productionBase = (& git -C ([string]$context.repositoryRoot) rev-parse "$remote/$productionBranch").Trim()
        $parentLine = (& git -C $worktree rev-list --parents -n 1 $reviewCommit).Trim()
        $parentParts = @($parentLine -split '\s+' | Where-Object { $_ })
        if ($parentParts.Count -ne 2) {
            throw "Approved review requires one single-parent task commit; '$reviewCommit' has $($parentParts.Count - 1) parent(s)."
        }
        $parent = [string]$parentParts[1]
        if ($parent -ne $developmentBase) {
            throw "Task commit is based on '$parent', while '$remote/$developmentBranch' is '$developmentBase'. Run sync and review again."
        }

        $savedCommands = Get-FactoryNestedValue -Target $state -Name "resolvedCommands"
        $integrationCommands = @(Get-ReviewCommands `
            -InputValue (Get-FactoryNestedValue -Target $reviewInput -Name "integrationTestCommands" -Default @()) `
            -ConfigValue (Get-FactoryNestedValue -Target $config -Name "integrationTestCommands" -Default @()) `
            -SavedValue (Get-FactoryNestedValue -Target $savedCommands -Name "integration" -Default @()))
        if ($integrationCommands.Count -eq 0) {
            throw "Approved review requires at least one integration test command."
        }
        $releaseCommands = @(Get-ReviewCommands `
            -InputValue (Get-FactoryNestedValue -Target $reviewInput -Name "releaseTestCommands" -Default @()) `
            -ConfigValue (Get-FactoryNestedValue -Target $config -Name "releaseTestCommands" -Default @()) `
            -SavedValue (Get-FactoryNestedValue -Target $savedCommands -Name "release" -Default @()))
        if ($releaseCommands.Count -eq 0) { $releaseCommands = @($integrationCommands) }

        $productionMode = [string](Get-FactoryNestedValue -Target $config -Name "productionMode" -Default "merge-develop")
        if ($productionMode -notin @("merge-develop", "task-only")) {
            throw "Unsupported productionMode '$productionMode'."
        }
        $allowsUnrelatedDevelopment = [bool]$config.allowUnrelatedDevelopCommitsToProduction
        if (($productionMode -eq "merge-develop") -ne $allowsUnrelatedDevelopment) {
            throw "productionMode '$productionMode' conflicts with allowUnrelatedDevelopCommitsToProduction=$allowsUnrelatedDevelopment. Use merge-develop/true or task-only/false."
        }
        $integrationPlan = [pscustomobject][ordered]@{
            version = 1
            taskId = $TaskId
            taskCommit = $reviewCommit
            remote = $remote
            developmentBranch = $developmentBranch
            developmentBase = $developmentBase
            productionBranch = $productionBranch
            productionBase = $productionBase
            productionMode = $productionMode
            allowUnrelatedDevelopCommitsToProduction = $allowsUnrelatedDevelopment
            integrationTestCommands = @($integrationCommands)
            releaseTestCommands = @($releaseCommands)
            autoPushDevelopment = [bool]$config.autoPushDevelopment
            autoPromoteToProduction = [bool]$config.autoPromoteToProduction
            createdAt = $now
            planHash = ""
        }
        $integrationPlan.planHash = Get-FactoryIntegrationPlanHash -Plan $integrationPlan
        Set-FactoryProperty -Target $state.resolvedCommands -Name "integration" -Value @($integrationCommands)
        Set-FactoryProperty -Target $state.resolvedCommands -Name "release" -Value @($releaseCommands)
    }

    Set-FactoryProperty -Target $task -Name "review" -Value ([pscustomobject]@{
        verdict = $verdict
        commit = $reviewCommit
        summary = $summary
        riskNotes = @($riskNotes)
        reviewedAt = $now
        integrationPlan = $integrationPlan
    })
    Set-FactoryProperty -Target $task -Name "approval" -Value $null
    Set-FactoryProperty -Target $task -Name "error" -Value $null
    Set-FactoryProperty -Target $task -Name "status" -Value "awaiting-review"
    Set-FactoryProperty -Target $task -Name "updatedAt" -Value $now
    Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
    Write-FactoryJsonAtomic -Path ([string]$context.statePath) -Value $state
    Remove-Item -LiteralPath $resolvedReviewPath -Force

    [ordered]@{
        taskId = $TaskId
        status = [string]$task.status
        verdict = $verdict
        commit = $reviewCommit
        summary = $summary
        riskNotes = @($riskNotes)
        planHash = if ($null -ne $integrationPlan) { [string]$integrationPlan.planHash } else { $null }
        integrationTestCommands = if ($null -ne $integrationPlan) { @($integrationPlan.integrationTestCommands) } else { @() }
        releaseTestCommands = if ($null -ne $integrationPlan) { @($integrationPlan.releaseTestCommands) } else { @() }
    } | ConvertTo-Json -Depth 30
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
