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

function Start-PipelineCheckSet {
    param(
        [ValidateSet("integrator", "release")][string]$Scope,
        [string]$Worktree,
        [object[]]$Commands
    )

    $safeTaskId = ConvertTo-FactoryTaskArtifactName -TaskId $TaskId
    $inputPath = Join-Path ([string]$context.sessionsPath) "$safeTaskId.$Scope-checks.$([Guid]::NewGuid().ToString('N')).json"
    Write-FactoryJsonAtomic -Path $inputPath -Value ([pscustomobject][ordered]@{
        version = 1
        taskId = $TaskId
        scope = $Scope
        commands = @($Commands | ForEach-Object { [string]$_ })
    })

    $resolvedPowerShell = Get-Command powershell -ErrorAction Stop
    $executable = if ([string]$resolvedPowerShell.Source) { [string]$resolvedPowerShell.Source } else { [string]$resolvedPowerShell.Path }
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "run-pipeline-check-set.ps1"),
        "-Repository", [string]$context.repositoryRoot,
        "-Scope", $Scope,
        "-WorkingDirectory", $Worktree,
        "-CommandsPath", $inputPath
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = (@($arguments | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }) -join ' ')
    $startInfo.WorkingDirectory = [string]$context.repositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = New-Object Text.UTF8Encoding($false)
    if ($null -ne $startInfo.PSObject.Properties["StandardOutputEncoding"]) { $startInfo.StandardOutputEncoding = $utf8 }
    if ($null -ne $startInfo.PSObject.Properties["StandardErrorEncoding"]) { $startInfo.StandardErrorEncoding = $utf8 }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start parallel $Scope checks." }
        return [pscustomobject]@{
            scope = $Scope
            inputPath = $inputPath
            process = $process
            stdoutTask = $process.StandardOutput.ReadToEndAsync()
            stderrTask = $process.StandardError.ReadToEndAsync()
        }
    } catch {
        $process.Dispose()
        Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Complete-PipelineCheckSet {
    param([Parameter(Mandatory = $true)]$Handle)

    $Handle.process.WaitForExit()
    $stdout = ([string]$Handle.stdoutTask.Result).Trim()
    $stderr = ([string]$Handle.stderrTask.Result).Trim()
    if ([int]$Handle.process.ExitCode -ne 0) {
        $detail = @($stdout, $stderr) | Where-Object { $_ }
        throw "Parallel $($Handle.scope) check runner failed with code $($Handle.process.ExitCode): $($detail -join ' ')"
    }
    if (-not $stdout) { throw "Parallel $($Handle.scope) check runner returned no data." }
    try {
        return $stdout | ConvertFrom-Json
    } catch {
        throw "Parallel $($Handle.scope) check runner returned invalid JSON."
    }
}

function Close-PipelineCheckSet {
    param($Handle)

    if ($null -eq $Handle) { return }
    try {
        if (-not $Handle.process.HasExited) {
            $Handle.process.Kill()
            $Handle.process.WaitForExit()
        }
    } catch {
        # Best-effort child cleanup; the original pipeline error remains authoritative.
    } finally {
        $Handle.process.Dispose()
        Remove-Item -LiteralPath ([string]$Handle.inputPath) -Force -ErrorAction SilentlyContinue
    }
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
    $productionSource = if ([string]$plan.productionMode -eq "task-only") { $taskCommit } else { $integrationMerge }

    $currentStage = "production"
    $release = Reset-PipelineWorktree -RepositoryRoot $repositoryRoot -WorktreeRoot ([string]$context.worktreeRoot) -Scope release -BaseCommit $remoteProduction -Config $config
    $releaseMerge = Invoke-PipelineMerge -Worktree $release -Commit $productionSource -Label "Production"

    $integrationCheckHandle = $null
    $releaseCheckHandle = $null
    try {
        $integrationCheckHandle = Start-PipelineCheckSet -Scope integrator -Worktree $integrator -Commands @($plan.integrationTestCommands)
        $releaseCheckHandle = Start-PipelineCheckSet -Scope release -Worktree $release -Commands @($plan.releaseTestCommands)
        $currentStage = "integration"
        $integrationCheckSet = Complete-PipelineCheckSet -Handle $integrationCheckHandle
        $currentStage = "production"
        $releaseCheckSet = Complete-PipelineCheckSet -Handle $releaseCheckHandle
    } finally {
        Close-PipelineCheckSet -Handle $integrationCheckHandle
        Close-PipelineCheckSet -Handle $releaseCheckHandle
    }
    $integrationTests = @($integrationCheckSet.tests)
    $releaseTests = @($releaseCheckSet.tests)
    $integrationAudit = [pscustomobject]@{
        status = "validated"
        taskCommit = $taskCommit
        baseCommit = $remoteDevelopment
        mergeCommit = $integrationMerge
        tests = @($integrationTests)
        checksParallel = $true
        validatedAt = Get-FactoryUtcTimestamp
    }
    if (-not [bool]$integrationCheckSet.success) {
        $currentStage = "integration"
        $script:LastCheckResults = @($integrationTests)
        $failureMessage = [string]$integrationCheckSet.failure
        throw $failureMessage
    }
    if (-not [bool]$releaseCheckSet.success) {
        $currentStage = "production"
        $script:LastCheckResults = @($releaseTests)
        $failureMessage = [string]$releaseCheckSet.failure
        throw $failureMessage
    }
    $productionAudit = [pscustomobject]@{
        status = "validated"
        mode = [string]$plan.productionMode
        taskCommit = $taskCommit
        baseCommit = $remoteProduction
        sourceCommit = $productionSource
        mergeCommit = $releaseMerge
        tests = @($releaseTests)
        checksParallel = $true
        validatedAt = Get-FactoryUtcTimestamp
    }

    $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $developmentBranch, $productionBranch) -Failure "Could not refresh tested branch bases"
    $developmentBeforePush = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$developmentBranch") -Failure "Cannot recheck development before push"
    $productionBeforePush = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$productionBranch") -Failure "Cannot recheck production before push"
    if ($developmentBeforePush -ne $remoteDevelopment) {
        $currentStage = "integration"
        $script:LastCheckResults = @($integrationTests)
        throw "Development moved while parallel checks were running. Run sync and review again."
    }
    if ($productionBeforePush -ne $remoteProduction) {
        $currentStage = "production"
        $script:LastCheckResults = @($releaseTests)
        throw "Production moved while parallel checks were running. Run review again."
    }

    $currentStage = "integration"
    $script:LastCheckResults = @($integrationTests)
    $null = Invoke-PipelineGit -WorkingDirectory $integrator -Arguments @("push", $remote, "HEAD:$developmentBranch") -Failure "Development push was rejected"
    $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $developmentBranch, $productionBranch) -Failure "Could not verify development push"
    $publishedDevelopment = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$developmentBranch") -Failure "Cannot resolve published development"
    $productionAfterDevelopment = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$productionBranch") -Failure "Cannot recheck production after development push"
    if ($publishedDevelopment -ne $integrationMerge -or -not (Test-PipelineAncestor -RepositoryRoot $repositoryRoot -Ancestor $taskCommit -Descendant "$remote/$developmentBranch")) {
        throw "Published development does not match the tested integration candidate."
    }
    $developmentPublished = $true
    $integrationAudit.status = "published"
    $integrationAudit.mergeCommit = $publishedDevelopment
    Set-FactoryProperty -Target $integrationAudit -Name "publishedAt" -Value (Get-FactoryUtcTimestamp)

    $currentStage = "production"
    $script:LastCheckResults = @($releaseTests)
    $productionAudit.status = "ready-to-push"
    Update-PipelineTask -Status "production" -ErrorText "" -IntegrationValue $integrationAudit -ProductionValue $productionAudit
    if ($productionAfterDevelopment -ne $remoteProduction) {
        throw "Production moved after validation and before push. Run review again."
    }
    $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $developmentBranch, $productionBranch) -Failure "Could not refresh branches before production push"
    $developmentBeforeProduction = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$developmentBranch") -Failure "Cannot recheck development before production push"
    $productionBeforeProduction = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$productionBranch") -Failure "Cannot recheck production before push"
    if ($developmentBeforeProduction -ne $integrationMerge) {
        throw "Development moved after its tested candidate was published; production was not pushed."
    }
    if ($productionBeforeProduction -ne $remoteProduction) {
        throw "Production moved after validation and before push. Run review again."
    }
    $null = Invoke-PipelineGit -WorkingDirectory $release -Arguments @("push", $remote, "HEAD:$productionBranch") -Failure "Production push was rejected"
    $null = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("fetch", $remote, $productionBranch) -Failure "Could not verify production push"
    $publishedProduction = Invoke-PipelineGit -WorkingDirectory $repositoryRoot -Arguments @("rev-parse", "$remote/$productionBranch") -Failure "Cannot resolve published production"
    if ($publishedProduction -ne $releaseMerge -or -not (Test-PipelineAncestor -RepositoryRoot $repositoryRoot -Ancestor $taskCommit -Descendant "$remote/$productionBranch")) {
        throw "Published production does not match the tested release candidate."
    }
    $productionAudit.status = "published"
    $productionAudit.mergeCommit = $publishedProduction
    Set-FactoryProperty -Target $productionAudit -Name "attempts" -Value 1
    Set-FactoryProperty -Target $productionAudit -Name "publishedAt" -Value (Get-FactoryUtcTimestamp)
    Set-FactoryProperty -Target $productionAudit -Name "summary" -Value "Approved commit was published to $remote/$developmentBranch and $remote/$productionBranch after parallel candidate checks."

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
