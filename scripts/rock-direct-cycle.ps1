[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ConfigPath, [string]$Epic = '', [string]$Reason = '', [string]$Task = '', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rock-actions.ps1')
$configuration = Get-FactoryRockConfiguration -ConfigPath $ConfigPath
if ($null -eq $configuration) { throw 'Direct ROCK transport is disabled.' }
if ($Epic -and -not @($configuration.orchestrators | Where-Object { [string]$_.name -ceq $Epic -or [string]$_.epicGid -ceq $Epic }).Count) { throw 'Unknown direct ROCK selector.' }
foreach ($orchestrator in @($configuration.orchestrators)) {
    if ($Epic -and $Epic -cne [string]$orchestrator.name -and $Epic -cne [string]$orchestrator.epicGid) { continue }
    $rockId = [string]$orchestrator.epicGid
    $paths = Get-FactoryRockPaths $configuration $rockId
    if ($DryRun) { Write-Output "Direct ROCK $rockId ($($orchestrator.name)): $($paths.root)"; continue }
    if ($Reason) {
        $bucket = [Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 1800)
        $null = Add-FactoryRockEvent $configuration $rockId "external/$Reason/$Task/$bucket" @{ kind = $Reason; taskId = $Task; repository = ''; owner = $false }
    }
    # Dedicated ROCK mutex only: never hold the Factory task-ledger mutex over AI.
    $mutex = New-Object Threading.Mutex($false, "Local\ClaudeFactory-RockRunner-$rockId")
    $owns = $false
    try {
        try { $owns = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns = $true }
        if (-not $owns) { continue }
        if (Test-Path -LiteralPath $paths.events) {
            foreach ($file in @(Get-ChildItem -LiteralPath $paths.events -Filter '*.json' -File | Sort-Object LastWriteTimeUtc, Name)) {
                Invoke-FactoryRockEvent $configuration $orchestrator $file.FullName
            }
        }
    } finally { if ($owns) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
