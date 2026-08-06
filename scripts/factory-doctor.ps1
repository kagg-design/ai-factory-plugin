param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = "claude"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "worker-launch.ps1")
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
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

$versionText = (& $ClaudeCommand --version 2>&1 | Out-String).Trim()
$versionMatch = [regex]::Match($versionText, '(\d+\.\d+\.\d+)')
$versionOk = $versionMatch.Success -and [version]$versionMatch.Groups[1].Value -ge [version]"2.1.139"
Add-DoctorCheck -Name "claudeVersion" -Passed $versionOk -Detail $versionText
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
Add-DoctorCheck -Name "workerAgentDefinition" -Passed $workerAgentOk -Detail $workerAgentDetail

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
Add-DoctorCheck -Name "workerAgentResolution" -Passed ($workerAgentOk -and $versionOk -and -not $noWorkingResolution) -Severity "required" -Detail $resolutionDetail

$manifestPath = Join-Path $context.pluginRoot ".claude-plugin\plugin.json"
$manifestOk = $false
$manifestDetail = "missing"
try {
    $manifest = Read-FactoryJson -Path $manifestPath
    $manifestOk = [string]$manifest.name -eq "factory"
    $manifestDetail = "$($manifest.name) v$($manifest.version)"
} catch {
    $manifestDetail = $_.Exception.Message
}
Add-DoctorCheck -Name "pluginManifest" -Passed $manifestOk -Detail $manifestDetail

Add-DoctorCheck -Name "repositoryRoot" -Passed (Test-Path -LiteralPath $context.repositoryRoot) -Detail ([string]$context.repositoryRoot)
Add-DoctorCheck -Name "runtimePath" -Passed (Test-Path -LiteralPath $context.projectData) -Detail ([string]$context.projectData)
Add-DoctorCheck -Name "stateJson" -Passed ($null -ne $state.tasks) -Detail "v$($state.version), $(@($state.tasks).Count) task(s)"
Add-DoctorCheck -Name "configJson" -Passed ([int]$config.concurrency -ge 1) -Detail "v$($config.version), concurrency $($config.concurrency)/$($config.maxConcurrency)"

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

$agentViewOk = $false
$agentViewDetail = "unavailable"
try {
    $agentRowsText = (& $ClaudeCommand agents --json --all 2>&1 | Out-String).Trim()
    $agentViewOk = $LASTEXITCODE -eq 0
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
Add-DoctorCheck -Name "agentView" -Passed $agentViewOk -Detail $agentViewDetail

$mcpText = (& $ClaudeCommand mcp list 2>&1 | Out-String).Trim()
$asanaMentioned = $mcpText -match '(?i)\basana\b'
Add-DoctorCheck -Name "asanaConnector" -Passed $asanaMentioned -Severity "warning" -Detail $(if ($asanaMentioned) { "Asana appears in Claude MCP configuration." } else { "Asana was not found in 'claude mcp list'; confirm it inside the factory session with /mcp." })

Add-DoctorCheck -Name "scheduler" -Passed $true -Severity "info" -Detail $(if ([string]$state.cronJobId) { "job $($state.cronJobId)" } else { "not scheduled" })

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
