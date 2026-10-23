param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts/factory-common.ps1')
. (Join-Path $PluginRoot 'scripts/publication-ci.ps1')
. (Join-Path $PluginRoot 'scripts/attention-state.ps1')
$ciTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-ci-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $ciTestRoot
$savedCiFactoryHome = $env:CLAUDE_FACTORY_HOME
$env:CLAUDE_FACTORY_HOME = Join-Path $ciTestRoot 'runtime'
$ciContext = [pscustomobject]@{ projectKey = ('ci-test-' + [Guid]::NewGuid().ToString('N')); projectData = $ciTestRoot; repositoryRoot = $ciTestRoot }
$script:CiAssertions = 0
$originalReader = $null
$originalNative = $null
function Assert-Ci { param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }; $script:CiAssertions++
}
function New-CiRun { param([string]$Sha, [string]$Conclusion = '', [int]$Attempt = 1, [string]$Id = '10', [string]$Branch = 'develop')
    [pscustomobject]@{ id = $Id; name = 'CI'; head_sha = $Sha; head_branch = $Branch; event = 'push'
        run_attempt = $Attempt; status = $(if ($Conclusion) { 'completed' } else { 'in_progress' }); conclusion = $Conclusion }
}
function Save-CiFixture { param($Journal)
    $mutex = Enter-FactoryMutex -ProjectKey "$($ciContext.projectKey)-ci"
    try { Write-FactoryJsonAtomic -Path (Get-FactoryCiPath $ciContext) -Value $Journal }
    finally { Exit-FactoryMutex $mutex }
}
try {
    $sha = 'a' * 40; $nextSha = 'b' * 40
    $task = [pscustomobject]@{ id = 'local:ci-test'; title = 'Targeted worker / full go' }
    Assert-Ci (-not (Get-FactoryCiStatus $ciContext).blocked) 'An absent journal blocked existing projects.'
    Register-FactoryCiPublication -Context $ciContext -Task $task -Slug 'fixture/project' -Branch develop -Sha $sha
    Register-FactoryCiPublication -Context $ciContext -Task $task -Slug 'fixture/project' -Branch develop -Sha $sha
    $journal = Read-FactoryCiJournal $ciContext
    Assert-Ci ($journal.entries.Count -eq 1) 'Register was not idempotent.'
    Assert-Ci (-not (Get-FactoryCiStatus $ciContext).blocked) 'Pending CI blocked publication.'
    $entry = $journal.entries[0]
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @() })
    Assert-Ci ($entry.status -eq 'pending') 'No workflow was treated as passing CI.'
    $run = New-CiRun $sha
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @($run) })
    Assert-Ci ($entry.status -eq 'pending') 'Running CI was not pending.'
    $skipEntry = $entry | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    Set-FactoryCiObservation $skipEntry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha success 2), (New-CiRun $sha skipped 1 '12')) })
    Assert-Ci ($skipEntry.status -eq 'passed' -and @($skipEntry.runs | Where-Object { $_.conclusion -eq 'skipped' }).Count -eq 1) 'A skipped companion workflow hid successful deploy CI or lost skip evidence.'
    $skipEntry.runs = @()
    Set-FactoryCiObservation $skipEntry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha skipped)) })
    Assert-Ci ($skipEntry.status -eq 'skipped') 'An entirely skipped CI remained actionable.'
    $skipEntry.runs = @()
    Set-FactoryCiObservation $skipEntry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha neutral)) })
    Assert-Ci ($skipEntry.status -eq 'skipped') 'Neutral-only CI remained actionable.'
    $requiredConfig = [pscustomobject]@{ ciMonitoring = [pscustomobject]@{ requireSuccessfulRunOn = @('develop') } }
    Set-FactoryCiObservation $skipEntry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha neutral)) }) -Config $requiredConfig
    Assert-Ci ($skipEntry.status -eq 'unverified') 'An explicitly required success was waived.'
    $optionalConfig = [pscustomobject]@{ ciMonitoring = [pscustomobject]@{ requireSuccessfulRunOn = @('master', 'release/*') } }
    $skipEntry.runs = @()
    Set-FactoryCiObservation $skipEntry ([pscustomobject]@{ complete = $true; runs = @() }) -Config $optionalConfig
    Assert-Ci ($skipEntry.status -eq 'skipped') 'A branch with no required CI stayed pending without workflows.'
    Assert-Ci ((Get-FactoryCiBranchPolicy $optionalConfig 'release/1').requireSuccess) 'Required branch patterns were ignored.'
    $emptyPolicy = [pscustomobject]@{ ciMonitoring = [pscustomobject]@{ requireSuccessfulRunOn = @() } }
    Assert-Ci ((Get-FactoryCiBranchPolicy $emptyPolicy 'develop').configured) 'An explicit empty required-branch list was lost.'
    Set-FactoryCiObservation $skipEntry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha failure)) }) -Config $optionalConfig
    Assert-Ci ($skipEntry.status -eq 'failed') 'A no-required-CI branch hid a known failure.'
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $nextSha failure)) })
    Assert-Ci ($entry.failures.Count -eq 0) 'Unrelated SHA affected the gate.'
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha failure 1 '10' master)) })
    Assert-Ci ($entry.failures.Count -eq 0) 'Unrelated branch affected the gate.'
    $run = New-CiRun $sha failure
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @($run) })
    Save-CiFixture $journal
    Assert-Ci ((Get-FactoryCiStatus $ciContext).blocked) 'Known CI failure did not block.'
    Assert-Ci (@(Get-FactoryCiAttentionEvents $ciContext).Count -eq 1) 'CI failure emitted no attention.'
    $fakeState = [pscustomobject]@{ tasks = @(); active = $false; paused = $false; scheduler = [pscustomobject]@{ status = 'stopped' } }
    $attention = Sync-FactoryAttentionState -Context $ciContext -State $fakeState -Config ([pscustomobject]@{})
    $again = Sync-FactoryAttentionState -Context $ciContext -State $fakeState -Config ([pscustomobject]@{})
    Assert-Ci ($attention.revision -eq $again.revision -and $again.events.Count -eq 1) 'Unchanged CI failure spammed attention.'
    Assert-Ci ($again.events[0].aiActionable) 'CI failure was not visible to the orchestrator.'
    # A transient unreadable, missing, or empty source cannot resolve CI keys.
    $failureKey = $again.events[0].key
    foreach ($sourceState in @('invalid', 'missing', 'empty')) {
        if ($sourceState -eq 'invalid') { Write-FactoryJsonAtomic -Path (Get-FactoryCiPath $ciContext) -Value ([pscustomobject]@{ version = 1 }) }
        elseif ($sourceState -eq 'missing') { Remove-Item -LiteralPath (Get-FactoryCiPath $ciContext) }
        else { Save-CiFixture ([pscustomobject]@{ version = 1; entries = @() }) }
        $gap = Sync-FactoryAttentionState -Context $ciContext -State $fakeState -Config ([pscustomobject]@{})
        Assert-Ci ($gap.activeKeys -contains $failureKey) "$sourceState source dropped a known CI key."
        Save-CiFixture $journal
        $recovered = Sync-FactoryAttentionState -Context $ciContext -State $fakeState -Config ([pscustomobject]@{})
        Assert-Ci (@($recovered.events | Where-Object kind -eq 'publication-ci').Count -eq 1) "$sourceState source recovery replayed CI."
    }
    Set-FactoryCiObservation -Entry $entry -Observation $null -ErrorText 'Authentication expired'
    Assert-Ci ($entry.status -eq 'failed' -and $entry.failures.Count -eq 1) 'Auth error erased known failure.'
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha '' 2)) })
    Assert-Ci ($entry.failures.Count -eq 1) 'Pending rerun cleared failure too early.'
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha cancelled 2)) })
    Assert-Ci ($entry.failures.Count -eq 1) 'Cancelled rerun cleared failure.'
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha success 2 '11')) })
    Assert-Ci ($entry.failures.Count -eq 1) 'A different workflow run cleared failure.'
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha success 2)) })
    Assert-Ci ($entry.failures.Count -eq 0) 'Successful exact rerun did not recover.'
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $false; runs = @((New-CiRun $sha success 2)) })
    Assert-Ci ($entry.status -eq 'unknown') 'Truncated API snapshot was treated as green.'
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $false; runs = @((New-CiRun $sha failure 3)) })
    Assert-Ci ($entry.failures.Count -eq 1) 'Truncated API snapshot hid a visible failure.'
    Save-CiFixture $journal
    $accepted = Confirm-FactoryCiFailure -Context $ciContext -Sha $sha -Reason 'Operator authorizes publishing a repair.'
    Assert-Ci (-not $accepted.blocked -and $accepted.entries[0].status -eq 'failed') 'Acknowledgement pretended CI passed.'
    Assert-Ci ($accepted.entries[0].acknowledgements[0].reason -match 'repair') 'Acknowledgement was not audited.'
    $journal = Read-FactoryCiJournal $ciContext; $entry = $journal.entries[0]
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha failure 4)) })
    Save-CiFixture $journal
    Assert-Ci ((Get-FactoryCiStatus $ciContext).blocked) 'A new failed attempt inherited the old waiver.'
    Set-FactoryCiObservation $entry ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $sha failure 3)) })
    Save-CiFixture $journal
    Assert-Ci ((Get-FactoryCiStatus $ciContext).blocked -and $entry.failures[0].attempt -eq 4) 'A stale API attempt reused an older acknowledgement.'
    Register-FactoryCiPublication -Context $ciContext -Task $task -Slug 'fixture/project' -Branch develop -Sha $nextSha
    Assert-Ci ((Get-FactoryCiStatus $ciContext).blocked) 'A newer publication erased the older failure.'

    # Fake the read boundary, not the production decision logic. Observe while
    # another publication/ack is registered, verifying merge-on-write behavior.
    $originalReader = ${function:Get-FactoryCiRuns}
    $script:CiReadCount = 0
    function Get-FactoryCiRuns {
        param($Context, $Entry, [int]$TimeoutSeconds)
        $script:CiReadCount++
        $stateOwnership = "$([Threading.Thread]::CurrentThread.ManagedThreadId):$([IO.Path]::GetFullPath((Join-Path $Context.projectData 'state.json')))"
        Assert-Ci (-not $global:FactoryStateMutexOwnership.ContainsKey($stateOwnership)) 'CI network read held the task-state lock.'
        Register-FactoryCiPublication -Context $Context -Task $task -Slug 'fixture/project' -Branch master -Sha ('c' * 40)
        [pscustomobject]@{ complete = $true; runs = @((New-CiRun $Entry.sha success 5), (New-CiRun $Entry.sha success 5 '11')) }
    }
    $journal = Read-FactoryCiJournal $ciContext
    foreach ($item in $journal.entries) { $item.lastPollAt = $null }
    Save-CiFixture $journal
    $polled = Sync-FactoryPublicationCi $ciContext
    Assert-Ci (-not $polled.error) "Poll failed: $($polled.error)"
    Assert-Ci (@($polled.entries | Where-Object { $_.error }).Count -eq 0) 'Per-entry observation failed.'
    Assert-Ci ($script:CiReadCount -ge 1) 'Poll did not query due entries.'
    Assert-Ci ($polled.entries.Count -eq 3) 'Polling overwrote a concurrent publication.'
    Assert-Ci (-not $polled.blocked) 'Observer failed to clear successful rerun.'
    $journal = Read-FactoryCiJournal $ciContext
    foreach ($item in $journal.entries) { $item.lastPollAt = Get-FactoryUtcTimestamp }
    Save-CiFixture $journal
    $before = $script:CiReadCount
    $null = Sync-FactoryPublicationCi $ciContext
    Assert-Ci ($script:CiReadCount -eq $before) 'Polling ignored the cooldown.'

    $sortNow = [DateTime]::SpecifyKind([DateTime]'2026-09-27T12:00:00', [DateTimeKind]::Utc)
    $mixedDue = @(Get-FactoryCiDueEntries -NowUtc $sortNow -Entries @(
        [pscustomobject]@{ key = 'never'; publishedAt = $sortNow.AddHours(-1); lastPollAt = $null; status = 'pending'; failures = @(); acknowledgements = @() },
        [pscustomobject]@{ key = 'datetime'; publishedAt = $sortNow.AddHours(-1).ToString('o'); lastPollAt = $sortNow.AddMinutes(-3); status = 'pending'; failures = @(); acknowledgements = @() },
        [pscustomobject]@{ key = 'string'; publishedAt = $sortNow.AddHours(-1); lastPollAt = $sortNow.AddMinutes(-2).ToString('o'); status = 'pending'; failures = @(); acknowledgements = @() },
        [pscustomobject]@{ key = 'offset'; publishedAt = $sortNow.AddHours(-1).ToString('o'); lastPollAt = [DateTimeOffset]$sortNow.AddMinutes(-1); status = 'pending'; failures = @(); acknowledgements = @() }
    ))
    Assert-Ci ((@($mixedDue | ForEach-Object { $_.key }) -join ',') -eq 'never,datetime,string,offset') 'Due CI sorting compared mixed timestamp representations directly.'
    Set-Item Function:Get-FactoryCiRuns -Value $originalReader

    # Exercise the real API/remote parsing boundary with captured native output.
    $originalNative = ${function:Invoke-FactoryNativeProcess}
    $script:CiRemoteUrl = 'git@github.com:example/project.git'
    $script:CiApiArguments = @()
    function Invoke-FactoryNativeProcess {
        param([string]$Command, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds)
        if ($Command -eq 'git') {
            Assert-Ci ($TimeoutSeconds -eq 3) 'Remote lookup timeout changed.'
            return [pscustomobject]@{ exitCode = 0; stdout = $script:CiRemoteUrl }
        }
        Assert-Ci ($TimeoutSeconds -eq 15) 'CI read did not use the 15-second default timeout.'
        Assert-Ci ($Command -eq 'gh') 'Observer invoked an unexpected executable.'
        $script:CiApiArguments = $Arguments
        [pscustomobject]@{ exitCode = 0; stdout = '{"total_count":101,"workflow_runs":[]}' }
    }
    foreach ($url in @('git@github.com:example/project.git', 'https://github.com/example/project.git', 'ssh://git@github.com/example/project.git')) {
        $script:CiRemoteUrl = $url
        Assert-Ci ((Get-FactoryCiRepository $ciContext ([pscustomobject]@{})) -eq 'example/project') "Could not resolve GitHub remote $url"
    }
    $script:CiRemoteUrl = 'C:\temporary\remote.git'
    Assert-Ci (-not (Get-FactoryCiRepository $ciContext ([pscustomobject]@{}))) 'Local remotes unexpectedly enabled network monitoring.'
    $script:CiRemoteUrl = 'git@github.com:example/project.git'
    Assert-Ci (-not (Get-FactoryCiRepository $ciContext ([pscustomobject]@{ ciMonitoring = [pscustomobject]@{ enabled = $false } }))) 'Disabled registration ignored config.'
    $apiEntry = [pscustomobject]@{ repository = 'example/project'; branch = 'feature/test'; sha = $sha }
    $response = Get-FactoryCiRuns $ciContext $apiEntry
    Assert-Ci (-not $response.complete) 'API boundary did not mark pagination incomplete.'
    Assert-Ci (($script:CiApiArguments -join ' ') -match 'api --hostname github.com --method GET repos/example/project/actions/runs\?head_sha=a{40}&branch=feature%2Ftest&event=push&per_page=100') 'API query was not pinned to the exact host/branch/SHA/push event.'
    Set-Item Function:Invoke-FactoryNativeProcess -Value $originalNative

    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    $fakeGh = Join-Path $ciTestRoot 'gh.exe'
    & $compiler /nologo /target:exe "/out:$fakeGh" (Join-Path $PluginRoot 'tests\FakeGh.cs') | Out-Null
    Assert-Ci ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $fakeGh)) 'Could not build the slow gh fixture.'
    $savedPath = $env:PATH
    try {
        $env:PATH = "$ciTestRoot;$savedPath"
        $env:FACTORY_FAKE_GH_SHA = 'd' * 40
        $env:FACTORY_FAKE_GH_BRANCH = 'develop'
        $env:FACTORY_FAKE_GH_MODE = 'success'
        Register-FactoryCiPublication -Context $ciContext -Task $task -Slug 'fixture/project' -Branch develop -Sha $env:FACTORY_FAKE_GH_SHA
        $slowJournal = Read-FactoryCiJournal $ciContext
        $slowJournal.entries = @($slowJournal.entries | Where-Object { $_.sha -eq $env:FACTORY_FAKE_GH_SHA })
        Save-CiFixture $slowJournal
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $slowStatus = Sync-FactoryPublicationCi -Context $ciContext -Config ([pscustomobject]@{
            ciMonitoring = [pscustomobject]@{ apiTimeoutSeconds = 15; pollBudgetSeconds = 20; maxObservationAttempts = 5 }
        })
        Assert-Ci ($slowStatus.entries[0].status -eq 'passed' -and $watch.Elapsed.TotalSeconds -ge 5 -and $watch.Elapsed.TotalSeconds -lt 15) 'A five-second gh response did not pass CI.'

        $env:FACTORY_FAKE_GH_MODE = 'timeout'
        $env:FACTORY_FAKE_GH_SHA = 'e' * 40
        Register-FactoryCiPublication -Context $ciContext -Task $task -Slug 'fixture/project' -Branch develop -Sha $env:FACTORY_FAKE_GH_SHA
        $timeoutJournal = Read-FactoryCiJournal $ciContext
        $timeoutJournal.entries = @($timeoutJournal.entries | Where-Object { $_.sha -eq $env:FACTORY_FAKE_GH_SHA })
        Save-CiFixture $timeoutJournal
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $timeoutJournal = Read-FactoryCiJournal $ciContext
            $timeoutJournal.entries[0].lastPollAt = $null
            Save-CiFixture $timeoutJournal
            $timeoutStatus = Sync-FactoryPublicationCi -Context $ciContext -Config ([pscustomobject]@{
                ciMonitoring = [pscustomobject]@{ apiTimeoutSeconds = 1; pollBudgetSeconds = 2; maxObservationAttempts = 5 }
            })
            $expectedStatus = if ($attempt -eq 5) { 'unverified' } else { 'pending' }
            Assert-Ci ($timeoutStatus.entries[0].status -eq $expectedStatus -and
                [int]$timeoutStatus.entries[0].observationFailures -eq $attempt) "Timeout attempt $attempt had the wrong CI state."
        }
        $attentionState = [pscustomobject]@{ tasks = @(); active = $false; paused = $false; scheduler = [pscustomobject]@{ status = 'stopped' } }
        $firstUnverified = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        $timeoutJournal = Read-FactoryCiJournal $ciContext
        $timeoutJournal.entries[0].error = 'Native command gh timed out again.'
        Save-CiFixture $timeoutJournal
        $secondUnverified = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        Assert-Ci ($firstUnverified.revision -eq $secondUnverified.revision) 'Changing timeout wording replayed one unverified outcome.'
        $unverifiedKey = @($secondUnverified.events | Where-Object status -eq 'unverified')[-1].key
        Assert-Ci (@(Get-FactoryClaudeDeliverableEvents $secondUnverified | Where-Object key -eq $unverifiedKey).Count -eq 1) 'Unverified outcome was not initially deliverable.'
        $timeoutJournal.entries[0].status = 'pending'; Save-CiFixture $timeoutJournal
        $null = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        $timeoutJournal.entries[0].status = 'unverified'; Save-CiFixture $timeoutJournal
        $beforeDelivery = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        Assert-Ci ($beforeDelivery.revision -eq $secondUnverified.revision -and
            @(Get-FactoryClaudeDeliverableEvents $beforeDelivery | Where-Object key -eq $unverifiedKey).Count -eq 1) 'A temporary gap lost an undelivered unverified notification.'
        $null = Update-FactoryAttentionRecord -Context $ciContext -Mutator {
            param($record)
            $record.orchestratorAcknowledgedRevision = $record.revision
        }
        $delivered = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        Assert-Ci (@($delivered.events | Where-Object { $_.key -eq $unverifiedKey -and $_.includeInDefaultWait }).Count -eq 0) 'A delivered unverified outcome remained in default wait.'
        Assert-Ci (@(Get-FactoryClaudeDeliverableEvents $delivered).Count -eq 0) 'A delivered unverified outcome rewoke Claude.'
        # Upgrade an old journal that already contains repeated revisions for
        # the same delivered identity. None of those duplicates may wake again.
        $null = Update-FactoryAttentionRecord -Context $ciContext -Mutator {
            param($record)
            $duplicate = @($record.events | Where-Object key -eq $unverifiedKey)[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $record.revision++
            $duplicate.revision = $record.revision
            $record.events = @($record.events) + @($duplicate)
        }
        $delivered = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        Assert-Ci (@($delivered.events | Where-Object { $_.key -eq $unverifiedKey -and ($_.includeInDefaultWait -or $_.aiActionable) }).Count -eq 0) 'An old duplicate revision replayed a delivered identity.'
        $timeoutJournal.entries[0].status = 'pending'; Save-CiFixture $timeoutJournal
        $null = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        $timeoutJournal.entries[0].status = 'unverified'; Save-CiFixture $timeoutJournal
        $returned = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        Assert-Ci ($returned.revision -eq $delivered.revision) 'A temporary pending outcome re-raised an unverified publication.'
        $null = Update-FactoryAttentionRecord -Context $ciContext -Mutator { param($record) $record.events = @() }
        $trimmed = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        Assert-Ci ($trimmed.revision -eq $returned.revision) 'Trimming attention history forgot a CI notification identity.'
        Set-FactoryCiObservation $timeoutJournal.entries[0] ([pscustomobject]@{ complete = $true; runs = @((New-CiRun $env:FACTORY_FAKE_GH_SHA failure)) })
        Save-CiFixture $timeoutJournal
        $red = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        Assert-Ci ($red.revision -eq $returned.revision + 1 -and @(Get-FactoryClaudeDeliverableEvents $red).Count -eq 1) 'A new failure did not wake after an unverified notification.'
        Register-FactoryCiPublication -Context $ciContext -Task $task -Slug 'fixture/project' -Branch develop -Sha ('f' * 40)
        $newPublication = Read-FactoryCiJournal $ciContext
        $newPublication.entries[1].status = 'unverified'
        Save-CiFixture $newPublication
        $newShaAttention = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        Assert-Ci ($newShaAttention.revision -eq $red.revision + 1) 'A new unverified SHA reused an older publication notification.'
        $null = Update-FactoryAttentionRecord -Context $ciContext -Mutator { param($record) $record.waitAcknowledgedRevision = $record.revision }
        $manuallyDelivered = Sync-FactoryAttentionState -Context $ciContext -State $attentionState -Config ([pscustomobject]@{})
        Assert-Ci (@($manuallyDelivered.events | Where-Object { $_.status -eq 'unverified' -and $_.includeInDefaultWait }).Count -eq 0) 'Manual wait delivery left unverified notifications actionable.'
        $timeoutJournal.entries[0].failures = @(); $timeoutJournal.entries[0].runs = @()
        $timeoutJournal.entries[0].status = 'unverified'
        $timeoutJournal.entries[0].publishedAt = [DateTime]::UtcNow.AddDays(-8).ToString('o')
        Save-CiFixture $timeoutJournal
        Assert-Ci (@(Get-FactoryCiAttentionEvents $ciContext).Count -eq 0) 'An expired unverified publication still produced attention.'
    } finally {
        $env:PATH = $savedPath
        Remove-Item Env:\FACTORY_FAKE_GH_MODE,Env:\FACTORY_FAKE_GH_SHA,Env:\FACTORY_FAKE_GH_BRANCH -ErrorAction SilentlyContinue
    }

    # Cached skipped-only evidence migrates even after its polling window,
    # persists once, and never needs a GitHub read or an operator journal edit.
    $migration = Read-FactoryCiJournal $ciContext
    $legacy = $migration.entries[0]
    $legacy.status = 'unverified'; $legacy.error = ''
    $legacy.runs = @([pscustomobject]@{ id = '10'; attempt = 1; status = 'completed'; conclusion = 'skipped'; name = 'CI' })
    Save-CiFixture $migration
    Assert-Ci ((Get-FactoryCiStatus $ciContext).entries[0].status -eq 'skipped') 'Legacy skipped runs still produced attention before polling.'
    Assert-Ci (@(Get-FactoryCiAttentionEvents $ciContext).Count -eq 0) 'Legacy skipped runs still raised an edge.'
    $migrated = Sync-FactoryPublicationCi $ciContext
    Assert-Ci ($migrated.entries[0].status -eq 'skipped' -and (Read-FactoryCiJournal $ciContext).entries[0].status -eq 'skipped') 'Skipped migration was not persisted outside the polling window.'
    $migrationText = [IO.File]::ReadAllText((Get-FactoryCiPath $ciContext))
    $null = Sync-FactoryPublicationCi $ciContext
    Assert-Ci ([IO.File]::ReadAllText((Get-FactoryCiPath $ciContext)) -ceq $migrationText) 'Skipped migration rewrote the journal repeatedly.'

    # Native command timeout is opt-in; regular callers retain their behavior.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try { $null = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 20') -TimeoutSeconds 1 }
    catch { $timedOut = $_.Exception.Message -match 'timed out' }
    Assert-Ci ($timedOut -and $watch.Elapsed.TotalSeconds -lt 5) 'CI native read timeout was not bounded.'
    $echo = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile', '-Command', "Write-Output 'unchanged'")
    Assert-Ci ($echo.exitCode -eq 0 -and $echo.stdout -eq 'unchanged') 'Default process capture regressed.'

    # Corruption cannot silently reset failure history.
    $journal.entries[0].failures = $null
    Save-CiFixture $journal
    Assert-Ci ((Get-FactoryCiStatus $ciContext).blocked) 'Malformed CI evidence failed open.'

    foreach ($file in @('agents/worker.md', 'resources/codex-worker-instructions.md')) {
        $contract = Get-Content -LiteralPath (Join-Path $PluginRoot $file) -Raw
        Assert-Ci ($contract.Contains('default worker policy is targeted')) "$file still requires blanket full suites."
        Assert-Ci ($contract.Contains('testLeaseScript') -and $contract.Contains('syncScript')) "$file lost safe sync/full-suite leases."
    }
    $launcher = Get-Content -LiteralPath (Join-Path $PluginRoot 'scripts/start-worker-session.ps1') -Raw
    Assert-Ci ($launcher.Contains('verificationMode = "targeted"') -and -not $launcher.Contains('fullTestCommands =')) 'Worker payload still inherits the integration suite.'
    Write-Output "Publication CI tests passed ($script:CiAssertions assertions)."
} finally {
    $env:CLAUDE_FACTORY_HOME = $savedCiFactoryHome
    if ($originalReader) { Set-Item Function:Get-FactoryCiRuns -Value $originalReader }
    if ($originalNative) { Set-Item Function:Invoke-FactoryNativeProcess -Value $originalNative }
    # Only this test's newly created, explicitly resolved temporary directory.
    $resolved = [IO.Path]::GetFullPath($ciTestRoot)
    if ((Split-Path $resolved -Leaf) -notlike 'factory-ci-tests-*' -or
        -not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected CI fixture cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
