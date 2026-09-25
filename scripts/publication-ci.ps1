# Durable, non-blocking observation of GitHub Actions for Factory pushes.
# No workflow writes, test lease, or task-state mutation belongs in this module.
Set-StrictMode -Version 2.0
if (-not (Get-Command Read-FactoryJson -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "factory-common.ps1")
}

function Get-FactoryCiPath {
    param($Context)
    Join-Path ([string]$Context.projectData) "publication-ci.json"
}

function Read-FactoryCiJournal {
    param($Context)
    $path = Get-FactoryCiPath $Context
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ version = 1; entries = @() }
    }
    $journal = Read-FactoryJson -Path $path
    if ($null -eq $journal -or [int](Get-FactoryNestedValue $journal "version" 0) -ne 1 -or
        $null -eq $journal.PSObject.Properties['entries']) { throw "Invalid CI journal: $path" }
    if ($journal.entries -isnot [Array]) { throw "Invalid CI entries collection: $path" }
    foreach ($entry in @($journal.entries)) {
        if ($null -eq $entry -or [string](Get-FactoryNestedValue $entry "sha" "") -notmatch '^[a-f0-9]{40}$' -or
            $null -eq $entry.PSObject.Properties['failures'] -or $null -eq $entry.PSObject.Properties['acknowledgements']) {
            throw "Invalid CI entry in $path"
        }
        if ($entry.failures -isnot [Array] -or $entry.acknowledgements -isnot [Array]) { throw "Invalid CI evidence in $path" }
        foreach ($field in @('key', 'repository', 'branch', 'taskId', 'title', 'publishedAt', 'lastPollAt', 'status', 'error', 'runs', 'url')) {
            if ($null -eq $entry.PSObject.Properties[$field]) { throw "Missing CI field '$field' in $path" }
        }
        if ($entry.repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
            $entry.key -cne "$($entry.repository)|$($entry.branch)|$($entry.sha)") { throw "Invalid CI identity in $path" }
        $null = [DateTime]::Parse($entry.publishedAt)
        if ($entry.lastPollAt) { $null = [DateTime]::Parse($entry.lastPollAt) }
        foreach ($failure in $entry.failures) {
            if ([string]$failure.runId -notmatch '^\d+$' -or [int]$failure.attempt -lt 1 -or
                $failure.key -cne "$($failure.runId)/$($failure.attempt)") { throw "Invalid CI failure in $path" }
        }
    }
    return $journal
}

function Get-FactoryCiUnacknowledgedFailures {
    param($Entry)
    $accepted = @($Entry.acknowledgements | ForEach-Object { [string]$_.key })
    @($Entry.failures | Where-Object { [string]$_.key -notin $accepted })
}

function Get-FactoryCiStatus {
    param($Context)
    try {
        $journal = Read-FactoryCiJournal $Context
        $blocking = @($journal.entries | Where-Object { @(Get-FactoryCiUnacknowledgedFailures $_).Count -gt 0 })
        return [pscustomobject]@{
            blocked = $blocking.Count -gt 0; error = ""; entries = @($journal.entries)
            blocking = $blocking; path = Get-FactoryCiPath $Context
        }
    } catch {
        # A damaged journal is not evidence of successful CI.
        return [pscustomobject]@{
            blocked = $true; error = "CI journal unreadable; publications blocked. $($_.Exception.Message)"
            entries = @(); blocking = @(); path = Get-FactoryCiPath $Context
        }
    }
}

function Get-FactoryCiRepository {
    param($Context, $Config, [string]$Remote = "")
    $settings = Get-FactoryNestedValue $Config "ciMonitoring"
    if (-not [bool](Get-FactoryNestedValue $settings "enabled" $true)) { return "" }
    if (-not $Remote) { $Remote = [string](Get-FactoryNestedValue $Config "remote" "origin") }
    $result = Invoke-FactoryNativeProcess -Command git -Arguments @('-C', [string]$Context.repositoryRoot, 'remote', 'get-url', '--push', $Remote) -TimeoutSeconds 3
    if ($result.exitCode -ne 0) { throw "Cannot resolve publication remote for CI: $Remote" }
    $url = ([string]$result.stdout).Trim()
    if ($url -match '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?$') {
        return [string]$Matches[1]
    }
    return "" # Local fixtures and non-GitHub remotes have no Actions observer.
}

function Register-FactoryCiPublication {
    param($Context, $Task, [string]$Slug, [string]$Branch, [string]$Sha)
    if (-not $Slug) { return }
    if ($Sha -notmatch '^[a-f0-9]{40}$') { throw "CI publication requires a full commit SHA." }
    $key = "$Slug|$Branch|$Sha"
    $mutex = Enter-FactoryMutex -ProjectKey "$($Context.projectKey)-ci"
    try {
        $journal = Read-FactoryCiJournal $Context
        if (@($journal.entries | Where-Object { $_.key -ceq $key }).Count) { return }
        $journal.entries = @($journal.entries) + @([pscustomobject]@{
            key = $key; repository = $Slug; branch = $Branch; sha = $Sha
            taskId = [string]$Task.id; title = [string]$Task.title
            publishedAt = Get-FactoryUtcTimestamp; lastPollAt = $null
            status = 'pending'; error = ''; runs = @(); failures = @(); acknowledgements = @()
            url = "https://github.com/$Slug/actions?query=branch%3A$([Uri]::EscapeDataString($Branch))"
        })
        Write-FactoryJsonAtomic -Path (Get-FactoryCiPath $Context) -Value $journal
    } finally { Exit-FactoryMutex $mutex }
}

function Get-FactoryCiRuns {
    param($Context, $Entry, [int]$TimeoutSeconds = 3)
    $endpoint = "repos/$($Entry.repository)/actions/runs?head_sha=$($Entry.sha)&branch=$([Uri]::EscapeDataString([string]$Entry.branch))&event=push&per_page=100"
    $result = Invoke-FactoryNativeProcess -Command gh -Arguments @('api', '--hostname', 'github.com', '--method', 'GET', $endpoint) `
        -WorkingDirectory ([string]$Context.repositoryRoot) -TimeoutSeconds $TimeoutSeconds
    if ($result.exitCode -ne 0) { throw "GitHub Actions read failed: $($result.output)" }
    $response = $result.stdout | ConvertFrom-Json
    if ($null -eq $response.PSObject.Properties['workflow_runs'] -or $null -eq $response.PSObject.Properties['total_count']) {
        throw 'GitHub Actions returned no workflow-run collection.'
    }
    # Never declare success from a truncated list. This bounded snapshot avoids
    # pagination/network waits growing with workflow history.
    return [pscustomobject]@{
        complete = [int]$response.total_count -le @($response.workflow_runs).Count
        runs = @($response.workflow_runs)
    }
}

function Set-FactoryCiObservation {
    param($Entry, $Observation, [string]$ErrorText = "")
    $Entry.lastPollAt = Get-FactoryUtcTimestamp
    if ($ErrorText) {
        $Entry.status = 'unknown'
        $Entry.error = $ErrorText
        return # Preserve known failure evidence through API/auth/timeout errors.
    }
    $runs = @($Observation.runs | Where-Object {
        [string]$_.head_sha -ceq [string]$Entry.sha -and [string]$_.head_branch -ceq [string]$Entry.branch -and
        [string]$_.event -eq 'push'
    } | Group-Object id | ForEach-Object { $_.Group | Sort-Object { [int]$_.run_attempt } -Descending | Select-Object -First 1 })
    $previousRuns = @{}
    foreach ($previousRun in @($Entry.runs)) { $previousRuns[[string]$previousRun.id] = $previousRun }
    $staleSnapshot = $false
    $runs = @(foreach ($run in $runs) {
        $previousRun = $previousRuns[[string]$run.id]
        if ($null -ne $previousRun -and ([int]$run.run_attempt -lt [int]$previousRun.attempt -or
            ([int]$run.run_attempt -eq [int]$previousRun.attempt -and $previousRun.status -eq 'completed' -and $run.status -ne 'completed'))) {
            $staleSnapshot = $true
            continue # A lagging API response cannot revive an acknowledged old attempt.
        }
        $run
    })
    $failures = @{}
    foreach ($failure in @($Entry.failures)) {
        $replacement = @($runs | Where-Object { [string]$_.id -eq [string]$failure.runId -and [int]$_.run_attempt -ge [int]$failure.attempt })
        if ($replacement.Count -eq 1 -and [string]$replacement[0].status -eq 'completed' -and
            [string]$replacement[0].conclusion -eq 'success') { continue }
        $failures[[string]$failure.runId] = $failure
    }
    foreach ($run in $runs) {
        if ([string]$run.conclusion -notin @('failure', 'timed_out', 'action_required', 'startup_failure')) { continue }
        $knownFailure = $failures[[string]$run.id]
        if ($null -ne $knownFailure -and [int]$run.run_attempt -lt [int]$knownFailure.attempt) { continue }
        $failures[[string]$run.id] = [pscustomobject]@{
            key = "$($run.id)/$($run.run_attempt)"; runId = [string]$run.id; attempt = [int]$run.run_attempt
            name = [string]$run.name; conclusion = [string]$run.conclusion
            url = "https://github.com/$($Entry.repository)/actions/runs/$($run.id)"
        }
    }
    $Entry.failures = @($failures.Values | Sort-Object key)
    foreach ($run in $runs) { $previousRuns[[string]$run.id] = [pscustomobject]@{
        id = [string]$run.id; attempt = [int]$run.run_attempt; name = [string]$run.name
        status = [string]$run.status; conclusion = [string]$run.conclusion
        url = "https://github.com/$($Entry.repository)/actions/runs/$($run.id)"
    } }
    $Entry.runs = @($previousRuns.Values | Sort-Object id)
    $missingRuns = @($Entry.runs | Where-Object { $_.id -notin @($runs | ForEach-Object { [string]$_.id }) }).Count -gt 0
    $Entry.error = if (-not $Observation.complete -or $staleSnapshot -or $missingRuns) { 'Incomplete or stale Actions snapshot; CI is unverified.' } else { '' }
    $Entry.status = if ($Entry.failures.Count) { 'failed' }
        elseif ($Entry.error) { 'unknown' }
        elseif (-not $runs.Count -or @($runs | Where-Object { $_.status -ne 'completed' }).Count) { 'pending' }
        elseif (-not @($runs | Where-Object { $_.conclusion -eq 'success' }).Count -or
            @($runs | Where-Object { $_.conclusion -notin @('success', 'skipped') }).Count) { 'unverified' }
        else { 'passed' }
}

function Sync-FactoryPublicationCi {
    param($Context)
    # One poller per project, independent of the task-state/test-lane locks.
    # Network I/O holds only this nonblocking poll ownership, never the journal
    # write mutex: concurrent pushes/acknowledgements are merged below.
    try { $pollMutex = Enter-FactoryMutex -ProjectKey "$($Context.projectKey)-ci-poll" -TimeoutMilliseconds 0 }
    catch { return Get-FactoryCiStatus $Context }
    try {
        $snapshot = Get-FactoryCiStatus $Context
        if ($snapshot.error -or -not $snapshot.entries.Count) { return $snapshot }
        $now = [DateTime]::UtcNow
        $deadline = $now.AddSeconds(8)
        $due = @($snapshot.entries | Where-Object {
            $age = ($now - [DateTime]::Parse($_.publishedAt).ToUniversalTime()).TotalDays
            $unresolved = @(Get-FactoryCiUnacknowledgedFailures $_).Count -gt 0
            $interval = if ($_.status -in @('passed', 'unverified')) { 300 } else { 30 }
            ($age -le 7 -or $unresolved) -and (-not $_.lastPollAt -or
                ($now - [DateTime]::Parse($_.lastPollAt).ToUniversalTime()).TotalSeconds -ge $interval)
        } | Sort-Object lastPollAt | Select-Object -First 10)
        foreach ($entry in $due) {
            if ([DateTime]::UtcNow -ge $deadline) { break }
            $observation = $null; $pollError = ''
            try { $observation = Get-FactoryCiRuns -Context $Context -Entry $entry }
            catch { $pollError = $_.Exception.Message }
            $mutex = Enter-FactoryMutex -ProjectKey "$($Context.projectKey)-ci"
            try {
                $journal = Read-FactoryCiJournal $Context
                $current = @($journal.entries | Where-Object { $_.key -ceq $entry.key })
                if ($current.Count -ne 1) { throw 'CI publication disappeared during observation.' }
                Set-FactoryCiObservation -Entry $current[0] -Observation $observation -ErrorText $pollError
                Write-FactoryJsonAtomic -Path (Get-FactoryCiPath $Context) -Value $journal
            } finally { Exit-FactoryMutex $mutex }
        }
        return Get-FactoryCiStatus $Context
    } catch {
        $status = Get-FactoryCiStatus $Context
        $status.error = "CI observation unavailable: $($_.Exception.Message)"
        return $status
    } finally { Exit-FactoryMutex $pollMutex }
}

function Confirm-FactoryCiFailure {
    param($Context, [string]$Sha, [string]$Reason)
    if ($Sha -notmatch '^[a-f0-9]{40}$' -or -not $Reason.Trim()) {
        throw 'Use: factory ci acknowledge <full-published-sha> "operator reason"'
    }
    $mutex = Enter-FactoryMutex -ProjectKey "$($Context.projectKey)-ci"
    try {
        $journal = Read-FactoryCiJournal $Context
        $count = 0
        foreach ($entry in @($journal.entries | Where-Object { $_.sha -ceq $Sha })) {
            foreach ($failure in @(Get-FactoryCiUnacknowledgedFailures $entry)) {
                $entry.acknowledgements = @($entry.acknowledgements) + @([pscustomobject]@{
                    key = [string]$failure.key; reason = $Reason.Trim(); acknowledgedAt = Get-FactoryUtcTimestamp
                })
                $count++
            }
        }
        if (-not $count) { throw 'No unacknowledged CI failures for that published SHA.' }
        Write-FactoryJsonAtomic -Path (Get-FactoryCiPath $Context) -Value $journal
    } finally { Exit-FactoryMutex $mutex }
    return Get-FactoryCiStatus $Context
}

function Get-FactoryCiAttentionEvents {
    param($Context)
    $status = Get-FactoryCiStatus $Context
    if ($status.error) {
        [pscustomobject]@{ kind = 'ci-monitor'; taskId = $null; title = 'Publication CI'; status = 'unknown'
            reason = $status.error; command = 'factory ci'; aiActionable = $true; humanDecision = $false }
    }
    foreach ($entry in $status.entries) {
        $failures = @(Get-FactoryCiUnacknowledgedFailures $entry)
        if (-not $failures.Count -and -not $entry.error) { continue }
        $reason = if ($failures.Count) {
            "Publications blocked: $($entry.branch) $($entry.sha). " +
            (($failures | ForEach-Object { "$($_.name): $($_.conclusion) (attempt $($_.attempt)) $($_.url)" }) -join '; ')
        } else { "CI is unverified for $($entry.branch) $($entry.sha): $($entry.error)" }
        [pscustomobject]@{
            kind = 'publication-ci'; taskId = $entry.taskId; title = $entry.title
            status = $(if ($failures.Count) { 'failed' } else { 'unknown' })
            reason = $reason; command = 'factory ci'; occurredAt = $entry.publishedAt
            aiActionable = $true; humanDecision = $false; includeInDefaultWait = $true
        }
    }
}
