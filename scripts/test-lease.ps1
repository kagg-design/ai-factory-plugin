[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet("acquire", "release", "status", "reclaim", "heartbeat")][string]$Action,
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$TaskId = "",
    [ValidateSet("", "verify", "review", "integration", "release")][string]$Phase = "",
    [string]$Token = "",
    [int]$OwnerPid = 0,
    [int]$WaitTimeoutSeconds = 0,
    [int]$PollMilliseconds = 0,
    [int]$TtlSeconds = 0,
    [string]$HeartbeatLogPath = "",
    [switch]$NoHeartbeat
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path ([string]$context.configPath)
$leasePath = Join-Path ([string]$context.projectData) "test-lease.json"
$reclaimLogPath = Join-Path ([string]$context.projectData) "test-lease.reclaims.jsonl"
$defaultHeartbeatLogPath = Join-Path ([string]$context.projectData) "test-lease.heartbeat.log"
if (-not $HeartbeatLogPath) { $HeartbeatLogPath = $defaultHeartbeatLogPath }
$settings = Get-FactoryNestedValue -Target $config -Name "testLease"
$configuredTtlMinutes = [int](Get-FactoryNestedValue -Target $settings -Name "ttlMinutes" -Default 30)
$effectiveTtlSeconds = if ($TtlSeconds -gt 0) { $TtlSeconds } else { [Math]::Max(60, $configuredTtlMinutes * 60) }
$heartbeatSeconds = [Math]::Max(1, [int](Get-FactoryNestedValue -Target $settings -Name "heartbeatSeconds" -Default 15))
$configuredPollMilliseconds = [int](Get-FactoryNestedValue -Target $settings -Name "pollMilliseconds" -Default 250)
$PollMilliseconds = [Math]::Max(25, $(if ($PollMilliseconds -gt 0) { $PollMilliseconds } else { $configuredPollMilliseconds }))

function New-TestLeaseState {
    return [pscustomobject][ordered]@{
        version = 1
        holder = $null
        queue = @()
        lastReclaim = $null
        updatedAt = Get-FactoryUtcTimestamp
    }
}

function Read-TestLeaseState {
    if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) {
        return New-TestLeaseState
    }
    $lease = Read-FactoryJson -Path $leasePath
    if ($null -eq $lease.PSObject.Properties["holder"]) { Set-FactoryProperty -Target $lease -Name "holder" -Value $null }
    if ($null -eq $lease.PSObject.Properties["queue"]) { Set-FactoryProperty -Target $lease -Name "queue" -Value @() }
    if ($null -eq $lease.PSObject.Properties["lastReclaim"]) { Set-FactoryProperty -Target $lease -Name "lastReclaim" -Value $null }
    return $lease
}

function Write-TestLeaseState {
    param([Parameter(Mandatory = $true)]$Lease)
    $holder = Get-FactoryNestedValue -Target $Lease -Name "holder"
    if ($null -ne $holder) {
        foreach ($name in @("acquiredAt", "heartbeatAt")) {
            $rawTimestamp = Get-FactoryNestedValue -Target $holder -Name $name
            $parsedTimestamp = ConvertFrom-FactoryRoundtripTimestamp -Value $rawTimestamp
            if ([bool]$parsedTimestamp.success) {
                Set-FactoryProperty -Target $holder -Name $name -Value (ConvertTo-FactoryRoundtripTimestamp -Value $parsedTimestamp.value)
            }
        }
    }
    Set-FactoryProperty -Target $Lease -Name "updatedAt" -Value (Get-FactoryUtcTimestamp)
    Write-FactoryJsonAtomic -Path $leasePath -Value $Lease
}

function Get-TestLeasePriority {
    param([string]$LeasePhase)
    if ($LeasePhase -in @("integration", "release")) { return 100 }
    return 10
}

function Get-TestLeaseHeartbeatInfo {
    param($Holder)
    if ($null -eq $Holder) {
        return [pscustomobject]@{ readable = $true; ageSeconds = 0; value = $null; warning = "" }
    }
    $heartbeatAt = Get-FactoryNestedValue -Target $Holder -Name "heartbeatAt" -Default $null
    $parsed = ConvertFrom-FactoryRoundtripTimestamp -Value $heartbeatAt
    if (-not [bool]$parsed.success) {
        return [pscustomobject]@{
            readable = $false
            ageSeconds = 0
            value = $null
            warning = "Test lease heartbeat is unreadable ($($parsed.error)); treating the holder as fresh and refusing automatic reclaim."
        }
    }
    return [pscustomobject]@{
        readable = $true
        ageSeconds = [Math]::Max(0, [int]([DateTime]::UtcNow - ([DateTime]$parsed.value)).TotalSeconds)
        value = [DateTime]$parsed.value
        warning = ""
    }
}

function Test-TestLeaseProcess {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Write-TestLeaseReclaimRecord {
    param($Holder, [string]$Reason)
    $heartbeatAt = Get-FactoryNestedValue -Target $Holder -Name "heartbeatAt" -Default $null
    $record = [ordered]@{
        reclaimedAt = Get-FactoryUtcTimestamp
        taskId = [string](Get-FactoryNestedValue -Target $Holder -Name "taskId" -Default "unknown")
        phase = [string](Get-FactoryNestedValue -Target $Holder -Name "phase" -Default "unknown")
        pid = [int](Get-FactoryNestedValue -Target $Holder -Name "pid" -Default 0)
        heartbeatAt = ConvertTo-FactoryRoundtripTimestamp -Value $heartbeatAt
        reason = $Reason
    }
    $line = ($record | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine
    [IO.File]::AppendAllText($reclaimLogPath, $line, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]$record
}

function Reclaim-StaleTestLease {
    param([Parameter(Mandatory = $true)]$Lease)
    $holder = Get-FactoryNestedValue -Target $Lease -Name "holder"
    if ($null -eq $holder) { return $null }
    $ownerPid = [int](Get-FactoryNestedValue -Target $holder -Name "pid" -Default 0)
    if (Test-TestLeaseProcess -ProcessId $ownerPid) { return $null }
    $heartbeat = Get-TestLeaseHeartbeatInfo -Holder $holder
    if (-not [bool]$heartbeat.readable) { return $null }
    $heartbeatPid = [int](Get-FactoryNestedValue -Target $holder -Name "heartbeatPid" -Default 0)
    if ($heartbeatPid -gt 0 -and (Test-TestLeaseProcess -ProcessId $heartbeatPid)) { return $null }
    $ageSeconds = [int]$heartbeat.ageSeconds
    $heartbeatPidWasRecorded = $heartbeatPid -gt 0
    if ($ageSeconds -le $effectiveTtlSeconds -and (-not $heartbeatPidWasRecorded -or $ownerPid -le 0)) {
        return $null
    }
    $reason = if ($ageSeconds -gt $effectiveTtlSeconds) {
        "Test lease holder process $ownerPid is not running and its heartbeat is $ageSeconds second(s) old; TTL is $effectiveTtlSeconds second(s)."
    } else {
        "Test lease holder process $ownerPid and heartbeat process $heartbeatPid are not running; reclaiming before TTL."
    }
    $record = Write-TestLeaseReclaimRecord -Holder $holder -Reason $reason
    Set-FactoryProperty -Target $Lease -Name "holder" -Value $null
    Set-FactoryProperty -Target $Lease -Name "lastReclaim" -Value $record
    return $record
}

function Remove-AbandonedTestLeaseWaiters {
    param([Parameter(Mandatory = $true)]$Lease)
    $original = @(Get-FactoryNestedValue -Target $Lease -Name "queue" -Default @())
    $remaining = @(
        $original | Where-Object {
            $waiterPid = [int](Get-FactoryNestedValue -Target $_ -Name "waiterPid" -Default 0)
            $waiterPid -eq $PID -or (Test-TestLeaseProcess -ProcessId $waiterPid)
        }
    )
    Set-FactoryProperty -Target $Lease -Name "queue" -Value $remaining
    return [Math]::Max(0, $original.Count - $remaining.Count)
}

function Get-SortedTestLeaseQueue {
    param([Parameter(Mandatory = $true)]$Lease)
    return @(
        @(Get-FactoryNestedValue -Target $Lease -Name "queue" -Default @()) |
            Sort-Object @{ Expression = { [int]$_.priority }; Descending = $true }, requestedAt, token
    )
}

function Get-ParentProcessId {
    try {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
        if ([int]$process.ParentProcessId -gt 0) { return [int]$process.ParentProcessId }
    } catch {
        # The caller may run on a host without CIM. The acquire process remains
        # a conservative owner until it returns.
    }
    return $PID
}

function Start-TestLeaseHeartbeat {
    param([string]$LeaseToken, [int]$LeaseOwnerPid)

    $resolvedPowerShell = Get-Command powershell -ErrorAction Stop
    $executable = if ([string]$resolvedPowerShell.Source) { [string]$resolvedPowerShell.Source } else { [string]$resolvedPowerShell.Path }
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath,
        "-Action", "heartbeat", "-Repository", [string]$context.repositoryRoot,
        "-Token", $LeaseToken, "-OwnerPid", [string]$LeaseOwnerPid,
        "-TtlSeconds", [string]$effectiveTtlSeconds,
        "-HeartbeatLogPath", $HeartbeatLogPath
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = (@($arguments | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }) -join " ")
    $startInfo.WorkingDirectory = [string]$context.repositoryRoot
    # ShellExecute is intentional. Under Windows PowerShell 5.1, CreateProcess
    # with any redirected stream can inherit unrelated inheritable handles from
    # acquire's own caller. That keeps the caller's stdout pipe open until the
    # heartbeat exits and deadlocks publication. A hidden shell launch is
    # detached from those pipes.
    $startInfo.UseShellExecute = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Could not start the test-lease heartbeat." }
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        if ($process.HasExited) {
            throw "Test-lease heartbeat exited immediately with code $($process.ExitCode). See '$HeartbeatLogPath'."
        }
        return [int]$process.Id
    } finally {
        $process.Dispose()
    }
}

if ($Action -eq "heartbeat") {
    if (-not $Token -or $OwnerPid -le 0) { throw "Heartbeat requires Token and OwnerPid." }
    try {
        while (Test-TestLeaseProcess -ProcessId $OwnerPid) {
            Start-Sleep -Seconds $heartbeatSeconds
            if (-not (Test-TestLeaseProcess -ProcessId $OwnerPid)) { break }
            $mutex = $null
            try {
                $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
                $lease = Read-TestLeaseState
                $holder = Get-FactoryNestedValue -Target $lease -Name "holder"
                if ($null -eq $holder -or [string](Get-FactoryNestedValue -Target $holder -Name "token" -Default "") -ne $Token) {
                    break
                }
                Set-FactoryProperty -Target $holder -Name "heartbeatAt" -Value (Get-FactoryUtcTimestamp)
                Write-TestLeaseState -Lease $lease
            } finally {
                Exit-FactoryMutex -Mutex $mutex
            }
        }
    } catch {
        $line = "$(Get-FactoryUtcTimestamp) token=$Token ownerPid=$OwnerPid $($_.Exception.Message)" + [Environment]::NewLine
        try { [IO.File]::AppendAllText($HeartbeatLogPath, $line, (New-Object Text.UTF8Encoding($false))) } catch {}
        throw
    }
    exit 0
}

if ($Action -eq "status") {
    $statusMutex = $null
    try {
        $statusMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
        $lease = Read-TestLeaseState
        $removedWaiters = Remove-AbandonedTestLeaseWaiters -Lease $lease
        if ($removedWaiters -gt 0) { Write-TestLeaseState -Lease $lease }
    } finally {
        Exit-FactoryMutex -Mutex $statusMutex
    }
    $holder = Get-FactoryNestedValue -Target $lease -Name "holder"
    $heartbeat = Get-TestLeaseHeartbeatInfo -Holder $holder
    $ownerPid = if ($null -ne $holder) { [int](Get-FactoryNestedValue -Target $holder -Name "pid" -Default 0) } else { 0 }
    $heartbeatPid = if ($null -ne $holder) { [int](Get-FactoryNestedValue -Target $holder -Name "heartbeatPid" -Default 0) } else { 0 }
    $ownerAlive = Test-TestLeaseProcess -ProcessId $ownerPid
    $heartbeatPidAlive = Test-TestLeaseProcess -ProcessId $heartbeatPid
    $acquired = if ($null -ne $holder) {
        ConvertFrom-FactoryRoundtripTimestamp -Value (Get-FactoryNestedValue -Target $holder -Name "acquiredAt" -Default $null)
    } else { [pscustomobject]@{ success = $false; value = $null } }
    $heartbeatChanged = (
        [bool]$heartbeat.readable -and [bool]$acquired.success -and
        ([DateTime]$heartbeat.value) -ne ([DateTime]$acquired.value)
    )
    $heartbeatStalled = (
        $null -ne $holder -and $ownerAlive -and -not $heartbeatChanged -and
        [int]$heartbeat.ageSeconds -gt [Math]::Max(5, $heartbeatSeconds * 2)
    )
    if (-not [bool]$heartbeat.readable) { [Console]::Error.WriteLine([string]$heartbeat.warning) }
    [ordered]@{
        path = $leasePath
        free = ($null -eq $holder)
        holder = $holder
        holderAgeSeconds = [int]$heartbeat.ageSeconds
        heartbeatReadable = [bool]$heartbeat.readable
        heartbeatWarning = [string]$heartbeat.warning
        holderProcessAlive = $ownerAlive
        heartbeatPidAlive = $heartbeatPidAlive
        heartbeatChanged = $heartbeatChanged
        heartbeatStalled = $heartbeatStalled
        stale = (
            $null -ne $holder -and -not $ownerAlive -and [bool]$heartbeat.readable -and
            ($heartbeatPid -le 0 -or -not $heartbeatPidAlive) -and
            ([int]$heartbeat.ageSeconds -gt $effectiveTtlSeconds -or ($ownerPid -gt 0 -and $heartbeatPid -gt 0))
        )
        ttlSeconds = $effectiveTtlSeconds
        removedWaiters = $removedWaiters
        queue = @(Get-SortedTestLeaseQueue -Lease $lease)
        lastReclaim = Get-FactoryNestedValue -Target $lease -Name "lastReclaim"
        reclaimLogPath = $reclaimLogPath
        heartbeatLogPath = $HeartbeatLogPath
    } | ConvertTo-Json -Depth 20
    exit 0
}

if ($Action -eq "reclaim") {
    $mutex = $null
    try {
        $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
        $lease = Read-TestLeaseState
        $record = Reclaim-StaleTestLease -Lease $lease
        if ($null -ne $record) { Write-TestLeaseState -Lease $lease }
        [ordered]@{
            reclaimed = ($null -ne $record)
            abandonedHolder = $record
            holder = Get-FactoryNestedValue -Target $lease -Name "holder"
            queue = @(Get-SortedTestLeaseQueue -Lease $lease)
        } | ConvertTo-Json -Depth 20
    } finally {
        Exit-FactoryMutex -Mutex $mutex
    }
    exit 0
}

if ($Action -eq "release") {
    if (-not $Token) { throw "Release requires Token." }
    $mutex = $null
    try {
        $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
        $lease = Read-TestLeaseState
        $holder = Get-FactoryNestedValue -Target $lease -Name "holder"
        $released = $null -ne $holder -and [string](Get-FactoryNestedValue -Target $holder -Name "token" -Default "") -eq $Token
        if ($released) { Set-FactoryProperty -Target $lease -Name "holder" -Value $null }
        Set-FactoryProperty -Target $lease -Name "queue" -Value @(
            @(Get-FactoryNestedValue -Target $lease -Name "queue" -Default @()) |
                Where-Object { [string](Get-FactoryNestedValue -Target $_ -Name "token" -Default "") -ne $Token }
        )
        Write-TestLeaseState -Lease $lease
        [ordered]@{ released = $released; token = $Token; holder = Get-FactoryNestedValue -Target $lease -Name "holder" } |
            ConvertTo-Json -Depth 20
    } finally {
        Exit-FactoryMutex -Mutex $mutex
    }
    exit 0
}

if (-not $TaskId -or -not $Phase) { throw "Acquire requires TaskId and Phase." }
$requestToken = if ($Token) { $Token } else { [Guid]::NewGuid().ToString("N") }
$effectiveOwnerPid = if ($OwnerPid -gt 0) { $OwnerPid } else { Get-ParentProcessId }
$requestedAt = Get-FactoryUtcTimestamp
$priority = Get-TestLeasePriority -LeasePhase $Phase
$deadline = if ($WaitTimeoutSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($WaitTimeoutSeconds) } else { [DateTime]::MaxValue }
$acquired = $null

while ($null -eq $acquired) {
    $mutex = $null
    try {
        $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
        $lease = Read-TestLeaseState
        $null = Reclaim-StaleTestLease -Lease $lease
        $null = Remove-AbandonedTestLeaseWaiters -Lease $lease
        $queue = @(Get-FactoryNestedValue -Target $lease -Name "queue" -Default @())
        if (@($queue | Where-Object { [string]$_.token -eq $requestToken }).Count -eq 0) {
            $queue += [pscustomobject][ordered]@{
                taskId = $TaskId
                phase = $Phase
                requestedAt = $requestedAt
                priority = $priority
                token = $requestToken
                waiterPid = $PID
            }
            Set-FactoryProperty -Target $lease -Name "queue" -Value $queue
        }
        $sortedQueue = @(Get-SortedTestLeaseQueue -Lease $lease)
        $holder = Get-FactoryNestedValue -Target $lease -Name "holder"
        if ($null -eq $holder -and $sortedQueue.Count -gt 0 -and [string]$sortedQueue[0].token -eq $requestToken) {
            $now = Get-FactoryUtcTimestamp
            $acquired = [pscustomobject][ordered]@{
                taskId = $TaskId
                phase = $Phase
                pid = $effectiveOwnerPid
                acquiredAt = $now
                heartbeatAt = $now
                priority = $priority
                token = $requestToken
            }
            Set-FactoryProperty -Target $lease -Name "holder" -Value $acquired
            Set-FactoryProperty -Target $lease -Name "queue" -Value @($sortedQueue | Where-Object { [string]$_.token -ne $requestToken })
        }
        Write-TestLeaseState -Lease $lease
    } finally {
        Exit-FactoryMutex -Mutex $mutex
    }
    if ($null -ne $acquired) { break }
    if ([DateTime]::UtcNow -ge $deadline) {
        $cleanupMutex = $null
        try {
            $cleanupMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
            $lease = Read-TestLeaseState
            Set-FactoryProperty -Target $lease -Name "queue" -Value @(
                @(Get-FactoryNestedValue -Target $lease -Name "queue" -Default @()) |
                    Where-Object { [string]$_.token -ne $requestToken }
            )
            Write-TestLeaseState -Lease $lease
        } finally {
            Exit-FactoryMutex -Mutex $cleanupMutex
        }
        throw "Timed out waiting for the test lease after $WaitTimeoutSeconds second(s)."
    }
    Start-Sleep -Milliseconds $PollMilliseconds
}

$heartbeatPid = 0
if (-not $NoHeartbeat) {
    try {
        $heartbeatPid = Start-TestLeaseHeartbeat -LeaseToken $requestToken -LeaseOwnerPid $effectiveOwnerPid
        $heartbeatMutex = $null
        try {
            $heartbeatMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
            $lease = Read-TestLeaseState
            $holder = Get-FactoryNestedValue -Target $lease -Name "holder"
            if ($null -eq $holder -or [string](Get-FactoryNestedValue -Target $holder -Name "token" -Default "") -ne $requestToken) {
                throw "Test lease changed before its heartbeat process could be recorded."
            }
            Set-FactoryProperty -Target $holder -Name "heartbeatPid" -Value $heartbeatPid
            Write-TestLeaseState -Lease $lease
        } finally {
            Exit-FactoryMutex -Mutex $heartbeatMutex
        }
    } catch {
        $cleanupMutex = $null
        try {
            $cleanupMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
            $lease = Read-TestLeaseState
            $holder = Get-FactoryNestedValue -Target $lease -Name "holder"
            if ($null -ne $holder -and [string](Get-FactoryNestedValue -Target $holder -Name "token" -Default "") -eq $requestToken) {
                Set-FactoryProperty -Target $lease -Name "holder" -Value $null
                Write-TestLeaseState -Lease $lease
            }
        } finally {
            Exit-FactoryMutex -Mutex $cleanupMutex
        }
        throw
    }
}
[ordered]@{
    acquired = $true
    token = $requestToken
    taskId = $TaskId
    phase = $Phase
    pid = $effectiveOwnerPid
    acquiredAt = [string]$acquired.acquiredAt
    heartbeatPid = if ($heartbeatPid -gt 0) { $heartbeatPid } else { $null }
    path = $leasePath
} | ConvertTo-Json -Depth 20
