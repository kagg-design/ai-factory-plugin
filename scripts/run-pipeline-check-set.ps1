[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][ValidateSet("integrator", "release")][string]$Scope,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$CommandsPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository) |
    ConvertFrom-Json
$resolvedCommandsPath = [IO.Path]::GetFullPath($CommandsPath)
$sessionsRoot = [IO.Path]::GetFullPath([string]$context.sessionsPath).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedCommandsPath.StartsWith($sessionsRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Pipeline check input must be inside '$($context.sessionsPath)'."
}
if (-not (Test-Path -LiteralPath $resolvedCommandsPath -PathType Leaf)) {
    throw "Pipeline check input does not exist: $resolvedCommandsPath"
}

$input = Read-FactoryJson -Path $resolvedCommandsPath
if ([int](Get-FactoryNestedValue -Target $input -Name "version" -Default 0) -ne 1) {
    throw "Unsupported pipeline check input version."
}
$commands = @((Get-FactoryNestedValue -Target $input -Name "commands" -Default @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($commands.Count -eq 0) { throw "Pipeline check input contains no commands." }

$results = New-Object System.Collections.Generic.List[object]
$success = $true
$failure = ""
foreach ($command in $commands) {
    if ($command.Length -gt 4096 -or $command -match '[\r\n]') {
        throw "Pipeline test commands must be single-line strings no longer than 4096 characters."
    }
    $started = Get-FactoryUtcTimestamp
    $run = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "run-isolated-test-command.ps1"),
        "-Repository", [string]$context.repositoryRoot,
        "-Scope", $Scope,
        "-WorkingDirectory", $WorkingDirectory,
        "-Command", $command,
        "-SkipContextInitialization"
    )
    $summary = if ([int]$run.exitCode -eq 0) {
        "Exited successfully."
    } else {
        ([string]$run.output -replace '[\r\n\t]+', ' ').Trim()
    }
    $results.Add([pscustomobject]@{
        command = $command
        status = if ([int]$run.exitCode -eq 0) { "passed" } else { "failed" }
        summary = $summary
        startedAt = $started
        completedAt = Get-FactoryUtcTimestamp
    })
    if ([int]$run.exitCode -ne 0) {
        $success = $false
        $failure = "$Scope check failed: $command. $summary"
        break
    }
}

[ordered]@{
    scope = $Scope
    success = $success
    failure = $failure
    tests = @($results | ForEach-Object { $_ })
} | ConvertTo-Json -Depth 30
