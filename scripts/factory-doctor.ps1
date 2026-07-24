param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = "claude"
)

$ErrorActionPreference = "Stop"
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Get-Content -LiteralPath $context.configPath -Raw | ConvertFrom-Json
$state = Get-Content -LiteralPath $context.statePath -Raw | ConvertFrom-Json
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

$manifestPath = Join-Path $context.pluginRoot ".claude-plugin\plugin.json"
$manifestOk = $false
$manifestDetail = "missing"
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
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
        $agentRows = if ($agentRowsText) { @($agentRowsText | ConvertFrom-Json) } else { @() }
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
