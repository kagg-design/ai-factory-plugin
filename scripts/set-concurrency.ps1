param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][int]$Value
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json

$mutex = $null
try {
    $mutex = Enter-FactoryMutex -ProjectKey "$($context.projectKey)-config"
    $config = Get-Content -LiteralPath $context.configPath -Raw | ConvertFrom-Json
    $maximum = if ($null -ne $config.maxConcurrency) { [int]$config.maxConcurrency } else { 20 }
    if ($Value -lt 1 -or $Value -gt $maximum) {
        throw "Concurrency must be between 1 and $maximum; received $Value."
    }

    $previous = [int]$config.concurrency
    Set-FactoryProperty -Target $config -Name "concurrency" -Value $Value
    Write-FactoryJsonAtomic -Path $context.configPath -Value $config

    [ordered]@{
        previous = $previous
        current = $Value
        maximum = $maximum
        increased = ($Value -gt $previous)
        decreased = ($Value -lt $previous)
        note = if ($Value -lt $previous) {
            "Running workers are preserved. New launches wait until active workers are below the new limit."
        } else {
            "The next factory tick may fill the newly available capacity."
        }
    } | ConvertTo-Json -Depth 10
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
