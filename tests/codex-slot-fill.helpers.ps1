# Bound both launcher execution and stream completion. WaitForExit alone does not
# bound ReadToEnd when a detached descendant inherited the redirected pipe.
function Invoke-CodexSlotFillProcess {
    param([string]$Command, [string[]]$Arguments, [int]$TimeoutSeconds = 180)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = [string](Get-Command $Command -ErrorAction Stop).Source
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-FactoryWindowsArgument ([string]$_) }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Could not start slot-fill fixture process.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "Slot-fill launcher did not exit within the $TimeoutSeconds-second watchdog."
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) {
            throw 'SLOT_FILL_INHERITED_PIPE: launcher exited but a descendant still holds its output pipe.'
        }
        if ($process.ExitCode -ne 0) { throw "Slot-fill launcher failed ($($process.ExitCode)): $($stderr.Result) $($stdout.Result)" }
        return $stdout.Result.Trim()
    } finally { $process.Dispose() }
}

function Assert-CodexSlotFillWorkers {
    param($Tick, $State, [string[]]$TaskIds)
    if ([int]$Tick.launchedCount -ne $TaskIds.Count) {
        throw "One scheduler cycle did not fill all $($TaskIds.Count) slots: $($Tick | ConvertTo-Json -Depth 20 -Compress)"
    }
    foreach ($taskId in $TaskIds) {
        $task = Get-FactoryTask -State $State -TaskId $taskId
        if ($null -eq $task.backgroundSession -or [int]$task.backgroundSession.processId -le 0) {
            throw "Scheduler did not persist a Codex process for '$taskId'."
        }
        try { $alive = $null -ne (Get-Process -Id ([int]$task.backgroundSession.processId) -ErrorAction Stop) } catch { $alive = $false }
        if (-not $alive) { throw "Codex worker '$taskId' exited before the scheduler filled its peers." }
    }
}
