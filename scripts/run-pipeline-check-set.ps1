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
$taskId = [string](Get-FactoryNestedValue -Target $input -Name "taskId" -Default "")
if (-not $taskId) { throw "Pipeline check input has no taskId." }
$commands = @((Get-FactoryNestedValue -Target $input -Name "commands" -Default @()) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
if ($commands.Count -eq 0) { throw "Pipeline check input contains no commands." }
$safeTaskId = ConvertTo-FactoryTaskArtifactName -TaskId $taskId
$taskEventRoot = Join-Path ([string]$context.eventsPath) $safeTaskId
New-Item -ItemType Directory -Path $taskEventRoot -Force | Out-Null

$results = New-Object System.Collections.Generic.List[object]
$success = $true
$failure = ""
$commandIndex = 0
foreach ($command in $commands) {
    $commandIndex++
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
    $cleanOutput = Remove-FactoryAnsiSequences -Value ([string]$run.output)
    $cleanOutput = $cleanOutput.Replace([string][char]0, "")
    $outputPath = Join-Path $taskEventRoot ("pipeline-{0}-{1:D2}-{2}.log" -f $Scope, $commandIndex, [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($outputPath, $cleanOutput + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $summary = if ([int]$run.exitCode -eq 0) {
        "Exited successfully."
    } else {
        (Get-FactoryBoundedTextTail -Value $cleanOutput -MaximumLength 8192).Trim()
    }
    if (-not $summary) { $summary = "Command exited with no diagnostic output." }
    $results.Add([pscustomobject]@{
        command = $command
        exitCode = [int]$run.exitCode
        status = if ([int]$run.exitCode -eq 0) { "passed" } else { "failed" }
        summary = $summary
        outputPath = $outputPath
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
