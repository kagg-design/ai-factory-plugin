# Native quality gates. Scanner output is kept in memory and only marked summary
# lines cross the boundary into state, logs or Asana. No raw scanner log is saved.
. (Join-Path $PSScriptRoot 'asana-common.ps1')

function Get-FactoryBlankEnvKeys {
    param($Config)
    return @(Get-FactoryNestedValue -Target $Config -Name 'blankEnvKeys' -Default @(
        'ASANA_ACCESS_TOKEN', 'ACCESS_*', 'BILLING_*', 'GITHUB_APP_*', 'GCS_KEY_FILE', '*_TOKEN', '*_SECRET', '*_API_KEY'
    ))
}

function Protect-FactoryEnvironmentFile {
    param($Config, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $keys = New-Object Collections.Generic.List[string]
    $patterns = @(Get-FactoryBlankEnvKeys -Config $Config)
    $text = [IO.File]::ReadAllText($Path)
    # Consume quoted multiline values as well as ordinary dotenv values.
    $pattern = '(?m)^(?<prefix>[ \t]*(?:export[ \t]+)?)(?<key>[A-Za-z_][A-Za-z0-9_]*)(?<eq>[ \t]*=[ \t]*)(?:"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|[^\r\n]*)(?<tail>[ \t]*(?:#[^\r\n]*)?)'
    $replace = [Text.RegularExpressions.MatchEvaluator]{ param($match)
        $key = $match.Groups['key'].Value
        $blank = @($patterns | Where-Object { $key -like $_ }).Count -gt 0
        if ($key -eq 'APP_KEY' -or $key -like 'DB_*') { $blank = $false }
        if (-not $blank) { return $match.Value }
        if (-not $keys.Contains($key)) { $keys.Add($key) }
        return $match.Groups['prefix'].Value + $key + '='
    }
    $clean = [regex]::Replace($text, $pattern, $replace)
    [IO.File]::WriteAllText($Path, $clean, (New-Object Text.UTF8Encoding($false)))
    if ($keys.Count) { [Console]::Error.WriteLine('Blanked environment keys: ' + ($keys.ToArray() -join ', ')) }
}

function Invoke-FactorySecurityCheck {
    param($Config, [string]$Repository, [string]$Worktree)
    $repo = Get-FactoryOwnRepo -Config $Config -Repository $Repository
    $profile = Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $Config -Name 'repos') -Name $repo
    $command = [string](Get-FactoryNestedValue -Target $profile -Name 'securityCommand' -Default '')
    if (-not $command) { return [pscustomobject]@{ status = 'skipped'; summary = 'not configured for this repo'; exitCode = 0 } }
    $presentWhen = [string](Get-FactoryNestedValue -Target $profile -Name 'securityPresentWhen' -Default '')
    if ($presentWhen) {
        if ($presentWhen -ne 'composer.json has scripts.security') { throw 'Unsupported securityPresentWhen condition.' }
        $composerPath = Join-Path $Worktree 'composer.json'
        $present = $false
        if (Test-Path -LiteralPath $composerPath -PathType Leaf) {
            $composer = Read-FactoryJson -Path $composerPath
            $present = $null -ne (Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $composer -Name 'scripts') -Name 'security')
        }
        if (-not $present) { return [pscustomobject]@{ status = 'skipped'; summary = 'command not present yet'; exitCode = 0 } }
    }
    if ($command.Length -gt 4096 -or $command -match '[\r\n]') { throw 'Invalid security command in repository config.' }
    $run = Invoke-FactoryNativeProcess -Command 'powershell' -Arguments @('-NoProfile', '-Command', ($command + '; if (-not $?) { exit 1 }; exit $LASTEXITCODE')) -WorkingDirectory $Worktree
    $lines = @((Remove-FactoryAnsiSequences -Value ([string]$run.output)) -split '\r?\n' | Where-Object {
        $_ -match '^\s*(?:Security:|Summary:|\[security-summary\])'
    } | Select-Object -First 20 | ForEach-Object { $_.Trim() })
    $summary = $lines -join '; '
    if (-not $summary) { $summary = "Security command exited $($run.exitCode); no summary lines returned." }
    # The repo masks scanner details. Also redact known process credentials if a
    # buggy command repeats one in a summary (never serialize the credential).
    foreach ($name in [Environment]::GetEnvironmentVariables().Keys) {
        if (@(Get-FactoryBlankEnvKeys -Config $Config | Where-Object { [string]$name -like $_ }).Count) {
            $secret = [Environment]::GetEnvironmentVariable([string]$name)
            if ($secret) { $summary = $summary.Replace($secret, '[REDACTED]') }
        }
    }
    return [pscustomobject]@{ status = $(if ($run.exitCode -eq 0) { 'passed' } else { 'failed' }); summary = $summary; exitCode = [int]$run.exitCode }
}

function Test-FactoryMergeGate {
    param($Context, $Config, $Task, [switch]$TerminalYes)
    $notes = [string]$Task.brief + "`n" + (@(Get-FactoryNestedValue $Task 'sourceNotes' @()) -join "`n")
    $gate = Get-FactoryNestedValue -Target $Task -Name 'mergeGate'
    $legacyGate = $gate -is [bool] -and $gate
    $asana = [bool](Get-FactoryNestedValue -Target $Task -Name 'asanaMode' -Default $false)
    if ($asana) {
        $remote = Get-FactoryAsanaTask -Config $Config -Gid ([string]$Task.id)
        if ((Get-FactoryAsanaField -Task $remote -Gid ([string]$Config.asana.fields.factory)) -ne [string]$Config.asana.fields.taken) {
            throw 'Asana task is no longer Taken. A new Ready requires a fresh run.'
        }
        $notes += "`n" + [string]$remote.notes
    }
    if (-not $legacyGate -and $notes -notmatch '(?im)^\s*Merge gate:\s*ask Igor before merging\s*$') { return $true }
    if ($null -eq $gate -or [string](Get-FactoryNestedValue $gate 'commit') -ne [string]$Task.commit) {
        $text = "MERGE GATE (factory): ready to merge $($Task.commit). Waiting for Igor: answer in the terminal, or comment /merge here."
        $requestedAt = Get-FactoryUtcTimestamp
        if ($asana) {
            $requestStory = Add-FactoryAsanaComment -Config $Config -Gid ([string]$Task.id) -Text $text
            $serverTime = Get-FactoryNestedValue $requestStory 'created_at'
            if ($serverTime) { $requestedAt = (ConvertTo-FactoryUtcDateTime $serverTime).ToString('o') }
        }
        $gate = [pscustomobject]@{ commit = [string]$Task.commit; requestedAt = $requestedAt; confirmedAt = $null; via = $null }
        Save-FactoryGateProperty -Context $Context -Task $Task -Name 'mergeGate' -Value $gate
        if ($TerminalYes) { throw 'Merge gate request recorded. Review its SHA, then confirm again.' }
        return $false
    }
    if ($gate.confirmedAt) { return $true }
    $via = if ($TerminalYes) { 'terminal' } else { '' }
    if ($asana -and -not $via) {
        $comments = @(Get-FactoryAsanaComments -Config $Config -Gid ([string]$Task.id))
        if (@($comments | Where-Object {
            (Get-FactoryAsanaCommentActor -Text ([string]$_.text)) -eq 'Igor' -and
            [string]$_.text -match '^\s*/merge(?:\s|$)' -and
            (ConvertTo-FactoryUtcDateTime $_.created_at) -gt (ConvertTo-FactoryUtcDateTime $gate.requestedAt)
        }).Count) { $via = 'comment' }
    }
    if (-not $via) { return $false }
    $now = Get-FactoryUtcTimestamp
    if ($asana) { $null = Add-FactoryAsanaComment -Config $Config -Gid ([string]$Task.id) -Text "MERGE GATE (factory): Igor confirmed ($via) at $now. Merging $($Task.commit)." }
    $gate.confirmedAt = $now
    $gate.via = $via
    Save-FactoryGateProperty -Context $Context -Task $Task -Name 'mergeGate' -Value $gate
    return $true
}

function Save-FactoryGateProperty {
    param($Context, $Task, [string]$Name, $Value)
    $lock = Enter-FactoryMutex -ProjectKey ([string]$Context.projectKey)
    try {
        $state = Read-FactoryJson -Path $Context.statePath
        $current = Get-FactoryTask -State $state -TaskId ([string]$Task.id)
        if ([string]$current.commit -ne [string]$Task.commit -or
            [string](Get-FactoryNestedValue $current 'runId') -ne [string](Get-FactoryNestedValue $Task 'runId')) { throw 'Task changed while checking its quality gate.' }
        Set-FactoryProperty -Target $current -Name $Name -Value $Value
        Write-FactoryJsonAtomic -Path $Context.statePath -Value $state
    } finally { Exit-FactoryMutex -Mutex $lock }
    Set-FactoryProperty -Target $Task -Name $Name -Value $Value
}

function Get-FactoryWorkerActivity {
    param($Task, $SessionRow = $null, $Event = $null)
    $times = New-Object Collections.Generic.List[DateTime]
    $session = Get-FactoryNestedValue -Target $Task -Name 'backgroundSession'
    foreach ($value in @((Get-FactoryNestedValue $Task 'launchStartedAt'), (Get-FactoryNestedValue $session 'startedAt'),
        (Get-FactoryNestedValue $session 'lastActivityAt'), (Get-FactoryNestedValue $SessionRow 'updatedAt'),
        (Get-FactoryNestedValue $SessionRow 'lastActivityAt'), (Get-FactoryNestedValue $Event 'capturedAt'))) {
        $parsed = ConvertFrom-FactoryRoundtripTimestamp -Value $value
        if ($parsed.success) { $times.Add($parsed.value) }
    }
    foreach ($path in @((Get-FactoryNestedValue $session 'transcriptPath'), (Get-FactoryNestedValue $SessionRow 'transcriptPath'))) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { $times.Add((Get-Item -LiteralPath $path).LastWriteTimeUtc) }
    }
    if (-not $times.Count) { return $null }
    return ($times | Sort-Object -Descending | Select-Object -First 1)
}
