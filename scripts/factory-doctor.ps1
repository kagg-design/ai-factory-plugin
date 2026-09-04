param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = "claude",
    [string]$CodexCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "worker-launch.ps1")
. (Join-Path $PSScriptRoot "codex-runtime.ps1")
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$workerRuntime = if ([string]$config.workerAgent) { [string]$config.workerAgent } else { "claude" }
$CodexCommand = Resolve-FactoryCodexCommand -Config $config -ExplicitCommand $CodexCommand
$state = Read-FactoryJson -Path $context.statePath
$checks = New-Object System.Collections.Generic.List[object]

function Add-DoctorCheck {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail,
        [ValidateSet("required", "warning", "info")][string]$Severity = "required"
    )
    $checks.Add([pscustomobject]@{
        name = $Name
        passed = $Passed
        severity = $Severity
        detail = $Detail
    })
}

$versionText = "not selected"
$versionMatch = [regex]::Match("", '(\d+\.\d+\.\d+)')
$versionOk = $workerRuntime -eq "codex"
if ($workerRuntime -eq "claude") {
    try {
        $versionResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @("--version")
        $versionText = ([string]$versionResult.output).Trim()
        $versionMatch = [regex]::Match($versionText, '(\d+\.\d+\.\d+)')
        $versionOk = [int]$versionResult.exitCode -eq 0 -and $versionMatch.Success -and [version]$versionMatch.Groups[1].Value -ge [version]"2.1.139"
    } catch {
        $versionText = $_.Exception.Message
        $versionOk = $false
    }
}
Add-DoctorCheck -Name "claudeVersion" -Passed $versionOk -Severity $(if ($workerRuntime -eq "codex") { "info" } else { "required" }) -Detail $versionText
$requiredCmdlets = @("ConvertFrom-Json", "ConvertTo-Json")
$missingCmdlets = @(
    $requiredCmdlets | Where-Object {
        $null -eq (Get-Command $_ -ErrorAction SilentlyContinue)
    }
)
Add-DoctorCheck `
    -Name "powershellRuntime" `
    -Passed ($missingCmdlets.Count -eq 0) `
    -Detail $(if ($missingCmdlets.Count -eq 0) {
        "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion); required cmdlets available; PSModulePath=$env:PSModulePath"
    } else {
        "Missing: $($missingCmdlets -join ', '); PSModulePath=$env:PSModulePath"
    })

$workerAgentOk = $false
$workerAgentDetail = "unreadable"
try {
    $inlineWorker = Read-FactoryInlineWorkerAgent -Path (Join-Path ([string]$context.pluginRoot) "agents\worker.md")
    $workerAgentOk = [bool]$inlineWorker.prompt
    $maxTurnsDetail = if ($null -ne $inlineWorker.maxTurns) {
        "; maxTurns $($inlineWorker.maxTurns) is not enforced on that fallback"
    } else { "" }
    $workerAgentDetail = "$([Text.Encoding]::UTF8.GetByteCount([string]$inlineWorker.prompt)) prompt bytes; additive system-prompt file fallback ready$maxTurnsDetail"
} catch {
    $workerAgentDetail = $_.Exception.Message
}
Add-DoctorCheck `
    -Name "workerAgentDefinition" `
    -Passed $(if ($workerRuntime -eq "codex") { $true } else { $workerAgentOk }) `
    -Severity $(if ($workerRuntime -eq "codex") { "info" } else { "required" }) `
    -Detail $(if ($workerRuntime -eq "codex") { "Claude worker definition is not selected." } else { $workerAgentDetail })

$resolutionCache = if ($null -ne $state.PSObject.Properties["agentResolutionCache"]) { $state.agentResolutionCache } else { $null }
$currentClaudeVersion = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { "" }
$cacheVersion = if ($null -ne $resolutionCache -and $null -ne $resolutionCache.PSObject.Properties["claudeVersion"]) {
    [string]$resolutionCache.claudeVersion
} else { "" }
$cacheSameVersion = [bool]$currentClaudeVersion -and $cacheVersion -eq $currentClaudeVersion
$cachedPreference = if ($null -ne $resolutionCache -and $null -ne $resolutionCache.PSObject.Properties["preferredResolution"]) {
    [string]$resolutionCache.preferredResolution
} else { "" }
$cachedOutcomes = if ($null -ne $resolutionCache -and $null -ne $resolutionCache.PSObject.Properties["outcomes"]) {
    $resolutionCache.outcomes
} else { $null }
$pluginOutcome = if ($null -ne $cachedOutcomes -and $null -ne $cachedOutcomes.PSObject.Properties["plugin"]) { [string]$cachedOutcomes.plugin } else { "" }
$inlineOutcome = if ($null -ne $cachedOutcomes -and $null -ne $cachedOutcomes.PSObject.Properties["inlineFallback"]) { [string]$cachedOutcomes.inlineFallback } else { "" }
$systemOutcome = if ($null -ne $cachedOutcomes -and $null -ne $cachedOutcomes.PSObject.Properties["systemPrompt"]) { [string]$cachedOutcomes.systemPrompt } else { "" }
$terminalFailures = @("failed", "unsupported")
$noWorkingResolution = (
    $cacheSameVersion -and
    -not $cachedPreference -and
    $pluginOutcome -in $terminalFailures -and
    $inlineOutcome -in $terminalFailures -and
    $systemOutcome -in $terminalFailures
)
$checkedAt = if ($null -ne $resolutionCache -and $null -ne $resolutionCache.PSObject.Properties["checkedAt"]) { [string]$resolutionCache.checkedAt } else { "unknown time" }
$resolutionDetail = if ($noWorkingResolution) {
    "no working resolution for Claude $currentClaudeVersion (plugin=$pluginOutcome, inline=$inlineOutcome, system-prompt=$systemOutcome); last checked $checkedAt"
} elseif ($cacheSameVersion -and $cachedPreference -eq "inline-fallback") {
    "legacy inline-fallback cache for Claude $currentClaudeVersion will migrate to additive system-prompt on the next launch"
} elseif ($cacheSameVersion -and $cachedPreference) {
    "$cachedPreference for Claude $currentClaudeVersion, checked $checkedAt"
} elseif ($cacheVersion -and -not $cacheSameVersion) {
    "cached result is for Claude $cacheVersion; Claude $currentClaudeVersion will probe plugin -> inline -> system-prompt"
} else {
    "not probed; the next worker launch will try plugin -> inline -> additive system-prompt file"
}
Add-DoctorCheck `
    -Name "workerAgentResolution" `
    -Passed $(if ($workerRuntime -eq "codex") { $true } else { $workerAgentOk -and $versionOk -and -not $noWorkingResolution }) `
    -Severity $(if ($workerRuntime -eq "codex") { "info" } else { "required" }) `
    -Detail $(if ($workerRuntime -eq "codex") { "Claude worker resolution is inactive; selected runtime is Codex." } else { $resolutionDetail })

$codexCapabilities = if ($workerRuntime -eq "codex") {
    Get-FactoryCodexCapabilities -CodexCommand $CodexCommand
} else {
    [pscustomobject]@{ supported = $true; version = ""; detail = "not selected" }
}
Add-DoctorCheck `
    -Name "codexWorkerRuntime" `
    -Passed ([bool]$codexCapabilities.supported) `
    -Severity $(if ($workerRuntime -eq "codex") { "required" } else { "info" }) `
    -Detail $(if ($workerRuntime -eq "codex") { "$([string]$codexCapabilities.version); $([string]$codexCapabilities.detail)" } else { "not selected" })

$manifestPath = if ($workerRuntime -eq "codex") {
    Join-Path $context.pluginRoot ".codex-plugin\plugin.json"
} else {
    Join-Path $context.pluginRoot ".claude-plugin\plugin.json"
}
$manifestOk = $false
$manifestDetail = "missing"
try {
    $manifest = Read-FactoryJson -Path $manifestPath
    $expectedManifestName = if ($workerRuntime -eq "codex") { "claude-factory-plugin" } else { "factory" }
    $manifestOk = [string]$manifest.name -eq $expectedManifestName
    $manifestDetail = "$($manifest.name) v$($manifest.version)"
} catch {
    $manifestDetail = $_.Exception.Message
}
Add-DoctorCheck -Name "pluginManifest" -Passed $manifestOk -Detail $manifestDetail

Add-DoctorCheck -Name "repositoryRoot" -Passed (Test-Path -LiteralPath $context.repositoryRoot) -Detail ([string]$context.repositoryRoot)
Add-DoctorCheck -Name "runtimePath" -Passed (Test-Path -LiteralPath $context.projectData) -Detail ([string]$context.projectData)
$runtimeInsidePlugin = (
    (Test-FactorySamePath -Left ([string]$context.runtimeHome) -Right ([string]$context.pluginRoot)) -or
    (Test-FactoryPathWithin -Path ([string]$context.runtimeHome) -Parent ([string]$context.pluginRoot))
)
Add-DoctorCheck `
    -Name "runtimePlacement" `
    -Passed (-not $runtimeInsidePlugin) `
    -Severity "warning" `
    -Detail $(if ($runtimeInsidePlugin) {
        "runtime is inside the plugin checkout and ignored by Git; 'git clean -x' can erase it. Run 'factory runtime' before cleanup or migration."
    } else {
        "runtime is outside the plugin checkout: $([string]$context.runtimeHome)"
    })
Add-DoctorCheck -Name "stateJson" -Passed ($null -ne $state.tasks) -Detail "v$($state.version), $(@($state.tasks).Count) task(s)"
$codingConcurrency = Get-FactoryCodingConcurrency -Config $config
$codingConcurrencySource = Get-FactoryCodingConcurrencySource -Config $config
Add-DoctorCheck -Name "configJson" -Passed ($codingConcurrency -ge 1 -and $workerRuntime -in @("claude", "codex")) -Detail "v$($config.version), coding concurrency $codingConcurrency/$($config.maxConcurrency) via $codingConcurrencySource, fixed test lane 1, runtime=$workerRuntime"

$publicationReadiness = Get-FactoryPublicationReadiness -Config $config -State $state -RepositoryRoot ([string]$context.repositoryRoot)
$publicationDetail = if ([bool]$publicationReadiness.ready) {
    $remoteName = if ([string]$config.remote) { [string]$config.remote } else { "origin" }
    "ready for $remoteName/$($config.developmentBranch) -> $remoteName/$($config.productionBranch); $(@($publicationReadiness.integrationTestCommands).Count) integration and $(@($publicationReadiness.releaseTestCommands).Count) release check(s)"
} else {
    "not ready: $(@($publicationReadiness.blockers) -join '; '); run 'factory config edit'"
}
Add-DoctorCheck `
    -Name "publicationPipeline" `
    -Passed ([bool]$publicationReadiness.ready) `
    -Severity "warning" `
    -Detail $publicationDetail

$databaseIsolationSettings = $null
try {
    $databaseIsolationSettings = Get-FactoryTestDatabaseSettings -Config $config -RepositoryRoot ([string]$context.repositoryRoot)
    if ($null -eq $databaseIsolationSettings) {
        Add-DoctorCheck -Name "testDatabaseIsolation" -Passed $true -Severity "info" -Detail "disabled"
    } else {
        $roleCheck = Invoke-FactoryPostgresMaintenance `
            -Settings $databaseIsolationSettings `
            -Sql "SELECT CASE WHEN rolcreatedb THEN 1 ELSE 0 END FROM pg_roles WHERE rolname = current_user"
        $versionCheck = Invoke-FactoryPostgresMaintenance -Settings $databaseIsolationSettings -Sql "SHOW server_version_num"
        $canCreate = ([string]$roleCheck.stdout).Trim() -eq "1"
        $serverVersion = 0
        [void][int]::TryParse(([string]$versionCheck.stdout).Trim(), [ref]$serverVersion)
        Add-DoctorCheck `
            -Name "testDatabaseIsolation" `
            -Passed ($canCreate -and $serverVersion -ge 130000) `
            -Detail "PostgreSQL server_version_num=$serverVersion; CREATEDB=$canCreate; prefix=$($databaseIsolationSettings.databasePrefix)"
    }
} catch {
    Add-DoctorCheck -Name "testDatabaseIsolation" -Passed $false -Detail $_.Exception.Message
}

$testLeaseCheck = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "test-lease.ps1"),
    "-Action", "status", "-Repository", [string]$context.repositoryRoot
)
if ([int]$testLeaseCheck.exitCode -eq 0) {
    $testLeaseInfo = ([string]$testLeaseCheck.stdout).Trim() | ConvertFrom-Json
    $leaseHolder = Get-FactoryNestedValue -Target $testLeaseInfo -Name "holder"
    $lastReclaim = Get-FactoryNestedValue -Target $testLeaseInfo -Name "lastReclaim"
    $heartbeatUnreadable = $null -ne $leaseHolder -and -not [bool](Get-FactoryNestedValue -Target $testLeaseInfo -Name "heartbeatReadable" -Default $true)
    $heartbeatStalled = [bool](Get-FactoryNestedValue -Target $testLeaseInfo -Name "heartbeatStalled" -Default $false)
    $heartbeatMissing = (
        $null -ne $leaseHolder -and
        [bool](Get-FactoryNestedValue -Target $testLeaseInfo -Name "holderProcessAlive" -Default $false) -and
        -not [bool](Get-FactoryNestedValue -Target $testLeaseInfo -Name "heartbeatPidAlive" -Default $false)
    )
    $leaseDetail = if ($heartbeatUnreadable) {
        "$([string]$testLeaseInfo.heartbeatWarning) Run 'factory doctor' after repairing '$([string]$testLeaseInfo.path)'; heartbeat log $([string]$testLeaseInfo.heartbeatLogPath)"
    } elseif ($heartbeatStalled) {
        "heartbeat has not advanced for live holder '$([string]$leaseHolder.taskId)'/$([string]$leaseHolder.phase); log $([string]$testLeaseInfo.heartbeatLogPath)"
    } elseif ($heartbeatMissing) {
        "heartbeat process is not alive for live holder '$([string]$leaseHolder.taskId)'/$([string]$leaseHolder.phase); log $([string]$testLeaseInfo.heartbeatLogPath)"
    } elseif ([bool]$testLeaseInfo.stale) {
        "stale $([string]$leaseHolder.phase) lease for '$([string]$leaseHolder.taskId)', heartbeat $([string]$leaseHolder.heartbeatAt); run test-lease.ps1 -Action reclaim"
    } elseif ($null -ne $leaseHolder) {
        "held by '$([string]$leaseHolder.taskId)' for $([string]$leaseHolder.phase); $(@($testLeaseInfo.queue).Count) queued"
    } elseif ($null -ne $lastReclaim) {
        "free; last reclaimed '$([string]$lastReclaim.taskId)'/$([string]$lastReclaim.phase) at $([string]$lastReclaim.reclaimedAt); log $([string]$testLeaseInfo.reclaimLogPath)"
    } else {
        "free; $(@($testLeaseInfo.queue).Count) queued; TTL $([int]$testLeaseInfo.ttlSeconds)s"
    }
    $leaseHealthy = -not ([bool]$testLeaseInfo.stale -or $heartbeatUnreadable -or $heartbeatStalled -or $heartbeatMissing)
    Add-DoctorCheck -Name "testLaneLease" -Passed $leaseHealthy -Severity "warning" -Detail $leaseDetail
} else {
    Add-DoctorCheck -Name "testLaneLease" -Passed $false -Severity "warning" -Detail ([string]$testLeaseCheck.output)
}

$remote = if ([string]$config.remote) { [string]$config.remote } else { "origin" }
$remoteUrl = (& git -C $context.repositoryRoot remote get-url $remote 2>$null | Out-String).Trim()
Add-DoctorCheck -Name "gitRemote" -Passed ($LASTEXITCODE -eq 0 -and [bool]$remoteUrl) -Detail $(if ($remoteUrl) { "$remote = $remoteUrl" } else { "Missing remote '$remote'" })

foreach ($branchName in @([string]$config.developmentBranch, [string]$config.productionBranch)) {
    if (-not $branchName) { continue }
    & git -C $context.repositoryRoot rev-parse --verify "$remote/$branchName^{commit}" *> $null
    Add-DoctorCheck -Name "remoteBranch:$branchName" -Passed ($LASTEXITCODE -eq 0) -Detail "$remote/$branchName"
}

$registeredFactoryWorktrees = New-Object System.Collections.Generic.List[string]
foreach ($line in @(& git -C $context.repositoryRoot worktree list --porcelain 2>$null)) {
    if ($line -like "worktree *") {
        $path = [IO.Path]::GetFullPath($line.Substring(9))
        if ($path.StartsWith([IO.Path]::GetFullPath([string]$context.worktreeRoot), [StringComparison]::OrdinalIgnoreCase)) {
            $registeredFactoryWorktrees.Add($path)
        }
    }
}
Add-DoctorCheck -Name "worktreeRegistry" -Passed $true -Severity "info" -Detail "$($registeredFactoryWorktrees.Count) factory worktree(s)"

$blockedWorkerTasks = @(
    @($state.tasks) | Where-Object {
        $taskStatus = [string](Get-FactoryNestedValue -Target $_ -Name "status" -Default "")
        $session = Get-FactoryNestedValue -Target $_ -Name "backgroundSession"
        $sessionState = [string](Get-FactoryNestedValue -Target $session -Name "state" -Default "")
        $sessionState -eq "blocked" -and $taskStatus -in @("starting", "planning", "running", "blocked")
    }
)
$blockedWorkerDetail = if ($blockedWorkerTasks.Count -eq 0) {
    "none"
} else {
    @($blockedWorkerTasks | ForEach-Object {
        $session = Get-FactoryNestedValue -Target $_ -Name "backgroundSession"
        $blockedAt = Get-FactoryNestedValue -Target $session -Name "blockedAt"
        $parsedBlockedAt = ConvertFrom-FactoryRoundtripTimestamp -Value $blockedAt
        $age = if ([bool]$parsedBlockedAt.success) {
            [Math]::Max(0, [int]([DateTime]::UtcNow - ([DateTime]$parsedBlockedAt.value)).TotalMinutes)
        } else { 0 }
        $reason = [string](Get-FactoryNestedValue -Target $session -Name "blockedReason" -Default "reason unavailable")
        "'$([string]$_.id)' ${age}m: $reason"
    }) -join "; "
}
Add-DoctorCheck -Name "blockedWorkerSessions" -Passed ($blockedWorkerTasks.Count -eq 0) -Severity "warning" -Detail $blockedWorkerDetail

$safeProjectKey = ([string]$context.projectKey) -replace '[^A-Za-z0-9_.-]', '-'
$sessionMutex = New-Object System.Threading.Mutex($false, "Local\ClaudeFactorySession-$safeProjectKey")
$factorySessionActive = $false
try {
    try {
        $acquired = $sessionMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if ($acquired) {
        $sessionMutex.ReleaseMutex()
    } else {
        $factorySessionActive = $true
    }
} finally {
    $sessionMutex.Dispose()
}
Add-DoctorCheck -Name "factorySessionLock" -Passed $true -Severity "info" -Detail $(if ($factorySessionActive) { "active" } else { "not active" })

$agentViewOk = $workerRuntime -eq "codex"
$agentViewDetail = if ($workerRuntime -eq "codex") { "not used by the Codex runtime" } else { "unavailable" }
if ($workerRuntime -eq "claude") {
    try {
        $agentRowsResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @("agents", "--json", "--all")
        $agentRowsText = ([string]$agentRowsResult.output).Trim()
        $agentViewOk = [int]$agentRowsResult.exitCode -eq 0
        if ($agentViewOk) {
            $parsedAgentRows = if ($agentRowsText) { $agentRowsText | ConvertFrom-Json } else { @() }
            $agentRows = @($parsedAgentRows | ForEach-Object { $_ })
            $agentViewDetail = "$($agentRows.Count) known background session(s)"
        } else {
            $agentViewDetail = $agentRowsText
        }
    } catch {
        $agentViewDetail = $_.Exception.Message
    }
}
Add-DoctorCheck -Name "agentView" -Passed $agentViewOk -Severity $(if ($workerRuntime -eq "codex") { "info" } else { "required" }) -Detail $agentViewDetail

$connectorCommand = if ($workerRuntime -eq "codex") { $CodexCommand } else { $ClaudeCommand }
$mcpText = try {
    $mcpResult = Invoke-FactoryNativeProcess -Command $connectorCommand -Arguments @("mcp", "list")
    ([string]$mcpResult.output).Trim()
} catch { $_.Exception.Message }
$asanaMentioned = $mcpText -match '(?i)\basana\b'
Add-DoctorCheck `
    -Name "asanaConnector" `
    -Passed $(if ($workerRuntime -eq "codex") { $true } else { $asanaMentioned }) `
    -Severity $(if ($workerRuntime -eq "codex") { "info" } else { "warning" }) `
    -Detail $(if ($asanaMentioned) {
        "Asana appears in the selected runtime's MCP configuration."
    } elseif ($workerRuntime -eq "codex") {
        "not connected; optional for local tasks created with factory new"
    } else {
        "Asana was not found in 'claude mcp list'; confirm it inside the factory session with /mcp."
    })

$schedulerCheck = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "factory-scheduler.ps1"),
    "-Action", "status", "-Repository", [string]$context.repositoryRoot,
    "-ClaudeCommand", $ClaudeCommand, "-RuntimeHome", [string]$context.runtimeHome
)
$schedulerCommandPassed = [int]$schedulerCheck.exitCode -eq 0
$schedulerInfo = $null
$schedulerDetail = if ($schedulerCommandPassed) {
    $schedulerInfo = [string]$schedulerCheck.stdout | ConvertFrom-Json
    if ([string]$schedulerInfo.status -eq "busy") {
        "native PID $($schedulerInfo.pid), busy $($schedulerInfo.activity) task '$($schedulerInfo.activityTaskId)' since $($schedulerInfo.activitySince), heartbeat $($schedulerInfo.heartbeatAt)"
    } elseif ([string]$schedulerInfo.status -eq "failed") {
        "native scheduler failed: $($schedulerInfo.lastError); stderr $($schedulerInfo.stderrPath)"
    } elseif ([bool]$schedulerInfo.running) {
        "native PID $($schedulerInfo.pid), heartbeat $($schedulerInfo.heartbeatAt), logs $($schedulerInfo.stdoutPath) and $($schedulerInfo.stderrPath)"
    } else {
        "native scheduler stopped; last exit '$($schedulerInfo.lastExitReason)', logs $($schedulerInfo.stdoutPath) and $($schedulerInfo.stderrPath)"
    }
} else {
    ([string]$schedulerCheck.output -replace '[\r\n\t]+', ' ').Trim()
}
$schedulerPassed = $schedulerCommandPassed -and ($null -eq $schedulerInfo -or [string]$schedulerInfo.status -ne "failed")
Add-DoctorCheck -Name "scheduler" -Passed $schedulerPassed -Severity "warning" -Detail $schedulerDetail

$requiredFailures = @($checks | Where-Object { $_.severity -eq "required" -and -not $_.passed })
$warnings = @($checks | Where-Object { $_.severity -eq "warning" -and -not $_.passed })
[ordered]@{
    healthy = ($requiredFailures.Count -eq 0)
    projectKey = [string]$context.projectKey
    repository = [string]$context.repositoryRoot
    requiredFailures = $requiredFailures.Count
    warnings = $warnings.Count
    checks = @($checks | ForEach-Object { $_ })
} | ConvertTo-Json -Depth 30
