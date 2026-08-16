[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$DefinitionPath
)

$ErrorActionPreference = "Stop"
$definition = [IO.File]::ReadAllText(
    [IO.Path]::GetFullPath($DefinitionPath),
    (New-Object Text.UTF8Encoding($false))
) | ConvertFrom-Json

foreach ($property in @($definition.environment.PSObject.Properties)) {
    [Environment]::SetEnvironmentVariable([string]$property.Name, [string]$property.Value, "Process")
}

$workingDirectory = [IO.Path]::GetFullPath([string]$definition.workingDirectory)
$stdoutPath = [IO.Path]::GetFullPath([string]$definition.stdoutPath)
$stderrPath = [IO.Path]::GetFullPath([string]$definition.stderrPath)
New-Item -ItemType Directory -Path (Split-Path -Parent $stdoutPath) -Force | Out-Null

try {
    Push-Location $workingDirectory
    try {
        & ([string]$definition.command) @($definition.arguments | ForEach-Object { [string]$_ }) `
            1>> $stdoutPath 2>> $stderrPath
        exit $LASTEXITCODE
    } finally {
        Pop-Location
    }
} catch {
    [IO.File]::AppendAllText(
        $stderrPath,
        $_.Exception.Message + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )
    exit 1
}
