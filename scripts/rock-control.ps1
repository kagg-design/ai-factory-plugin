[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [ValidateSet('status', 'questions', 'answer', 'pause', 'resume', 'import', 'retry')][string]$Action = 'status',
    [string]$EpicGid = '', [string]$QuestionId = '', [string]$Text = '', [string]$File = '', [string]$EventId = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rock-common.ps1')
$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$rock = Get-FactoryRockConfiguration -Config $config
if ($null -eq $rock) { throw 'Direct ROCK is disabled for this project. Configure rocks.enabled and rocks.configPath.' }
if ($Action -in @('answer', 'pause', 'resume', 'import', 'retry') -and -not $EpicGid) { throw 'This action requires a ROCK epic GID.' }
if ($EpicGid) { $null = Get-FactoryRockOrchestrator $rock $EpicGid }
if ($Action -eq 'answer') {
    if (-not $QuestionId -or -not $Text.Trim() -or $Text.Length -gt 16000) { throw 'Answer requires question ID and 1-16000 characters.' }
    $null = Update-FactoryRockMemory $rock $EpicGid {
        param($memory)
        $question = @($memory.questions | Where-Object { [string]$_.id -ceq $QuestionId })
        if ($question.Count -ne 1) { throw 'Unknown ROCK question.' }
        if ($question[0].status -eq 'answered') {
            if ([string]$question[0].answer -cne $Text) { throw 'Question already has a different answer.' }
            return
        }
        $question[0].status = 'answered'; $question[0].answer = $Text
        $memory.decisions = @($memory.decisions) + @([pscustomobject]@{ actor = 'operator'; text = $Text; questionId = $QuestionId; createdAt = Get-FactoryUtcTimestamp })
    }
    $null = Add-FactoryRockEvent $rock $EpicGid "operator-answer/$QuestionId" @{ kind = 'operator-answer'; questionId = $QuestionId; text = $Text; owner = $false }
    Start-FactoryRockService -Context $context -Config $config
    Write-Output 'Operator answer saved; ROCK will continue. This does not approve code, GO or a merge gate.'
    return
}
if ($Action -in @('pause', 'resume')) {
    $null = Update-FactoryRockMemory $rock $EpicGid { param($memory) $memory.paused = $Action -eq 'pause' }
    if ($Action -eq 'resume') { Start-FactoryRockService -Context $context -Config $config }
    Write-Output "ROCK $EpicGid`: $Action. Factory pause/approval policies remain in effect."
    return
}
if ($Action -eq 'import') {
    if (-not $File -or -not (Test-Path -LiteralPath $File -PathType Leaf)) { throw 'Import requires an existing UTF-8 snapshot file.' }
    $snapshot = [IO.File]::ReadAllText([IO.Path]::GetFullPath($File), (New-Object Text.UTF8Encoding($false, $true)))
    if (-not $snapshot.Trim() -or $snapshot.Length -gt 1000000) { throw 'Snapshot must contain 1-1000000 characters.' }
    $paths = Get-FactoryRockPaths $rock $EpicGid
    $id = Get-FactoryTextSha256 $snapshot
    $destination = Join-Path $paths.root "sources\$id.json"
    Write-FactoryJsonAtomic -Path $destination -Value @{ content = $snapshot; importedAt = Get-FactoryUtcTimestamp; sourceFile = [IO.Path]::GetFileName($File); authority = 'source-material' }
    $null = Update-FactoryRockMemory $rock $EpicGid {
        param($memory)
        $sources = @((Get-FactoryNestedValue $memory 'sources' @()))
        if ($destination -cnotin $sources) { Set-FactoryProperty $memory 'sources' @($sources + @($destination)) }
        Set-FactoryProperty $memory 'sourceRefreshRequired' $false
        Set-FactoryProperty $memory 'sourcesUpdatedAt' (Get-FactoryUtcTimestamp)
    }
    Write-Output "Saved source snapshot: $destination. Imported text does not grant operator authority."
    return
}
if ($Action -eq 'retry') {
    if ($EventId -notmatch '^[0-9a-f]{64}$') { throw 'Retry requires a full native event ID.' }
    $paths = Get-FactoryRockPaths $rock $EpicGid
    $path = Join-Path $paths.events "$EventId.json"
    $mutex = New-Object Threading.Mutex($false, "Local\ClaudeFactory-RockRunner-$EpicGid")
    $owns = $false
    try {
        try { $owns = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns = $true }
        if (-not $owns) { throw 'ROCK runner is busy; retry after its current cycle.' }
        $event = Read-FactoryJson -Path $path
        if ($event.status -ne 'failed') { throw 'Only failed events can be retried; completed actions are never replayed.' }
        $event.status = 'pending'; $event.attempts = 0; $event.applyAttempts = 0; $event.retryAt = $null; $event.error = $null
        Write-FactoryJsonAtomic -Path $path -Value $event
    } finally { if ($owns) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    Start-FactoryRockService -Context $context -Config $config
    return
}
foreach ($item in @($rock.orchestrators)) {
    if ($EpicGid -and [string]$item.epicGid -cne $EpicGid) { continue }
    $paths = Get-FactoryRockPaths $rock ([string]$item.epicGid)
    $memory = Read-FactoryRockMemory $rock ([string]$item.epicGid)
    Write-Output "ROCK $($item.name) / $($item.epicGid) / revision $($memory.revision) / paused $($memory.paused)"
    Write-Output "Memory: $($paths.root)"
    if ([bool](Get-FactoryNestedValue $memory 'sourceRefreshRequired' $false)) { Write-Output "Browser source refresh required: factory rock import $($item.epicGid) --file SNAPSHOT" }
    if ($Action -eq 'status') {
        Write-Output ([string]$memory.summary)
        $events = if (Test-Path -LiteralPath $paths.events) { @(Get-ChildItem -LiteralPath $paths.events -Filter '*.json' -File | ForEach-Object { Read-FactoryJson $_.FullName }) } else { @() }
        Write-Output "Events: pending $(@($events | Where-Object status -eq 'pending').Count), failed $(@($events | Where-Object status -eq 'failed').Count), completed $(@($events | Where-Object status -eq 'completed').Count)"
        foreach ($event in @($events | Where-Object status -eq 'failed')) { Write-Output "Failed $($event.id): $($event.error)" }
        foreach ($event in @($events | Where-Object { $_.status -eq 'pending' -and $_.error })) { Write-Output "Pending $($event.id): $($event.error)" }
    }
    foreach ($question in @($memory.questions | Where-Object status -eq 'open')) {
        Write-Output "Question $($question.id): $($question.text)"
        Write-Output "factory rock answer $($item.epicGid) $($question.id) --text YOUR_ANSWER"
    }
}
