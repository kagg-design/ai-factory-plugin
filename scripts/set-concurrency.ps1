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
    $config = Read-FactoryJson -Path $context.configPath
    $maximum = if ($null -ne $config.maxConcurrency) { [int]$config.maxConcurrency } else { 20 }
    if ($Value -lt 1 -or $Value -gt $maximum) {
        throw "Concurrency must be between 1 and $maximum; received $Value."
    }

    $previous = Get-FactoryCodingConcurrency -Config $config
    Set-FactoryProperty -Target $config -Name "codingConcurrency" -Value $Value
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
            "The limit changed without resuming the factory. If it is paused, run 'factory resume' explicitly."
        }
    } | ConvertTo-Json -Depth 10
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
