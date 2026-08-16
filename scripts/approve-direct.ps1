param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$ClaudeCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

function Invoke-DirectJsonScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string[]]$Arguments = @()
    )

    $native = Invoke-FactoryNativeProcess -Command "powershell" -Arguments (@(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot $ScriptName)
    ) + @($Arguments))
    if ([int]$native.exitCode -ne 0) {
        $detail = ([string]$native.output).Trim()
        if (-not $detail) { $detail = "no diagnostic output" }
        throw "$ScriptName exited with code $($native.exitCode): $detail"
    }
    $output = ([string]$native.stdout).Trim()
    if (-not $output) { throw "$ScriptName returned no data." }
    try {
        return $output | ConvertFrom-Json
    } catch {
        throw "$ScriptName returned invalid JSON."
    }
}

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$state = Read-FactoryJson -Path ([string]$context.statePath)
$task = Get-FactoryTask -State $state -TaskId $TaskId
$commit = ([string]$task.commit).ToLowerInvariant()
if ($commit -notmatch '^[0-9a-f]{40}$') {
    throw "Task '$TaskId' has no validated worker commit to approve directly."
}

$safeTaskId = ConvertTo-FactoryTaskArtifactName -TaskId $TaskId
$reviewPath = Join-Path ([string]$context.sessionsPath) "$safeTaskId.direct-review.$([Guid]::NewGuid().ToString('N')).json"
Write-FactoryJsonAtomic -Path $reviewPath -Value ([pscustomobject][ordered]@{
    commit = $commit
    verdict = "approved"
    summary = "Native operator-direct approval request."
    riskNotes = @()
    integrationTestCommands = @()
    releaseTestCommands = @()
})

try {
    $review = Invoke-DirectJsonScript -ScriptName "record-review.ps1" -Arguments @(
        "-Repository", [string]$context.repositoryRoot,
        "-TaskId", $TaskId,
        "-ReviewPath", $reviewPath,
        "-Mode", "operator-direct"
    )
    $approval = Invoke-DirectJsonScript -ScriptName "task-action.ps1" -Arguments @(
        "-Repository", [string]$context.repositoryRoot,
        "-Action", "go",
        "-TaskId", $TaskId,
        "-ClaudeCommand", $ClaudeCommand
    )
    [ordered]@{
        taskId = $TaskId
        status = [string]$approval.status
        approvedCommit = [string]$approval.approvedCommit
        approvedPlanHash = [string]$approval.approvedPlanHash
        approvalMode = [string]$approval.approvalMode
        reviewMode = [string]$review.mode
        reviewSummary = [string]$review.summary
        integrationTestCommands = @($review.integrationTestCommands)
        releaseTestCommands = @($review.releaseTestCommands)
    } | ConvertTo-Json -Depth 30
} finally {
    if (Test-Path -LiteralPath $reviewPath) {
        Remove-Item -LiteralPath $reviewPath -Force
    }
}
