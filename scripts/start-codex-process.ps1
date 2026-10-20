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

# exec has no --name option. Observe only the thread ID emitted by this newly
# launched process, then set its persisted title through the native API. This
# detached helper never starts a turn or touches any other saved conversation.
# Publish the launch result first so naming cannot hold a task launch/state lock.
$sessionName = [string](Get-FactoryNestedValue $request 'sessionName' '')
if (-not $sessionName) { return }
$nameStatusPath = [string]$request.nameStatusPath
try {
    Write-FactoryJsonAtomic $nameStatusPath @{ status = 'pending'; name = $sessionName }
    $threadId = ''
    do {
        if (Test-Path -LiteralPath ([string]$request.stdoutPath)) {
            foreach ($line in @(Get-Content -LiteralPath ([string]$request.stdoutPath) -TotalCount 20 -ErrorAction SilentlyContinue)) {
                try { $event = $line | ConvertFrom-Json } catch { continue }
                if ([string](Get-FactoryNestedValue $event 'type' '') -eq 'thread.started') {
                    $threadId = [string](Get-FactoryNestedValue $event 'thread_id' '')
                    if ($threadId) { break }
                }
            }
        }
        if ($threadId -or $process.HasExited) { break }
        Start-Sleep -Milliseconds 250
    } while ($true)
    if (-not $threadId) { throw 'Worker exited before emitting its thread ID; native title was not updated.' }
    . (Join-Path $PSScriptRoot 'codex-orchestrator.ps1')
    # The naming helper/API must not hold the task worktree as its cwd after
    # the worker exits: cleanup may remove that worktree while naming finishes.
    Set-FactoryCodexThreadName -CodexCommand ([string]$request.executable) -WorkingDirectory $PSScriptRoot `
        -ThreadId $threadId -Name $sessionName
    Write-FactoryJsonAtomic $nameStatusPath @{ status = 'named'; threadId = $threadId; name = $sessionName }
} catch {
    # A title failure is diagnostic; it must never stop an otherwise healthy
    # worker or change its result/approval state.
    Write-FactoryJsonAtomic $nameStatusPath @{ status = 'failed'; name = $sessionName; warning = $_.Exception.Message }
}
