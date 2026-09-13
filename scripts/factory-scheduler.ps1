[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("status", "start", "stop", "pause", "resume", "run", "tick")]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = "claude",
    [string]$RuntimeHome = "",
    [int]$IntervalSeconds = 0,
    [Parameter(DontShow = $true)]$ProjectContext = $null
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
$schedulerScriptPath = $MyInvocation.MyCommand.Path
. (Join-Path $PSScriptRoot "factory-common.ps1")

if ($RuntimeHome) {
    $env:CLAUDE_FACTORY_HOME = [IO.Path]::GetFullPath($RuntimeHome)
}

if ($null -ne $ProjectContext) {
    if ($Action -ne "status" -or -not (Test-FactorySamePath -Left ([string]$ProjectContext.repositoryRoot) -Right $Repository)) {
        throw "A supplied project context is supported only for status of the matching repository."
    }
    $context = $ProjectContext
} else {
    $contextText = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize | Out-String).Trim()
    if (-not $contextText) { throw "Factory project context returned no data." }
    $context = $contextText | ConvertFrom-Json
}
$config = Read-FactoryJson -Path ([string]$context.configPath)
$schedulerConfig = if ($null -ne $config.PSObject.Properties["nativeScheduler"]) {
    $config.nativeScheduler
} else {
    [pscustomobject]@{ enabled = $true; startWithOrchestrator = $true; intervalSeconds = 15; maximumBackoffSeconds = 300 }
}
if ($IntervalSeconds -le 0) {
    $IntervalSeconds = [int]$schedulerConfig.intervalSeconds
}
if ($IntervalSeconds -lt 2) { $IntervalSeconds = 2 }
$maximumBackoffSeconds = [int]$schedulerConfig.maximumBackoffSeconds
if ($maximumBackoffSeconds -lt $IntervalSeconds) { $maximumBackoffSeconds = $IntervalSeconds }

$stopPath = Join-Path ([string]$context.projectData) "scheduler.stop"
$wakePath = Join-Path ([string]$context.projectData) "scheduler.wake"
$stdoutPath = Join-Path ([string]$context.projectData) "scheduler.stdout.log"
$stderrPath = Join-Path ([string]$context.projectData) "scheduler.stderr.log"
$heartbeatPath = Join-Path ([string]$context.projectData) "scheduler-heartbeat.json"
$script:lastHeartbeatWriteUtc = [DateTime]::MinValue
$script:heartbeatIdentity = $null
$safeProjectKey = ([string]$context.projectKey) -replace '[^A-Za-z0-9_.-]', '-'
$schedulerMutexName = "Local\ClaudeFactoryNativeScheduler-$safeProjectKey"

function Initialize-SchedulerLogs {
    New-Item -ItemType Directory -Path ([string]$context.projectData) -Force | Out-Null
    foreach ($path in @($stdoutPath, $stderrPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            try {
                [IO.File]::WriteAllText($path, "", (New-Object Text.UTF8Encoding($false)))
            } catch [IO.IOException] {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw }
            }
        }
    }
}

function Request-SchedulerWake {
    New-Item -ItemType Directory -Path ([string]$context.projectData) -Force | Out-Null
    [IO.File]::WriteAllText($wakePath, (Get-FactoryUtcTimestamp), (New-Object Text.UTF8Encoding($false)))
}

function Write-SchedulerLog {
    param(
        [ValidateSet("stdout", "stderr")][string]$Stream,
        [string]$Event,
        [hashtable]$Values = @{}
    )

    Initialize-SchedulerLogs
    $entry = [ordered]@{ timestamp = Get-FactoryUtcTimestamp; event = $Event }
    foreach ($item in $Values.GetEnumerator()) { $entry[[string]$item.Key] = $item.Value }
    $line = $entry | ConvertTo-Json -Depth 20 -Compress
    $path = if ($Stream -eq "stderr") { $stderrPath } else { $stdoutPath }
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            [IO.File]::AppendAllText($path, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
            break
        } catch [IO.IOException] {
            if ($attempt -ge 6) { throw }
            Start-Sleep -Milliseconds (20 * $attempt)
        }
    }
}

function Get-SchedulerState {
    $state = Read-FactoryJson -Path ([string]$context.statePath)
    if ($null -eq $state.PSObject.Properties["scheduler"]) { return $null }
    return Merge-SchedulerHeartbeat -Scheduler $state.scheduler
}

function Merge-SchedulerHeartbeat {
    param($Scheduler)

    # Lifecycle state remains authoritative. Ignore telemetry from an older
    # process or activity, including a heartbeat racing with stop/start.
    if ($null -ne $Scheduler -and [IO.File]::Exists($heartbeatPath)) {
        try {
            $heartbeat = Read-FactoryJson -Path $heartbeatPath
            $matches = $true
            foreach ($name in @("pid", "processStartTimeUtc", "activity", "activitySince")) {
                if ([string](Get-CliSafeProperty $Scheduler $name) -cne [string](Get-CliSafeProperty $heartbeat $name)) { $matches = $false }
            }
            if ($matches -and [string]$heartbeat.heartbeatAt -gt [string]$Scheduler.heartbeatAt) {
                $Scheduler.heartbeatAt = $heartbeat.heartbeatAt
                if ([string]$Scheduler.activity -ne "idle") { $Scheduler.activityHeartbeatAt = $heartbeat.heartbeatAt }
            }
        } catch {
            # Telemetry is optional; the durable scheduler identity is intact.
        }
    }
    return $Scheduler
}

function Test-SchedulerProcess {
    param($Scheduler)

    if ($null -eq $Scheduler -or -not [int](Get-CliSafeProperty -InputObject $Scheduler -Name "pid" -Default 0)) {
        return $false
    }
    $pidValue = [int]$Scheduler.pid
    try {
        $process = Get-Process -Id $pidValue -ErrorAction Stop
        $expectedStart = [string](Get-CliSafeProperty -InputObject $Scheduler -Name "processStartTimeUtc" -Default "")
        if (-not $expectedStart) { return $true }
        $actual = $process.StartTime.ToUniversalTime()
        $expected = [DateTime]::Parse($expectedStart).ToUniversalTime()
        return [Math]::Abs(($actual - $expected).TotalSeconds) -lt 1
    } catch {
        return $false
    }
}

function Test-SchedulerOwnershipHeld {
    $probe = New-Object Threading.Mutex($false, $schedulerMutexName)
    $ownsProbe = $false
    try {
        try {
            $ownsProbe = $probe.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $ownsProbe = $true
        }
        if ($ownsProbe) {
            try { $probe.ReleaseMutex() } catch {}
            return $false
        }
        return $true
    } finally {
        $probe.Dispose()
    }
}

function Get-CliSafeProperty {
    param($InputObject, [string]$Name, $Default = $null)

    if ($null -eq $InputObject -or $null -eq $InputObject.PSObject.Properties[$Name]) { return $Default }
    $value = $InputObject.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

function Update-SchedulerState {
    param(
        [hashtable]$Values = @{},
        [Nullable[bool]]$Active = $null,
        [Nullable[bool]]$Paused = $null,
        [int]$TimeoutMilliseconds = 30000
    )

    $mutex = $null
    try {
        $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey) -TimeoutMilliseconds $TimeoutMilliseconds
        $state = Read-FactoryJson -Path ([string]$context.statePath)
        if ($null -eq $state.PSObject.Properties["scheduler"] -or $null -eq $state.scheduler) {
            Set-FactoryProperty -Target $state -Name "scheduler" -Value ([pscustomobject]@{})
        }
        foreach ($entry in $Values.GetEnumerator()) {
            Set-FactoryProperty -Target $state.scheduler -Name ([string]$entry.Key) -Value $entry.Value
        }
        if ($null -ne $Active) { Set-FactoryProperty -Target $state -Name "active" -Value ([bool]$Active) }
        if ($null -ne $Paused) { Set-FactoryProperty -Target $state -Name "paused" -Value ([bool]$Paused) }
        Set-FactoryProperty -Target $state -Name "updatedAt" -Value (Get-FactoryUtcTimestamp)
        Write-FactoryJsonAtomic -Path ([string]$context.statePath) -Value $state
        $script:heartbeatIdentity = $state.scheduler
    } finally {
        Exit-FactoryMutex -Mutex $mutex
    }
}

function Set-SchedulerActivity {
    param(
        [ValidateSet("idle", "reconciling", "integrating", "launching")][string]$Activity,
        [string]$TaskId = "",
        [string]$TaskTitle = "",
        [string]$Since = ""
    )

    $now = Get-FactoryUtcTimestamp
    $values = @{
        status = if ($Activity -eq "idle") { "running" } else { "busy" }
        activity = $Activity
        activityTaskId = if ($TaskId) { $TaskId } else { $null }
        activityTaskTitle = if ($TaskTitle) { $TaskTitle } else { $null }
        activitySince = if ($Activity -eq "idle") { $null } elseif ($Since) { $Since } else { $now }
        activityHeartbeatAt = if ($Activity -eq "idle") { $null } else { $now }
        heartbeatAt = $now
    }
    Update-SchedulerState -Values $values
}

function Touch-SchedulerHeartbeat {
    param([int]$TimeoutMilliseconds = 30000)

    if (([DateTime]::UtcNow - $script:lastHeartbeatWriteUtc).TotalSeconds -lt 1) { return }
    if ($null -eq $script:heartbeatIdentity) { $script:heartbeatIdentity = Get-SchedulerState }
    $values = [ordered]@{ heartbeatAt = Get-FactoryUtcTimestamp }
    foreach ($name in @("pid", "processStartTimeUtc", "activity", "activitySince")) {
        $values[$name] = Get-CliSafeProperty -InputObject $script:heartbeatIdentity -Name $name
    }
    Write-FactoryJsonAtomic -Path $heartbeatPath -Value $values
    $script:lastHeartbeatWriteUtc = [DateTime]::UtcNow
}

function Write-SchedulerLoopErrorSafe {
    param(
        [Parameter(Mandatory = $true)][string]$ErrorText,
        [Parameter(Mandatory = $true)][string]$Operation,
        [int]$FailureCount = 0
    )

    try {
        Write-SchedulerLog -Stream stderr -Event "loop-error" -Values @{
            pid = $PID
            error = $ErrorText
            failureCount = $FailureCount
            operation = $Operation
            transient = $true
        }
    } catch {
        # State-lock contention must not become fatal merely because its
        # diagnostic log is temporarily unavailable too.
        try { [Console]::Error.WriteLine("Scheduler $Operation bookkeeping failed: $ErrorText") } catch {}
    }
}

function Update-SchedulerLoopStateSafe {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [Parameter(Mandatory = $true)][string]$Operation,
        [int]$FailureCount = 0
    )

    try {
        # This timeout is intentionally short. Scheduler telemetry is
        # disposable bookkeeping; the next loop can refresh it, and waiting
        # for the general 30-second state timeout would stall queue progress.
        Update-SchedulerState -Values $Values -TimeoutMilliseconds 1000
        return $true
    } catch {
        Write-SchedulerLoopErrorSafe `
            -ErrorText "Scheduler bookkeeping '$Operation' was skipped: $($_.Exception.Message)" `
            -Operation $Operation `
            -FailureCount $FailureCount
        return $false
    }
}

function Touch-SchedulerLoopHeartbeatSafe {
    param([int]$FailureCount = 0)

    try {
        Touch-SchedulerHeartbeat -TimeoutMilliseconds 1000
        return $true
    } catch {
        Write-SchedulerLoopErrorSafe `
            -ErrorText "Scheduler bookkeeping 'heartbeat' was skipped: $($_.Exception.Message)" `
            -Operation "heartbeat" `
            -FailureCount $FailureCount
        return $false
    }
}

function Get-SchedulerStatusResult {
    $state = Read-FactoryJson -Path ([string]$context.statePath)
    $scheduler = if ($null -ne $state.PSObject.Properties["scheduler"]) { Merge-SchedulerHeartbeat -Scheduler $state.scheduler } else { $null }
    $processRunning = Test-SchedulerProcess -Scheduler $scheduler
    $ownershipHeld = Test-SchedulerOwnershipHeld
    $running = $processRunning -or $ownershipHeld
    $savedStatus = [string](Get-CliSafeProperty -InputObject $scheduler -Name "status" -Default "stopped")
    $activity = [string](Get-CliSafeProperty -InputObject $scheduler -Name "activity" -Default "idle")
    $operationalStatus = if ($running -and $activity -ne "idle") {
        "busy"
    } elseif ($running -and $savedStatus -eq "failed") {
        "failed"
    } elseif ($running) {
        "running"
    } elseif ($savedStatus -eq "failed") {
        "failed"
    } else {
        "stopped"
    }
    $runnableTaskCount = @($state.tasks | Where-Object { [string]$_.status -in @("queued", "approved") }).Count
    $actionRequired = $runnableTaskCount -gt 0 -and ([bool]$state.paused -or -not $running)
    $problem = if ($runnableTaskCount -gt 0 -and [bool]$state.paused) {
        "Factory is paused with $runnableTaskCount runnable task(s); the scheduler will not launch or publish them. Run 'factory resume'."
    } elseif ($runnableTaskCount -gt 0 -and -not $running) {
        "Scheduler is $operationalStatus with $runnableTaskCount runnable task(s); run 'factory resume' or inspect the scheduler error log."
    } else { $null }
    return [ordered]@{
        projectKey = [string]$context.projectKey
        repository = [string]$context.repositoryRoot
        enabled = [bool]$schedulerConfig.enabled
        running = $running
        status = $operationalStatus
        active = [bool]$state.active
        paused = [bool]$state.paused
        runnableTaskCount = $runnableTaskCount
        actionRequired = $actionRequired
        problem = $problem
        recommendedAction = if ($actionRequired) { "factory resume" } else { $null }
        pid = if ($running) { [int]$scheduler.pid } else { $null }
        intervalSeconds = if ($running -and [int](Get-CliSafeProperty -InputObject $scheduler -Name "intervalSeconds" -Default 0) -gt 0) {
            [int]$scheduler.intervalSeconds
        } else { $IntervalSeconds }
        startedAt = Get-CliSafeProperty -InputObject $scheduler -Name "startedAt"
        heartbeatAt = Get-CliSafeProperty -InputObject $scheduler -Name "heartbeatAt"
        lastTickAt = Get-CliSafeProperty -InputObject $scheduler -Name "lastTickAt"
        lastTransitionAt = Get-CliSafeProperty -InputObject $scheduler -Name "lastTransitionAt"
        lastError = Get-CliSafeProperty -InputObject $scheduler -Name "lastError"
        lastFailureAt = Get-CliSafeProperty -InputObject $scheduler -Name "lastFailureAt"
        failureCount = [int](Get-CliSafeProperty -InputObject $scheduler -Name "failureCount" -Default 0)
        activity = $activity
        activityTaskId = Get-CliSafeProperty -InputObject $scheduler -Name "activityTaskId"
        activityTaskTitle = Get-CliSafeProperty -InputObject $scheduler -Name "activityTaskTitle"
        activitySince = Get-CliSafeProperty -InputObject $scheduler -Name "activitySince"
        activityHeartbeatAt = Get-CliSafeProperty -InputObject $scheduler -Name "activityHeartbeatAt"
        lastExitReason = Get-CliSafeProperty -InputObject $scheduler -Name "lastExitReason"
        ownershipHeld = $ownershipHeld
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        wakePath = $wakePath
    }
}

function Invoke-SchedulerChildJson {
    param([string]$ScriptName, [string[]]$Arguments)

    if ($ScriptName -eq "integrate-task.ps1") {
        $testDelay = 0
        if ([int]::TryParse([string]$env:CLAUDE_FACTORY_TEST_SCHEDULER_BUSY_MILLISECONDS, [ref]$testDelay) -and $testDelay -gt 0) {
            $delayDeadline = [DateTime]::UtcNow.AddMilliseconds($testDelay)
            while ([DateTime]::UtcNow -lt $delayDeadline) {
                if (Test-Path -LiteralPath $stopPath) {
                    throw "Scheduler stop requested during synthetic busy delay."
                }
                Touch-SchedulerHeartbeat
                Start-Sleep -Milliseconds ([Math]::Min(250, [Math]::Max(1, [int]($delayDeadline - [DateTime]::UtcNow).TotalMilliseconds)))
            }
        }
    }
    $childRoot = Join-Path ([string]$context.projectData) "scheduler-children"
    New-Item -ItemType Directory -Path $childRoot -Force | Out-Null
    $childId = [Guid]::NewGuid().ToString("N")
    $requestPath = Join-Path $childRoot "$childId.request.json"
    $resultPath = Join-Path $childRoot "$childId.result.json"
    $stdoutPath = Join-Path $childRoot "$childId.stdout.log"
    $stderrPath = Join-Path $childRoot "$childId.stderr.log"
    Write-FactoryJsonAtomic -Path $requestPath -Value ([ordered]@{
        version = 1
        scriptPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $ScriptName))
        arguments = @($Arguments | ForEach-Object { [string]$_ })
        workingDirectory = [string]$context.repositoryRoot
        resultPath = $resultPath
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        createdAt = Get-FactoryUtcTimestamp
    })
    $childArguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "scheduler-child-runner.ps1"),
        "-RequestPath", $requestPath
    )
    $resolvedPowerShell = Get-Command powershell -ErrorAction Stop
    $powerShellExecutable = if ([string]$resolvedPowerShell.Source) { [string]$resolvedPowerShell.Source } else { [string]$resolvedPowerShell.Path }
    $childArgumentLine = (@($childArguments | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }) -join " ")

    if (-not ("ClaudeFactory.DetachedProcessLauncher" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudeFactory
{
    public static class DetachedProcessLauncher
    {
        private const uint CREATE_NO_WINDOW = 0x08000000;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(
            string lpApplicationName,
            StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            bool bInheritHandles,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            string lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static int Start(string applicationName, string arguments, string currentDirectory)
        {
            if (applicationName.IndexOf('\"') >= 0)
                throw new ArgumentException("Executable path contains an invalid quote.", "applicationName");

            var commandLine = new StringBuilder();
            commandLine.Append('\"').Append(applicationName).Append('\"');
            if (!String.IsNullOrWhiteSpace(arguments))
                commandLine.Append(' ').Append(arguments);

            var startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            PROCESS_INFORMATION process;
            if (!CreateProcess(
                applicationName,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                CREATE_NO_WINDOW,
                IntPtr.Zero,
                currentDirectory,
                ref startup,
                out process))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try { return process.dwProcessId; }
            finally
            {
                if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
                if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
            }
        }
    }
}
'@
    }
    $runnerProcessId = [ClaudeFactory.DetachedProcessLauncher]::Start(
        $powerShellExecutable,
        $childArgumentLine,
        [string]$context.repositoryRoot
    )
    try {
        while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            Start-Sleep -Milliseconds 100
            Touch-SchedulerHeartbeat
            try {
                $runnerAlive = $null -ne (Get-Process -Id $runnerProcessId -ErrorAction Stop)
            } catch {
                $runnerAlive = $false
            }
            if (-not $runnerAlive -and -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                Start-Sleep -Milliseconds 100
                if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                    throw "Scheduler child runner for '$ScriptName' exited without an atomic result file."
                }
            }
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "Scheduler child runner for '$ScriptName' exited without an atomic result file."
        }
        $result = Read-FactoryJson -Path $resultPath
        $stdout = ([string](Get-CliSafeProperty -InputObject $result -Name "stdout" -Default "")).Trim()
        $stderr = ([string](Get-CliSafeProperty -InputObject $result -Name "stderr" -Default "")).Trim()
        $childExitCode = [int](Get-CliSafeProperty -InputObject $result -Name "exitCode" -Default 1)
        if ($childExitCode -ne 0) {
            $detailParts = @($stdout, $stderr) | Where-Object { $_ } | ForEach-Object { [string]$_ }
            $detail = Remove-FactoryAnsiSequences -Value ($detailParts -join [Environment]::NewLine)
            $detail = (Get-FactoryBoundedTextTail -Value $detail -MaximumLength 8192).Trim()
            throw "$ScriptName exited with code $childExitCode`: $detail"
        }
        if (-not $stdout) { return $null }
        return ($stdout | ConvertFrom-Json)
    } finally {
        foreach ($path in @($requestPath, $resultPath, $stdoutPath, $stderrPath)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SchedulerTick {
    Initialize-SchedulerLogs
    $tickStartedAt = Get-FactoryUtcTimestamp
    $tickMutex = New-Object Threading.Mutex($false, "Local\ClaudeFactoryTick-$safeProjectKey")
    $ownsTick = $false
    try {
        try {
            $ownsTick = $tickMutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $ownsTick = $true
        }
        if (-not $ownsTick) {
            $skippedResult = [ordered]@{ skipped = $true; reason = "another tick is running"; launched = @(); errors = @() }
            Write-SchedulerLog -Stream stdout -Event "tick-skipped" -Values @{ reason = "another tick is running" }
            return $skippedResult
        }

        if ([string]$env:CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ONCE_MARKER -and (Test-Path -LiteralPath ([string]$env:CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ONCE_MARKER))) {
            Remove-Item -LiteralPath ([string]$env:CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ONCE_MARKER) -Force
            throw "Synthetic one-shot scheduler loop failure."
        }
        if ($env:CLAUDE_FACTORY_TEST_SCHEDULER_THROW_ON_TICK -eq "1") {
            throw "Synthetic scheduler loop failure."
        }
        if ($Action -eq "run") { Set-SchedulerActivity -Activity reconciling -Since $tickStartedAt }
        $reconcile = Invoke-SchedulerChildJson -ScriptName "reconcile-worker-sessions.ps1" -Arguments @(
            "-Repository", [string]$context.repositoryRoot,
            "-ClaudeCommand", $ClaudeCommand
        )
        $launched = New-Object Collections.Generic.List[object]
        $integrated = New-Object Collections.Generic.List[object]
        $errors = New-Object Collections.Generic.List[string]

        $state = Read-FactoryJson -Path ([string]$context.statePath)
        if ([bool]$state.active -and -not [bool]$state.paused) {
            $approved = @($state.tasks | Where-Object { [string]$_.status -eq "approved" } | Sort-Object createdAt, id)
            if ($approved.Count -gt 0) {
                if ($Action -eq "run") {
                    Set-SchedulerActivity `
                        -Activity integrating `
                        -TaskId ([string]$approved[0].id) `
                        -TaskTitle ([string](Get-CliSafeProperty -InputObject $approved[0] -Name "title" -Default "Untitled task"))
                }
                try {
                    $pipeline = Invoke-SchedulerChildJson -ScriptName "integrate-task.ps1" -Arguments @(
                        "-Repository", [string]$context.repositoryRoot,
                        "-TaskId", [string]$approved[0].id,
                        "-ClaudeCommand", $ClaudeCommand
                    )
                    $integrated.Add($pipeline)
                } catch {
                    $errors.Add($_.Exception.Message)
                }
            }
        }

        while ($true) {
            $state = Read-FactoryJson -Path ([string]$context.statePath)
            $configNow = Read-FactoryJson -Path ([string]$context.configPath)
            if (-not [bool]$state.active -or [bool]$state.paused) { break }
            $activeWorkers = Get-FactoryLaunchedWorkerCount -State $state
            $capacity = (Get-FactoryCodingConcurrency -Config $configNow) - $activeWorkers
            if ($capacity -le 0) { break }
            $queued = @($state.tasks | Where-Object { [string]$_.status -eq "queued" } | Sort-Object createdAt, id)
            if ($queued.Count -eq 0) { break }
            $task = $queued[0]
            if ($Action -eq "run") {
                Set-SchedulerActivity `
                    -Activity launching `
                    -TaskId ([string]$task.id) `
                    -TaskTitle ([string](Get-CliSafeProperty -InputObject $task -Name "title" -Default "Untitled task"))
            }
            try {
                $launch = Invoke-SchedulerChildJson -ScriptName "start-worker-session.ps1" -Arguments @(
                    "-Repository", [string]$context.repositoryRoot,
                    "-TaskId", [string]$task.id,
                    "-Mode", [string]$task.startMode,
                    "-ClaudeCommand", $ClaudeCommand
                )
                $launched.Add($launch)
            } catch {
                $errors.Add($_.Exception.Message)
                break
            }
        }

        $state = Read-FactoryJson -Path ([string]$context.statePath)
        $activeWorkers = Get-FactoryLaunchedWorkerCount -State $state
        $queuedCount = @($state.tasks | Where-Object { [string]$_.status -eq "queued" }).Count
        $approvedCount = @($state.tasks | Where-Object { [string]$_.status -in @("approved", "integrating", "production") }).Count
        $runnableCount = $activeWorkers + $queuedCount + $approvedCount
        if ($runnableCount -eq 0 -and [bool]$state.active) {
            Update-SchedulerState -Active $false
        }
        $now = Get-FactoryUtcTimestamp
        $tickError = if ($errors.Count -gt 0) { @($errors.ToArray()) -join "; " } else { $null }
        $savedScheduler = Get-SchedulerState
        $previousFailures = [int](Get-CliSafeProperty -InputObject $savedScheduler -Name "failureCount" -Default 0)
        $schedulerOwned = (Test-SchedulerOwnershipHeld) -or (Test-SchedulerProcess -Scheduler $savedScheduler)
        $schedulerValues = @{
            mode = "native"
            lastTickAt = $now
            heartbeatAt = $now
            activity = "idle"
            activityTaskId = $null
            activityTaskTitle = $null
            activitySince = $null
            activityHeartbeatAt = $null
            status = if ($tickError) { "failed" } elseif ($schedulerOwned) { "running" } else { "stopped" }
            lastError = $tickError
            failureCount = if ($tickError) { $previousFailures + 1 } else { 0 }
        }
        if ($tickError) { $schedulerValues.lastFailureAt = $now }
        if ($launched.Count -gt 0 -or $integrated.Count -gt 0 -or [int](Get-CliSafeProperty -InputObject $reconcile -Name "changed" -Default 0) -gt 0) {
            $schedulerValues.lastTransitionAt = $now
        }
        Update-SchedulerState -Values $schedulerValues
        $attention = $null
        $attentionConfig = Read-FactoryJson -Path ([string]$context.configPath)
        $attentionSettings = Get-CliSafeProperty -InputObject $attentionConfig -Name "orchestrator"
        if (
            [string](Get-CliSafeProperty -InputObject $attentionConfig -Name "workerAgent" -Default "claude") -eq "codex" -and
            [bool](Get-CliSafeProperty -InputObject $attentionSettings -Name "attentionBridge" -Default $true)
        ) {
            try {
                $attention = Invoke-SchedulerChildJson -ScriptName "orchestrator-attention.ps1" -Arguments @(
                    "-Repository", [string]$context.repositoryRoot,
                    "-Action", "dispatch"
                )
                if ($null -ne $attention -and [bool](Get-CliSafeProperty -InputObject $attention -Name "dispatched" -Default $false)) {
                    Write-SchedulerLog -Stream stdout -Event "orchestrator-wake" -Values @{
                        revision = [long](Get-CliSafeProperty -InputObject $attention -Name "revision" -Default 0)
                        threadId = [string](Get-CliSafeProperty -InputObject $attention -Name "threadId" -Default "")
                        turnId = [string](Get-CliSafeProperty -InputObject $attention -Name "turnId" -Default "")
                    }
                }
            } catch {
                # AI notification must never stop native reconciliation, launch, or
                # publication. The durable attention journal remains pending.
                Write-SchedulerLog -Stream stderr -Event "orchestrator-wake-error" -Values @{ error = $_.Exception.Message }
            }
        }
        $tickResult = [ordered]@{
            skipped = $false
            reconciledTransitions = [int](Get-CliSafeProperty -InputObject $reconcile -Name "changed" -Default 0)
            launched = $launched.ToArray()
            launchedCount = $launched.Count
            integrated = $integrated.ToArray()
            integratedCount = $integrated.Count
            activeWorkers = $activeWorkers
            queued = $queuedCount
            approvedPipelineTasks = $approvedCount
            attention = $attention
            errors = $errors.ToArray()
        }
        Write-SchedulerLog -Stream stdout -Event "tick" -Values @{
            startedAt = $tickStartedAt
            reconciledTransitions = [int](Get-CliSafeProperty -InputObject $reconcile -Name "changed" -Default 0)
            launchedTaskIds = @($launched.ToArray() | ForEach-Object { [string](Get-CliSafeProperty -InputObject $_ -Name "taskId" -Default "") } | Where-Object { $_ })
            integratedTaskIds = @($integrated.ToArray() | ForEach-Object { [string](Get-CliSafeProperty -InputObject $_ -Name "taskId" -Default "") } | Where-Object { $_ })
            activeWorkers = $activeWorkers
            queued = $queuedCount
            approvedPipelineTasks = $approvedCount
            errorCount = $errors.Count
        }
        if ($tickError) { Write-SchedulerLog -Stream stderr -Event "tick-error" -Values @{ error = $tickError } }
        return $tickResult
    } catch {
        $failure = $_.Exception.Message
        $savedScheduler = Get-SchedulerState
        $previousFailures = [int](Get-CliSafeProperty -InputObject $savedScheduler -Name "failureCount" -Default 0)
        Update-SchedulerState -Values @{
            status = "failed"
            heartbeatAt = Get-FactoryUtcTimestamp
            lastError = $failure
            lastFailureAt = Get-FactoryUtcTimestamp
            failureCount = $previousFailures + 1
            activity = "idle"
            activityTaskId = $null
            activityTaskTitle = $null
            activitySince = $null
            activityHeartbeatAt = $null
        }
        Write-SchedulerLog -Stream stdout -Event "tick" -Values @{
            startedAt = $tickStartedAt
            result = "failed"
            errorCount = 1
        }
        Write-SchedulerLog -Stream stderr -Event "tick-exception" -Values @{ startedAt = $tickStartedAt; error = $failure }
        throw
    } finally {
        if ($ownsTick) {
            try { $tickMutex.ReleaseMutex() } catch {}
        }
        $tickMutex.Dispose()
    }
}

function Start-NativeScheduler {
    if (-not [bool]$schedulerConfig.enabled) {
        throw "Native scheduler is disabled in the private project config."
    }
    $current = Get-SchedulerStatusResult
    if ([bool]$current.running) {
        $reason = if ([string]$current.activity -ne "idle") {
            "Scheduler is busy $([string]$current.activity) task '$([string]$current.activityTaskId)' since $([string]$current.activitySince); a second scheduler was not started."
        } else {
            "Scheduler ownership is already held; a second scheduler was not started."
        }
        $warning = if ([bool]$current.paused) {
            "Factory remains paused; the scheduler will not launch or publish tasks. Run 'factory resume'."
        } else { $null }
        return [ordered]@{ started = $false; alreadyRunning = $true; reason = $reason; warning = $warning; scheduler = $current }
    }
    Initialize-SchedulerLogs
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $wakePath -Force -ErrorAction SilentlyContinue
    $argumentLine = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $schedulerScriptPath,
        "-Action", "run",
        "-Repository", [string]$context.repositoryRoot,
        "-ClaudeCommand", $ClaudeCommand,
        "-RuntimeHome", [string]$context.runtimeHome,
        "-IntervalSeconds", [string]$IntervalSeconds
    ) | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }
    $process = Start-Process `
        -FilePath (Get-Command powershell -ErrorAction Stop).Source `
        -ArgumentList ($argumentLine -join " ") `
        -WorkingDirectory ([string]$context.repositoryRoot) `
        -WindowStyle Hidden `
        -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $status = Get-SchedulerStatusResult
        if ([bool]$status.running -and [int]$status.pid -eq $process.Id) {
            $warning = if ([bool]$status.paused) {
                "Factory remains paused; the scheduler is running but will not launch or publish tasks. Run 'factory resume'."
            } else { $null }
            return [ordered]@{ started = $true; alreadyRunning = $false; warning = $warning; scheduler = $status }
        }
        if ($process.HasExited) {
            $winner = Get-SchedulerStatusResult
            if ([bool]$winner.running) {
                $warning = if ([bool]$winner.paused) {
                    "Factory remains paused; the scheduler will not launch or publish tasks. Run 'factory resume'."
                } else { $null }
                return [ordered]@{ started = $false; alreadyRunning = $true; warning = $warning; scheduler = $winner }
            }
            throw "Native scheduler exited during startup. Inspect scheduler state for its last error."
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Native scheduler process $($process.Id) did not publish a heartbeat within five seconds."
}

function Stop-NativeScheduler {
    $current = Get-SchedulerStatusResult
    if (-not [bool]$current.running) {
        Update-SchedulerState -Values @{
            status = "stopped"; pid = $null; processStartTimeUtc = $null
            activity = "idle"; activityTaskId = $null; activityTaskTitle = $null
            activitySince = $null; activityHeartbeatAt = $null
        }
        return [ordered]@{ stopped = $false; alreadyStopped = $true; scheduler = Get-SchedulerStatusResult }
    }
    [IO.File]::WriteAllText($stopPath, (Get-FactoryUtcTimestamp), (New-Object Text.UTF8Encoding($false)))
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 100
        $status = Get-SchedulerStatusResult
        if (-not [bool]$status.running) {
            return [ordered]@{ stopped = $true; alreadyStopped = $false; scheduler = $status }
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Native scheduler process $($current.pid) did not stop within ten seconds."
}

switch ($Action) {
    "status" {
        $statusResult = Get-SchedulerStatusResult
        $savedScheduler = Get-SchedulerState
        $savedStatus = [string](Get-CliSafeProperty -InputObject $savedScheduler -Name "status" -Default "stopped")
        $savedPid = [int](Get-CliSafeProperty -InputObject $savedScheduler -Name "pid" -Default 0)
        if (-not [bool]$statusResult.running -and $savedPid -gt 0 -and $savedStatus -ne "stopped") {
            $failure = "Recorded scheduler process is no longer running; its launcher or an external process may have terminated it."
            $failureAt = Get-FactoryUtcTimestamp
            Update-SchedulerState -Values @{
                status = "failed"
                pid = $null
                processStartTimeUtc = $null
                lastError = $failure
                lastFailureAt = $failureAt
                lastTransitionAt = $failureAt
                lastExitReason = "unexpected process termination"
            }
            Write-SchedulerLog -Stream stderr -Event "process-missing" -Values @{
                previousStatus = $savedStatus
                activity = [string](Get-CliSafeProperty -InputObject $savedScheduler -Name "activity" -Default "idle")
                taskId = [string](Get-CliSafeProperty -InputObject $savedScheduler -Name "activityTaskId" -Default "")
                error = $failure
            }
            $statusResult = Get-SchedulerStatusResult
        }
        $statusResult | ConvertTo-Json -Depth 20
    }
    "start" {
        Start-NativeScheduler | ConvertTo-Json -Depth 20
    }
    "stop" {
        Stop-NativeScheduler | ConvertTo-Json -Depth 20
    }
    "pause" {
        Update-SchedulerState -Paused $true
        [ordered]@{ paused = $true; scheduler = Get-SchedulerStatusResult } | ConvertTo-Json -Depth 20
    }
    "resume" {
        if (-not [bool]$schedulerConfig.enabled) { throw "Native scheduler is disabled in the private project config." }
        Update-SchedulerState -Active $true -Paused $false
        $current = Get-SchedulerStatusResult
        if ([bool]$current.running -and [string]$current.activity -ne "idle") {
            [ordered]@{
                resumed = $false
                reason = "Scheduler is busy $([string]$current.activity) task '$([string]$current.activityTaskId)' since $([string]$current.activitySince); resume did not start or tick another scheduler."
                start = [ordered]@{ started = $false; alreadyRunning = $true; scheduler = $current }
                tick = $null
                scheduler = $current
            } | ConvertTo-Json -Depth 30
            break
        }
        $started = Start-NativeScheduler
        Request-SchedulerWake
        [ordered]@{
            resumed = $true
            start = $started
            tick = $null
            wakeRequested = $true
            scheduler = Get-SchedulerStatusResult
        } | ConvertTo-Json -Depth 30
    }
    "tick" {
        Invoke-SchedulerTick | ConvertTo-Json -Depth 30
    }
    "run" {
        $schedulerMutex = New-Object Threading.Mutex($false, $schedulerMutexName)
        $ownsScheduler = $false
        $exitReason = "stop requested"
        $fatalError = ""
        try {
            try {
                $ownsScheduler = $schedulerMutex.WaitOne(0)
            } catch [Threading.AbandonedMutexException] {
                $ownsScheduler = $true
            }
            if (-not $ownsScheduler) {
                Write-SchedulerLog -Stream stderr -Event "duplicate-run-refused" -Values @{ pid = $PID; reason = "scheduler ownership is already held" }
                exit 0
            }
            Initialize-SchedulerLogs
            $self = Get-Process -Id $PID
            $startedAt = Get-FactoryUtcTimestamp
            Update-SchedulerState -Values @{
                mode = "native"
                status = "running"
                pid = $PID
                intervalSeconds = $IntervalSeconds
                processStartTimeUtc = $self.StartTime.ToUniversalTime().ToString("o")
                startedAt = $startedAt
                heartbeatAt = $startedAt
                lastError = $null
                lastFailureAt = $null
                failureCount = 0
                activity = "idle"
                activityTaskId = $null
                activityTaskTitle = $null
                activitySince = $null
                activityHeartbeatAt = $null
                lastExitReason = $null
            }
            Write-SchedulerLog -Stream stdout -Event "process-start" -Values @{ pid = $PID; intervalSeconds = $IntervalSeconds }
            $failureCount = 0
            $pendingFailureAt = $null
            while (-not (Test-Path -LiteralPath $stopPath)) {
                Remove-Item -LiteralPath $wakePath -Force -ErrorAction SilentlyContinue
                $lastError = $null
                $failureAt = $null
                try {
                    $currentConfig = Read-FactoryJson -Path ([string]$context.configPath)
                    if ($null -ne $currentConfig.PSObject.Properties["nativeScheduler"] -and -not [bool]$currentConfig.nativeScheduler.enabled) {
                        $exitReason = "disabled in project config"
                        break
                    }
                    if (
                        [string]$env:CLAUDE_FACTORY_TEST_SCHEDULER_DAEMON_THROW_ONCE_MARKER -and
                        (Test-Path -LiteralPath ([string]$env:CLAUDE_FACTORY_TEST_SCHEDULER_DAEMON_THROW_ONCE_MARKER))
                    ) {
                        Remove-Item -LiteralPath ([string]$env:CLAUDE_FACTORY_TEST_SCHEDULER_DAEMON_THROW_ONCE_MARKER) -Force
                        throw "Synthetic one-shot scheduler daemon-loop failure."
                    }
                    $tick = Invoke-SchedulerTick
                    if (@($tick.errors).Count -gt 0) {
                        $lastError = @($tick.errors) -join "; "
                        $failureAt = Get-FactoryUtcTimestamp
                        $failureCount++
                    } else {
                        $failureCount = 0
                    }
                } catch {
                    $lastError = $_.Exception.Message
                    $failureAt = Get-FactoryUtcTimestamp
                    $failureCount++
                    Write-SchedulerLog -Stream stderr -Event "loop-error" -Values @{ pid = $PID; error = $lastError; failureCount = $failureCount }
                }
                if ($failureAt) { $pendingFailureAt = $failureAt }
                $schedulerValues = @{
                    status = if ($lastError) { "failed" } else { "running" }
                    heartbeatAt = Get-FactoryUtcTimestamp
                    lastError = $lastError
                    failureCount = $failureCount
                    activity = "idle"
                    activityTaskId = $null
                    activityTaskTitle = $null
                    activitySince = $null
                    activityHeartbeatAt = $null
                }
                if ($pendingFailureAt) { $schedulerValues.lastFailureAt = $pendingFailureAt }
                $schedulerStateRecorded = Update-SchedulerLoopStateSafe `
                    -Values $schedulerValues `
                    -Operation "loop-state" `
                    -FailureCount $failureCount
                if ($schedulerStateRecorded -and $pendingFailureAt) { $pendingFailureAt = $null }
                $delay = if ($failureCount -gt 0) {
                    [Math]::Min($maximumBackoffSeconds, $IntervalSeconds * [Math]::Pow(2, [Math]::Min(5, $failureCount)))
                } else { $IntervalSeconds }
                $remainingMilliseconds = [int]($delay * 1000)
                $heartbeatMilliseconds = 5000
                while (
                    $remainingMilliseconds -gt 0 -and
                    -not (Test-Path -LiteralPath $stopPath) -and
                    -not (Test-Path -LiteralPath $wakePath)
                ) {
                    $slice = [Math]::Min(500, $remainingMilliseconds)
                    Start-Sleep -Milliseconds $slice
                    $remainingMilliseconds -= $slice
                    $heartbeatMilliseconds -= $slice
                    if ($heartbeatMilliseconds -le 0) {
                        $null = Touch-SchedulerLoopHeartbeatSafe -FailureCount $failureCount
                        $heartbeatMilliseconds = 5000
                    }
                }
            }
        } catch {
            $fatalError = $_.Exception.Message
            $exitReason = "fatal scheduler error"
            if ($ownsScheduler) {
                try {
                    Update-SchedulerState -Values @{
                        status = "failed"
                        heartbeatAt = Get-FactoryUtcTimestamp
                        lastError = $fatalError
                        lastFailureAt = Get-FactoryUtcTimestamp
                    }
                    Write-SchedulerLog -Stream stderr -Event "process-error" -Values @{ pid = $PID; error = $fatalError }
                } catch {}
            }
            throw
        } finally {
            if ($ownsScheduler) {
                try {
                    Update-SchedulerState -Values @{
                        status = if ($fatalError) { "failed" } else { "stopped" }
                        pid = $null
                        processStartTimeUtc = $null
                        heartbeatAt = Get-FactoryUtcTimestamp
                        lastError = if ($fatalError) { $fatalError } else { $null }
                        lastFailureAt = if ($fatalError) { Get-FactoryUtcTimestamp } else { $null }
                        activity = "idle"
                        activityTaskId = $null
                        activityTaskTitle = $null
                        activitySince = $null
                        activityHeartbeatAt = $null
                        lastExitReason = $exitReason
                    }
                } catch {
                    Write-SchedulerLoopErrorSafe `
                        -ErrorText "Scheduler final-state bookkeeping was skipped: $($_.Exception.Message)" `
                        -Operation "process-exit" `
                        -FailureCount $failureCount
                }
                Write-SchedulerLog -Stream stdout -Event "process-exit" -Values @{ pid = $PID; reason = $exitReason; error = if ($fatalError) { $fatalError } else { $null } }
                Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
                try { $schedulerMutex.ReleaseMutex() } catch {}
            }
            $schedulerMutex.Dispose()
        }
    }
}
