param(
    [string]$Repository = ".",
    [switch]$Initialize
)

$ErrorActionPreference = "Stop"
$repoInput = (Resolve-Path $Repository).Path
$repoRoot = (& git -C $repoInput rev-parse --show-toplevel 2>$null).Trim()
if (-not $repoRoot) { throw "Not inside a Git repository: $repoInput" }
$repoRoot = [IO.Path]::GetFullPath($repoRoot)

$pluginRoot = Split-Path -Parent $PSScriptRoot
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
$worktreeContainer = Join-Path (Split-Path $repoRoot -Parent) ".claude-factory-worktrees"
$worktreeRoot = Join-Path $worktreeContainer $projectKey

if ($Initialize) {
    New-Item -ItemType Directory -Path $projectData -Force | Out-Null
    New-Item -ItemType Directory -Path $worktreeRoot -Force | Out-Null
    if (-not (Test-Path $configPath)) {
        Copy-Item (Join-Path $pluginRoot "config.default.json") $configPath
    }
    if (-not (Test-Path $statePath)) {
        Copy-Item (Join-Path $pluginRoot "resources\state.template.json") $statePath
    }
}

[ordered]@{
    pluginRoot = $pluginRoot
    runtimeHome = $runtimeHome
    repositoryRoot = $repoRoot
    projectKey = $projectKey
    projectData = $projectData
    configPath = $configPath
    statePath = $statePath
    worktreeContainer = $worktreeContainer
    worktreeRoot = $worktreeRoot
    resultSchemaPath = (Join-Path $pluginRoot "resources\result.schema.json")
} | ConvertTo-Json -Depth 5
