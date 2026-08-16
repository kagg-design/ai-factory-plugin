[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("status", "start", "stop", "pause", "resume", "run", "tick")]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = "claude",
    [string]$RuntimeHome = "",
    [int]$IntervalSeconds = 0
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
$schedulerScriptPath = $MyInvocation.MyCommand.Path
. (Join-Path $PSScriptRoot "factory-common.ps1")

if ($RuntimeHome) {
    $env:CLAUDE_FACTORY_HOME = [IO.Path]::GetFullPath($RuntimeHome)
}

$contextText = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize | Out-String).Trim()
if (-not $contextText) { throw "Factory project context returned no data." }
$context = $contextText | ConvertFrom-Json
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
$stdoutPath = Join-Path ([string]$context.projectData) "scheduler.stdout.log"
$stderrPath = Join-Path ([string]$context.projectData) "scheduler.stderr.log"
$safeProjectKey = ([string]$context.projectKey) -replace '[^A-Za-z0-9_.-]', '-'

function Get-SchedulerState {
    $state = Read-FactoryJson -Path ([string]$context.statePath)
    if ($null -eq $state.PSObject.Properties["scheduler"]) { return $null }
    return $state.scheduler
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
        [Nullable[bool]]$Paused = $null
    )

    $mutex = $null
    try {
        $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
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
    } finally {
        Exit-FactoryMutex -Mutex $mutex
    }
}

function Get-SchedulerStatusResult {
    $state = Read-FactoryJson -Path ([string]$context.statePath)
    $scheduler = if ($null -ne $state.PSObject.Properties["scheduler"]) { $state.scheduler } else { $null }
    $running = Test-SchedulerProcess -Scheduler $scheduler
    return [ordered]@{
        projectKey = [string]$context.projectKey
        repository = [string]$context.repositoryRoot
        enabled = [bool]$schedulerConfig.enabled
        running = $running
        status = if ($running) { "running" } else { "stopped" }
        active = [bool]$state.active
        paused = [bool]$state.paused
        pid = if ($running) { [int]$scheduler.pid } else { $null }
        intervalSeconds = if ($running -and [int](Get-CliSafeProperty -InputObject $scheduler -Name "intervalSeconds" -Default 0) -gt 0) {
            [int]$scheduler.intervalSeconds
        } else { $IntervalSeconds }
        startedAt = Get-CliSafeProperty -InputObject $scheduler -Name "startedAt"
        heartbeatAt = Get-CliSafeProperty -InputObject $scheduler -Name "heartbeatAt"
        lastTickAt = Get-CliSafeProperty -InputObject $scheduler -Name "lastTickAt"
        lastTransitionAt = Get-CliSafeProperty -InputObject $scheduler -Name "lastTransitionAt"
        lastError = Get-CliSafeProperty -InputObject $scheduler -Name "lastError"
        failureCount = [int](Get-CliSafeProperty -InputObject $scheduler -Name "failureCount" -Default 0)
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
    }
}

function Invoke-SchedulerChildJson {
    param([string]$ScriptName, [string[]]$Arguments)

    $native = Invoke-FactoryNativeProcess -Command "powershell" -Arguments (@(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot $ScriptName)
    ) + @($Arguments))
    if ([int]$native.exitCode -ne 0) {
        $detail = ([string]$native.output -replace '[\r\n\t]+', ' ').Trim()
        throw "$ScriptName exited with code $($native.exitCode): $detail"
    }
    if (-not [string]$native.stdout) { return $null }
    return ([string]$native.stdout | ConvertFrom-Json)
}

function Invoke-SchedulerTick {
    $tickMutex = New-Object Threading.Mutex($false, "Local\ClaudeFactoryTick-$safeProjectKey")
    $ownsTick = $false
    try {
        try {
            $ownsTick = $tickMutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $ownsTick = $true
        }
        if (-not $ownsTick) {
            return [ordered]@{ skipped = $true; reason = "another tick is running"; launched = @(); errors = @() }
        }

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
            $activeWorkers = @($state.tasks | Where-Object { [string]$_.status -in @("starting", "planning", "running") }).Count
            $capacity = [int]$configNow.concurrency - $activeWorkers
            if ($capacity -le 0) { break }
            $queued = @($state.tasks | Where-Object { [string]$_.status -eq "queued" } | Sort-Object createdAt, id)
            if ($queued.Count -eq 0) { break }
            $task = $queued[0]
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
        $activeWorkers = @($state.tasks | Where-Object { [string]$_.status -in @("starting", "planning", "running") }).Count
        $queuedCount = @($state.tasks | Where-Object { [string]$_.status -eq "queued" }).Count
        $approvedCount = @($state.tasks | Where-Object { [string]$_.status -in @("approved", "integrating", "production") }).Count
        $runnableCount = $activeWorkers + $queuedCount + $approvedCount
        if ($runnableCount -eq 0 -and [bool]$state.active) {
            Update-SchedulerState -Active $false
        }
        $now = Get-FactoryUtcTimestamp
        $schedulerValues = @{
            mode = "native"
            lastTickAt = $now
        }
        if ($launched.Count -gt 0 -or $integrated.Count -gt 0 -or [int](Get-CliSafeProperty -InputObject $reconcile -Name "changed" -Default 0) -gt 0) {
            $schedulerValues.lastTransitionAt = $now
        }
        Update-SchedulerState -Values $schedulerValues
        return [ordered]@{
            skipped = $false
            reconciledTransitions = [int](Get-CliSafeProperty -InputObject $reconcile -Name "changed" -Default 0)
            launched = $launched.ToArray()
            launchedCount = $launched.Count
            integrated = $integrated.ToArray()
            integratedCount = $integrated.Count
            activeWorkers = $activeWorkers
            queued = $queuedCount
            approvedPipelineTasks = $approvedCount
            errors = $errors.ToArray()
        }
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
        return [ordered]@{ started = $false; alreadyRunning = $true; scheduler = $current }
    }
    Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
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
            return [ordered]@{ started = $true; alreadyRunning = $false; scheduler = $status }
        }
        if ($process.HasExited) {
            $winner = Get-SchedulerStatusResult
            if ([bool]$winner.running) {
                return [ordered]@{ started = $false; alreadyRunning = $true; scheduler = $winner }
            }
            throw "Native scheduler exited during startup. Inspect scheduler state for its last error."
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Native scheduler process $($process.Id) did not publish a heartbeat within five seconds."
}

function Stop-NativeScheduler {
    param([bool]$PauseFactory)

    $current = Get-SchedulerStatusResult
    if ($PauseFactory) {
        Update-SchedulerState -Active $false -Paused $true
    }
    if (-not [bool]$current.running) {
        Update-SchedulerState -Values @{ status = "stopped"; pid = $null; processStartTimeUtc = $null }
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
        if (-not [bool]$statusResult.running -and [string](Get-CliSafeProperty -InputObject $savedScheduler -Name "status" -Default "stopped") -eq "running") {
            Update-SchedulerState -Values @{
                status = "stopped"
                pid = $null
                processStartTimeUtc = $null
                lastError = "Recorded scheduler process is no longer running."
            }
            $statusResult = Get-SchedulerStatusResult
        }
        $statusResult | ConvertTo-Json -Depth 20
    }
    "start" {
        Start-NativeScheduler | ConvertTo-Json -Depth 20
    }
    "stop" {
        Stop-NativeScheduler -PauseFactory $true | ConvertTo-Json -Depth 20
    }
    "pause" {
        Update-SchedulerState -Paused $true
        [ordered]@{ paused = $true; scheduler = Get-SchedulerStatusResult } | ConvertTo-Json -Depth 20
    }
    "resume" {
        if (-not [bool]$schedulerConfig.enabled) { throw "Native scheduler is disabled in the private project config." }
        Update-SchedulerState -Active $true -Paused $false
        $started = Start-NativeScheduler
        $tick = Invoke-SchedulerTick
        [ordered]@{ resumed = $true; start = $started; tick = $tick; scheduler = Get-SchedulerStatusResult } | ConvertTo-Json -Depth 30
    }
    "tick" {
        Invoke-SchedulerTick | ConvertTo-Json -Depth 30
    }
    "run" {
        $schedulerMutex = New-Object Threading.Mutex($false, "Local\ClaudeFactoryNativeScheduler-$safeProjectKey")
        $ownsScheduler = $false
        try {
            try {
                $ownsScheduler = $schedulerMutex.WaitOne(0)
            } catch [Threading.AbandonedMutexException] {
                $ownsScheduler = $true
            }
            if (-not $ownsScheduler) { exit 0 }
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
                failureCount = 0
            }
            $failureCount = 0
            while (-not (Test-Path -LiteralPath $stopPath)) {
                $currentConfig = Read-FactoryJson -Path ([string]$context.configPath)
                if ($null -ne $currentConfig.PSObject.Properties["nativeScheduler"] -and -not [bool]$currentConfig.nativeScheduler.enabled) {
                    break
                }
                $lastError = $null
                try {
                    $tick = Invoke-SchedulerTick
                    if (@($tick.errors).Count -gt 0) {
                        $lastError = @($tick.errors) -join "; "
                        $failureCount++
                    } else {
                        $failureCount = 0
                    }
                } catch {
                    $lastError = $_.Exception.Message
                    $failureCount++
                }
                Update-SchedulerState -Values @{
                    status = "running"
                    heartbeatAt = Get-FactoryUtcTimestamp
                    lastError = $lastError
                    failureCount = $failureCount
                }
                $delay = if ($failureCount -gt 0) {
                    [Math]::Min($maximumBackoffSeconds, $IntervalSeconds * [Math]::Pow(2, [Math]::Min(5, $failureCount)))
                } else { $IntervalSeconds }
                $remainingMilliseconds = [int]($delay * 1000)
                while ($remainingMilliseconds -gt 0 -and -not (Test-Path -LiteralPath $stopPath)) {
                    $slice = [Math]::Min(500, $remainingMilliseconds)
                    Start-Sleep -Milliseconds $slice
                    $remainingMilliseconds -= $slice
                }
            }
        } finally {
            if ($ownsScheduler) {
                Update-SchedulerState -Values @{
                    status = "stopped"
                    pid = $null
                    processStartTimeUtc = $null
                    heartbeatAt = Get-FactoryUtcTimestamp
                }
                Remove-Item -LiteralPath $stopPath -Force -ErrorAction SilentlyContinue
                try { $schedulerMutex.ReleaseMutex() } catch {}
            }
            $schedulerMutex.Dispose()
        }
    }
}
