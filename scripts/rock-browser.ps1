# Durable intent only. The browser-capable main orchestrator performs the UI work;
# the read-only ROCK model cannot post, set fields or acknowledge browser work.
function Test-FactoryRockBrowserProjection {
    param($Configuration)
    return [bool](Get-FactoryNestedValue (Get-FactoryNestedValue $Configuration.direct 'browserProjection') 'enabled' $false)
}

function Get-FactoryRockBrowserItems {
    param($Configuration)
    $paths = Get-FactoryRockCoordinatorPaths $Configuration
    if (-not (Test-Path -LiteralPath $paths.outbox)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $paths.outbox -File -Filter '*.json' | Sort-Object LastWriteTimeUtc, Name)) {
        if ($file.Name -notmatch '^[a-f0-9]{64}\.json$' -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid browser outbox entry.' }
        $item = Read-FactoryJson $file.FullName
        if ([string]$item.id -cne [IO.Path]::GetFileNameWithoutExtension($file.Name)) { throw 'Browser outbox identity mismatch.' }
        Write-Output $item
    }
}

function Add-FactoryRockBrowserItem {
    param($Configuration, [string]$EpicGid, [string]$Key, [string]$Text = '', [string]$TaskId = '', [string]$FactoryState = '', [string]$NativeIdentity = '', [string]$SourceRunId = '', [int]$SourceAttempts = 0, [string]$SourceCommit = '', [string]$SourceQuestionId = '')
    if (-not (Test-FactoryRockBrowserProjection $Configuration)) { return $null }
    $goal = Get-FactoryRockOrchestrator $Configuration $EpicGid
    $kind = if ($FactoryState) { 'status' } else { 'comment' }
    if ($kind -eq 'status' -and ($FactoryState -cnotin @('Ready', 'Taken', 'Question', 'Done', 'Failed') -or
        -not @($goal.ownedTasks | Where-Object { [string]$_.taskId -ceq $TaskId }).Count)) { throw 'Board status must target a trusted owned task.' }
    if ($kind -eq 'comment' -and (-not $Text.Trim() -or $Text.Length -gt 24000)) { throw 'Browser digest must contain 1-24000 characters.' }
    $paths = Get-FactoryRockCoordinatorPaths $Configuration
    $id = Get-FactoryTextSha256 "browser/$EpicGid/$kind/$Key"
    $path = Join-Path $paths.outbox "$id.json"
    $marker = "[factory-rock/$($Configuration.direct.coordinatorId)/$($id.Substring(0,16))]"
    $target = if ($kind -eq 'status') { $TaskId } else { $EpicGid }
    $url = ([string]$goal.epicUrl) -replace '\d+$', $target
    if ($url -notmatch '^https://app\.asana\.com/(?:[0-9/]+|[0-9/]+project/[0-9]+/task/[0-9]+)$') { throw 'Browser target must be a trusted Asana task URL.' }
    $body = $Text.Trim()
    if ($kind -eq 'comment' -and -not $body.StartsWith("[$($goal.name)-orchestrator]", [StringComparison]::Ordinal)) { $body = "[$($goal.name)-orchestrator] $body" }
    $mutex = Enter-FactoryMutex -ProjectKey "rock-browser-$((Get-FactoryTextSha256 $paths.root).Substring(0,16))"
    try {
        if (Test-Path -LiteralPath $path) { return $id }
        if (Test-Path -LiteralPath "$path.previous.bak") { throw 'Browser item is missing but a recovery copy exists.' }
        if ($kind -eq 'status') {
            foreach ($previous in @(Get-FactoryRockBrowserItems $Configuration | Where-Object { $_.kind -eq 'status' -and $_.targetGid -ceq $target -and $_.status -eq 'pending' })) {
                $previous.status = 'superseded'
                Write-FactoryRockJson (Join-Path $paths.outbox "$($previous.id).json") $previous
            }
        }
        Write-FactoryRockJson $path ([ordered]@{ version = 1; id = $id; rockId = $EpicGid; kind = $kind; targetGid = $target; url = $url; marker = $marker; text = $(if ($kind -eq 'comment') { "$body`n`n$marker" } else { '' }); factoryState = $FactoryState; nativeIdentity = $NativeIdentity; sourceRunId = $SourceRunId; sourceAttempts = $SourceAttempts; sourceCommit = $SourceCommit; sourceQuestionId = $SourceQuestionId; status = 'pending'; claimId = ''; leaseUntil = ''; needsVerification = $false; attempts = 0; createdAt = Get-FactoryUtcTimestamp; publishedAt = ''; receipt = $null; error = '' })
    } finally { Exit-FactoryMutex $mutex }
    return $id
}

function Sync-FactoryRockBrowserStatuses {
    param($Configuration, $Context, $State)
    if (-not (Test-FactoryRockBrowserProjection $Configuration)) { return }
    foreach ($task in @($State.tasks)) {
        if (-not [string](Get-FactoryNestedValue $task 'rockId')) { continue }
        $owner = Get-FactoryRockOwner $Configuration ([string]$task.id) ([string]$Context.repositoryRoot)
        if ($null -eq $owner -or [string]$owner.epicGid -cne [string]$task.rockId) { continue }
        $question = Get-FactoryNestedValue $task 'asanaQuestion'
        $field = switch ([string]$task.status) {
            'queued' { if ((Test-FactoryRockPrerequisites $Configuration ([string]$task.id) ([string]$Context.repositoryRoot)).ready) { 'Ready' } }
            { $_ -in @('starting', 'planning', 'running', 'awaiting-review', 'approved', 'integrating', 'production') } { 'Taken' }
            { $_ -in @('blocked', 'awaiting-input') } { if ($null -ne $question -and [string](Get-FactoryNestedValue $question 'channel') -eq 'rock') { 'Question' } }
            'done' { 'Done' }
            'failed' { 'Failed' }
        }
        if (-not $field) { continue }
        $identity = "$($Context.projectKey)/$($task.id)/$(Get-FactoryNestedValue $task 'runId')/$([int]$task.attempts)/$field/$(Get-FactoryNestedValue $question 'storyGid')/$(Get-FactoryNestedValue $task 'commit')"
        $null = Add-FactoryRockBrowserItem $Configuration ([string]$owner.epicGid) $identity -TaskId ([string]$task.id) -FactoryState $field -NativeIdentity $identity -SourceRunId ([string](Get-FactoryNestedValue $task 'runId')) -SourceAttempts ([int]$task.attempts) -SourceCommit ([string](Get-FactoryNestedValue $task 'commit')) -SourceQuestionId ([string](Get-FactoryNestedValue $question 'storyGid'))
    }
}

function Test-FactoryRockBrowserStatusCurrent {
    param($Configuration, $Item)
    $goal = Get-FactoryRockOrchestrator $Configuration ([string]$Item.rockId)
    $binding = @($goal.ownedTasks | Where-Object { [string]$_.taskId -ceq [string]$Item.targetGid })
    if ($binding.Count -ne 1 -or -not [string]$Item.nativeIdentity) { return $false }
    $cache = @{}
    $view = Get-FactoryRockTaskView $binding[0] $cache
    if (-not $view.available) { return $false }
    if ($view.origin -eq 'archive') { return $Item.factoryState -ceq 'Done' -and $view.status -ceq 'done' -and $view.commit -ceq $Item.sourceCommit -and [int]$view.attempts -eq [int]$Item.sourceAttempts }
    $project = $cache[[IO.Path]::GetFullPath([string]$binding[0].repository)]
    $task = @($project.state.tasks | Where-Object { [string]$_.id -ceq [string]$Item.targetGid })[0]
    if ([string](Get-FactoryNestedValue $task 'rockId') -cne [string]$Item.rockId) { return $false }
    if ($view.runId -cne [string]$Item.sourceRunId -or [int]$view.attempts -ne [int]$Item.sourceAttempts) { return $false }
    $current = switch ($view.status) {
        'queued' { if ((Test-FactoryRockPrerequisites $Configuration ([string]$binding[0].taskId) ([string]$binding[0].repository)).ready) { 'Ready' } }
        { $_ -in @('starting', 'planning', 'running', 'awaiting-review', 'approved', 'integrating', 'production') } { 'Taken' }
        { $_ -in @('blocked', 'awaiting-input') } { if ($view.questionId -and $view.questionId -ceq [string]$Item.sourceQuestionId) { 'Question' } }
        'done' { if ($view.commit -ceq [string]$Item.sourceCommit) { 'Done' } }
        'failed' { 'Failed' }
    }
    return [string]$current -ceq [string]$Item.factoryState
}

function Invoke-FactoryRockBrowserControl {
    param($Configuration, [string]$Action = 'list', [string]$EpicGid = '', [string]$ReceiptFile = '')
    $paths = Get-FactoryRockCoordinatorPaths $Configuration
    $mutex = Enter-FactoryMutex -ProjectKey "rock-browser-$((Get-FactoryTextSha256 $paths.root).Substring(0,16))"
    try {
        if ($Action -eq 'list') { return @(Get-FactoryRockBrowserItems $Configuration | Where-Object { (-not $EpicGid -or $_.rockId -ceq $EpicGid) -and $_.status -in @('pending', 'claimed', 'blocked') }) }
        if ($Action -eq 'claim') {
            $candidates = @(Get-FactoryRockBrowserItems $Configuration | Where-Object {
                (-not $EpicGid -or $_.rockId -ceq $EpicGid) -and ($_.status -eq 'pending' -or ($_.status -eq 'claimed' -and (ConvertTo-FactoryRockDateTimeOffset $_.leaseUntil) -lt [DateTimeOffset]::UtcNow))
            })
            $item = $null
            foreach ($candidate in $candidates) {
                if ($candidate.kind -eq 'status' -and -not (Test-FactoryRockBrowserStatusCurrent $Configuration $candidate)) {
                    $candidate.status = 'superseded'
                    Write-FactoryRockJson (Join-Path $paths.outbox "$($candidate.id).json") $candidate
                    continue
                }
                $item = $candidate; break
            }
            if ($null -eq $item) { return $null }
            # A lost click/receipt is never interpreted as "not posted".
            $item.needsVerification = [bool]$item.needsVerification -or $item.status -eq 'claimed'
            $item.status = 'claimed'; $item.claimId = [Guid]::NewGuid().ToString('N')
            $item.leaseUntil = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o'); $item.attempts = [int]$item.attempts + 1
            Write-FactoryRockJson (Join-Path $paths.outbox "$($item.id).json") $item
            return $item
        }
        if ($Action -notin @('confirm', 'defer', 'absent', 'retry', 'discard') -or -not $ReceiptFile) { throw 'Browser control requires list, claim, confirm, absent, retry, discard or defer with a receipt file.' }
        $receipt = Read-FactoryJson ([IO.Path]::GetFullPath($ReceiptFile))
        $id = [string](Get-FactoryNestedValue $receipt 'id')
        if ($id -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid browser receipt identity.' }
        $path = Join-Path $paths.outbox "$id.json"
        $item = Read-FactoryJson $path
        if ($Action -eq 'retry') {
            if ($item.status -ne 'blocked' -or [string]$receipt.claimId -cne [string]$item.claimId) { throw 'Only the exact blocked browser item can be retried.' }
            $item.status = 'pending'; $item.needsVerification = $true; $item.error = ''
            Write-FactoryRockJson $path $item
            return $item
        }
        if ($item.status -eq 'published' -and $Action -eq 'confirm' -and [string]$receipt.claimId -ceq [string]$item.claimId) { return $item }
        if ($item.status -cne 'claimed' -or [string]$receipt.claimId -cne [string]$item.claimId) { throw 'Browser receipt has a stale or missing claim.' }
        if ((ConvertTo-FactoryRockDateTimeOffset $item.leaseUntil) -lt [DateTimeOffset]::UtcNow) { throw 'Browser claim expired; inspect and reclaim before acknowledging.' }
        if ($Action -eq 'discard') {
            $reason = [string](Get-FactoryNestedValue $receipt 'reason')
            if (-not $reason.Trim() -or [bool]$item.needsVerification -or [int]$item.attempts -ne 1) { throw 'Discard requires a review reason and a fresh claim with no uncertain prior browser action.' }
            $item.status = 'superseded'; $item.error = $reason
        } elseif ($Action -eq 'defer') {
            $item.status = 'blocked'; $item.error = [string](Get-FactoryNestedValue $receipt 'reason' 'Browser action needs inspection.')
            $item.needsVerification = $true
        } else {
            $observedUrl = [string](Get-FactoryNestedValue $receipt 'url')
            if ($observedUrl -cne [string]$item.url) { throw 'Browser receipt URL differs from the exact queued target.' }
            $observed = [regex]::Replace([string](Get-FactoryNestedValue $receipt 'observedText'), '\s+', ' ').Trim()
            if (-not $observed) { throw 'Browser receipt requires freshly observed page text.' }
            if ($Action -eq 'absent') {
                if ($item.kind -ne 'comment' -or -not [bool](Get-FactoryNestedValue $receipt 'allCommentsInspected' $false) -or $observed.Contains([string]$item.marker)) { throw 'An uncertain comment requires an explicit complete browser inspection before retry.' }
                $item.status = 'pending'; $item.needsVerification = $false; $item.error = ''
            } else {
                if ($item.kind -eq 'comment') {
                    $expected = [regex]::Replace([string]$item.text, '\s+', ' ').Trim()
                    if (-not $observed.Contains($expected)) { throw 'Receipt must show both the exact digest and its idempotency marker.' }
                } elseif ([string](Get-FactoryNestedValue $receipt 'factoryState') -cne [string]$item.factoryState -or -not $observed.Contains([string]$item.factoryState)) { throw 'Receipt does not show the requested Factory field value.' }
                $item.status = 'published'; $item.publishedAt = Get-FactoryUtcTimestamp; $item.needsVerification = $false; $item.error = ''
            }
        }
        $item.receipt = $receipt
        Write-FactoryRockJson $path $item
        return $item
    } finally { Exit-FactoryMutex $mutex }
}
