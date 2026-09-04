param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [string]$RuntimeHome = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($RuntimeHome) { $env:CLAUDE_FACTORY_HOME = [IO.Path]::GetFullPath($RuntimeHome) }
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository) | ConvertFrom-Json
$projectsRoot = [IO.Path]::GetFullPath((Join-Path ([string]$context.runtimeHome) "projects")).TrimEnd('\', '/')
$projectData = [IO.Path]::GetFullPath([string]$context.projectData).TrimEnd('\', '/')
$worktreeContainer = [IO.Path]::GetFullPath([string]$context.worktreeContainer).TrimEnd('\', '/')
$worktreeRoot = [IO.Path]::GetFullPath([string]$context.worktreeRoot).TrimEnd('\', '/')
if (-not $projectData.StartsWith($projectsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing cleanup because project runtime '$projectData' is not below '$projectsRoot'."
}
if (-not $worktreeRoot.StartsWith($worktreeContainer + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing cleanup because worktree root '$worktreeRoot' is not below '$worktreeContainer'."
}
foreach ($protectedPath in @($pluginRoot, [string]$context.repositoryRoot, [string]$context.runtimeHome, $projectsRoot, $worktreeContainer)) {
    if ($projectData.Equals([IO.Path]::GetFullPath($protectedPath).TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing cleanup because project runtime resolves to protected path '$projectData'."
    }
}
$null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-preview.ps1") -Action stop -Repository ([string]$context.repositoryRoot) -RuntimeHome ([string]$context.runtimeHome) | Out-String)
if ($LASTEXITCODE -ne 0) { throw "Failed to stop the browser preview before project cleanup." }
$null = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\factory-scheduler.ps1") -Action stop -Repository ([string]$context.repositoryRoot) -RuntimeHome ([string]$context.runtimeHome) | Out-String)
if ($LASTEXITCODE -ne 0) { throw "Failed to stop the native scheduler before project cleanup." }

$registered = @()
$current = $null
foreach ($line in (& git -C $context.repositoryRoot worktree list --porcelain)) {
    if ($line -like "worktree *") {
        $path = $line.Substring(9)
        if ($path.StartsWith($context.worktreeRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $registered += $path
        }
    }
}

if ($registered.Count -gt 0 -and -not $Force) {
    Write-Host "Factory worktrees are still registered:" -ForegroundColor Yellow
    $registered | ForEach-Object { Write-Host "  $_" }
    throw "Cleanup stopped. Finish or inspect the factory first. Use -Force only after manual review."
}

foreach ($path in $registered) {
    if (Test-Path $path) {
        $dirty = (& git -C $path status --porcelain 2>$null)
        if ($dirty -and -not $Force) { throw "Worktree contains changes: $path" }
    }
    if ($Force) {
        & git -C $context.repositoryRoot worktree remove --force $path
    } else {
        & git -C $context.repositoryRoot worktree remove $path
    }
    if ($LASTEXITCODE -ne 0) { throw "Failed to remove worktree: $path" }
}

& git -C $context.repositoryRoot worktree prune

if (Test-Path -LiteralPath $worktreeRoot) {
    $items = Get-ChildItem -LiteralPath $worktreeRoot -Force -ErrorAction SilentlyContinue
    if ($items.Count -eq 0 -or $Force) {
        Remove-Item -LiteralPath $worktreeRoot -Recurse -Force
    }
}

if (Test-Path -LiteralPath $projectData) {
    Remove-Item -LiteralPath $projectData -Recurse -Force
}

if (Test-Path -LiteralPath $worktreeContainer) {
    $items = Get-ChildItem -LiteralPath $worktreeContainer -Force -ErrorAction SilentlyContinue
    if ($items.Count -eq 0) { Remove-Item -LiteralPath $worktreeContainer -Force }
}

Write-Host "Factory runtime data removed for $($context.repositoryRoot)." -ForegroundColor Green
