[CmdletBinding()]
param(
    [string]$Epic = '',
    [string]$EpicGid = '',
    [switch]$Force,
    [string]$Reason = 'schedule',
    [string]$Task = '',
    [switch]$DryRun,
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'rock-cycle.json' }
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
        $age = ([DateTimeOffset]::UtcNow - (ConvertTo-RockTimestamp -Value $record.startedAt)).TotalMinutes
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
    return @(Get-FactoryAsanaPages -Config $ApiConfig -Path "/tasks/$($Gid)/stories?opt_fields=$fields" |
        Where-Object { [string]$_.resource_subtype -eq 'comment_added' })
}

function Get-RockPauseControl {
    param([object[]]$Stories, [string]$IgorGid)
    $control = @($Stories | Where-Object {
        $creator = $_.PSObject.Properties['created_by']
        $creatorGid = if ($null -ne $creator -and $null -ne $creator.Value) { [string]$creator.Value.gid } else { '' }
        $creatorGid -eq $IgorGid -and
        [string]$_.text -match '^\s*/(pause|resume)\b' -and
        (Get-FactoryAsanaCommentActor -Text ([string]$_.text)) -eq 'Igor'
    } | Sort-Object created_at, gid -Descending | Select-Object -First 1)
    if (-not $control.Count) { return 'none' }
    if ([string]$control[0].text -match '^\s*/pause\b') { return 'paused' }
    return 'resumed'
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

function Write-RockStateAtomic {
    param([string]$Path, $Value)
    $fullPath = [IO.Path]::GetFullPath($Path)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath)) | Out-Null
    $temporaryPath = "$fullPath.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$fullPath.previous.bak"
    try {
        $json = $Value | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        $null = [IO.File]::ReadAllText($temporaryPath) | ConvertFrom-Json
        if ([IO.File]::Exists($fullPath)) {
            [IO.File]::Replace($temporaryPath, $fullPath, $backupPath, $true)
        } else {
            [IO.File]::Move($temporaryPath, $fullPath)
        }
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
}

function Get-RockInstancePaths {
    param([string]$StateRoot, [string]$Name, [string]$EpicGid)
    $root = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($StateRoot))
    if ($root.Contains('%')) { throw 'stateDir contains an unexpanded environment variable.' }
    return [pscustomobject]@{
        stateDir = Join-Path $root $Name
        mutexName = "Local\RockOrchestratorCycle-$EpicGid"
    }
}

function Test-RockEpicUrl {
    param([string]$Url, [string]$EpicGid)
    if ($EpicGid -notmatch '^\d+$') { return $false }
    try { $uri = [Uri]$Url } catch { return $false }
    return $uri.Scheme -eq 'https' -and $uri.Host -eq 'app.asana.com' -and
        $uri.AbsolutePath -match ("/task/{0}(?:/|$)" -f [regex]::Escape($EpicGid))
}

function Select-RockOrchestrators {
    param([object[]]$Orchestrators, [string]$EpicName = '', [string]$LegacyEpicGid = '',
        [string]$TaskGid = '', [object[]]$Dependents = @())
    $candidates = @($Orchestrators)
    if ($EpicName) { $candidates = @($candidates | Where-Object { [string]$_.name -ieq $EpicName }) }
    if ($LegacyEpicGid) { $candidates = @($candidates | Where-Object { [string]$_.epicGid -eq $LegacyEpicGid }) }
    if ($candidates.Count -eq 0) { throw 'Requested rock orchestrator is not configured.' }
    if (-not $TaskGid) { return [pscustomobject]@{ items = $candidates; fallback = $false } }
    $dependentGids = @($Dependents | ForEach-Object { [string]$_.gid })
    $matched = @($candidates | Where-Object { [string]$_.epicGid -in $dependentGids })
    if ($matched.Count) { return [pscustomobject]@{ items = $matched; fallback = $false } }
    return [pscustomobject]@{ items = $candidates; fallback = $true }
}

function Invoke-RockOrchestrator {
    param($Orchestrator, $Config, $ApiConfig, [string]$TaskGid, [string]$RunReason,
        [bool]$ForceRun, [switch]$DryRun)
    $name = [string]$Orchestrator.name
    $gid = [string]$Orchestrator.epicGid
    $paths = Get-RockInstancePaths -StateRoot ([string]$Config.stateDir) -Name $name -EpicGid $gid
    $stateDir = [string]$paths.stateDir
    $lockPath = Join-Path $stateDir 'lock.json'
    $statePath = Join-Path $stateDir 'state.json'
    $mutex = $null
    $ownsMutex = $false
    $ownsLock = $false
    try {
        if (-not $DryRun) {
            $mutex = New-Object Threading.Mutex($false, ([string]$paths.mutexName))
            try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
            if (-not $ownsMutex) { return [pscustomobject]@{ message = "$($name): busy"; exitCode = 0 } }
        }
        $lockStatus = Get-RockLockStatus -Path $lockPath -StaleMinutes ([int]$Config.staleLockMinutes)
        if ($lockStatus -eq 'busy') { return [pscustomobject]@{ message = "$($name): busy"; exitCode = 0 } }
        if (-not $DryRun) {
            [IO.Directory]::CreateDirectory($stateDir) | Out-Null
            if ($lockStatus -eq 'stale') { [IO.File]::Delete($lockPath) }
            $lock = [ordered]@{ pid = $PID; startedAt = [DateTimeOffset]::UtcNow.ToString('o') }
            [IO.File]::WriteAllText($lockPath, ($lock | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
            $ownsLock = $true
        }
        $epicStories = @(Get-RockStories -ApiConfig $ApiConfig -Gid $gid)
        if ((Get-RockPauseControl -Stories $epicStories -IgorGid ([string]$Config.igorGid)) -eq 'paused') {
            if (-not $DryRun) { Write-RockDecisionLog -StateDirectory $stateDir -Message 'paused by Igor in Asana' }
            return [pscustomobject]@{ message = "$($name): paused by Igor in Asana"; exitCode = 0 }
        }
        $saved = if ([IO.File]::Exists($statePath)) { [IO.File]::ReadAllText($statePath) | ConvertFrom-Json } else { $null }
        $boundary = if ($saved -and $saved.lastRunEnd) { ConvertTo-RockTimestamp -Value $saved.lastRunEnd } else { $null }
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $lastDailyRun = if ($saved) { [string]$saved.lastDailyRun } else { '' }
        $dailyDue = [int](Get-Date).Hour -ge [int]$Config.dailyHourLocal -and $lastDailyRun -ne $today
        $changed = New-Object Collections.Generic.List[string]
        if (-not $ForceRun) {
            $epic = (Invoke-FactoryAsana -Config $ApiConfig -Path "/tasks/$($gid)?opt_fields=gid,modified_at").data
            $dependencies = @(Get-FactoryAsanaPages -Config $ApiConfig -Path "/tasks/$($gid)/dependencies?opt_fields=gid,name,modified_at")
            foreach ($item in @($epic) + $dependencies) {
                if (-not $item -or -not [string]$item.gid) { continue }
                $stories = if ([string]$item.gid -eq $gid) { $epicStories } else {
                    @(Get-RockStories -ApiConfig $ApiConfig -Gid ([string]$item.gid))
                }
                $storyChanged = @($stories | Where-Object { Test-RockAfter -Value $_.created_at -Boundary $boundary }).Count -gt 0
                if ((Test-RockAfter -Value $item.modified_at -Boundary $boundary) -or $storyChanged) {
                    $changed.Add([string]$item.gid)
                }
            }
        }
        $reason = if ($RunReason -ne 'schedule') { $RunReason } elseif ($dailyDue) { 'daily' } else { 'schedule' }
        $shouldRun = $ForceRun -or $changed.Count -gt 0 -or $dailyDue
        $changedText = if ($changed.Count) { @($changed.ToArray() | Select-Object -Unique) -join ', ' } else { 'n/a' }
        $decision = if ($shouldRun) { "run: $reason; changed tasks: $changedText" } else { 'no changes' }
        if ($DryRun) { return [pscustomobject]@{ message = "DryRun: $($name): $decision"; exitCode = 0 } }
        if (-not $shouldRun) {
            Write-RockDecisionLog -StateDirectory $stateDir -Message 'no changes'
            return [pscustomobject]@{ message = "$($name): no changes"; exitCode = 0 }
        }
        $repoPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Orchestrator.repoPath))
        if (-not [IO.Directory]::Exists($repoPath)) { throw "Read-only checkout not found: $repoPath" }
        $extraDirs = @()
        foreach ($extra in @($Orchestrator.extraDirs)) {
            $extraPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$extra))
            if (-not [IO.Directory]::Exists($extraPath)) { throw "Extra read-only directory not found: $extraPath" }
            $extraDirs += $extraPath
        }
        $actor = "$($name)-orchestrator"
        $prompt = "You are the $actor for Asana task $($Orchestrator.epicUrl). Read it and run one cycle. Reason: $reason. Changed tasks: $changedText. Only groom, dispatch, answer, or edit tasks that are children of your epic. Dependencies that are not children are read-only watched tasks. A watched task may be owned by another orchestrator. Start every comment with [$actor], or with ANSWER ($actor): when answering a factory question. Do not change code."
        if ($TaskGid) { $prompt += " Hint task: $TaskGid." }
        $logsDir = Join-Path $stateDir 'logs'
        [IO.Directory]::CreateDirectory($logsDir) | Out-Null
        $logPath = Join-Path $logsDir ("rock-cycle-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $stdoutPath = "$logPath.stdout"
        $stderrPath = "$logPath.stderr"
        $exitCode = 1
        $started = $false
        try {
            $claudeCommand = Get-Command ([string]$Config.claudePath) -ErrorAction Stop
            $claudeArgs = @('-p', $prompt, '--permission-mode', 'dontAsk', '--disallowedTools', 'Edit', 'Write', 'NotebookEdit', '--allowedTools') + @($Config.allowedTools)
            if ($extraDirs.Count) { $claudeArgs += @('--add-dir') + $extraDirs }
            $claudeArgs += @('--output-format', 'json')
            $argumentLine = (@($claudeArgs | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }) -join ' ')
            $process = Start-Process -FilePath ([string]$claudeCommand.Source) -ArgumentList $argumentLine -WorkingDirectory $repoPath -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
            $started = $true
            if (-not $process.WaitForExit([int]$Config.timeoutMinutes * 60000)) {
                $null = Invoke-FactoryNativeProcess -Command 'taskkill' -Arguments @('/PID', [string]$process.Id, '/T', '/F') -TimeoutSeconds 10
                $exitCode = 124
            } else { $exitCode = [int]$process.ExitCode }
        } catch {
            $exitCode = 1
            [IO.File]::AppendAllText($stderrPath, "Launcher error: $($_.Exception.Message)" + [Environment]::NewLine)
        } finally {
            $output = "stdout:" + [Environment]::NewLine + $(if ([IO.File]::Exists($stdoutPath)) { [IO.File]::ReadAllText($stdoutPath) } else { '' }) +
                [Environment]::NewLine + "stderr:" + [Environment]::NewLine + $(if ([IO.File]::Exists($stderrPath)) { [IO.File]::ReadAllText($stderrPath) } else { '' })
            [IO.File]::WriteAllText($logPath, $output + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
            Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
            if ($started) {
                $newState = [ordered]@{
                    lastRunEnd = [DateTimeOffset]::UtcNow.ToString('o')
                    lastDailyRun = if ($reason -eq 'daily') { $today } else { $lastDailyRun }
                }
                Write-RockStateAtomic -Path $statePath -Value $newState
            }
        }
        return [pscustomobject]@{ message = "$($name): cycle: $reason; exit: $exitCode; log: $logPath"; exitCode = $exitCode }
    } catch {
        return [pscustomobject]@{ message = "$($name): error: $($_.Exception.Message)"; exitCode = 1 }
    } finally {
        if ($ownsLock -and [IO.File]::Exists($lockPath)) { [IO.File]::Delete($lockPath) }
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

if (-not [IO.File]::Exists($ConfigPath)) { throw "Rock config not found: $ConfigPath" }
$config = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
foreach ($required in @('tokenEnv', 'igorGid', 'stateDir', 'claudePath')) {
    if (-not [string]$config.$required) { throw "Rock config is missing '$required'." }
}
if ([string]$config.igorGid -notmatch '^\d+$') { throw 'Invalid Igor Asana GID in rock config.' }
if ([int]$config.timeoutMinutes -lt 1 -or [int]$config.timeoutMinutes -gt 60) { throw 'timeoutMinutes must be 1-60.' }
if ([int]$config.staleLockMinutes -lt 1) { throw 'staleLockMinutes must be positive.' }
if ([int]$config.dailyHourLocal -lt 0 -or [int]$config.dailyHourLocal -gt 23) { throw 'dailyHourLocal must be 0-23.' }
if ($Task -and $Task -notmatch '^\d+$') { throw 'Task hint must be a numeric Asana GID.' }
if ($Epic -and $EpicGid) { throw 'Use either -Epic or -EpicGid, not both.' }
$safeTools = @('mcp__asana', 'Read', 'Grep', 'Glob', 'WebSearch', 'WebFetch',
    'Bash(git fetch *)', 'Bash(git log *)', 'Bash(git show *)')
foreach ($tool in @($config.allowedTools)) {
    if ([string]$tool -cnotin $safeTools) { throw "Unsafe or unknown rock tool: $tool" }
}
if (@($config.allowedTools).Count -eq 0) { throw 'allowedTools may not be empty.' }
$orchestrators = @($config.orchestrators)
if ($orchestrators.Count -eq 0) { throw 'Rock config has no orchestrators.' }
$names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$gids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($orchestrator in $orchestrators) {
    $name = [string]$orchestrator.name
    $gid = [string]$orchestrator.epicGid
    if ($name -notmatch '^[a-z][a-z0-9_-]*$' -or -not $names.Add($name)) { throw "Invalid or duplicate rock orchestrator name: $name" }
    if ($gid -notmatch '^\d+$' -or -not $gids.Add($gid)) { throw "Invalid or duplicate rock epic GID: $gid" }
    if (-not (Test-RockEpicUrl -Url ([string]$orchestrator.epicUrl) -EpicGid $gid)) { throw "Invalid epicUrl for $name." }
    if (-not [string]$orchestrator.repoPath) { throw "Missing repoPath for $name." }
    if ($null -eq $orchestrator.PSObject.Properties['extraDirs']) { throw "Missing extraDirs for $name." }
}
$apiConfig = [pscustomobject]@{ asana = [pscustomobject]@{ tokenEnv = [string]$config.tokenEnv } }
$globalMutex = $null
$ownsGlobalMutex = $false
if (-not $DryRun) {
    $globalMutex = New-Object Threading.Mutex($false, 'Local\RockOrchestratorLauncher')
    try { $ownsGlobalMutex = $globalMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsGlobalMutex = $true }
    if (-not $ownsGlobalMutex) {
        $globalMutex.Dispose()
        Write-Output 'busy: another rock launcher is running'
        exit 0
    }
}
$firstExitCode = 0
try {
    $dependents = if ($Task) { @(Get-FactoryAsanaPages -Config $apiConfig -Path "/tasks/$($Task)/dependents?opt_fields=gid") } else { @() }
    $selection = Select-RockOrchestrators -Orchestrators $orchestrators -EpicName $Epic -LegacyEpicGid $EpicGid -TaskGid $Task -Dependents $dependents
    $forceRun = -not $selection.fallback -and ([bool]$Force -or $Reason -ne 'schedule')
    $effectiveReason = if ($selection.fallback) { 'schedule' } else { $Reason }
    foreach ($orchestrator in @($selection.items)) {
        $result = Invoke-RockOrchestrator -Orchestrator $orchestrator -Config $config -ApiConfig $apiConfig -TaskGid $Task -RunReason $effectiveReason -ForceRun $forceRun -DryRun:$DryRun
        Write-Output $result.message
        if ($firstExitCode -eq 0 -and [int]$result.exitCode -ne 0) { $firstExitCode = [int]$result.exitCode }
    }
} finally {
    if ($ownsGlobalMutex) { $globalMutex.ReleaseMutex() }
    if ($globalMutex) { $globalMutex.Dispose() }
}
exit $firstExitCode
