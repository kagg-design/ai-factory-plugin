param([string]$PluginRoot, [switch]$ObserveBaseline)

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\completed-archive.ps1')
$archiveFixture = Join-Path ([IO.Path]::GetTempPath()) ('factory-archive-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $archiveFixture 'repository'
$savedHome = $env:CLAUDE_FACTORY_HOME
function Get-ArchiveTestStatus {
    param([string[]]$Options = @())
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') status @Options -Repository $repository -NoReconcile | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Archive fixture status failed.' }
    if ($output -notmatch 'COMPLETED[^\d]*(\d+)') { throw "Completed figure missing: $output" }
    return [pscustomobject]@{ count = [int]$Matches[1]; text = $output }
}
function Assert-ArchiveFixture {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function New-ArchiveFixtureTask {
    param([string]$Id, [string]$Commit, [string]$Status = 'done', [string]$Date = '2026-09-01T12:00:00Z')
    return [pscustomobject]@{
        id = $Id; title = "Fixture $Id"; commit = $Commit; status = $Status; attempts = 2
        updatedAt = $Date; brief = ('Unwanted large brief. ' * 8000)
        source = [pscustomobject]@{ adapter = 'local'; id = $Id; url = "https://example.test/tasks/$Id" }
    }
}
try {
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    & git init --quiet $repository
    $env:CLAUDE_FACTORY_HOME = Join-Path $archiveFixture 'runtime'
    $context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
    $archivePath = Join-Path $context.projectData 'archive\completed-tasks.jsonl'
    $mutex = Enter-FactoryMutex $context.projectKey
    try {
        $state = Read-FactoryJson $context.statePath
        $state.tasks = @(1..2 | ForEach-Object { [pscustomobject]@{
            id = "archive-$_"; title = "Completed task $_"; status = 'done'; commit = ([string]$_ * 40)
            attempts = 1; source = $null; updatedAt = '2026-09-01T12:00:00Z'
        } })
        Write-FactoryJsonAtomic $context.statePath $state
    } finally { Exit-FactoryMutex $mutex }
    if (-not $ObserveBaseline) {
        $missing = Get-ArchiveTestStatus
        Assert-ArchiveFixture ($missing.count -eq 2 -and $missing.text.Contains('Archive missing') -and $missing.text.Contains('live completed task IDs only')) 'Missing archive must explicitly report only the live count.'
    }
    $mutex = Enter-FactoryMutex $context.projectKey
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $archivePath) -Force | Out-Null
        $rows = @($state.tasks | ForEach-Object { [ordered]@{
            id = $_.id; title = $_.title; outcome = 'production'; commit = $_.commit
            landedAt = $_.updatedAt; attempts = 1; source = $null; archivedAt = $_.updatedAt
        } | ConvertTo-Json -Compress })
        [IO.File]::WriteAllText($archivePath, ($rows -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    } finally { Exit-FactoryMutex $mutex }
    $before = Get-ArchiveTestStatus
    $mutex = Enter-FactoryMutex $context.projectKey
    try {
        $blank = Read-FactoryJson (Join-Path $PluginRoot 'resources\state.template.json')
        # Deliberately simulate ledger loss only in this disposable runtime.
        Write-FactoryJsonAtomic $context.statePath $blank -RemovedTaskIds @('archive-1', 'archive-2')
    } finally { Exit-FactoryMutex $mutex }
    $after = Get-ArchiveTestStatus
    if ($ObserveBaseline) {
        if ($before.count -ne 2 -or $after.count -ne 0) { throw "Unexpected baseline: $($before.count) -> $($after.count)." }
        Write-Host "ARCHIVE BASELINE: completed count fell from $($before.count) to $($after.count) after wiping the ledger, despite 2 archived rows."
        return
    }
    if ($before.count -ne 2 -or $after.count -ne 2) { throw "Completed count did not survive ledger loss: $($before.count) -> $($after.count)." }
    Write-Host 'Completed archive count survives a wiped ledger and deduplicates live done rows.'

    # Preserve a partial tail when appending the next completion, and keep the
    # warning visible without losing the preceding valid history.
    [IO.File]::AppendAllText($archivePath, '{"id":"torn', (New-Object Text.UTF8Encoding($false)))
    $torn = Get-ArchiveTestStatus
    Assert-ArchiveFixture ($torn.count -eq 2 -and $torn.text.Contains('torn final line')) 'A torn last row must warn and preserve the valid count.'
    $prefix = [IO.File]::ReadAllText($archivePath)
    $newRow = New-FactoryCompletedArchiveRow (New-ArchiveFixtureTask 'newest-row' ('a' * 40) -Date '2026-09-12T12:00:00Z') production
    $rejectRow = New-FactoryCompletedArchiveRow (New-ArchiveFixtureTask 'rejected-row' '') rejected
    $refused = $false
    try { $null = Add-FactoryCompletedArchiveRows $context @($newRow) } catch { $refused = $_.Exception.Message.Contains('requires the project mutex') }
    Assert-ArchiveFixture $refused 'An append without the project mutex was accepted.'
    $mutex = Enter-FactoryMutex $context.projectKey
    try {
        $null = Add-FactoryCompletedArchiveRows $context @($newRow, $rejectRow)
        $firstBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($archivePath))
        $null = Add-FactoryCompletedArchiveRows $context @($newRow, $rejectRow)
        Assert-ArchiveFixture ($firstBytes -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($archivePath))) 'Repeated appends changed archive bytes.'
    } finally { Exit-FactoryMutex $mutex }
    Assert-ArchiveFixture ([IO.File]::ReadAllText($archivePath).StartsWith($prefix, [StringComparison]::Ordinal)) 'Append changed existing bytes after a torn tail.'
    $limited = Get-ArchiveTestStatus -Options @('done', '--limit', '1')
    Assert-ArchiveFixture ($limited.count -eq 3 -and $limited.text.Contains('newest-row') -and -not $limited.text.Contains('Completed task 1') -and -not $limited.text.Contains('rejected-row')) 'History limit, newest ordering, or rejected exclusion failed.'

    # A separate clean archive tests source union, older history, reopened IDs,
    # fat legacy trimming, nonterminal exclusion, and byte-for-byte reseeding.
    $repository = Join-Path $archiveFixture 'seed-repository'
    New-Item -ItemType Directory -Path $repository -Force | Out-Null
    & git init --quiet $repository
    $commits = @()
    foreach ($subject in @('feat(reopened): first delivery', 'fix(reopened): second delivery', 'feat(git-only): standalone delivery', 'docs: no task-shaped subject')) {
        & git -C $repository -c user.name=ArchiveTest -c user.email=archive@example.test -c commit.gpgsign=false commit --allow-empty --quiet -m $subject
        if ($LASTEXITCODE -ne 0) { throw 'Seed fixture commit failed.' }
        $commits += (& git -C $repository rev-parse HEAD).Trim()
    }
    & git -C $repository update-ref refs/remotes/origin/master HEAD
    $context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
    $config = Read-FactoryJson $context.configPath
    $config.productionBranch = 'master'; $config.remote = 'origin'
    Write-FactoryJsonAtomic $context.configPath $config
    $reopened = New-ArchiveFixtureTask 'reopened' $commits[0]
    $snapshotOnly = New-ArchiveFixtureTask 'snapshot-only' ('b' * 40)
    $legacyOnly = New-ArchiveFixtureTask 'legacy-only' ('c' * 40)
    $rejected = New-ArchiveFixtureTask 'seed-rejected' '' rejected
    $queued = New-ArchiveFixtureTask 'not-done' '' queued
    $snapshotPath = Join-Path $context.projectData 'state.json.c90a745db00b4ba59ed541b5dc8a69dd.tmp'
    $oldSnapshotPath = Join-Path $context.projectData 'state.json.pre-reboot-fix.bak'
    $legacyPath = Join-Path $context.projectData 'archive\completed-tasks.json'
    Write-FactoryJsonAtomic $snapshotPath ([pscustomobject]@{ tasks = @($reopened, $snapshotOnly, $rejected, $queued) })
    Write-FactoryJsonAtomic $oldSnapshotPath ([pscustomobject]@{ tasks = @($reopened) })
    Write-FactoryJsonAtomic $legacyPath ([pscustomobject]@{ tasks = @($legacyOnly) })
    $sourceHashes = @($snapshotPath, $oldSnapshotPath, $legacyPath | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash })
    $archivePath = Get-FactoryCompletedArchivePath $context
    $preview = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\seed-completed-archive.ps1') -Repository $repository -Preview) | ConvertFrom-Json
    Assert-ArchiveFixture ($LASTEXITCODE -eq 0 -and $preview.rows -eq 6 -and $preview.completedDistinctIds -eq 4 -and -not (Test-Path -LiteralPath $archivePath)) 'Seed preview union is incorrect or wrote the archive.'
    $previewText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') archive:seed --preview -Repository $repository | Out-String
    Assert-ArchiveFixture ($LASTEXITCODE -eq 0 -and $previewText.Contains('Would append 6 rows') -and -not (Test-Path -LiteralPath $archivePath)) 'Public seed preview failed or wrote the archive.'
    $seedText = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') archive:seed -Repository $repository | Out-String
    Assert-ArchiveFixture ($LASTEXITCODE -eq 0 -and $seedText.Contains('Appended 6 rows') -and $seedText.Contains('4 distinct completed task IDs')) 'Public seed command failed or did not report the source union.'
    $seedBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($archivePath))
    $secondSeed = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\seed-completed-archive.ps1') -Repository $repository) | ConvertFrom-Json
    Assert-ArchiveFixture ($LASTEXITCODE -eq 0 -and $secondSeed.added -eq 0 -and $seedBytes -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($archivePath))) 'Seeding twice did not preserve exact bytes.'
    $afterHashes = @($snapshotPath, $oldSnapshotPath, $legacyPath | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash })
    Assert-ArchiveFixture (($sourceHashes -join ',') -ceq ($afterHashes -join ',')) 'Seed changed a recovery source.'
    $seeded = Read-FactoryCompletedArchive $context
    Assert-ArchiveFixture (@($seeded.rows | Where-Object { $_.id -eq 'reopened' }).Count -eq 2) 'Reopened ID lost one of its commits.'
    Assert-ArchiveFixture (@($seeded.rows | Where-Object { $_.outcome -eq 'rejected' }).Count -eq 1) 'Seed lost rejected history.'
    Assert-ArchiveFixture ((Get-ArchiveTestStatus).count -eq 4) 'Seeded count includes rejected rows or misses produced IDs.'
    foreach ($line in [IO.File]::ReadAllLines($archivePath)) {
        $row = $line | ConvertFrom-Json
        Assert-ArchiveFixture ([Text.Encoding]::UTF8.GetByteCount($line + "`n") -lt 1024 -and @($row.PSObject.Properties).Count -eq 8 -and -not $line.Contains('Unwanted large brief')) 'Seed retained fat task fields or an oversized row.'
    }
    $unicodeTask = New-ArchiveFixtureTask 'unicode' ('d' * 40)
    $unicodeTask.title = (([char]0x6F22).ToString() * 900)
    $unicodeRow = New-FactoryCompletedArchiveRow $unicodeTask development
    Assert-ArchiveFixture ([Text.Encoding]::UTF8.GetByteCount(($unicodeRow | ConvertTo-Json -Depth 5 -Compress) + "`n") -lt 1024) 'Unicode summary exceeded its byte limit.'
    Write-Host 'Completed archive tests passed: missing archive, torn tail, append ownership, bounded history, rejected outcomes, seed union, retained sources, and byte-for-byte idempotency.'
} finally {
    $env:CLAUDE_FACTORY_HOME = $savedHome
    Write-Host "Archive fixture: $archiveFixture"
}
