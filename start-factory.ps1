param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [string]$Name = "Asana Factory"
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:CLAUDE_FACTORY_HOME = Join-Path $pluginRoot "runtime"

$contextJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository -Initialize
$context = $contextJson | ConvertFrom-Json

Write-Host "Repository: $($context.repositoryRoot)" -ForegroundColor Cyan
Write-Host "Project config: $($context.configPath)" -ForegroundColor Cyan
Write-Host "Factory state: $($context.statePath)" -ForegroundColor Cyan
Write-Host "Worktrees: $($context.worktreeRoot)" -ForegroundColor Cyan
Write-Host ""

Set-Location $context.repositoryRoot
& claude --plugin-dir $pluginRoot --permission-mode auto --remote-control $Name
exit $LASTEXITCODE
