[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Repository, [switch]$Preview)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
. (Join-Path $PSScriptRoot 'completed-archive.ps1')
$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository | ConvertFrom-Json
$config = Read-FactoryJson $context.configPath
$candidates = New-Object 'Collections.Generic.List[object]'
$sources = New-Object 'Collections.Generic.List[object]'
$archivedAt = Get-FactoryUtcTimestamp

foreach ($relative in @(
    'state.json.c90a745db00b4ba59ed541b5dc8a69dd.tmp',
    'state.json.pre-reboot-fix.bak',
    'archive\completed-tasks.json',
    'state.json'
)) {
    $path = Join-Path $context.projectData $relative
    $source = [pscustomobject][ordered]@{ source = $relative; present = [IO.File]::Exists($path); scanned = 0; eligible = 0; skipped = 0; added = 0; duplicates = 0; retained = $true }
    $sources.Add($source)
    if (-not $source.present) { continue }
    $document = Read-FactoryJson $path
    $tasks = @(if ($document -is [Array]) { $document } else { Get-FactoryNestedValue $document 'tasks' @() })
    $source.scanned = $tasks.Count
    foreach ($task in $tasks) {
        $status = [string](Get-FactoryNestedValue $task 'status' '')
        if ($status -notin @('done', 'rejected')) { $source.skipped++; continue }
        $outcome = if ($status -eq 'rejected') { 'rejected' } elseif ([string]$config.productionBranch -or $null -ne (Get-FactoryNestedValue $task 'production')) { 'production' } else { 'development' }
        $commit = [string](Get-FactoryNestedValue $task 'commit' '')
        if ($commit -match '^[a-fA-F0-9]{7,39}$') {
            $resolved = & git -C $context.repositoryRoot rev-parse --verify "$commit^{commit}" 2>$null
            if ($LASTEXITCODE -eq 0) { Set-FactoryProperty $task 'commit' ([string]$resolved) }
        }
        $row = New-FactoryCompletedArchiveRow -Task $task -Outcome $outcome -ArchivedAt $archivedAt
        $candidates.Add([pscustomobject]@{ row = $row; source = $source })
        $source.eligible++
    }
}

$branch = if ([string]$config.productionBranch) { [string]$config.productionBranch } else { [string]$config.developmentBranch }
$ref = "$([string]$config.remote)/$branch"
$revision = (& git -C $context.repositoryRoot rev-parse --verify "$ref^{commit}" 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $revision) { throw "Cannot seed history: local publication ref '$ref' is unavailable. Fetch it before seeding." }
$gitSource = [pscustomobject][ordered]@{
    source = "git:$ref"; revision = $revision; scanned = 0; eligible = 0; skipped = 0; added = 0; duplicates = 0
    distinctSubjectIds = 0; afterSeptember4 = 0; earlierHistory = 0; excludedCommits = @()
}
$sources.Add($gitSource)
$subjectIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$log = @(& git -C $context.repositoryRoot log $revision '--format=%H%x09%cI%x09%s' --reverse)
if ($LASTEXITCODE -ne 0) { throw "Could not read git history for '$ref'." }
foreach ($line in $log) {
    $parts = ([string]$line).Split(@([char]9), 3)
    if ($parts.Length -ne 3 -or $parts[2] -notmatch '^(?:fix|feat)\(([^)]+)\):\s*(.*)$') { continue }
    $id = $Matches[1]; $title = $Matches[2]
    $gitSource.scanned++
    [void]$subjectIds.Add($id)
    # Documented false subject, not an implementation. Do not generalize this
    # to all documentation commits: other documentation tasks are real history.
    if ($parts[0] -eq '553ccc6ac3cafbda2418ea26ba5cfbd79afe73b6') {
        $gitSource.skipped++
        $gitSource.excludedCommits += $parts[0]
        continue
    }
    if ($parts[1].Substring(0, 10) -ge '2026-09-04') { $gitSource.afterSeptember4++ } else { $gitSource.earlierHistory++ }
    $task = [pscustomobject]@{ id = $id; title = $title; commit = $parts[0]; attempts = 0; source = [pscustomobject]@{ adapter = 'git'; id = $id } }
    $outcome = if ([string]$config.productionBranch) { 'production' } else { 'development' }
    $row = New-FactoryCompletedArchiveRow -Task $task -Outcome $outcome -LandedAt $parts[1] -ArchivedAt $archivedAt
    $candidates.Add([pscustomobject]@{ row = $row; source = $gitSource })
    $gitSource.eligible++
}
$gitSource.distinctSubjectIds = $subjectIds.Count

$mutex = Enter-FactoryMutex $context.projectKey
try {
    $archive = Read-FactoryCompletedArchive $context
    $keys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $producedIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $rejectedIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $pending = New-Object 'Collections.Generic.List[object]'
    foreach ($row in $archive.rows) {
        [void]$keys.Add((Get-FactoryArchiveKey $row))
        if ($row.outcome -eq 'rejected') { [void]$rejectedIds.Add([string]$row.id) } else { [void]$producedIds.Add([string]$row.id) }
    }
    foreach ($candidate in $candidates) {
        $row = $candidate.row
        if (-not $keys.Add((Get-FactoryArchiveKey $row))) { $candidate.source.duplicates++; continue }
        $candidate.source.added++
        $pending.Add($row)
        if ($row.outcome -eq 'rejected') { [void]$rejectedIds.Add([string]$row.id) } else { [void]$producedIds.Add([string]$row.id) }
    }
    if (-not $Preview) { $null = Add-FactoryCompletedArchiveRows -Context $context -Rows $pending.ToArray() }
    [ordered]@{
        archivePath = $archive.path; preview = [bool]$Preview; added = $pending.Count; rows = $keys.Count
        completedDistinctIds = $producedIds.Count; rejectedDistinctIds = $rejectedIds.Count
        countMeaning = 'Distinct task IDs with production or development outcomes; rejected outcomes are excluded.'
        sources = $sources.ToArray(); warnings = $archive.warnings
        legacyFiles = 'Both snapshots and archive/completed-tasks.json are retained unchanged.'
        gitHistory = 'All reachable fix/feat subjects are included, including older history missing from snapshots. Git dates are commit timestamps.'
    } | ConvertTo-Json -Depth 8
} finally { Exit-FactoryMutex $mutex }
