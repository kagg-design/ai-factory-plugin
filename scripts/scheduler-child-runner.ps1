[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

function Test-SchedulerChildPathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}

$request = $null
$resultPath = ""
try {
    $request = Read-FactoryJson -Path $RequestPath
    if ([int](Get-FactoryNestedValue -Target $request -Name "version" -Default 0) -ne 1) {
        throw "Unsupported scheduler child request version."
    }

    $scriptPath = [IO.Path]::GetFullPath([string](Get-FactoryNestedValue -Target $request -Name "scriptPath" -Default ""))
    $scriptsRoot = [IO.Path]::GetFullPath($PSScriptRoot)
    if (-not (Test-SchedulerChildPathInsideRoot -Path $scriptPath -Root $scriptsRoot) -or
        [IO.Path]::GetExtension($scriptPath) -ne ".ps1" -or
        -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Scheduler child script is outside the Factory scripts directory: $scriptPath"
    }

    $workingDirectory = [IO.Path]::GetFullPath([string](Get-FactoryNestedValue -Target $request -Name "workingDirectory" -Default ""))
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        throw "Scheduler child working directory does not exist: $workingDirectory"
    }

    $resultPath = [IO.Path]::GetFullPath([string](Get-FactoryNestedValue -Target $request -Name "resultPath" -Default ""))
    $stdoutPath = [IO.Path]::GetFullPath([string](Get-FactoryNestedValue -Target $request -Name "stdoutPath" -Default ""))
    $stderrPath = [IO.Path]::GetFullPath([string](Get-FactoryNestedValue -Target $request -Name "stderrPath" -Default ""))
    $requestRoot = Split-Path -Parent ([IO.Path]::GetFullPath($RequestPath))
    foreach ($path in @($resultPath, $stdoutPath, $stderrPath)) {
        if (-not (Test-SchedulerChildPathInsideRoot -Path $path -Root $requestRoot)) {
            throw "Scheduler child artifact is outside '$requestRoot': $path"
        }
    }

    foreach ($path in @($stdoutPath, $stderrPath)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    $arguments = @((Get-FactoryNestedValue -Target $request -Name "arguments" -Default @()) | ForEach-Object { [string]$_ })
    if (($arguments.Count % 2) -ne 0) {
        throw "Scheduler child arguments must be named parameter/value pairs."
    }
    $parameters = [ordered]@{}
    for ($argumentIndex = 0; $argumentIndex -lt $arguments.Count; $argumentIndex += 2) {
        $parameterToken = [string]$arguments[$argumentIndex]
        if ($parameterToken -notmatch '^-[A-Za-z][A-Za-z0-9]*$') {
            throw "Scheduler child argument '$parameterToken' is not a named parameter."
        }
        $parameterName = $parameterToken.Substring(1)
        if ($parameters.Contains($parameterName)) {
            throw "Scheduler child parameter '$parameterName' was supplied more than once."
        }
        $parameters[$parameterName] = [string]$arguments[$argumentIndex + 1]
    }
    $previousLocation = Get-Location
    $exitCode = 0
    $stderr = ""
    try {
        Set-Location -LiteralPath $workingDirectory
        # The runner itself is already the isolated direct child. Invoking the
        # Factory script here removes every redirected inheritable handle from
        # the scheduler/launcher boundary. Detached workers may outlive this
        # process without holding a pipe or exclusive log handle open.
        $outputItems = @(& $scriptPath @parameters)
        $stdout = (@($outputItems | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    } catch {
        $exitCode = 1
        $stdout = ""
        $stderr = (($_ | Out-String).Trim())
        if (-not $stderr) { $stderr = $_.Exception.Message }
    } finally {
        Set-Location -LiteralPath ([string]$previousLocation)
    }
    [IO.File]::WriteAllText($stdoutPath, $stdout, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($stderrPath, $stderr, (New-Object Text.UTF8Encoding($false)))
    Write-FactoryJsonAtomic -Path $resultPath -Value ([ordered]@{
        version = 1
        exitCode = $exitCode
        stdout = $stdout
        stderr = $stderr
        completedAt = Get-FactoryUtcTimestamp
    })
} catch {
    if ($resultPath) {
        try {
            Write-FactoryJsonAtomic -Path $resultPath -Value ([ordered]@{
                version = 1
                exitCode = 1
                stdout = ""
                stderr = $_.Exception.Message
                completedAt = Get-FactoryUtcTimestamp
            })
        } catch {}
    }
    throw
}
