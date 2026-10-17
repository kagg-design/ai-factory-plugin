[CmdletBinding()]
param(
    [switch]$Force,
    [string]$Reason = 'schedule',
    [string]$Task = '',
    [string]$EpicGid = '',
    [switch]$DryRun,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'rock-cycle.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\factory-common.ps1')
. (Join-Path $PSScriptRoot 'scripts\asana-common.ps1')

function ConvertTo-RockTimestamp {
    param($Value)
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToUniversalTime() }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Get-RockLockStatus {
    param([string]$Path, [int]$StaleMinutes)
    if (-not [IO.File]::Exists($Path)) { return 'absent' }
    try {
        $record = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $started = ConvertTo-RockTimestamp -Value $record.startedAt
        $age = ([DateTimeOffset]::UtcNow - $started.ToUniversalTime()).TotalMinutes
        $alive = $false
        if ([int]$record.pid -gt 0) {
            try { $null = Get-Process -Id ([int]$record.pid) -ErrorAction Stop; $alive = $true } catch { }
        }
        if ($alive -and $age -lt $StaleMinutes -and $age -ge -1) { return 'busy' }
    } catch { }
    return 'stale'
}

function Get-RockStories {
    param($ApiConfig, [string]$Gid)
    $fields = 'gid,created_at,created_by.gid,resource_subtype,text'
    return @(Get-FactoryAsanaPages -Config $ApiConfig -Path "/tasks/$Gid/stories?opt_fields=$fields" |
        Where-Object { [string]$_.resource_subtype -eq 'comment_added' })
}

function Test-RockAfter {
    param($Value, $Boundary)
    if (-not $Boundary -or -not $Value) { return $true }
    return (ConvertTo-RockTimestamp -Value $Value) -gt $Boundary
}

function Write-RockDecisionLog {
    param([string]$StateDirectory, [string]$Message)
    $logDir = Join-Path $StateDirectory 'logs'
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $line = "{0} {1}{2}" -f [DateTimeOffset]::UtcNow.ToString('o'), $Message, [Environment]::NewLine
    [IO.File]::AppendAllText((Join-Path $logDir 'decisions.log'), $line, (New-Object Text.UTF8Encoding($false)))
}

function Get-RockInstancePaths {
    param([string]$StateRoot, [string]$EpicGid)
    $root = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
    if ($root.Contains('%')) { throw 'stateDir contains an unexpanded environment variable.' }
    return [pscustomobject]@{
        stateDir = Join-Path $root $EpicGid
        mutexName = "Local\RockOrchestratorCycle-$EpicGid"
    }
}

function Test-RockTaskInScope {
    param([string]$TaskGid, [string]$EpicGid, [object[]]$Dependencies)
    if (-not $TaskGid) { return $true }
    if ($TaskGid -eq $EpicGid) { return $true }
    return @($Dependencies | Where-Object { [string]$_.gid -eq $TaskGid }).Count -gt 0
}

function Get-RockEpicUrl {
    param([string]$ConfiguredUrl, [string]$ConfiguredGid, [string]$TargetGid)
    if ($ConfiguredGid -notmatch '^\d+$' -or $TargetGid -notmatch '^\d+$') { throw 'Epic GID must be numeric.' }
    $uri = [Uri]$ConfiguredUrl
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'app.asana.com' -or
        $uri.AbsolutePath -notmatch ("/task/{0}(?:/|$)" -f [regex]::Escape($ConfiguredGid))) {
        throw 'epicUrl must point to epicGid on app.asana.com.'
    }
    $builder = [UriBuilder]$uri
    $builder.Path = [regex]::Replace($uri.AbsolutePath, '/task/\d+(?=/|$)', "/task/$TargetGid")
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri.AbsoluteUri.TrimEnd('/')
}

if (-not [IO.File]::Exists($ConfigPath)) { throw "Rock config not found: $ConfigPath" }
$config = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
foreach ($required in @('repoPath', 'epicGid', 'epicUrl', 'igorGid', 'tokenEnv', 'stateDir', 'claudePath')) {
    if (-not [string]$config.$required) { throw "Rock config is missing '$required'." }
}
if ([string]$config.epicGid -notmatch '^\d+$' -or [string]$config.igorGid -notmatch '^\d+$') { throw 'Invalid Asana GID in rock config.' }
$selectedEpicGid = if ($EpicGid) { $EpicGid } else { [string]$config.epicGid }
$config.epicUrl = Get-RockEpicUrl -ConfiguredUrl ([string]$config.epicUrl) -ConfiguredGid ([string]$config.epicGid) -TargetGid $selectedEpicGid
$config.epicGid = $selectedEpicGid
if ([int]$config.timeoutMinutes -lt 1 -or [int]$config.timeoutMinutes -gt 60) { throw 'timeoutMinutes must be 1-60.' }
if ([int]$config.staleLockMinutes -lt 1) { throw 'staleLockMinutes must be positive.' }
if ([int]$config.dailyHourLocal -lt 0 -or [int]$config.dailyHourLocal -gt 23) { throw 'dailyHourLocal must be 0-23.' }
if ($Task -and $Task -notmatch '^\d+$') { throw 'Task hint must be a numeric Asana GID.' }
$safeTools = @('mcp__asana', 'Read', 'Grep', 'Glob', 'WebSearch', 'WebFetch',
    'Bash(git fetch *)', 'Bash(git log *)', 'Bash(git show *)')
foreach ($tool in @($config.allowedTools)) {
    if ([string]$tool -cnotin $safeTools) { throw "Unsafe or unknown rock tool: $tool" }
}
if (@($config.allowedTools).Count -eq 0) { throw 'allowedTools may not be empty.' }

$instancePaths = Get-RockInstancePaths -StateRoot ([string]$config.stateDir) -EpicGid ([string]$config.epicGid)
$stateDir = [string]$instancePaths.stateDir
$lockPath = Join-Path $stateDir 'lock.json'
$statePath = Join-Path $stateDir 'state.json'
$forceRun = [bool]$Force -or $Reason -ne 'schedule'
$apiConfig = [pscustomobject]@{ asana = [pscustomobject]@{ tokenEnv = [string]$config.tokenEnv } }
$mutex = $null
$ownsMutex = $false
$ownsLock = $false

try {
    if (-not $DryRun) {
        $mutex = New-Object Threading.Mutex($false, ([string]$instancePaths.mutexName))
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { Write-Output 'busy'; exit 0 }
    }
    $lockStatus = Get-RockLockStatus -Path $lockPath -StaleMinutes ([int]$config.staleLockMinutes)
    if ($lockStatus -eq 'busy') { Write-Output 'busy'; exit 0 }
    if (-not $DryRun) {
        [IO.Directory]::CreateDirectory($stateDir) | Out-Null
        if ($lockStatus -eq 'stale') { [IO.File]::Delete($lockPath) }
        $lock = [ordered]@{ pid = $PID; startedAt = [DateTimeOffset]::UtcNow.ToString('o') }
        [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        $ownsLock = $true
    }

    $epicStories = @(Get-RockStories -ApiConfig $apiConfig -Gid ([string]$config.epicGid))
    $control = @($epicStories | Where-Object {
        [string]$_.created_by.gid -eq [string]$config.igorGid -and
        [string]$_.text -match '^\s*/(pause|resume)\b'
    } | Sort-Object created_at, gid -Descending | Select-Object -First 1)
    if ($control.Count -and [string]$control[0].text -match '^\s*/pause\b') {
        if (-not $DryRun) { Write-RockDecisionLog -StateDirectory $stateDir -Message 'paused by Igor in Asana' }
        Write-Output 'paused by Igor in Asana'
        exit 0
    }

    $deps = @()
    if ($Task -or -not $forceRun) {
        $deps = @(Get-FactoryAsanaPages -Config $apiConfig -Path "/tasks/$($config.epicGid)/dependencies?opt_fields=gid,name,modified_at")
    }
    if (-not (Test-RockTaskInScope -TaskGid $Task -EpicGid ([string]$config.epicGid) -Dependencies $deps)) {
        $ignored = "ignored unrelated task $Task for epic $($config.epicGid)"
        if (-not $DryRun) { Write-RockDecisionLog -StateDirectory $stateDir -Message $ignored }
        Write-Output $(if ($DryRun) { "DryRun: $ignored" } else { $ignored })
        exit 0
    }

    $saved = if ([IO.File]::Exists($statePath)) { [IO.File]::ReadAllText($statePath) | ConvertFrom-Json } else { $null }
    $boundary = if ($saved -and $saved.lastRunEnd) { ConvertTo-RockTimestamp -Value $saved.lastRunEnd } else { $null }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $lastDailyRun = if ($saved) { [string]$saved.lastDailyRun } else { '' }
    $dailyDue = [int](Get-Date).Hour -ge [int]$config.dailyHourLocal -and
        $lastDailyRun -ne $today
    $changed = New-Object Collections.Generic.List[string]
    if (-not $forceRun) {
        $epic = (Invoke-FactoryAsana -Config $apiConfig -Path "/tasks/$($config.epicGid)?opt_fields=gid,modified_at").data
        foreach ($item in @($epic) + $deps) {
            if (-not $item -or -not [string]$item.gid) { continue }
            $stories = if ([string]$item.gid -eq [string]$config.epicGid) { $epicStories } else {
                @(Get-RockStories -ApiConfig $apiConfig -Gid ([string]$item.gid))
            }
            $storyChanged = @($stories | Where-Object { Test-RockAfter -Value $_.created_at -Boundary $boundary }).Count -gt 0
            if ((Test-RockAfter -Value $item.modified_at -Boundary $boundary) -or $storyChanged) {
                $changed.Add([string]$item.gid)
            }
        }
    }
    $runReason = if ($Reason -ne 'schedule') { $Reason } elseif ($dailyDue) { 'daily' } else { 'schedule' }
    $shouldRun = $forceRun -or $changed.Count -gt 0 -or $dailyDue
    $changedText = if ($changed.Count) { @($changed.ToArray() | Select-Object -Unique) -join ', ' } else { 'n/a' }
    $decision = if ($shouldRun) { "run: $runReason; changed tasks: $changedText" } else { 'no changes' }
    if ($DryRun) { Write-Output "DryRun: $decision"; exit 0 }
    if (-not $shouldRun) {
        Write-RockDecisionLog -StateDirectory $stateDir -Message 'no changes'
        Write-Output 'no changes'
        exit 0
    }

    $repoPath = [IO.Path]::GetFullPath([string]$config.repoPath)
    if (-not [IO.Directory]::Exists($repoPath)) { throw "AwesomeHR read-only checkout not found: $repoPath" }
    $prompt = "You are the orchestrator for Asana task $($config.epicUrl). Read it and run one cycle. Work on this epic and its dependencies; do not act on other rock epics. Reason: $runReason. Changed tasks: $changedText."
    if ($Task) { $prompt += " Hint task: $Task." }
    $logsDir = Join-Path $stateDir 'logs'
    [IO.Directory]::CreateDirectory($logsDir) | Out-Null
    $logPath = Join-Path $logsDir ("rock-cycle-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $stdoutPath = "$logPath.stdout"
    $stderrPath = "$logPath.stderr"
    $exitCode = 1
    $started = $false
    try {
        $claudeCommand = Get-Command ([string]$config.claudePath) -ErrorAction Stop
        $claudeArgs = @('-p', $prompt, '--allowedTools') + @($config.allowedTools) + @('--output-format', 'json')
        $argumentLine = (@($claudeArgs | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }) -join ' ')
        $process = Start-Process -FilePath ([string]$claudeCommand.Source) -ArgumentList $argumentLine `
            -WorkingDirectory $repoPath -WindowStyle Hidden -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath -PassThru
        $started = $true
        if (-not $process.WaitForExit([int]$config.timeoutMinutes * 60000)) {
            $null = Invoke-FactoryNativeProcess -Command 'taskkill' -Arguments @('/PID', [string]$process.Id, '/T', '/F') -TimeoutSeconds 10
            $exitCode = 124
        } else { $exitCode = [int]$process.ExitCode }
    } catch {
        $exitCode = 1
        [IO.File]::AppendAllText($stderrPath, "Launcher error: $($_.Exception.Message)" + [Environment]::NewLine)
    } finally {
        $output = "stdout:`r`n" + $(if ([IO.File]::Exists($stdoutPath)) { [IO.File]::ReadAllText($stdoutPath) } else { '' }) +
            "`r`nstderr:`r`n" + $(if ([IO.File]::Exists($stderrPath)) { [IO.File]::ReadAllText($stderrPath) } else { '' })
        [IO.File]::WriteAllText($logPath, $output + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
        if ($started) {
            $newState = [ordered]@{
                lastRunEnd = [DateTimeOffset]::UtcNow.ToString('o')
                lastDailyRun = if ($runReason -eq 'daily') { $today } else { $lastDailyRun }
            }
            Write-FactoryJsonAtomic -Path $statePath -Value $newState
        }
    }
    Write-Output "cycle: $runReason; exit: $exitCode; log: $logPath"
    exit $exitCode
} finally {
    if ($ownsLock -and [IO.File]::Exists($lockPath)) { [IO.File]::Delete($lockPath) }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
