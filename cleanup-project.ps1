param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:CLAUDE_FACTORY_HOME = Join-Path $pluginRoot "runtime"
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository) | ConvertFrom-Json

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

if (Test-Path $context.worktreeRoot) {
    $items = Get-ChildItem $context.worktreeRoot -Force -ErrorAction SilentlyContinue
    if ($items.Count -eq 0 -or $Force) {
        Remove-Item $context.worktreeRoot -Recurse -Force
    }
}

if (Test-Path $context.projectData) {
    Remove-Item $context.projectData -Recurse -Force
}

if (Test-Path $context.worktreeContainer) {
    $items = Get-ChildItem $context.worktreeContainer -Force -ErrorAction SilentlyContinue
    if ($items.Count -eq 0) { Remove-Item $context.worktreeContainer -Force }
}

Write-Host "Factory runtime data removed for $($context.repositoryRoot)." -ForegroundColor Green
