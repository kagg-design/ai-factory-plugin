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
    [switch]$NoHeartbeat
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path ([string]$context.configPath)
$leasePath = Join-Path ([string]$context.projectData) "test-lease.json"
$reclaimLogPath = Join-Path ([string]$context.projectData) "test-lease.reclaims.jsonl"
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
    Set-FactoryProperty -Target $Lease -Name "updatedAt" -Value (Get-FactoryUtcTimestamp)
    Write-FactoryJsonAtomic -Path $leasePath -Value $Lease
}

function Get-TestLeasePriority {
    param([string]$LeasePhase)
    if ($LeasePhase -in @("integration", "release")) { return 100 }
    return 10
}

function Get-TestLeaseAgeSeconds {
    param($Holder)
    if ($null -eq $Holder) { return 0 }
    $heartbeatAt = [string](Get-FactoryNestedValue -Target $Holder -Name "heartbeatAt" -Default "")
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($heartbeatAt, [ref]$parsed)) { return [int]::MaxValue }
    return [Math]::Max(0, [int]([DateTime]::UtcNow - $parsed.ToUniversalTime()).TotalSeconds)
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
    $record = [ordered]@{
        reclaimedAt = Get-FactoryUtcTimestamp
        taskId = [string](Get-FactoryNestedValue -Target $Holder -Name "taskId" -Default "unknown")
        phase = [string](Get-FactoryNestedValue -Target $Holder -Name "phase" -Default "unknown")
        pid = [int](Get-FactoryNestedValue -Target $Holder -Name "pid" -Default 0)
        heartbeatAt = [string](Get-FactoryNestedValue -Target $Holder -Name "heartbeatAt" -Default "")
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
    $ageSeconds = Get-TestLeaseAgeSeconds -Holder $holder
    if ($ageSeconds -le $effectiveTtlSeconds) { return $null }
    $reason = "Test lease heartbeat is $ageSeconds second(s) old; TTL is $effectiveTtlSeconds second(s)."
    $record = Write-TestLeaseReclaimRecord -Holder $holder -Reason $reason
    Set-FactoryProperty -Target $Lease -Name "holder" -Value $null
    Set-FactoryProperty -Target $Lease -Name "lastReclaim" -Value $record
    return $record
}

function Remove-AbandonedTestLeaseWaiters {
    param([Parameter(Mandatory = $true)]$Lease)
    $remaining = @(
        @(Get-FactoryNestedValue -Target $Lease -Name "queue" -Default @()) | Where-Object {
            $waiterPid = [int](Get-FactoryNestedValue -Target $_ -Name "waiterPid" -Default 0)
            $waiterPid -eq $PID -or (Test-TestLeaseProcess -ProcessId $waiterPid)
        }
    )
    Set-FactoryProperty -Target $Lease -Name "queue" -Value $remaining
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
        "-TtlSeconds", [string]$effectiveTtlSeconds
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
        return [int]$process.Id
    } finally {
        $process.Dispose()
    }
}

if ($Action -eq "heartbeat") {
    if (-not $Token -or $OwnerPid -le 0) { throw "Heartbeat requires Token and OwnerPid." }
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
    exit 0
}

if ($Action -eq "status") {
    $lease = Read-TestLeaseState
    $holder = Get-FactoryNestedValue -Target $lease -Name "holder"
    $ageSeconds = Get-TestLeaseAgeSeconds -Holder $holder
    [ordered]@{
        path = $leasePath
        free = ($null -eq $holder)
        holder = $holder
        holderAgeSeconds = $ageSeconds
        stale = ($null -ne $holder -and $ageSeconds -gt $effectiveTtlSeconds)
        ttlSeconds = $effectiveTtlSeconds
        queue = @(Get-SortedTestLeaseQueue -Lease $lease)
        lastReclaim = Get-FactoryNestedValue -Target $lease -Name "lastReclaim"
        reclaimLogPath = $reclaimLogPath
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
        Remove-AbandonedTestLeaseWaiters -Lease $lease
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

$heartbeatPid = if ($NoHeartbeat) { 0 } else { Start-TestLeaseHeartbeat -LeaseToken $requestToken -LeaseOwnerPid $effectiveOwnerPid }
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
