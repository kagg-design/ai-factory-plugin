[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PluginRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\rock-actions.ps1')
. (Join-Path $PluginRoot 'scripts\completed-archive.ps1')
function Assert-Coord { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }
function Assert-CoordThrows { param([scriptblock]$Code, [string]$Pattern) $message=''; try { & $Code | Out-Null } catch { $message=$_.Exception.Message }; Assert-Coord ($message -match $Pattern) "Expected $Pattern; got $message" }
$fixture = Join-Path ([IO.Path]::GetTempPath()) "factory-rock-coordinator-$([Guid]::NewGuid().ToString('N'))"
$savedHome = $env:CLAUDE_FACTORY_HOME
$job = $null
$nativeWorkerMayExist = $false
$oldWorkerRelease = $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH
function Set-CoordFixtureTasks {
    param($Context, [object[]]$Tasks, [string[]]$Removed = @())
    $mutex = Enter-FactoryMutex $Context.projectKey
    try { $state = Read-FactoryJson $Context.statePath; $state.tasks = $Tasks; Write-FactoryJsonAtomic $Context.statePath $state -RemovedTaskIds $Removed } finally { Exit-FactoryMutex $mutex }
}
try {
    $env:CLAUDE_FACTORY_HOME = Join-Path $fixture 'runtime'
    $contexts = @()
    foreach ($name in @('hr', 'auditors')) {
        $repo = Join-Path $fixture $name
        $null = New-Item -ItemType Directory -Path $repo -Force
        git -C $repo init --quiet --initial-branch=develop
        git -C $repo -c user.name=CoordinatorTest -c user.email=test@example.invalid -c commit.gpgsign=false commit --allow-empty --quiet -m fixture
        if ($LASTEXITCODE) { throw 'Could not create coordinator Git fixture.' }
        $contexts += & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repo -Initialize | ConvertFrom-Json
    }
    $one=$contexts[0]; $two=$contexts[1]
    git -C $one.repositoryRoot branch master
    $remote=Join-Path $fixture 'remote.git'
    git init --bare --quiet $remote
    git -C $one.repositoryRoot remote add origin $remote
    git -C $one.repositoryRoot push --quiet origin develop master
    $head=(& git -C $two.repositoryRoot rev-parse HEAD).Trim()
    $reviewed = Join-Path $fixture 'reviewed.json'
    $configuration = [ordered]@{ claudePath='must-never-run'; timeoutMinutes=1; direct=@{enabled=$true;coordinatorId='two-rocks';memoryDir=(Join-Path $fixture 'rocks');browserProjection=@{enabled=$true}}; orchestrators=@(
        @{name='access';epicGid='100';epicUrl='https://app.asana.com/0/0/100';repoPath=$one.repositoryRoot;extraDirs=@();ownedTasks=@(
            @{taskId='501';repository=$one.repositoryRoot;prerequisites=@(@{taskId='601';repository=$two.repositoryRoot;stage='production';commit=$head})},
            @{taskId='502';repository=$one.repositoryRoot});watchedTasks=@()},
        @{name='billing';epicGid='200';epicUrl='https://app.asana.com/0/0/200';repoPath=$two.repositoryRoot;extraDirs=@();ownedTasks=@(@{taskId='601';repository=$two.repositoryRoot});watchedTasks=@(@{taskId='501';repository=$one.repositoryRoot})}) }
    Write-FactoryJsonAtomic $reviewed $configuration
    $before = [IO.File]::ReadAllText($one.statePath)
    foreach ($context in $contexts) {
        $result = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') rock configure -Repository $context.repositoryRoot -File $reviewed
        Assert-Coord ($LASTEXITCODE -eq 0 -and ($result | ConvertFrom-Json).configured) "Public configure failed: $result"
    }
    Assert-Coord ([IO.File]::ReadAllText($one.statePath) -ceq $before) 'Configure changed factory activity/pause or ledger.'
    $installed = [string](Read-FactoryJson $one.configPath).rocks.configPath
    $rock = Get-FactoryRockConfiguration -ConfigPath $installed
    $a=Get-FactoryRockOrchestrator $rock '100'; $b=Get-FactoryRockOrchestrator $rock '200'
    $upstream = [pscustomobject]@{id='601';title='Upstream';status='failed';commit=$head;attempts=1;runId='run-one';integration=[pscustomobject]@{status='published';taskCommit=$head};production=[pscustomobject]@{status='failed';taskCommit=$head}}
    $queued = [pscustomobject]@{id='501';title='Downstream';brief='Fixture';status='queued';rockId='100';attempts=0;commit=$null;createdAt=Get-FactoryUtcTimestamp;updatedAt=Get-FactoryUtcTimestamp;worktree=$null;branch=$null}
    Set-CoordFixtureTasks $two @($upstream)
    Set-CoordFixtureTasks $one @($queued)
    Assert-Coord (-not (Test-FactoryRockPrerequisites $rock '501' $one.repositoryRoot).ready) 'Failed upstream released downstream.'
    $native = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\start-worker-session.ps1') -Repository $one.repositoryRoot -TaskId 501 -ClaudeCommand must-never-run | ConvertFrom-Json
    Assert-Coord ($LASTEXITCODE -eq 0 -and $native.deferred -and (Read-FactoryJson $one.statePath).tasks[0].attempts -eq 0) 'Native launch consumed an attempt or ran before prerequisites.'
    $upstream.status='done'
    Set-CoordFixtureTasks $two @($upstream)
    Assert-Coord (-not (Test-FactoryRockPrerequisites $rock '501' $one.repositoryRoot).ready) 'Done was treated as proof of production publication.'
    $upstream.production.status='published'
    Set-CoordFixtureTasks $two @($upstream)
    Assert-Coord ((Test-FactoryRockPrerequisites $rock '501' $one.repositoryRoot).ready) 'Published cross-repository prerequisite did not release downstream.'
    foreach($blockedStatus in @('failed','rejected','held','blocked')){
        $upstream.status=$blockedStatus;Set-CoordFixtureTasks $two @($upstream)
        Assert-Coord (-not (Test-FactoryRockPrerequisites $rock '501' $one.repositoryRoot).ready) 'Retained publication evidence overrode a failed/rejected/held upstream.'
    }
    $upstream.status='done';Set-CoordFixtureTasks $two @($upstream)
    # Intake succeeds, then the upstream regresses before launch. A blocked
    # first queue item must not consume a slot or starve an independent task.
    $fakeClaude=Join-Path $fixture 'fake-claude.exe'; $fakeCodex=Join-Path $fixture 'fake-codex.exe'
    foreach($compilerInput in @(@{source='FakeClaude.cs';output=$fakeClaude},@{source='FakeCodex.cs';output=$fakeCodex})) {
        $compile="Add-Type -Path '"+(Join-Path $PluginRoot "tests\$($compilerInput.source)").Replace("'","''")+"' -OutputAssembly '"+$compilerInput.output.Replace("'","''")+"' -OutputType ConsoleApplication"
        $run=Invoke-FactoryNativeProcess powershell @('-NoProfile','-Command',$compile) -TimeoutSeconds 60
        Assert-Coord ($run.exitCode -eq 0) "Fake worker compilation failed: $($run.output)"
    }
    Set-CoordFixtureTasks $one @() @('501')
    $nativeConfig=Read-FactoryJson $one.configPath
    $nativeConfig.workerAgent='codex';$nativeConfig.codexCommand=$fakeCodex;$nativeConfig.codingConcurrency=1
    $nativeConfig.orchestrator.attentionBridge=$false;$nativeConfig.ciMonitoring.enabled=$false
    Write-FactoryJsonAtomic $one.configPath $nativeConfig
    $nativeMutex=Enter-FactoryMutex $one.projectKey
    try {$nativeState=Read-FactoryJson $one.statePath;$nativeState.active=$true;Write-FactoryJsonAtomic $one.statePath $nativeState} finally {Exit-FactoryMutex $nativeMutex}
    foreach($taskId in @('501','502')) {
        $intake=Join-Path $fixture "$taskId.intake.json"
        Write-FactoryJsonAtomic $intake @{version=1;source=@{adapter='asana';id=$taskId;url="https://app.asana.com/0/0/$taskId"};startMode='auto';title="Task $taskId";brief='Repo: local/hr';acceptanceCriteria=@();sourceNotes=@();sourceError=$null}
        $null=& (Join-Path $PluginRoot 'scripts\enqueue-task.ps1') -Repository $one.repositoryRoot -IntakePath $intake -RockId 100 -RockActionId "gate/$taskId" -NoResume
    }
    Assert-Coord (((Read-FactoryJson $one.statePath).tasks[0].brief) -match 'Merge gate: ask Igor before merging') 'Native intake omitted the default human merge gate.'
    $upstream.status='failed';$upstream.production.status='failed';Set-CoordFixtureTasks $two @($upstream)
    $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH=Join-Path $fixture 'worker-release'
    $nativeWorkerMayExist=$true
    $tickRun=Invoke-FactoryNativeProcess powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PluginRoot 'scripts\factory-scheduler.ps1'),'-Action','tick','-Repository',$one.repositoryRoot,'-ClaudeCommand',$fakeClaude,'-RuntimeHome',$env:CLAUDE_FACTORY_HOME) -TimeoutSeconds 120
    Assert-Coord ($tickRun.exitCode -eq 0) "Native dependency tick failed: $($tickRun.output)"
    $tick=$tickRun.stdout | ConvertFrom-Json
    $afterTick=Read-FactoryJson $one.statePath
    $blocked=Get-FactoryTask $afterTick '501';$independent=Get-FactoryTask $afterTick '502'
    Assert-Coord ($tick.launchedCount -eq 1 -and $blocked.status -eq 'queued' -and $blocked.attempts -eq 0 -and $null -ne $independent.backgroundSession) 'A blocked task starved its independent peer or launched prematurely.'
    $null=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\reject-task.ps1') -Repository $one.repositoryRoot -TaskId 502 -Yes -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex
    Assert-Coord ($LASTEXITCODE -eq 0) 'Native fake-worker cleanup failed.'
    $nativeWorkerMayExist=$false
    [IO.File]::WriteAllText($env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH,'release')
    $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH=$oldWorkerRelease
    $upstream.status='done';$upstream.production.status='published';Set-CoordFixtureTasks $two @($upstream)
    $upstream.commit=('f'*40)
    Set-CoordFixtureTasks $two @($upstream)
    Assert-Coord (-not (Test-FactoryRockPrerequisites $rock '501' $one.repositoryRoot).ready) 'Wrong upstream commit satisfied a pin.'
    $upstream.commit=$head
    Set-CoordFixtureTasks $two @($upstream)
    $archiveMutex=Enter-FactoryMutex $two.projectKey
    try { $null=Add-FactoryCompletedArchiveRows -Context $two -Rows @((New-FactoryCompletedArchiveRow -Task $upstream -Outcome production)) } finally { Exit-FactoryMutex $archiveMutex }
    Set-CoordFixtureTasks $two @() @('601')
    Assert-Coord ((Test-FactoryRockPrerequisites $rock '501' $one.repositoryRoot).ready) 'Completed archive lost a cleaned upstream prerequisite.'
    $archivePath=Get-FactoryCompletedArchivePath $two
    $validArchive=[IO.File]::ReadAllText($archivePath)
    [IO.File]::AppendAllText($archivePath,'{torn')
    Assert-Coord (-not (Test-FactoryRockPrerequisites $rock '501' $one.repositoryRoot).ready) 'Corrupt archive allowed a dependency.'
    [IO.File]::WriteAllText($archivePath,$validArchive)
    $configuration.orchestrators[1].ownedTasks[0].prerequisites=@(@{taskId='501';repository=$one.repositoryRoot})
    Write-FactoryJsonAtomic $reviewed $configuration

    $pauseBefore=[IO.File]::ReadAllText($one.statePath)
    $null=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') rock pause -Repository $one.repositoryRoot
    Assert-Coord ($LASTEXITCODE -eq 0 -and (Read-FactoryRockCoordinatorMemory $rock).paused) 'Public shared coordinator pause failed.'
    $pausedCycle=Invoke-FactoryRockCoordinatorCycle $rock -ModelInvoker {throw 'Paused coordinator called the model.'}
    Assert-Coord ($pausedCycle.paused -and [IO.File]::ReadAllText($one.statePath) -ceq $pauseBefore) 'Shared pause changed Factory activity/state.'
    $null=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') rock resume -Repository $one.repositoryRoot
    Assert-Coord ($LASTEXITCODE -eq 0 -and -not (Read-FactoryRockCoordinatorMemory $rock).paused) 'Public shared coordinator resume failed.'
    Assert-CoordThrows { Get-FactoryRockConfiguration -ConfigPath $reviewed } 'cycle'
    $configuration.orchestrators[1].ownedTasks[0].Remove('prerequisites')
    Write-FactoryJsonAtomic $reviewed $configuration

    $first=Add-FactoryRockEvent $rock '100' 'joint-a' @{kind='observation';taskId='501';repository=$one.repositoryRoot;owner=$true}
    Invoke-FactoryRockEvent $rock $a $first -ModelInvoker {
        param($prompt,$request)
        Assert-Coord (@($request.coordination.rocks).Count -eq 2) 'Planner did not receive both ROCKs.'
        @{version=1;eventId=$request.event.id;summary='Access shared decision';decisions=@('Shared invariant A');actions=@(@{id='digest';type='report';text='A verified code milestone, waiting on live evidence.'})} | ConvertTo-Json -Depth 8 -Compress
    }
    $second=Add-FactoryRockEvent $rock '200' 'joint-b' @{kind='observation';taskId='601';repository=$two.repositoryRoot;owner=$true}
    Invoke-FactoryRockEvent $rock $b $second -ModelInvoker {
        param($prompt,$request)
        Assert-Coord (($request.coordination.decisions | ConvertTo-Json -Depth 12) -match 'Shared invariant A') 'Billing did not receive Access shared history.'
        @{version=1;eventId=$request.event.id;summary='Billing follows A';decisions=@('Shared invariant B');actions=@()} | ConvertTo-Json -Depth 8 -Compress
    }
    Assert-Coord (@((Read-FactoryRockCoordinatorMemory $rock).appliedEvents).Count -eq 2) 'Shared checkpoint was not persisted.'
    Invoke-FactoryRockEvent $rock $b $second -ModelInvoker { throw 'Completed event replay called the model.' }
    Assert-Coord (@((Read-FactoryRockCoordinatorMemory $rock).appliedEvents).Count -eq 2) 'Shared event replay duplicated history.'
    Assert-CoordThrows { Invoke-FactoryRockAction $rock $b ([pscustomobject]@{id='fake';payload=@{}}) ([pscustomobject]@{id='answer';type='answer';taskId='501';repository=$one.repositoryRoot;text='No'}) } 'ownership'

    $outbox=@(Get-FactoryRockBrowserItems $rock | Where-Object kind -eq 'comment')
    Assert-Coord ($outbox.Count -eq 1 -and $outbox[0].text.StartsWith('[access-orchestrator]')) 'Report did not become one attributed browser item.'
    Set-FactoryProperty $rock.direct.browserProjection 'consumerMode' 'external'
    Write-FactoryJsonAtomic $installed $rock
    Assert-Coord (@(Get-FactoryRockAttentionEvents $one (Read-FactoryJson $one.configPath) | Where-Object kind -eq 'rock-browser-work').Count -eq 0) 'External browser consumer also notified the native Claude consumer.'
    $rock.direct.browserProjection.consumerMode='orchestrator'
    Write-FactoryJsonAtomic $installed $rock
    $claim=Invoke-FactoryRockBrowserControl $rock claim '100'
    $receiptPath=Join-Path $fixture 'receipt.json'
    $receipt=@{id=$claim.id;claimId='wrong';url=$claim.url;observedText=$claim.text}
    Write-FactoryJsonAtomic $receiptPath $receipt
    Assert-CoordThrows { Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $receiptPath } 'claim'
    $receipt.claimId=$claim.claimId; $receipt.observedText=$claim.marker
    Write-FactoryJsonAtomic $receiptPath $receipt
    Assert-CoordThrows { Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $receiptPath } 'exact digest'
    $receipt.observedText=$claim.text
    Write-FactoryJsonAtomic $receiptPath $receipt
    $confirmed=Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $receiptPath
    Assert-Coord ($confirmed.status -eq 'published') 'Fresh browser evidence did not confirm publication.'
    $null=Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $receiptPath
    $id=Add-FactoryRockBrowserItem $rock '100' 'crash-window' -Text 'Second meaningful milestone.'
    $lost=Invoke-FactoryRockBrowserControl $rock claim '100'
    $lost.leaseUntil=[DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
    Write-FactoryRockJson (Join-Path (Get-FactoryRockCoordinatorPaths $rock).outbox "$id.json") $lost
    $reclaimed=Invoke-FactoryRockBrowserControl $rock claim '100'
    Assert-Coord ($reclaimed.needsVerification -and $reclaimed.claimId -cne $lost.claimId) 'Lost click was silently treated as unpublished.'
    $receipt=@{id=$reclaimed.id;claimId=$reclaimed.claimId;url=$reclaimed.url;observedText=$reclaimed.text}
    Write-FactoryJsonAtomic $receiptPath $receipt
    Assert-CoordThrows { Invoke-FactoryRockBrowserControl $rock discard -ReceiptFile $receiptPath } 'fresh claim'
    $null=Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $receiptPath

    $discardId=Add-FactoryRockBrowserItem $rock '100' 'reviewed-away' -Text 'An internal checkpoint should not be published.'
    $discardClaim=Invoke-FactoryRockBrowserControl $rock claim '100'
    Write-FactoryJsonAtomic $receiptPath @{id=$discardClaim.id;claimId=$discardClaim.claimId;reason='Supervisor review: this is internal context, not a milestone.'}
    $discarded=Invoke-FactoryRockBrowserControl $rock discard -ReceiptFile $receiptPath
    Assert-Coord ($discarded.id -ceq $discardId -and $discarded.status -eq 'superseded') 'Supervisor could not discard an unpublished internal checkpoint.'
    $questionsBefore=@((Read-FactoryRockMemory $rock '100').questions).Count
    Invoke-FactoryRockAction $rock $a ([pscustomobject]@{id='source-review';payload=@{}}) ([pscustomobject]@{id='read';type='refresh';text='Read the current report date via the browser.'})
    Assert-Coord ((Read-FactoryRockMemory $rock '100').sourceRefreshRequired -and @((Read-FactoryRockMemory $rock '100').questions).Count -eq $questionsBefore) 'Read-only browser refresh became a human question.'
    $null=Update-FactoryRockMemory $rock '100' {param($memory) $memory.sourceRefreshRequired=$false}
    Invoke-FactoryRockAction $rock $a ([pscustomobject]@{id='review-fixture';payload=@{}}) ([pscustomobject]@{id='ask';type='escalate';text='An erroneous agent question, pending supervisor review.'})
    $withdrawOutput=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') rock withdraw 100 review-fixture/ask --text 'New browser evidence answers this factual question.' -Repository $one.repositoryRoot
    Assert-Coord ($LASTEXITCODE -eq 0) "Native question withdrawal failed: $withdrawOutput"
    $withdrawn=@((Read-FactoryRockMemory $rock '100').questions | Where-Object id -eq 'review-fixture/ask')[0]
    Assert-Coord ($withdrawn.status -eq 'withdrawn' -and -not $withdrawn.answer) 'Withdrawal manufactured an operator answer.'
    $reviewEvent=Add-FactoryRockEvent $rock '100' 'after-withdrawal' @{kind='supervisor-review';owner=$false}
    Invoke-FactoryRockEvent $rock $a $reviewEvent -ModelInvoker {
        param($prompt,$request)
        Assert-Coord (@($request.memory.questions | Where-Object { $_.id -eq 'review-fixture/ask' -and $_.status -eq 'withdrawn' }).Count -eq 1) 'Compact memory hid withdrawal and could resurrect a stale question.'
        Assert-Coord (($request.memory.decisions | ConvertTo-Json -Depth 8) -match 'New browser evidence answers') 'Planner lost supervisor review reasons.'
        @{version=1;eventId=$request.event.id;summary='Supervisor correction retained';decisions=@();actions=@()} | ConvertTo-Json -Depth 8 -Compress
    }

    $ready=Join-Path $fixture 'mutex-ready'; $release=Join-Path $fixture 'mutex-release'
    $pwsh=Get-Command pwsh -ErrorAction SilentlyContinue
    if($null -ne $pwsh){
        $ps7Probe=Join-Path $fixture 'ps7-browser-receipt.ps1'
        [IO.File]::WriteAllText($ps7Probe, @'
param($Root,$ConfigPath,$ReceiptPath)
$ErrorActionPreference='Stop'
[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('ru-RU')
. (Join-Path $Root 'scripts\rock-common.ps1')
$cfg=Get-FactoryRockConfiguration -ConfigPath $ConfigPath
$id=Add-FactoryRockBrowserItem $cfg '200' 'ps7-roundtrip' -Text 'A verified PS7 browser milestone.'
$claim=Invoke-FactoryRockBrowserControl $cfg claim '200'
if($claim.id -cne $id){throw 'Unexpected PS7 browser claim.'}
Write-FactoryJsonAtomic $ReceiptPath @{id=$id;claimId=$claim.claimId;url=$claim.url;observedText=$claim.text}
$confirmed=Invoke-FactoryRockBrowserControl $cfg confirm -ReceiptFile $ReceiptPath
if($confirmed.status -ne 'published'){throw 'PS7 date/receipt roundtrip failed.'}
'@)
        $probeOutput=& $pwsh.Source -NoProfile -File $ps7Probe $PluginRoot $installed (Join-Path $fixture 'ps7-receipt.json')
        Assert-Coord ($LASTEXITCODE -eq 0) "PowerShell 7 / ru-RU browser receipt failed: $probeOutput"
    }
    $job=Start-Job -ArgumentList $PluginRoot,$installed,$ready,$release -ScriptBlock {
        param($Root,$ConfigPath,$Ready,$Release)
        . (Join-Path $Root 'scripts\rock-common.ps1')
        $cfg=Get-FactoryRockConfiguration -ConfigPath $ConfigPath
        $m=New-Object Threading.Mutex($false,(Get-FactoryRockCoordinatorPaths $cfg).mutexName)
        try { $null=$m.WaitOne(); [IO.File]::WriteAllText($Ready,'ready'); $deadline=[DateTime]::UtcNow.AddSeconds(30); while(-not [IO.File]::Exists($Release) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50} } finally { $m.ReleaseMutex();$m.Dispose() }
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while(-not [IO.File]::Exists($ready) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    Assert-Coord ([IO.File]::Exists($ready)) 'Mutex fixture did not acquire the coordinator.'
    $busy=Invoke-FactoryRockCoordinatorCycle $rock -ModelInvoker { throw 'A second coordinator entered the model.' }
    Assert-Coord $busy.busy 'Two factories ran the shared coordinator concurrently.'
    [IO.File]::WriteAllText($release,'release'); $null=Wait-Job $job -Timeout 10; $null=Receive-Job $job -ErrorAction Stop
    Remove-Job $job; $job=$null
    $script:coordModelCalls=0
    $model={param($prompt,$request) $script:coordModelCalls++; @{version=1;eventId=$request.event.id;summary='Current inputs reconciled';decisions=@();actions=@()} | ConvertTo-Json -Depth 8 -Compress}
    $null=Invoke-FactoryRockCoordinatorCycle $rock -Reason schedule -ModelInvoker $model
    $script:coordModelCalls=0
    $unchanged=Invoke-FactoryRockCoordinatorCycle $rock -Reason schedule -ModelInvoker $model
    Assert-Coord ($unchanged.processed -eq 0 -and $script:coordModelCalls -eq 0) 'Unchanged scheduled inputs paid for another model cycle.'
    $queued=(Read-FactoryJson $one.statePath).tasks[0]
    $queued.status='running'
    Set-CoordFixtureTasks $one @($queued)
    Sync-FactoryRockBrowserStatuses $rock $one (Read-FactoryJson $one.statePath)
    $statuses=@(Get-FactoryRockBrowserItems $rock | Where-Object {$_.kind -eq 'status' -and $_.targetGid -eq '501' -and $_.status -eq 'pending'})
    Assert-Coord ($statuses.Count -eq 1 -and $statuses[0].factoryState -eq 'Taken') 'Status projection did not coalesce an obsolete Ready.'
    $configuration.orchestrators[0].ownedTasks[0].mode='observe'
    Write-FactoryJsonAtomic $reviewed $configuration
    $null=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'factory.ps1') rock configure -Repository $one.repositoryRoot -File $reviewed
    $rock=Get-FactoryRockConfiguration -ConfigPath $installed
    Assert-Coord (-not (Test-FactoryRockTaskLaunchPrerequisites $one (Read-FactoryJson $one.configPath) $queued).ready) 'Observation-only binding permitted a worker launch.'
    Assert-CoordThrows { Invoke-FactoryRockAction $rock (Get-FactoryRockOrchestrator $rock '100') ([pscustomobject]@{id='observe';payload=@{}}) ([pscustomobject]@{id='dispatch';type='dispatch';taskId='501';repository=$one.repositoryRoot;title='No';brief='No'}) } 'Observation-only'
    Write-Output 'Shared ROCK coordinator tests passed (two repositories, shared memory, mutex, graph, launch gates, archive, browser receipts, crash recovery, no-change scheduling).'
} finally {
    if($nativeWorkerMayExist -and $null -ne $one){try{$null=& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\reject-task.ps1') -Repository $one.repositoryRoot -TaskId 502 -Yes -ClaudeCommand $fakeClaude -CodexCommand $fakeCodex}catch{}}
    if($env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH -and $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH.StartsWith($fixture,[StringComparison]::OrdinalIgnoreCase)){[IO.File]::WriteAllText($env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH,'release')}
    $env:CLAUDE_FACTORY_TEST_CODEX_WORKER_RELEASE_PATH=$oldWorkerRelease
    if($null -ne $job){Stop-Job $job -ErrorAction SilentlyContinue;Remove-Job $job -Force}
    $env:CLAUDE_FACTORY_HOME=$savedHome
    $absolute=[IO.Path]::GetFullPath($fixture)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\factory-rock-coordinator-'
    if($absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
