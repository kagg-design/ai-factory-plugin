[CmdletBinding()]
param(
    [string]$Repository = '.',
    [DateTimeOffset]$Since = [DateTimeOffset]::UtcNow.AddDays(-7),
    [DateTimeOffset]$Until = [DateTimeOffset]::UtcNow,
    [switch]$Post,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\factory-common.ps1')
. (Join-Path $PSScriptRoot 'scripts\metrics-common.ps1')
$sinceUtc = $Since.UtcDateTime; $untilUtc = $Until.UtcDateTime
if ($sinceUtc -gt $untilUtc) { throw 'Since must be before Until.' }
# DryRun never initializes or migrates config/state, and never acquires a lock
# that writes runtime diagnostics. It only reads the existing configuration.
$context = & (Join-Path $PSScriptRoot 'scripts\project-context.ps1') -Repository $Repository -Initialize:(-not $DryRun) | ConvertFrom-Json
$defaults = Read-FactoryJson -Path (Join-Path $PSScriptRoot 'config.default.json')
$config = if (Test-Path -LiteralPath $context.configPath) { Read-FactoryJson -Path $context.configPath } else { $defaults }
# A first dry run also works with an older private config: fill defaults only
# in memory, so previewing the report never migrates or rewrites that config.
Add-MissingFactoryProperties -Target $config -Defaults $defaults
$typeGid = [string]$config.asana.fields.type
$type = (Invoke-FactoryAsana -Config $config -Path "/custom_fields/$typeGid`?opt_fields=enum_options.gid,enum_options.name").data
$bugOptions = @($type.enum_options | Where-Object { [string]$_.name -eq 'Bug' })
if ($bugOptions.Count -ne 1) { throw 'Type field must contain exactly one Bug option.' }
$fields = 'gid,name,notes,completed,completed_at,created_at,custom_fields,custom_fields.gid,custom_fields.enum_value.gid,custom_fields.text_value,permalink_url'
$query = "/workspaces/$($config.asana.workspace)/tasks/search?projects.any=$($config.asana.project)&custom_fields.$($config.asana.fields.factory).is_set=true&opt_fields=$fields"
$tasks = @(Get-FactoryAsanaSearchTasks -Config $config -Path $query -FallbackPath "/projects/$($config.asana.project)/tasks?limit=100&completed_since=1970-01-01T00:00:00Z&opt_fields=$fields" | Where-Object {
    Get-FactoryAsanaField -Task $_ -Gid ([string]$config.asana.fields.factory)
})
$stories = @{}
foreach ($task in $tasks) {
    $created = Get-FactoryMetricDate $task.created_at
    if ($null -ne $created -and $created -le $untilUtc) { $stories[[string]$task.gid] = @(Get-FactoryAsanaComments -Config $config -Gid ([string]$task.gid)) }
}
$reports = @(Get-FactoryMetrics -Config $config -Tasks $tasks -Stories $stories -BugOption ([string]$bugOptions[0].gid) -Since $sinceUtc -Until $untilUtc)
$token = Get-FactoryAsanaToken -Config $config
function Protect-MetricsText {
    param([string]$Text)
    if ($token) { return $Text.Replace($token, '[REDACTED]') }
    return $Text
}
$summary = '[factory-metrics]' + "`n" + ((@($reports | ForEach-Object { Format-FactoryMetrics -Report $_ -Since $sinceUtc -Until $untilUtc })) -join "`n`n")
$summary += "`n`nEscape rate uses the Done cohort for each period and defects found by Until. Defects/Done uses defects created in the period. Multi-project defects count once per origin project and once in _all. Fallback origins remain unknown. Failed now and FAILED comments are separate counts and can overlap. Percentiles use linear interpolation."
$summary = Protect-MetricsText $summary
if ($DryRun) { Write-Output $summary; return }
$mutex = Enter-FactoryMutex -ProjectKey "$($context.projectKey)-metrics"
try {
    foreach ($report in $reports) {
        if ($report.repo -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$') { throw 'Unsafe metrics project name.' }
        $folder = Join-Path (Join-Path $context.projectData 'metrics') $report.repo
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $rows = @($report.defects | ForEach-Object {
            [pscustomobject][ordered]@{
                gid = $_.gid; name = $_.name; origin_gids = $(if ($_.origins.Count) { $_.origins -join ',' } else { 'unknown' })
                found_in = $_.foundIn; regression = $_.regression; created_at = $_.createdAt.ToString('o')
                origin_completed_at = @($_.originDates | ForEach-Object { $_.ToString('o') }) -join ','
                days_to_find = @($_.days | ForEach-Object { $_.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture) }) -join ','
                source = $_.source
            }
        })
        $csv = if ($rows.Count) { @($rows | ConvertTo-Csv -NoTypeInformation) -join "`r`n" } else {
            '"gid","name","origin_gids","found_in","regression","created_at","origin_completed_at","days_to_find","source"'
        }
        [IO.File]::WriteAllText((Join-Path $folder 'escaped-defects.csv'), (Protect-MetricsText $csv) + "`r`n", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $folder 'latest.md'), (Protect-MetricsText (Format-FactoryMetrics -Report $report -Since $sinceUtc -Until $untilUtc)), (New-Object Text.UTF8Encoding($false)))
        if (-not (Test-Path -LiteralPath (Join-Path $folder 'weekly.csv'))) {
            [IO.File]::WriteAllText((Join-Path $folder 'weekly.csv'), '"run_at","since","until","done","escaped","escape_rate","defects_per_done","questions","failed","failed_now","failed_comments","median_cycle_hours","p90_cycle_hours"' + "`r`n", (New-Object Text.UTF8Encoding($true)))
        }
        if ($Post) {
            $m = $report.window
            $weekly = [pscustomobject][ordered]@{
                run_at = [DateTime]::UtcNow.ToString('o'); since = $sinceUtc.ToString('o'); until = $untilUtc.ToString('o')
                done = $m.done; escaped = $m.escaped; escape_rate = $m.escapeRate; defects_per_done = $m.defectsPerDone
                questions = $m.questions; failed = $m.failedNow + $m.failedComments; failed_now = $m.failedNow; failed_comments = $m.failedComments
                median_cycle_hours = $m.medianCycleHours; p90_cycle_hours = $m.p90CycleHours
            }
            $weekly | Export-Csv -LiteralPath (Join-Path $folder 'weekly.csv') -NoTypeInformation -Append -Encoding UTF8
        }
    }
    $metricsTask = [string](Get-FactoryNestedValue $config 'metricsTaskGid' '')
    if ($Post -and $metricsTask) { $null = Add-FactoryAsanaComment -Config $config -Gid $metricsTask -Text $summary }
} finally { Exit-FactoryMutex -Mutex $mutex }
Write-Output $summary
