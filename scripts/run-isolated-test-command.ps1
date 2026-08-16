param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [ValidateSet("integrator", "release")][string]$Scope,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$Command
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path ([string]$context.configPath)
$workingFull = [IO.Path]::GetFullPath($WorkingDirectory)
$expectedWorktree = [IO.Path]::GetFullPath((Join-Path ([string]$context.worktreeRoot) "factory-$Scope"))
if (-not (Test-FactorySamePath -Left $workingFull -Right $expectedWorktree)) {
    throw "Isolated $Scope checks must run in '$expectedWorktree', not '$workingFull'."
}
if (-not (Test-Path -LiteralPath $workingFull -PathType Container)) {
    throw "$Scope worktree does not exist: $workingFull"
}

$database = Initialize-FactoryTestDatabase `
    -Config $config `
    -RepositoryRoot ([string]$context.repositoryRoot) `
    -Scope $Scope

$commandEnvironment = @{}
if ($database.enabled) {
    $settings = Get-FactoryTestDatabaseSettings -Config $config -RepositoryRoot ([string]$context.repositoryRoot)
    $commandEnvironment = Get-FactoryTestDatabaseProcessEnvironment -Settings $settings -DatabaseName ([string]$database.name)
}
$previousEnvironment = @{}
foreach ($entry in $commandEnvironment.GetEnumerator()) {
    $previousEnvironment[[string]$entry.Key] = [Environment]::GetEnvironmentVariable(
        [string]$entry.Key,
        [EnvironmentVariableTarget]::Process
    )
}

Push-Location $workingFull
try {
    foreach ($entry in $commandEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable(
            [string]$entry.Key,
            [string]$entry.Value,
            [EnvironmentVariableTarget]::Process
        )
    }
    $global:LASTEXITCODE = 0
    & ([ScriptBlock]::Create($Command))
    if ($LASTEXITCODE -ne 0) {
        throw "$Scope test command exited with code ${LASTEXITCODE}: $Command"
    }
} finally {
    Pop-Location
    foreach ($entry in $commandEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable(
            [string]$entry.Key,
            $previousEnvironment[[string]$entry.Key],
            [EnvironmentVariableTarget]::Process
        )
    }
}
