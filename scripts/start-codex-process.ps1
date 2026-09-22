param([Parameter(Mandatory = $true)][string]$RequestPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
$request = Read-FactoryJson $RequestPath
$process = $null
try {
    $context = (& (Join-Path $PSScriptRoot 'project-context.ps1') -Repository ([string]$request.worktree)) | ConvertFrom-Json
    if ($env:CLAUDE_FACTORY_TASK_ID) {
        $task = Get-FactoryTask -State (Read-FactoryJson $context.statePath) -TaskId $env:CLAUDE_FACTORY_TASK_ID
        $settings = Get-FactoryTestDatabaseSettings -Config (Read-FactoryJson $context.configPath) -RepositoryRoot $context.repositoryRoot
        Assert-FactoryWorkerEnvironment -Task $task -DatabaseSettings $settings
    }
    $process = Start-Process -FilePath ([string]$request.executable) `
        -ArgumentList ([string]$request.arguments) -WorkingDirectory ([string]$request.worktree) `
        -RedirectStandardInput ([string]$request.promptPath) `
        -RedirectStandardOutput ([string]$request.stdoutPath) `
        -RedirectStandardError ([string]$request.stderrPath) -WindowStyle Hidden -PassThru
    Write-FactoryJsonAtomic ([string]$request.resultPath) ([ordered]@{
        processId = $process.Id
        processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
        error = $null
    })
} catch {
    if ($null -ne $process) {
        try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch {}
    }
    Write-FactoryJsonAtomic ([string]$request.resultPath) ([ordered]@{ error = $_.Exception.Message })
    exit 1
}
