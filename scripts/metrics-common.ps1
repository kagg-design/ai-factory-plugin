. (Join-Path $PSScriptRoot 'asana-common.ps1')

function Get-FactoryMetricsSeeds {
    return @{
        '1219603269391307' = @('1219601066607741', 'verification')
        '1219603808377002' = @('1219601066591116', 'verification')
        '1219607755346455' = @('1219600878769036', 'external')
        '1219609793800273' = @('1219600856229897', 'verification')
        '1219610138861663' = @('1219600856222205', 'verification')
    }
}

function Get-FactoryMetricDate {
    param($Value)
    if (-not $Value) { return $null }
    try { return ConvertTo-FactoryUtcDateTime -Value $Value } catch { return $null }
}

function Get-FactoryMetricPercentile {
    param([object[]]$Values, [double]$Percentile = 0.5)
    $sorted = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if (-not $sorted.Count) { return $null }
    $position = ($sorted.Count - 1) * $Percentile
    $low = [int][Math]::Floor($position)
    $high = [int][Math]::Ceiling($position)
    return [Math]::Round(($sorted[$low] + ($sorted[$high] - $sorted[$low]) * ($position - $low)), 3)
}

function Get-FactoryDefectRecord {
    param($Task, $Config, [string]$BugOption, $Seeds, $Unparsed)
    if ((Get-FactoryAsanaField -Task $Task -Gid ([string]$Config.asana.fields.type)) -ne $BugOption) { return $null }
    $notes = [string]$Task.notes
    $originLines = @([regex]::Matches($notes, '(?im)^\s*Escaped-from[^\r\n]*'))
    $foundLines = @([regex]::Matches($notes, '(?im)^\s*Found-in[^\r\n]*'))
    $regressionLines = @([regex]::Matches($notes, '(?im)^\s*Regression[^\r\n]*'))
    $origins = @(); $found = 'unknown'; $source = ''; $regression = $false
    if ($originLines.Count) {
        $source = 'line'
        if ($originLines.Count -ne 1 -or $originLines[0].Value -notmatch '^\s*Escaped-from:\s*(\d+(?:\s*,\s*\d+)*)\s*$') {
            $Unparsed.Add("$($Task.gid): malformed or duplicate Escaped-from line.")
            return $null
        }
        $origins = @($Matches[1] -split '\s*,\s*' | Select-Object -Unique)
    } elseif ($Seeds.ContainsKey([string]$Task.gid)) {
        $seed = $Seeds[[string]$Task.gid]; $source = 'seed'; $origins = @($seed[0]); $found = $seed[1]
    } else {
        $reporter = Get-FactoryAsanaField -Task $Task -Gid ([string]$Config.asana.fields.reporter)
        if ((Get-FactoryAsanaField -Task $Task -Gid ([string]$Config.asana.fields.factory)) -and $reporter -in @('access-orchestrator', 'billing-orchestrator')) { $source = 'fallback' } else { return $null }
    }
    if ($foundLines.Count) {
        if ($foundLines.Count -eq 1 -and $foundLines[0].Value -match '^\s*Found-in:\s*(verification|ci|stage|prod|external)\s*$') { $found = $Matches[1].ToLowerInvariant() }
        else { $Unparsed.Add("$($Task.gid): malformed or duplicate Found-in line."); $found = 'unknown' }
    } elseif ($source -eq 'line') { $Unparsed.Add("$($Task.gid): missing Found-in line.") }
    if ($source -eq 'fallback') { $found = 'unknown' }
    if ($regressionLines.Count) {
        if ($regressionLines.Count -eq 1 -and $regressionLines[0].Value -match '^\s*Regression:\s*(yes|no)\s*$') { $regression = $Matches[1] -eq 'yes' }
        else { $Unparsed.Add("$($Task.gid): malformed or duplicate Regression line.") }
    }
    return [pscustomobject]@{
        gid = [string]$Task.gid; name = [string]$Task.name; origins = @($origins); foundIn = $found
        regression = $regression; createdAt = Get-FactoryMetricDate $Task.created_at; source = $source
        repos = @(); originDates = @(); days = @(); findTimes = @()
    }
}

function Get-FactoryMetrics {
    param($Config, [object[]]$Tasks, $Stories, [string]$BugOption, [DateTime]$Since, [DateTime]$Until)
    $unparsed = New-Object Collections.Generic.List[string]
    $done = New-Object Collections.Generic.List[object]
    $repos = New-Object Collections.Generic.List[string]
    foreach ($task in $Tasks) {
        $repo = Resolve-FactoryTaskRepo -Config $Config -Notes ([string]$task.notes)
        if (-not $repos.Contains($repo)) { $repos.Add($repo) }
        if ((Get-FactoryAsanaField -Task $task -Gid ([string]$Config.asana.fields.factory)) -eq [string]$Config.asana.fields.done) {
            $at = Get-FactoryMetricDate $task.completed_at
            if ($null -eq $at) { $unparsed.Add("$($task.gid): Done task has no completed_at."); continue }
            if ($at -le $Until) { $done.Add([pscustomobject]@{ gid = [string]$task.gid; repo = $repo; at = $at }) }
        }
    }
    $seeds = Get-FactoryMetricsSeeds
    $defects = New-Object Collections.Generic.List[object]
    foreach ($task in $Tasks) {
        $defect = Get-FactoryDefectRecord -Task $task -Config $Config -BugOption $BugOption -Seeds $seeds -Unparsed $unparsed
        if ($null -eq $defect) { continue }
        if ($null -eq $defect.createdAt) { $unparsed.Add("$($task.gid): defect has no valid created_at."); continue }
        if ($defect.createdAt -gt $Until) { continue }
        $valid = $true; $projects = @(); $dates = @(); $days = @(); $findTimes = @()
        foreach ($origin in $defect.origins) {
            $originDone = @($done | Where-Object { $_.gid -eq $origin })
            if (-not $originDone.Count) { $unparsed.Add("$($task.gid): origin $origin is not a Done task by Until."); $valid = $false; continue }
            $projects += $originDone[0].repo; $dates += $originDone[0].at
            $delay = ($defect.createdAt - $originDone[0].at).TotalDays
            if ($delay -ge 0) { $days += $delay; $findTimes += [pscustomobject]@{ repo = $originDone[0].repo; days = $delay } } else { $unparsed.Add("$($task.gid): found before origin $origin completed.") }
        }
        if (-not $valid) { continue }
        if ($defect.source -eq 'fallback') { $projects = @(Resolve-FactoryTaskRepo -Config $Config -Notes ([string]$task.notes)) }
        $defect.repos = @($projects | Select-Object -Unique); $defect.originDates = @($dates); $defect.days = @($days)
        $defect.findTimes = @($findTimes)
        $defects.Add($defect)
    }
    $reports = New-Object Collections.Generic.List[object]
    foreach ($repo in @(@($repos.ToArray() | Sort-Object) + @('_all'))) {
        $repoTasks = @($Tasks | Where-Object { $repo -eq '_all' -or (Resolve-FactoryTaskRepo -Config $Config -Notes ([string]$_.notes)) -eq $repo })
        $repoDone = @($done | Where-Object { $repo -eq '_all' -or $_.repo -eq $repo })
        $repoDefects = @($defects | Where-Object { $repo -eq '_all' -or $repo -in $_.repos })
        $periods = @{}
        foreach ($period in @('all', 'window')) {
            $cohort = @($repoDone | Where-Object { $period -eq 'all' -or $_.at -ge $Since })
            $found = @($repoDefects | Where-Object { $period -eq 'all' -or $_.createdAt -ge $Since })
            $escapedOrigins = @($cohort | Where-Object { $id = $_.gid; @($repoDefects | Where-Object { $id -in $_.origins }).Count })
            $cycles = @(); $missing = 0; $questions = 0; $failedComments = 0
            foreach ($task in $repoTasks) {
                foreach ($story in @($Stories[[string]$task.gid])) {
                    if ($null -eq $story) { continue }
                    $at = Get-FactoryMetricDate $story.created_at
                    if ($null -eq $at -or $at -gt $Until -or ($period -eq 'window' -and $at -lt $Since)) { continue }
                    if ([string]$story.text -match '^\s*QUESTION \(factory\):') { $questions++ }
                    if ([string]$story.text -match '^\s*FAILED \(factory\):') { $failedComments++ }
                }
            }
            foreach ($completed in $cohort) {
                $taken = $null; $cycle = $null
                foreach ($story in @($Stories[$completed.gid] | Sort-Object created_at, gid)) {
                    if ($null -eq $story) { continue }
                    $at = Get-FactoryMetricDate $story.created_at
                    if ($null -eq $at -or $at -gt $Until) { continue }
                    if ([string]$story.text -match '^\s*TAKEN \(factory\):') { $taken = $at }
                    if ([string]$story.text -match '^\s*DONE \(factory\):' -and $null -ne $taken -and $at -ge $taken) { $cycle = ($at - $taken).TotalHours }
                }
                if ($null -eq $cycle) { $missing++ } else { $cycles += $cycle }
            }
            $byFound = [ordered]@{}
            foreach ($environment in @('verification', 'ci', 'stage', 'prod', 'external', 'unknown')) { $byFound[$environment] = @($found | Where-Object { $_.foundIn -eq $environment }).Count }
            $timesToFind = @($found | ForEach-Object { $_.findTimes | Where-Object { $repo -eq '_all' -or $_.repo -eq $repo } | ForEach-Object { $_.days } })
            $periods[$period] = [pscustomobject]@{
                done = $cohort.Count; escaped = $found.Count; escapedOrigins = $escapedOrigins.Count
                escapeRate = $(if ($cohort.Count) { [Math]::Round($escapedOrigins.Count / $cohort.Count, 4) } else { 0 })
                defectsPerDone = $(if ($cohort.Count) { [Math]::Round($found.Count / $cohort.Count, 4) } else { 0 })
                byFound = $byFound; regressions = @($found | Where-Object { $_.regression }).Count
                medianDaysToFind = Get-FactoryMetricPercentile -Values $timesToFind
                medianCycleHours = Get-FactoryMetricPercentile -Values $cycles
                p90CycleHours = Get-FactoryMetricPercentile -Values $cycles -Percentile 0.9
                missingCycle = $missing; questions = $questions; failedComments = $failedComments
                failedNow = @($repoTasks | Where-Object { (Get-FactoryAsanaField -Task $_ -Gid ([string]$Config.asana.fields.factory)) -eq [string]$Config.asana.fields.failed }).Count
            }
        }
        $reports.Add([pscustomobject]@{ repo = $repo; all = $periods.all; window = $periods.window; defects = $repoDefects; unparsed = @($unparsed.ToArray()) })
    }
    return $reports.ToArray()
}

function Format-FactoryMetrics {
    param($Report, [DateTime]$Since, [DateTime]$Until)
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add("## $($Report.repo)")
    $lines.Add("Window: $($Since.ToString('o')) to $($Until.ToString('o')) (UTC, inclusive).")
    foreach ($period in @('all', 'window')) {
        $m = $Report.$period
        $lines.Add("### $period")
        $lines.Add("Done: $($m.done); escaped: $($m.escaped); escape rate: $([Math]::Round($m.escapeRate * 100, 2))% ($($m.escapedOrigins) Done origins); defects/Done: $($m.defectsPerDone); regressions: $($m.regressions).")
        $lines.Add('Found-in: ' + (($m.byFound.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') + '.')
        $find = if ($null -eq $m.medianDaysToFind) { 'n/a' } else { [string]$m.medianDaysToFind }
        $median = if ($null -eq $m.medianCycleHours) { 'n/a' } else { [string]$m.medianCycleHours }
        $p90 = if ($null -eq $m.p90CycleHours) { 'n/a' } else { [string]$m.p90CycleHours }
        $lines.Add("Time to find median: $find days. Cycle median: $median hours; p90: $p90 hours; excluded without both comments: $($m.missingCycle).")
        $lines.Add("Failed now: $($m.failedNow); FAILED comments: $($m.failedComments); questions: $($m.questions).")
    }
    $lines.Add('### Fallback — needs an Escaped-from line')
    $fallback = @($Report.defects | Where-Object { $_.source -eq 'fallback' })
    if (-not $fallback.Count) { $lines.Add('None.') }
    foreach ($bug in $fallback) { $lines.Add("- $($bug.gid): $($bug.name) — origin unknown, Found-in unknown.") }
    $lines.Add('### Unparsed lines')
    if (-not $Report.unparsed.Count) { $lines.Add('None.') }
    foreach ($line in $Report.unparsed) { $lines.Add('- ' + $line) }
    return $lines.ToArray() -join "`n"
}
