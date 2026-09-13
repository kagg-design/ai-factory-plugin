param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = "claude",
    [string]$CodexCommand = "",
    [switch]$NoReconcile
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

# One request-local context, with the same native checks and PowerShell 5.1
# runtime as the standalone commands. Only paths are reused: every status
# request reads live data again, with optional worker reconciliation.
$context = (& (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository) | ConvertFrom-Json
if (
    -not (Test-Path -LiteralPath ([string]$context.configPath) -PathType Leaf) -or
    -not (Test-Path -LiteralPath ([string]$context.statePath) -PathType Leaf)
) {
    # Preserve `status` on a repository that has never been initialized, while
    # avoiding schema/default rewrites on every read of an existing factory.
    $context = (& (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) | ConvertFrom-Json
}
$repositoryRoot = [string]$context.repositoryRoot
$reconcileWarning = ""
if (-not $NoReconcile) {
    try {
        $null = & (Join-Path $PSScriptRoot "reconcile-worker-sessions.ps1") `
            -Repository $repositoryRoot -ClaudeCommand $ClaudeCommand -CodexCommand $CodexCommand -ProjectContext $context
    } catch {
        $reconcileWarning = "Session reconciliation failed: $($_.Exception.Message); showing saved state."
    }
}

# Keep the existing dead-scheduler detection and its guarded state update.
$null = & (Join-Path $PSScriptRoot "factory-scheduler.ps1") `
    -Action status -Repository $repositoryRoot -ClaudeCommand $ClaudeCommand -ProjectContext $context

$testLease = $null
$testLeaseError = ""
try {
    $testLease = (& (Join-Path $PSScriptRoot "test-lease.ps1") `
        -Action status -Repository $repositoryRoot -ProjectContext $context) | ConvertFrom-Json
} catch {
    $testLeaseError = $_.Exception.Message
}

[ordered]@{
    context = $context
    state = Read-FactoryJson -Path ([string]$context.statePath)
    config = Read-FactoryJson -Path ([string]$context.configPath)
    reconcileWarning = $reconcileWarning
    testLease = $testLease
    testLeaseError = $testLeaseError
} | ConvertTo-Json -Depth 100
