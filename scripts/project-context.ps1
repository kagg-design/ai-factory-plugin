param(
    [string]$Repository = ".",
    [switch]$Initialize
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "factory-common.ps1")

$repoInput = (Resolve-Path $Repository).Path
$currentWorktree = (& git -C $repoInput rev-parse --show-toplevel 2>$null).Trim()
if (-not $currentWorktree) { throw "Not inside a Git repository: $repoInput" }
$currentWorktree = [IO.Path]::GetFullPath($currentWorktree)

$worktreeLines = @(& git -C $currentWorktree worktree list --porcelain 2>$null)
$mainWorktreeLine = $worktreeLines | Where-Object { $_ -like "worktree *" } | Select-Object -First 1
$repoRoot = if ($mainWorktreeLine) {
    [IO.Path]::GetFullPath($mainWorktreeLine.Substring(9))
} else {
    $currentWorktree
}

$runtimeHome = if ($env:CLAUDE_FACTORY_HOME) {
    [IO.Path]::GetFullPath($env:CLAUDE_FACTORY_HOME)
} else {
    Join-Path $pluginRoot "runtime"
}

$normalized = $repoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar).ToLowerInvariant()
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant().Substring(0, 8)
} finally {
    $sha.Dispose()
}

$repoName = Split-Path $repoRoot -Leaf
$safeRepoName = ($repoName -replace '[^A-Za-z0-9._-]', '-').Trim('-')
if (-not $safeRepoName) { $safeRepoName = "repository" }
$projectKey = "$safeRepoName-$hash"
$projectData = Join-Path (Join-Path $runtimeHome "projects") $projectKey
$configPath = Join-Path $projectData "config.json"
$statePath = Join-Path $projectData "state.json"
$sessionsPath = Join-Path $projectData "sessions"
$eventsPath = Join-Path $projectData "events"
$previewPath = Join-Path $projectData "preview.json"
$previewRoot = Join-Path $projectData "preview"
$worktreeContainer = Join-Path (Split-Path $repoRoot -Parent) ".claude-factory-worktrees"
$worktreeRoot = Join-Path $worktreeContainer $projectKey

if ($Initialize) {
    New-Item -ItemType Directory -Path $projectData -Force | Out-Null
    New-Item -ItemType Directory -Path $sessionsPath -Force | Out-Null
    New-Item -ItemType Directory -Path $eventsPath -Force | Out-Null
    New-Item -ItemType Directory -Path $worktreeRoot -Force | Out-Null

    if (-not (Test-Path -LiteralPath $configPath)) {
        Copy-Item (Join-Path $pluginRoot "config.default.json") $configPath
    } else {
        $config = Read-FactoryJson -Path $configPath
        $configDefaults = Read-FactoryJson -Path (Join-Path $pluginRoot "config.default.json")
        Add-MissingFactoryProperties -Target $config -Defaults $configDefaults
        Set-FactoryProperty -Target $config -Name "version" -Value $configDefaults.version
        Write-FactoryJsonAtomic -Path $configPath -Value $config
    }

    if (-not (Test-Path -LiteralPath $statePath)) {
        Copy-Item (Join-Path $pluginRoot "resources\state.template.json") $statePath
    } else {
        $state = Read-FactoryJson -Path $statePath
        $stateDefaults = Read-FactoryJson -Path (Join-Path $pluginRoot "resources\state.template.json")
        Add-MissingFactoryProperties -Target $state -Defaults $stateDefaults
        Set-FactoryProperty -Target $state -Name "version" -Value $stateDefaults.version

        foreach ($task in @($state.tasks)) {
            foreach ($property in @{
                source = $null
                startMode = "auto"
                backgroundSession = $null
                rejectionReason = $null
                rejectedAt = $null
                plan = $null
                review = $null
                approval = $null
                integration = $null
                production = $null
                cleanup = $null
                reworkRequestedAt = $null
                planRecordedAt = $null
                resultRecordedAt = $null
                pendingInstructions = $null
                holdReason = $null
                attemptPrepared = $false
                answerHash = $null
                testDatabase = $null
            }.GetEnumerator()) {
                if ($null -eq $task.PSObject.Properties[$property.Key]) {
                    $task | Add-Member -NotePropertyName $property.Key -NotePropertyValue $property.Value
                }
            }
        }
        Write-FactoryJsonAtomic -Path $statePath -Value $state
    }
}

[ordered]@{
    pluginRoot = $pluginRoot
    runtimeHome = $runtimeHome
    repositoryRoot = $repoRoot
    currentWorktree = $currentWorktree
    projectKey = $projectKey
    projectData = $projectData
    configPath = $configPath
    statePath = $statePath
    sessionsPath = $sessionsPath
    eventsPath = $eventsPath
    previewPath = $previewPath
    previewRoot = $previewRoot
    worktreeContainer = $worktreeContainer
    worktreeRoot = $worktreeRoot
    resultSchemaPath = (Join-Path $pluginRoot "resources\result.schema.json")
    planSchemaPath = (Join-Path $pluginRoot "resources\plan.schema.json")
    reviewSchemaPath = (Join-Path $pluginRoot "resources\review.schema.json")
    intakeSchemaPath = (Join-Path $pluginRoot "resources\intake.schema.json")
} | ConvertTo-Json -Depth 5
