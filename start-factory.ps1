[CmdletBinding()]
param(
    [string]$Repository = (Get-Location).Path,
    [string]$Name = "Claude Factory",
    [switch]$Resume,
    [switch]$Continue,
    [string]$Model = ""
)

$ErrorActionPreference = "Stop"
if ($Resume -and $Continue) {
    throw "-Resume and -Continue are mutually exclusive."
}

$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$standaloneRoot = Join-Path $pluginRoot "standalone"
$env:CLAUDE_FACTORY_HOME = Join-Path $pluginRoot "runtime"
if ($Model) {
    $env:CLAUDE_FACTORY_MODEL = $Model
}

$contextJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository -Initialize
$context = $contextJson | ConvertFrom-Json

$safeProjectKey = ([string]$context.projectKey) -replace '[^A-Za-z0-9_.-]', '-'
$sessionMutex = New-Object System.Threading.Mutex($false, "Local\ClaudeFactorySession-$safeProjectKey")
$ownsMutex = $false
try {
    try {
        $ownsMutex = $sessionMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
    if (-not $ownsMutex) {
        throw "A factory session is already running for '$($context.repositoryRoot)'."
    }

    Write-Host "Repository: $($context.repositoryRoot)" -ForegroundColor Cyan
    Write-Host "Project config: $($context.configPath)" -ForegroundColor Cyan
    Write-Host "Factory state: $($context.statePath)" -ForegroundColor Cyan
    Write-Host "Worktrees: $($context.worktreeRoot)" -ForegroundColor Cyan
    Write-Host "Agent View: claude agents" -ForegroundColor Cyan
    Write-Host "Command: /factory" -ForegroundColor Cyan
    Write-Host ""

    $claudeArguments = @(
        "--plugin-dir", $pluginRoot,
        "--add-dir", $standaloneRoot,
        "--permission-mode", "auto",
        "--remote-control", $Name
    )
    if ($Model) {
        $claudeArguments += @("--model", $Model)
    }
    if ($Resume) {
        $claudeArguments += "--resume"
    } elseif ($Continue) {
        $claudeArguments += "--continue"
    }

    Set-Location $context.repositoryRoot
    & claude @claudeArguments
    exit $LASTEXITCODE
} finally {
    if ($ownsMutex) {
        try { $sessionMutex.ReleaseMutex() } catch {}
    }
    $sessionMutex.Dispose()
}
