# The shared ROCK coordinator owns Asana writes. Factories attest the facts and
# may correct a proposed digest; no external Codex browser consumer is required.
function Test-FactoryRockCoordinatorPublication {
    param($Configuration)
    return [bool](Get-FactoryNestedValue (Get-FactoryNestedValue $Configuration.direct 'publication') 'enabled' $false)
}

function Get-FactoryRockPublicationFacts {
    param($Configuration, [string]$EpicGid, [string]$TaskId = '')
    $goal = Get-FactoryRockOrchestrator $Configuration $EpicGid
    $bindings = @(@((Get-FactoryNestedValue $goal 'ownedTasks' @())) + @((Get-FactoryNestedValue $goal 'watchedTasks' @())))
    if ($TaskId) { $bindings = @($bindings | Where-Object { [string]$_.taskId -ceq $TaskId }) }
    if (-not $bindings.Count) { throw 'Publication requires at least one trusted Factory binding.' }
    $cache = @{}
    $groups = @()
    foreach ($repository in @($bindings | ForEach-Object { [IO.Path]::GetFullPath([string]$_.repository) } | Sort-Object -Unique)) {
        $context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $repository | ConvertFrom-Json
        $projectConfig = Read-FactoryJson $context.configPath
        $factoryPaused = [bool](Read-FactoryJson $context.statePath).paused
        $projectRock = Get-FactoryRockConfiguration -Config $projectConfig
        if ($null -eq $projectRock -or -not (Test-FactorySamePath $projectRock.configurationPath $Configuration.configurationPath)) { throw 'A publication factory has not enabled this coordinator configuration.' }
        $facts = @()
        foreach ($binding in @($bindings | Where-Object { Test-FactorySamePath ([string]$_.repository) $repository } | Sort-Object taskId)) {
            $view = Get-FactoryRockTaskView $binding $cache
            # Deliberately omit heartbeat/updatedAt. A scheduler tick is not new evidence.
            $facts += [pscustomobject][ordered]@{
                taskId = [string]$view.taskId; available = [bool]$view.available
                status = [string]$view.status; commit = [string]$view.commit
                runId = [string]$view.runId; attempts = [int](Get-FactoryNestedValue $view 'attempts' 0)
                development = [string](Get-FactoryNestedValue $view 'development')
                production = [string](Get-FactoryNestedValue $view 'production')
                developmentCommit = [string](Get-FactoryNestedValue $view 'developmentCommit')
                productionCommit = [string](Get-FactoryNestedValue $view 'productionCommit')
                questionId = [string](Get-FactoryNestedValue $view 'questionId')
                error = [string](Get-FactoryNestedValue $view 'error')
            }
        }
        $hash = Get-FactoryTextSha256 ([ordered]@{paused=$factoryPaused;facts=$facts} | ConvertTo-Json -Depth 15 -Compress)
        $groups += [pscustomobject]@{ repository = $repository; paused=$factoryPaused; factsHash = $hash; facts = $facts }
    }
    return $groups
}

function Set-FactoryRockPublicationProposal {
    param($Configuration, $Item, [int]$Revision = 1)
    $factories = @()
    $taskId = if ($Item.kind -eq 'status') { [string]$Item.targetGid } else { '' }
    foreach ($group in @(Get-FactoryRockPublicationFacts $Configuration ([string]$Item.rockId) $taskId)) {
        $factories += [pscustomobject]@{ repository = $group.repository; paused=$group.paused; factsHash = $group.factsHash; facts = @($group.facts); decision = 'pending'; reason = ''; reviewedAt = ''; actor = '' }
    }
    $proposal = [pscustomobject]@{ version = 1; revision = $Revision; textHash = Get-FactoryTextSha256 "$($Item.kind)/$($Item.text)/$($Item.factoryState)"; factories = $factories }
    # A board status is a deterministic projection of native task state; the
    # owning factory can attest it without another model round-trip.
    if ($Item.kind -eq 'status' -and (Test-FactoryRockBrowserStatusCurrent $Configuration $Item)) {
        foreach ($factory in $proposal.factories) { $factory.decision = 'approved'; $factory.actor = 'native-factory'; $factory.reason = 'Exact native status projection.'; $factory.reviewedAt = Get-FactoryUtcTimestamp }
    }
    Set-FactoryProperty $Item 'publication' $proposal
}

function Test-FactoryRockPublicationCurrent {
    param($Configuration, $Item)
    $proposal = Get-FactoryNestedValue $Item 'publication'
    if ($null -eq $proposal) { return $false }
    if ([string]$proposal.textHash -cne (Get-FactoryTextSha256 "$($Item.kind)/$($Item.text)/$($Item.factoryState)")) { return $false }
    $taskId = if ($Item.kind -eq 'status') { [string]$Item.targetGid } else { '' }
    $current = @(Get-FactoryRockPublicationFacts $Configuration ([string]$Item.rockId) $taskId)
    if ($current.Count -ne @($proposal.factories).Count) { return $false }
    foreach ($factory in @($proposal.factories)) {
        $match = @($current | Where-Object { Test-FactorySamePath ([string]$_.repository) ([string]$factory.repository) })
        if ($match.Count -ne 1 -or [string]$match[0].factsHash -cne [string]$factory.factsHash) { return $false }
    }
    if ($Item.kind -eq 'status' -and -not (Test-FactoryRockBrowserStatusCurrent $Configuration $Item)) { return $false }
    return $true
}

function Test-FactoryRockPublicationApproved {
    param($Configuration, $Item)
    if (-not (Test-FactoryRockPublicationCurrent $Configuration $Item)) { return $false }
    $factories = @($Item.publication.factories)
    return $factories.Count -gt 0 -and @($factories | Where-Object { $_.decision -ne 'approved' -or [bool](Get-FactoryNestedValue $_ 'paused' $false) }).Count -eq 0
}

function Sync-FactoryRockPublicationProposals {
    param($Configuration)
    if (-not (Test-FactoryRockCoordinatorPublication $Configuration)) { return }
    $paths = Get-FactoryRockCoordinatorPaths $Configuration
    $mutex = Enter-FactoryMutex -ProjectKey "rock-browser-$((Get-FactoryTextSha256 $paths.root).Substring(0,16))"
    try {
        foreach ($item in @(Get-FactoryRockBrowserItems $Configuration | Where-Object status -eq 'pending')) {
            if (Test-FactoryRockPublicationCurrent $Configuration $item) { continue }
            if ([bool]$item.needsVerification) { continue } # Never revise a possibly posted comment.
            if ($item.kind -eq 'status' -and -not (Test-FactoryRockBrowserStatusCurrent $Configuration $item)) { $item.status = 'superseded' }
            else { $revision = [int](Get-FactoryNestedValue (Get-FactoryNestedValue $item 'publication') 'revision' 0) + 1; Set-FactoryRockPublicationProposal $Configuration $item $revision }
            Write-FactoryRockJson (Join-Path $paths.outbox "$($item.id).json") $item
        }
    } finally { Exit-FactoryMutex $mutex }
}

function Get-FactoryRockPublicationReviews {
    param($Configuration, [string]$Repository)
    Sync-FactoryRockPublicationProposals $Configuration
    foreach ($item in @(Get-FactoryRockBrowserItems $Configuration | Where-Object status -eq 'pending')) {
        $proposal = Get-FactoryNestedValue $item 'publication'
        if ($null -eq $proposal) { continue }
        foreach ($factory in @($proposal.factories | Where-Object { $_.decision -eq 'pending' -and -not [bool](Get-FactoryNestedValue $_ 'paused' $false) -and (Test-FactorySamePath ([string]$_.repository) $Repository) })) {
            [pscustomobject]@{ id = [string]$item.id; rockId = [string]$item.rockId; revision = [int]$proposal.revision; text = [string]$item.text; kind = [string]$item.kind; factoryState = [string]$item.factoryState; url = [string]$item.url; repository = [string]$factory.repository; factsHash = [string]$factory.factsHash; facts = @($factory.facts) }
        }
    }
}

function Sync-FactoryRockParticipantAttention {
    param($Configuration)
    if (-not (Test-FactoryRockCoordinatorPublication $Configuration)) { return }
    . (Join-Path $PSScriptRoot 'attention-state.ps1')
    $repositories = @($Configuration.orchestrators | ForEach-Object { @($_.ownedTasks) + @($_.watchedTasks) } | ForEach-Object { [string]$_.repository } | Sort-Object -Unique)
    foreach ($repository in $repositories) {
        try {
            $context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $repository | ConvertFrom-Json
            $config = Read-FactoryJson $context.configPath
            $enabled = Get-FactoryRockConfiguration -Config $config
            if ($null -eq $enabled -or -not (Test-FactorySamePath $enabled.configurationPath $Configuration.configurationPath)) { continue }
            # The existing attention bridge delivers this journal. Do not start
            # another agent, chat heartbeat, scheduler or worker for publication.
            $null = Sync-FactoryAttentionState -Context $context -State (Read-FactoryJson $context.statePath) -Config $config
        } catch { Write-Warning "ROCK participant attention is retained for reconciliation: $($_.Exception.Message)" }
    }
}

function Submit-FactoryRockPublicationReview {
    param($Configuration, $Context, [string]$ReceiptFile)
    $review = Read-FactoryJson ([IO.Path]::GetFullPath($ReceiptFile))
    $id = [string](Get-FactoryNestedValue $review 'id')
    if ($id -cnotmatch '^[a-f0-9]{64}$' -or [string](Get-FactoryNestedValue $review 'decision') -cnotin @('approve','revise','reject')) { throw 'Review requires an exact item ID and approve, revise or reject.' }
    $paths = Get-FactoryRockCoordinatorPaths $Configuration
    $mutex = Enter-FactoryMutex -ProjectKey "rock-browser-$((Get-FactoryTextSha256 $paths.root).Substring(0,16))"
    try {
        $path = Join-Path $paths.outbox "$id.json"
        $item = Read-FactoryJson $path
        if ($item.status -ne 'pending' -or [bool]$item.needsVerification) { throw 'Only an unposted pending proposal can be reviewed.' }
        if (-not (Test-FactoryRockPublicationCurrent $Configuration $item)) { throw 'Factory facts changed; refresh the proposal before reviewing.' }
        if ([int]$review.revision -ne [int]$item.publication.revision) { throw 'Publication review has a stale revision.' }
        $factory = @($item.publication.factories | Where-Object { Test-FactorySamePath ([string]$_.repository) ([string]$Context.repositoryRoot) })
        if ($factory.Count -ne 1 -or [string]$review.factsHash -cne [string]$factory[0].factsHash) { throw 'Review does not match this factory and its exact facts.' }
        $reason = [string](Get-FactoryNestedValue $review 'reason')
        if ($review.decision -eq 'reject') {
            if (-not $reason.Trim()) { throw 'Rejection requires a reason.' }
            $item.status = 'superseded'; $item.error = $reason
        } else {
            if ($review.decision -eq 'revise') {
                if ($item.kind -ne 'comment') { throw 'A native status cannot be revised as free text.' }
                $body = [string](Get-FactoryNestedValue $review 'text')
                $body = [regex]::Replace($body, '\s*' + [regex]::Escape([string]$item.marker) + '\s*$', '').Trim()
                if (-not $body.Trim() -or $body.Length -gt 16000) { throw 'Revision requires 1-16000 characters.' }
                $goal = Get-FactoryRockOrchestrator $Configuration ([string]$item.rockId)
                if (-not $body.StartsWith("[$($goal.name)-orchestrator]", [StringComparison]::Ordinal)) { $body = "[$($goal.name)-orchestrator] $body" }
                $body = "$($body.Trim())`n`n$($item.marker)"
                if ($body -cne $item.text) { $item.text = $body; Set-FactoryRockPublicationProposal $Configuration $item ([int]$item.publication.revision + 1) }
                $factory = @($item.publication.factories | Where-Object { Test-FactorySamePath ([string]$_.repository) ([string]$Context.repositoryRoot) })
            }
            $factory[0].decision = 'approved'; $factory[0].reason = $reason; $factory[0].actor = "factory:$($Context.projectKey)"; $factory[0].reviewedAt = Get-FactoryUtcTimestamp
        }
        Write-FactoryRockJson $path $item
    } finally { Exit-FactoryMutex $mutex }
    if ($review.decision -eq 'reject') {
        $null = Add-FactoryRockEvent $Configuration ([string]$item.rockId) "publication-rejected/$id/$($item.publication.revision)" @{ kind = 'publication-rejected'; owner = $false; itemId = $id; text = [string]$item.text; reason = $reason }
    }
    elseif (Test-FactoryRockPublicationApproved $Configuration $item) {
        $null = Add-FactoryRockEvent $Configuration ([string]$item.rockId) "publication-ready/$id/$($item.publication.revision)" @{kind='publication-ready';owner=$false;itemId=$id;revision=[int]$item.publication.revision}
    }
    Sync-FactoryRockParticipantAttention $Configuration
    return [pscustomobject]@{ id = $id; revision = [int]$item.publication.revision; status = $item.status; approved = $item.status -eq 'pending' -and (Test-FactoryRockPublicationApproved $Configuration $item) }
}

function Invoke-FactoryRockPublication {
    param($Configuration, [string]$EpicGid='', [scriptblock]$PublisherInvoker, [switch]$CoordinatorLockHeld)
    if (-not (Test-FactoryRockCoordinatorPublication $Configuration)) { return [pscustomobject]@{published=0;disabled=$true} }
    $transport=[string](Get-FactoryNestedValue (Get-FactoryNestedValue $Configuration.direct 'publication') 'transport' 'disabled')
    if($null -eq $PublisherInvoker -and $transport -eq 'disabled'){return [pscustomobject]@{published=0;disabled=$true}}
    $paths=Get-FactoryRockCoordinatorPaths $Configuration
    $mutex=$null;$owns=$false;$published=0;$errors=New-Object 'Collections.Generic.List[string]'
    try{
        if(-not $CoordinatorLockHeld){
            $mutex=New-Object Threading.Mutex($false,$paths.mutexName)
            try{$owns=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owns=$true}
            if(-not $owns){return [pscustomobject]@{published=0;busy=$true}}
        }
        if([bool](Read-FactoryRockCoordinatorMemory $Configuration).paused){return [pscustomobject]@{published=0;paused=$true}}
        Sync-FactoryRockPublicationProposals $Configuration
        # One item per turn keeps browser/connector work bounded; the durable
        # ready event and service wake handle the next item without a model poller.
        $claim=Invoke-FactoryRockBrowserControl $Configuration claim $EpicGid
        if($null -eq $claim){return [pscustomobject]@{published=0;empty=$true}}
        try{
            if(-not (Test-FactoryRockPublicationApproved $Configuration $claim)){throw 'Factory evidence changed before coordinator publication.'}
            if($null -ne $PublisherInvoker){$proof=& $PublisherInvoker $Configuration $claim}
            else{$proof=Invoke-FactoryRockExistingAsanaPublisher $Configuration $claim}
            if($null -eq $proof){throw 'Coordinator transport returned no independently observed proof.'}
            $receipt=@{id=$claim.id;claimId=$claim.claimId;url=[string]$proof.url;observedText=[string]$proof.observedText}
            if($claim.kind -eq 'status'){$receipt.factoryState=[string]$proof.factoryState}
            $receiptPath=Join-Path $paths.root "publication-$($claim.id)-$($claim.claimId).receipt.json"
            Write-FactoryRockJson $receiptPath $receipt
            $confirmed=Invoke-FactoryRockBrowserControl $Configuration confirm -ReceiptFile $receiptPath
            if($confirmed.status -eq 'published'){$published++}
        }catch{
            $errors.Add($_.Exception.Message)
            $deferPath=Join-Path $paths.root "publication-$($claim.id)-$($claim.claimId).defer.json"
            Write-FactoryRockJson $deferPath @{id=$claim.id;claimId=$claim.claimId;reason=$_.Exception.Message}
            $null=Invoke-FactoryRockBrowserControl $Configuration defer -ReceiptFile $deferPath
        }
        return [pscustomobject]@{published=$published;errors=$errors.ToArray()}
    }finally{if($null -ne $mutex){if($owns){$mutex.ReleaseMutex()};$mutex.Dispose()}}
}
