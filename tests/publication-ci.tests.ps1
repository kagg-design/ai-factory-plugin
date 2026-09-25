param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts/factory-common.ps1')
. (Join-Path $PluginRoot 'scripts/publication-ci.ps1')
. (Join-Path $PluginRoot 'scripts/attention-state.ps1')
$ciTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-ci-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $ciTestRoot
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
    Assert-Ci ($skipEntry.status -eq 'unverified') 'An entirely skipped CI was labelled successful.'
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
    Set-FactoryCiObservation -Entry $entry -Observation $null -ErrorText 'Authentication expired'
    Assert-Ci ($entry.status -eq 'unknown' -and $entry.failures.Count -eq 1) 'Auth error erased known failure.'
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
    Set-Item Function:Get-FactoryCiRuns -Value $originalReader

    # Exercise the real API/remote parsing boundary with captured native output.
    $originalNative = ${function:Invoke-FactoryNativeProcess}
    $script:CiRemoteUrl = 'git@github.com:example/project.git'
    $script:CiApiArguments = @()
    function Invoke-FactoryNativeProcess {
        param([string]$Command, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds)
        Assert-Ci ($TimeoutSeconds -eq 3) 'CI read lost its short native timeout.'
        if ($Command -eq 'git') { return [pscustomobject]@{ exitCode = 0; stdout = $script:CiRemoteUrl } }
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
