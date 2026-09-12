param(
    [string]$PluginRoot,
    [string]$Repository,
    [string]$RuntimeHome,
    [string]$ClaudeCommand,
    [int]$Seconds = 60,
    [switch]$Busy,
    [switch]$ObserveOnly
)

$ErrorActionPreference = 'Stop'
$fixturePrefix = Join-Path ([IO.Path]::GetTempPath()) 'factory-ledger-'
if (-not ([IO.Path]::GetFullPath($RuntimeHome)).StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Scheduler measurement requires an isolated factory-ledger-* temporary runtime.'
}
$savedHome = $env:CLAUDE_FACTORY_HOME
$env:CLAUDE_FACTORY_HOME = $RuntimeHome
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
$context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $Repository -Initialize | ConvertFrom-Json
$schedulerScript = Join-Path $PluginRoot 'scripts\factory-scheduler.ps1'
$savedThreshold = $env:CLAUDE_FACTORY_LOCK_SLOW_MILLISECONDS
$savedBusy = $env:CLAUDE_FACTORY_TEST_SCHEDULER_BUSY_MILLISECONDS
$env:CLAUDE_FACTORY_LOCK_SLOW_MILLISECONDS = '1'
$lockPath = Join-Path $context.projectData 'factory-locks.jsonl'
$ownsMeasurementScheduler = $false
try {
    if ($Busy) {
        $mutex = Enter-FactoryMutex $context.projectKey
        try {
            $state = Read-FactoryJson $context.statePath
            $state.tasks[0].status = 'approved'
            $state.active = $true
            $state.paused = $false
            Write-FactoryJsonAtomic $context.statePath $state
        } finally { Exit-FactoryMutex $mutex }
        $env:CLAUDE_FACTORY_TEST_SCHEDULER_BUSY_MILLISECONDS = [string](($Seconds + 30) * 1000)
    }
    $previousTickAt = [string](Read-FactoryJson $context.statePath).scheduler.lastTickAt
    $started = & powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action start -Repository $Repository -RuntimeHome $RuntimeHome -ClaudeCommand $ClaudeCommand -IntervalSeconds 15 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $started.started) { throw 'Measurement scheduler did not start.' }
    $ownsMeasurementScheduler = $true
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 100
        $state = Read-FactoryJson $context.statePath
        $ready = if ($Busy) { [string]$state.scheduler.activity -eq 'integrating' } else { [string]$state.scheduler.lastTickAt -ne $previousTickAt }
    } while (-not $ready -and [DateTime]::UtcNow -lt $deadline)
    if (-not $ready) { throw 'Measurement scheduler did not reach the target activity.' }
    $before = [IO.File]::ReadAllText($context.statePath)
    $measurementStart = [DateTime]::UtcNow
    Start-Sleep -Seconds $Seconds
    $measurementEnd = [DateTime]::UtcNow
    $after = [IO.File]::ReadAllText($context.statePath)
    $holds = @(Get-Content -LiteralPath $lockPath | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object {
        $_.event -eq 'released' -and ([DateTime]$_.timestamp).ToUniversalTime() -ge $measurementStart -and ([DateTime]$_.timestamp).ToUniversalTime() -le $measurementEnd
    })
    $rate = [Math]::Round($holds.Count * 60 / ($measurementEnd - $measurementStart).TotalSeconds, 1)
    $bytes = @($holds | ForEach-Object { ($_ | ConvertTo-Json -Compress).Length + 2 } | Measure-Object -Sum).Sum
    $measurementName = if ($Busy) { 'ledger-lock-measurement.busy.json' } else { 'ledger-lock-measurement.idle.json' }
    Write-FactoryJsonAtomic -Path (Join-Path $context.projectData $measurementName) -Value ([ordered]@{
        startedAt = $measurementStart.ToString('o'); endedAt = $measurementEnd.ToString('o')
        busy = [bool]$Busy; holds = $holds.Count; holdsPerMinute = $rate; journalBytes = $bytes
    })
    Write-Host "Scheduler ledger measurement: busy=$Busy; holds=$($holds.Count); seconds=$Seconds; holds/min=$rate; journalBytes=$bytes"
    $holds | Group-Object caller | ForEach-Object { Write-Host "  $($_.Count) $($_.Name)" }
    if (-not $ObserveOnly) {
        if ($Busy -and $before -cne $after) { throw 'Busy heartbeats rewrote the ledger.' }
        if ($rate -gt 25) { throw "Scheduler state-lock rate is excessive: $rate/min." }
        $heartbeat = Read-FactoryJson (Join-Path $context.projectData 'scheduler-heartbeat.json')
        if (([DateTime]$heartbeat.heartbeatAt).ToUniversalTime() -lt $measurementStart) { throw 'Scheduler sidecar heartbeat did not advance.' }
    }
} finally {
    if ($ownsMeasurementScheduler) {
        $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $schedulerScript -Action stop -Repository $Repository -RuntimeHome $RuntimeHome -ClaudeCommand $ClaudeCommand
    }
    $env:CLAUDE_FACTORY_LOCK_SLOW_MILLISECONDS = $savedThreshold
    $env:CLAUDE_FACTORY_TEST_SCHEDULER_BUSY_MILLISECONDS = $savedBusy
    $env:CLAUDE_FACTORY_HOME = $savedHome
}
