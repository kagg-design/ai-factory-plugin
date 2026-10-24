[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ConfigPath, [string]$Epic = '', [string]$Reason = '', [string]$Task = '', [switch]$DryRun)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rock-actions.ps1')
$configuration = Get-FactoryRockConfiguration -ConfigPath $ConfigPath
if ($null -eq $configuration) { throw 'Direct ROCK transport is disabled.' }
if ($Epic -and -not @($configuration.orchestrators | Where-Object { [string]$_.name -ceq $Epic -or [string]$_.epicGid -ceq $Epic }).Count) { throw 'Unknown direct ROCK selector.' }
if ($DryRun) {
    foreach ($goal in @($configuration.orchestrators)) {
        if (-not $Epic -or $Epic -ceq [string]$goal.name -or $Epic -ceq [string]$goal.epicGid) { Write-Output "Direct ROCK $($goal.epicGid) ($($goal.name)): $((Get-FactoryRockPaths $configuration ([string]$goal.epicGid)).root)" }
    }
    return
}
# Drain event-produced deliveries in this bounded native job. There is no idle
# model loop or timer: stop as soon as no publication was delivered. The normal
# factory reconciliation can pick up a larger remaining batch after the cap.
for ($deliveryPass = 0; $deliveryPass -lt 5; $deliveryPass++) {
    $cycle = Invoke-FactoryRockCoordinatorCycle $configuration -Epic $Epic -Reason $Reason
    $cycle | ConvertTo-Json -Depth 8
    if ([int](Get-FactoryNestedValue (Get-FactoryNestedValue $cycle 'publication') 'published' 0) -eq 0) { break }
    $Reason = ''
}
