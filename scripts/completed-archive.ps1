# Summary history is separate from the mutable task ledger. Callers append only
# while holding the existing project mutex; no archive operation rewrites rows.
if (-not (Get-Command Read-FactoryJson -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'factory-common.ps1')
}

function Get-FactoryCompletedArchivePath {
    param($Context)
    return Join-Path ([string]$Context.projectData) 'archive\completed-tasks.jsonl'
}

function Get-FactoryArchiveKey {
    param($Row)
    return ConvertTo-Json -InputObject @([string]$Row.id, ([string]$Row.commit).ToLowerInvariant()) -Compress
}

function ConvertTo-FactoryArchiveText {
    param($Value, [int]$MaximumLength = 220)
    $text = ([string]$Value -replace '\s+', ' ').Trim()
    if ($text.Length -gt $MaximumLength) {
        $length = $MaximumLength - 3
        if ([char]::IsHighSurrogate($text[$length - 1])) { $length-- }
        $text = $text.Substring(0, $length) + '...'
    }
    return $text
}

function New-FactoryCompletedArchiveRow {
    param(
        $Task,
        [ValidateSet('production', 'development', 'rejected')][string]$Outcome,
        $LandedAt = '',
        [string]$ArchivedAt = ''
    )
    $id = [string](Get-FactoryNestedValue $Task 'id' '')
    if (-not $id) { throw 'An archive row requires a task ID.' }
    $commit = ([string](Get-FactoryNestedValue $Task 'commit' '')).ToLowerInvariant()
    if ($commit -and $commit -notmatch '^[a-f0-9]{7,64}$') { throw "Invalid archive commit for '$id'." }
    if (-not $LandedAt -and $Outcome -ne 'rejected') {
        $audit = Get-FactoryNestedValue $Task $(if ($Outcome -eq 'production') { 'production' } else { 'integration' })
        foreach ($name in @('publishedAt', 'pushedAt', 'completedAt', 'verifiedAt')) {
            $LandedAt = Get-FactoryNestedValue $audit $name ''
            if ($LandedAt) { break }
        }
        if (-not $LandedAt) { $LandedAt = Get-FactoryNestedValue $Task 'updatedAt' '' }
    }
    if ($LandedAt) {
        $parsedTime = ConvertFrom-FactoryRoundtripTimestamp $LandedAt
        $LandedAt = if ($parsedTime.success) { $parsedTime.value.ToUniversalTime().ToString('o') } else { '' }
    }
    $taskSource = Get-FactoryNestedValue $Task 'source'
    $adapter = [string](Get-FactoryNestedValue $taskSource 'adapter' '')
    if (-not $adapter) { $adapter = if ($id.StartsWith('local:')) { 'local' } elseif ($id -match '^\d+$') { 'asana' } else { 'unknown' } }
    $sourceId = [string](Get-FactoryNestedValue $taskSource 'id' $id)
    $url = [string](Get-FactoryNestedValue $Task 'url' (Get-FactoryNestedValue $taskSource 'url' (Get-FactoryNestedValue $taskSource 'suppliedUrl' '')))
    $source = [pscustomobject][ordered]@{
        adapter = ConvertTo-FactoryArchiveText $adapter 32
        id = ConvertTo-FactoryArchiveText $sourceId 128
        url = if ($url.Length -le 210 -and $url -match '^https?://') { $url } else { $null }
    }
    $attempts = 0
    [void][int]::TryParse([string](Get-FactoryNestedValue $Task 'attempts' ''), [ref]$attempts)
    $row = [pscustomobject][ordered]@{
        id = $id
        title = ConvertTo-FactoryArchiveText (Get-FactoryNestedValue $Task 'title' 'Untitled task')
        outcome = $Outcome
        commit = if ($commit) { $commit } else { $null }
        landedAt = if ($LandedAt -and $Outcome -ne 'rejected') { $LandedAt } else { $null }
        attempts = [Math]::Max(0, $attempts)
        source = $source
        archivedAt = if ($ArchivedAt) { $ArchivedAt } else { Get-FactoryUtcTimestamp }
    }
    # Bound the actual UTF-8 serialized row, including JSON escaping and LF.
    while ([Text.Encoding]::UTF8.GetByteCount(($row | ConvertTo-Json -Depth 5 -Compress) + "`n") -ge 1024) {
        if ($row.source.url) { $row.source.url = $null }
        elseif ($row.title.Length -gt 24) { $row.title = ConvertTo-FactoryArchiveText $row.title ([Math]::Max(24, $row.title.Length - 24)) }
        elseif ($row.source.id) { $row.source.id = $null }
        else { throw "Archive identity '$id' cannot fit in a summary row under 1 KB." }
    }
    return $row
}

function Read-FactoryCompletedArchive {
    param($Context)
    $path = Get-FactoryCompletedArchivePath $Context
    $rows = New-Object 'Collections.Generic.List[object]'
    $warnings = New-Object 'Collections.Generic.List[string]'
    $keys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $exists = [IO.File]::Exists($path)
    if ($exists) {
        # Readers can observe an in-flight final append; it is skipped below if
        # incomplete. Sharing writes avoids failing status during completion.
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)))
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $lines = $text.Split([char]10)
        for ($index = 0; $index -lt $lines.Length; $index++) {
            $line = $lines[$index].TrimEnd([char]13)
            if (-not $line.Trim()) { continue }
            try {
                if ([Text.Encoding]::UTF8.GetByteCount($line + "`n") -ge 1024) { throw 'row exceeds the summary size limit' }
                $row = $line | ConvertFrom-Json
                if (-not [string]$row.id -or [string]$row.outcome -notin @('production', 'development', 'rejected')) { throw 'invalid summary identity or outcome' }
                foreach ($name in @('id', 'title', 'outcome', 'commit', 'landedAt', 'attempts', 'source', 'archivedAt')) {
                    if ($null -eq $row.PSObject.Properties[$name]) { throw "missing $name" }
                }
                # PowerShell 7 may deserialize ISO timestamps as DateTime.
                # Normalize for consistent display and chronological sorting.
                foreach ($name in @('landedAt', 'archivedAt')) {
                    if ($row.$name) {
                        $date = ConvertFrom-FactoryRoundtripTimestamp $row.$name
                        if (-not $date.success) { throw "invalid $name" }
                        $row.$name = $date.value.ToUniversalTime().ToString('o')
                    }
                }
                if ($keys.Add((Get-FactoryArchiveKey $row))) { $rows.Add($row) }
            } catch {
                $kind = if ($index -eq $lines.Length - 1) { 'torn final line' } else { 'invalid line' }
                $warnings.Add("Completed archive: skipped $kind $($index + 1) in '$path': $($_.Exception.Message)")
            }
        }
    }
    return [pscustomobject]@{ path = $path; exists = $exists; rows = $rows.ToArray(); warnings = $warnings.ToArray() }
}

function Add-FactoryCompletedArchiveRows {
    param($Context, [object[]]$Rows = @())
    $statePath = [IO.Path]::GetFullPath([string]$Context.statePath)
    $ownershipKey = "$([Threading.Thread]::CurrentThread.ManagedThreadId):$statePath"
    if (-not $global:FactoryStateMutexOwnership.ContainsKey($ownershipKey)) { throw 'Appending completed history requires the project mutex.' }
    $archive = Read-FactoryCompletedArchive $Context
    # Status and the seed report surface reader warnings. Keep append callers'
    # machine-readable JSON output free of host warning text.
    $keys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($row in $archive.rows) { [void]$keys.Add((Get-FactoryArchiveKey $row)) }
    $pending = New-Object 'Collections.Generic.List[string]'
    foreach ($row in $Rows) {
        $line = $row | ConvertTo-Json -Depth 5 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($line + "`n") -ge 1024) { throw 'Completed archive row must be under 1 KB.' }
        if ($keys.Add((Get-FactoryArchiveKey $row))) { $pending.Add($line) }
    }
    if ($pending.Count -eq 0 -and $archive.exists) { return 0 }
    New-Item -ItemType Directory -Path (Split-Path -Parent $archive.path) -Force | Out-Null
    $stream = [IO.File]::Open($archive.path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        $needsNewline = $false
        if ($stream.Length -gt 0) {
            [void]$stream.Seek(-1, [IO.SeekOrigin]::End)
            $needsNewline = $stream.ReadByte() -ne 10
        }
        [void]$stream.Seek(0, [IO.SeekOrigin]::End)
        foreach ($line in $pending) {
            # Separate a torn tail without ever modifying the existing prefix.
            $bytes = [Text.Encoding]::UTF8.GetBytes($(if ($needsNewline) { "`n" }) + $line + "`n")
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
            $needsNewline = $false
        }
    } finally { $stream.Dispose() }
    return $pending.Count
}

function Get-FactoryCompletedHistory {
    param($Context, $State, $Config)
    $archive = Read-FactoryCompletedArchive $Context
    $rows = New-Object 'Collections.Generic.List[object]'
    $keys = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($row in $archive.rows) {
        if ([string]$row.outcome -ne 'rejected' -and $keys.Add((Get-FactoryArchiveKey $row))) { $rows.Add($row) }
    }
    foreach ($task in @($State.tasks | Where-Object { [string]$_.status -eq 'done' })) {
        $outcome = if ([string]$Config.productionBranch) { 'production' } else { 'development' }
        $row = New-FactoryCompletedArchiveRow -Task $task -Outcome $outcome
        if ($keys.Add((Get-FactoryArchiveKey $row))) { $rows.Add($row) }
    }
    $ids = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($row in $rows) { [void]$ids.Add([string]$row.id) }
    return [pscustomobject]@{
        count = $ids.Count; rows = @($rows.ToArray() | Sort-Object @{ Expression = { [string]$_.landedAt }; Descending = $true }, id, commit)
        archiveExists = $archive.exists; warnings = $archive.warnings; path = $archive.path
    }
}
