[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PluginRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PluginRoot 'scripts\rock-actions.ps1')
function Assert-Publication {param([bool]$Value,[string]$Message) if(-not $Value){throw $Message}}
function Assert-PublicationThrows {param([scriptblock]$Code,[string]$Pattern) $message='';try{& $Code|Out-Null}catch{$message=$_.Exception.Message};Assert-Publication ($message -match $Pattern) "Expected $Pattern; got $message"}
function Set-PublicationTasks {param($Context,$Tasks) $m=Enter-FactoryMutex $Context.projectKey;try{$s=Read-FactoryJson $Context.statePath;$s.tasks=@($Tasks);Write-FactoryJsonAtomic $Context.statePath $s}finally{Exit-FactoryMutex $m}}
function Invoke-PublicationCli {param([string[]]$Arguments) Invoke-FactoryNativeProcess powershell (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PluginRoot 'factory.ps1'))+$Arguments) -TimeoutSeconds 60}
$fixture=Join-Path ([IO.Path]::GetTempPath()) "factory-publication-tests-$([Guid]::NewGuid().ToString('N'))"
$savedHome=$env:CLAUDE_FACTORY_HOME
try{
    $env:CLAUDE_FACTORY_HOME=Join-Path $fixture 'runtime'
    $contexts=@()
    foreach($name in @('hr','auditors')){
        $repo=Join-Path $fixture $name;$null=New-Item -ItemType Directory -Path $repo -Force
        git -C $repo init --quiet
        git -C $repo -c user.name=PublicationTest -c user.email=test@example.invalid -c commit.gpgsign=false commit --allow-empty --quiet -m fixture
        if($LASTEXITCODE){throw 'Cannot initialize fixture.'}
        $contexts+=& (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repo -Initialize|ConvertFrom-Json
    }
    $one=$contexts[0];$two=$contexts[1]
    $head=(& git -C $one.repositoryRoot rev-parse HEAD).Trim()
    $reviewed=Join-Path $fixture 'reviewed.json'
    Write-FactoryJsonAtomic $reviewed @{claudePath='must-never-run';timeoutMinutes=1;direct=@{enabled=$true;coordinatorId='publication-test';memoryDir=(Join-Path $fixture 'rocks');publication=@{enabled=$true;transport='disabled'}};orchestrators=@(
        @{name='access';epicGid='100';epicUrl='https://app.asana.com/0/0/100';repoPath=$one.repositoryRoot;extraDirs=@();ownedTasks=@(@{taskId='501';repository=$one.repositoryRoot});watchedTasks=@(@{taskId='601';repository=$two.repositoryRoot})},
        @{name='billing';epicGid='200';epicUrl='https://app.asana.com/0/0/200';repoPath=$two.repositoryRoot;extraDirs=@();ownedTasks=@(@{taskId='601';repository=$two.repositoryRoot});watchedTasks=@(@{taskId='501';repository=$one.repositoryRoot})})}
    foreach($ctx in $contexts){
        $configured=Invoke-PublicationCli @('rock','configure','-Repository',$ctx.repositoryRoot,'-File',$reviewed)
        Assert-Publication ($configured.exitCode -eq 0) $configured.output
        $cfg=Read-FactoryJson $ctx.configPath;$cfg.nativeScheduler.enabled=$false;Write-FactoryJsonAtomic $ctx.configPath $cfg
    }
    $rock=Get-FactoryRockConfiguration -ConfigPath ([string](Read-FactoryJson $one.configPath).rocks.configPath)
    $a=[pscustomobject]@{id='501';url='https://app.asana.com/0/0/501';title='HR work';status='done';attempts=1;runId='hr-run';commit=$head;integration=@{status='published';taskCommit=$head};source=@{adapter='asana';id='501';url='https://app.asana.com/0/0/501'}}
    $b=[pscustomobject]@{id='601';url='https://app.asana.com/0/0/601';title='Auditor work';status='done';attempts=1;runId='auditor-run';commit=$head;integration=@{status='published';taskCommit=$head}}
    Set-PublicationTasks $one @($a);Set-PublicationTasks $two @($b)
    $id=Add-FactoryRockBrowserItem $rock '100' 'joint-result' -Text 'Both factories produced code; deployment is not asserted.'
    $proposal=@(Get-FactoryRockBrowserItems $rock|Where-Object id -eq $id)[0]
    Assert-Publication (@($proposal.publication.factories).Count -eq 2) 'Cross-repository digest omitted a factory review.'
    Assert-Publication ($null -eq (Invoke-FactoryRockBrowserControl $rock claim '100')) 'Coordinator claimed an unapproved digest.'
    $events=@(Get-FactoryRockAttentionEvents $one (Read-FactoryJson $one.configPath))
    Assert-Publication (@($events|Where-Object kind -eq 'rock-publication-review').Count -eq 1 -and @($events|Where-Object kind -eq 'rock-browser-work').Count -eq 0) 'Factory was told to publish rather than review.'
    $reviewFile=Join-Path $fixture 'review.json'
    foreach($ctx in $contexts){
        $list=Invoke-PublicationCli @('rock','publication','list','-Repository',$ctx.repositoryRoot)
        Assert-Publication ($list.exitCode -eq 0) $list.output
        $request=@($list.stdout|ConvertFrom-Json)[0]
        Write-FactoryJsonAtomic $reviewFile @{id=$id;revision=$request.revision;factsHash=$request.factsHash;decision='approve';reason='Factory facts checked.'}
        $approval=Invoke-PublicationCli @('rock','publication','review','-File',$reviewFile,'-Repository',$ctx.repositoryRoot)
        Assert-Publication ($approval.exitCode -eq 0) $approval.output
        if($ctx -eq $one){Assert-Publication (-not ($approval.stdout|ConvertFrom-Json).approved) 'One factory approved another factory evidence.'}
    }
    $proposal=@(Get-FactoryRockBrowserItems $rock|Where-Object id -eq $id)[0]
    Assert-Publication (Test-FactoryRockPublicationApproved $rock $proposal) 'Two reviews did not release the coordinator.'
    $a.attempts=2;$a.runId='replacement-run';Set-PublicationTasks $one @($a)
    Assert-Publication ($null -eq (Invoke-FactoryRockBrowserControl $rock claim '100')) 'Stale run approval allowed publication.'
    Sync-FactoryRockPublicationProposals $rock
    $request=@(Get-FactoryRockPublicationReviews $rock $one.repositoryRoot)[0]
    Assert-Publication ($request.revision -eq 2) 'Changed evidence did not reset the proposal revision.'
    Assert-PublicationThrows {Submit-FactoryRockPublicationReview $rock $one $reviewFile} 'stale revision'
    Write-FactoryJsonAtomic $reviewFile @{id=$id;revision=$request.revision;factsHash=$request.factsHash;decision='revise';text='Both factories produced code. HR used replacement-run. No deployed behavior is asserted.';reason='Corrected the native run.'}
    $revised=Submit-FactoryRockPublicationReview $rock $one $reviewFile
    Assert-Publication ($revised.revision -eq 3 -and -not $revised.approved) 'Factory correction did not reset peer review.'
    $request=@(Get-FactoryRockPublicationReviews $rock $two.repositoryRoot)[0]
    Write-FactoryJsonAtomic $reviewFile @{id=$id;revision=$request.revision;factsHash=$request.factsHash;decision='approve'}
    $null=Submit-FactoryRockPublicationReview $rock $two $reviewFile
    $null=Update-FactoryRockCoordinatorMemory $rock {param($m)$m.paused=$true}
    Assert-Publication ($null -eq (Invoke-FactoryRockBrowserControl $rock claim '100')) 'Paused coordinator claimed a publication.'
    $null=Update-FactoryRockCoordinatorMemory $rock {param($m)$m.paused=$false}
    $claim=Invoke-FactoryRockBrowserControl $rock claim '100'
    Assert-Publication ($claim.id -ceq $id -and $claim.text -match 'replacement-run') 'Coordinator did not receive the factory-corrected digest.'
    $proof=Join-Path $fixture 'browser-proof.json'
    Write-FactoryJsonAtomic $proof @{id=$id;claimId=$claim.claimId;url=$claim.url;observedText=$claim.text}
    $a.commit='f'*40;Set-PublicationTasks $one @($a)
    Assert-PublicationThrows {Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $proof} 'stale'
    $a.commit=$head;Set-PublicationTasks $one @($a)
    $confirmed=Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $proof
    Assert-Publication ($confirmed.status -eq 'published') 'Approved digest proof was not retained.'
    $null=Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $proof

    # The existing ROCK Asana adapter is guarded independently of model prose.
    $guardId=Add-FactoryRockBrowserItem $rock '100' 'guarded-publication' -Text 'Verified code milestone; no deployment assertion.'
    foreach($ctx in $contexts){$request=@(Get-FactoryRockPublicationReviews $rock $ctx.repositoryRoot|Where-Object id -eq $guardId)[0];Write-FactoryJsonAtomic $reviewFile @{id=$guardId;revision=$request.revision;factsHash=$request.factsHash;decision='approve'};$null=Submit-FactoryRockPublicationReview $rock $ctx $reviewFile}
    $guardClaim=Invoke-FactoryRockBrowserControl $rock claim '100'
    $prepared=New-FactoryRockPublisherRequest $rock $guardClaim
    Assert-PublicationThrows {New-FactoryRockPublisherRequest $rock $guardClaim} 'already has delivery evidence'
    $guardSettings=Read-FactoryJson $prepared.paths.settings
    Assert-Publication ($guardSettings.hooks.PreToolUse[0].hooks[0].onFailure -eq 'block') 'A failed publication hook would fail open.'
    function Invoke-GuardFixture {param($Event,$Tool,$ToolArguments,$Response=$null) Invoke-FactoryRockAsanaToolHook $rock $guardClaim.id $guardClaim.claimId ([pscustomobject]@{hook_event_name=$Event;tool_name=$Tool;tool_input=[pscustomobject]$ToolArguments;tool_response=$Response})}
    $add=@{task_id='100';text=$guardClaim.text}
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__add_comment $add} 'inspection'
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__get_task @{task_id='999'}} 'target'
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__get_task @{task_id='100';include_subtasks=$true}} 'only the target'
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse Bash @{command='anything'}} 'cannot use'
    Invoke-GuardFixture PostToolUse mcp__claude_ai_Asana__get_task @{task_id='100'} ([pscustomobject]@{data=[pscustomobject]@{gid='100';completed=$false}})
    Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='100';limit=20}
    Invoke-GuardFixture PostToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='100'} ([pscustomobject]@{data=@();next_page=[pscustomobject]@{offset='page-two'}})
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__add_comment $add} 'inspection'
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='100';limit=100}} 'bounded pages'
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='100';limit=20;offset='skip'}} 'cursor'
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='100';limit=20;offset='page-two';opt_fields='gid'}} 'retain all'
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='100';limit=20;offset='page-two';sort_ascending=$false}} 'changed projection'
    Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='100';limit=20;offset='page-two'}
    Invoke-GuardFixture PostToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='100';offset='page-two'} ([pscustomobject]@{data=@();next_page=$null})
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__add_comment @{task_id='100';text='Unapproved text'}} 'exact approved'
    Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__add_comment $add
    Assert-PublicationThrows {Invoke-GuardFixture PreToolUse mcp__claude_ai_Asana__add_comment $add} 'inspection'
    Invoke-GuardFixture PostToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='100'} ([pscustomobject]@{data=@([pscustomobject]@{gid='901';text=$guardClaim.text;resource_subtype='comment_added';created_at=Get-FactoryUtcTimestamp});next_page=$null})
    $guardAudit=Read-FactoryJson $prepared.paths.audit
    Assert-Publication ($null -ne $guardAudit.proof -and $guardAudit.proof.storyGid -ceq '901') 'Actual tool-read did not produce independent publication proof.'
    Write-FactoryJsonAtomic $proof @{id=$guardClaim.id;claimId=$guardClaim.claimId;url=$guardAudit.proof.url;observedText=$guardAudit.proof.observedText}
    $null=Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $proof

    # Ready delivery is handled natively, not fed back to the planning model.
    $nativeEvent=Add-FactoryRockEvent $rock '100' 'native-publication-ready-probe' @{kind='publication-ready';owner=$false;itemId=$guardId;revision=1}
    $script:publicationPlanningCalls=0
    $model={param($prompt,$request)$script:publicationPlanningCalls++;@{version=1;eventId=$request.event.id;summary='Task inputs recorded';decisions=@();actions=@()}|ConvertTo-Json -Depth 8 -Compress}
    $null=Invoke-FactoryRockCoordinatorCycle $rock -ModelInvoker $model
    Assert-Publication ((Read-FactoryJson $nativeEvent).status -eq 'completed') 'Native publication signal was not dispatched.'
    $script:publicationPlanningCalls=0
    $null=Invoke-FactoryRockCoordinatorCycle $rock -ModelInvoker $model
    Assert-Publication ($script:publicationPlanningCalls -eq 0) 'Unchanged publication queue caused another planning call.'

    # The real existing update_tasks schema uses tasks[].task (not task_id).
    $cfg=Read-FactoryJson $one.configPath
    Set-FactoryProperty $cfg.asana 'fields' ([pscustomobject]@{factory='901';done='902';resolution='903';resolutionFixed='904'})
    Write-FactoryJsonAtomic $one.configPath $cfg
    Set-FactoryProperty $a 'rockId' '100';Set-PublicationTasks $one @($a)
    Sync-FactoryRockBrowserStatuses $rock $one (Read-FactoryJson $one.statePath)
    $statusClaim=Invoke-FactoryRockBrowserControl $rock claim '100'
    Assert-Publication ($statusClaim.kind -eq 'status' -and $statusClaim.factoryState -eq 'Done') 'Native status projection was not attested.'
    $statusPrepared=New-FactoryRockPublisherRequest $rock $statusClaim
    $mutation=$statusPrepared.mutation|ConvertTo-Json -Depth 10 -Compress|ConvertFrom-Json
    Assert-Publication ($mutation.tasks[0].task -ceq '501' -and $null -eq $mutation.tasks[0].PSObject.Properties['task_id']) 'Existing Asana update_tasks schema was not respected.'
    function Invoke-StatusGuard {param($Event,$Tool,$ToolArguments,$Response=$null) Invoke-FactoryRockAsanaToolHook $rock $statusClaim.id $statusClaim.claimId ([pscustomobject]@{hook_event_name=$Event;tool_name=$Tool;tool_input=$ToolArguments;tool_response=$Response})}
    $openTask=[pscustomobject]@{data=[pscustomobject]@{gid='501';completed=$false;custom_fields=@([pscustomobject]@{gid='901';enum_value=[pscustomobject]@{gid='905'}})}}
    Invoke-StatusGuard PostToolUse mcp__claude_ai_Asana__get_task @{task_id='501'} $openTask
    Invoke-StatusGuard PostToolUse mcp__claude_ai_Asana__get_task_stories @{task_id='501'} ([pscustomobject]@{data=@();next_page=$null})
    Set-FactoryProperty $mutation.tasks[0] 'assignee' 'me'
    Assert-PublicationThrows {Invoke-StatusGuard PreToolUse mcp__claude_ai_Asana__update_tasks $mutation} 'unapproved fields'
    $mutation.tasks[0].PSObject.Properties.Remove('assignee')
    Set-FactoryProperty $openTask.data 'resource_subtype' 'approval'
    Invoke-StatusGuard PostToolUse mcp__claude_ai_Asana__get_task @{task_id='501'} $openTask
    Assert-PublicationThrows {Invoke-StatusGuard PreToolUse mcp__claude_ai_Asana__update_tasks $mutation} 'human approval'
    $openTask.data.resource_subtype='default_task'
    Invoke-StatusGuard PostToolUse mcp__claude_ai_Asana__get_task @{task_id='501'} $openTask
    $a.attempts=3;Set-PublicationTasks $one @($a)
    Assert-PublicationThrows {Invoke-StatusGuard PreToolUse mcp__claude_ai_Asana__update_tasks $mutation} 'stale'
    $a.attempts=2;Set-PublicationTasks $one @($a)
    Invoke-StatusGuard PreToolUse mcp__claude_ai_Asana__update_tasks $mutation
    Invoke-StatusGuard PostToolUse mcp__claude_ai_Asana__get_task @{task_id='501'} ([pscustomobject]@{data=[pscustomobject]@{gid='501';completed=$true;custom_fields=@([pscustomobject]@{gid='901';enum_value=[pscustomobject]@{gid='902'}},[pscustomobject]@{gid='903';enum_value=[pscustomobject]@{gid='904'}})}})
    $statusAudit=Read-FactoryJson $statusPrepared.paths.audit
    Assert-Publication ($statusAudit.proof.factoryState -ceq 'Done') 'Exact completed/custom field readback was not retained.'
    Write-FactoryJsonAtomic $proof @{id=$statusClaim.id;claimId=$statusClaim.claimId;url=$statusAudit.proof.url;factoryState=$statusAudit.proof.factoryState;observedText=$statusAudit.proof.observedText}
    $null=Invoke-FactoryRockBrowserControl $rock confirm -ReceiptFile $proof

    $humanId=Add-FactoryRockBrowserItem $rock '100' 'human-hold' -Text 'This proposal must yield to a newer human instruction.'
    foreach($ctx in $contexts){$request=@(Get-FactoryRockPublicationReviews $rock $ctx.repositoryRoot|Where-Object id -eq $humanId)[0];Write-FactoryJsonAtomic $reviewFile @{id=$humanId;revision=$request.revision;factsHash=$request.factsHash;decision='approve'};$null=Submit-FactoryRockPublicationReview $rock $ctx $reviewFile}
    $humanClaim=Invoke-FactoryRockBrowserControl $rock claim '100'
    $null=New-FactoryRockPublisherRequest $rock $humanClaim
    Invoke-FactoryRockAsanaToolHook $rock $humanClaim.id $humanClaim.claimId ([pscustomobject]@{hook_event_name='PostToolUse';tool_name='mcp__claude_ai_Asana__get_task';tool_input=@{task_id='100'};tool_response=[pscustomobject]@{data=[pscustomobject]@{gid='100';completed=$false}}})
    Invoke-FactoryRockAsanaToolHook $rock $humanClaim.id $humanClaim.claimId ([pscustomobject]@{hook_event_name='PostToolUse';tool_name='mcp__claude_ai_Asana__get_task_stories';tool_input=@{task_id='100'};tool_response=[pscustomobject]@{data=@([pscustomobject]@{gid='999';text='Hold this update until I verify it.';resource_subtype='comment_added';created_at=[DateTimeOffset]::UtcNow.AddSeconds(2).ToString('o')});next_page=$null}})
    Assert-PublicationThrows {Invoke-FactoryRockAsanaToolHook $rock $humanClaim.id $humanClaim.claimId ([pscustomobject]@{hook_event_name='PreToolUse';tool_name='mcp__claude_ai_Asana__add_comment';tool_input=[pscustomobject]@{task_id='100';text=$humanClaim.text}})} 'conflict-free'
    Write-FactoryJsonAtomic $proof @{id=$humanClaim.id;claimId=$humanClaim.claimId;reason='New human hold requires inspection.'}
    $null=Invoke-FactoryRockBrowserControl $rock defer -ReceiptFile $proof
    Assert-Publication (@(Get-FactoryRockAttentionEvents $one (Read-FactoryJson $one.configPath)|Where-Object kind -eq 'rock-publication-blocked').Count -eq 1) 'Blocked coordinator delivery disappeared from native attention.'

    $deliveryId=Add-FactoryRockBrowserItem $rock '100' 'driver-proof' -Text 'Native delivery callback milestone.'
    foreach($ctx in $contexts){$request=@(Get-FactoryRockPublicationReviews $rock $ctx.repositoryRoot|Where-Object id -eq $deliveryId)[0];Write-FactoryJsonAtomic $reviewFile @{id=$deliveryId;revision=$request.revision;factsHash=$request.factsHash;decision='approve'};$null=Submit-FactoryRockPublicationReview $rock $ctx $reviewFile}
    $pauseMutex=Enter-FactoryMutex $one.projectKey
    try{$pausedState=Read-FactoryJson $one.statePath;$pausedState.paused=$true;Write-FactoryJsonAtomic $one.statePath $pausedState}finally{Exit-FactoryMutex $pauseMutex}
    $pausedDelivery=Invoke-FactoryRockPublication $rock '100' -PublisherInvoker {throw 'Paused factory reached its publisher.'}
    Assert-Publication ($pausedDelivery.published -eq 0 -and $pausedDelivery.empty) 'A factory pause did not block coordinator publication.'
    $pauseMutex=Enter-FactoryMutex $one.projectKey
    try{$pausedState=Read-FactoryJson $one.statePath;$pausedState.paused=$false;Write-FactoryJsonAtomic $one.statePath $pausedState}finally{Exit-FactoryMutex $pauseMutex}
    foreach($ctx in $contexts){$request=@(Get-FactoryRockPublicationReviews $rock $ctx.repositoryRoot|Where-Object id -eq $deliveryId)[0];Write-FactoryJsonAtomic $reviewFile @{id=$deliveryId;revision=$request.revision;factsHash=$request.factsHash;decision='approve'};$null=Submit-FactoryRockPublicationReview $rock $ctx $reviewFile}
    $delivered=Invoke-FactoryRockCoordinatorCycle $rock -Epic access -ModelInvoker $model -PublisherInvoker {param($cfg,$item) [pscustomobject]@{url=$item.url;observedText=$item.text}}
    Assert-Publication ($delivered.publication.published -eq 1 -and @((Get-FactoryRockBrowserItems $rock)|Where-Object { $_.id -eq $deliveryId -and $_.status -eq 'published' }).Count -eq 1) 'Native publication driver failed for a named ROCK selector.'

    # Actual native add intake stays out of the legacy Asana question loop.
    $intake=Join-Path $fixture 'intake.json'
    Write-FactoryJsonAtomic $intake @{version=1;source=@{adapter='asana';id='701';url='https://app.asana.com/0/0/701'};startMode='auto';title='Ordinary Asana add';brief="Repo: fixture/hr`nA real normalized intake fixture";acceptanceCriteria=@('Native completion');sourceNotes=@();sourceError=$null}
    $null=& (Join-Path $PluginRoot 'scripts\enqueue-task.ps1') -Repository $one.repositoryRoot -IntakePath $intake -NoResume
    $ordinary=@((Read-FactoryJson $one.statePath).tasks|Where-Object id -eq '701')[0]
    Assert-Publication (-not $ordinary.asanaMode -and $ordinary.source.adapter -eq 'asana') 'Add enabled the Asana worker transport.'
    $cfg=Read-FactoryJson $one.configPath
    Assert-Publication ($null -eq (Get-FactoryPendingSourceCompletion $ordinary $cfg)) 'Queued add task requested source completion.'
    $ordinary.status='done';$ordinary.commit=$head;$ordinary.attempts=1
    Set-FactoryProperty $ordinary 'integration' ([pscustomobject]@{status='published';taskCommit=$head})
    Set-PublicationTasks $one @($a,$ordinary)
    $pending=Get-FactoryPendingSourceCompletion $ordinary $cfg
    Assert-Publication ($null -ne $pending) 'Done ordinary Asana add did not request completion.'
    Assert-Publication ($null -eq (Get-FactoryPendingSourceCompletion $a $cfg)) 'ROCK-owned task bypassed the coordinator source closure.'
    $events=@(Get-FactoryOperatorActionEvents (Read-FactoryJson $one.statePath) $cfg)
    Assert-Publication (@($events|Where-Object kind -eq 'source-completion').Count -eq 1) 'No event-driven source completion was delivered.'
    foreach($status in @('failed','held','approved','running')){$ordinary.status=$status;Assert-Publication ($null -eq (Get-FactoryPendingSourceCompletion $ordinary $cfg)) 'Unfinished task requested source closure.'}
    $ordinary.status='done';$ordinary.integration.taskCommit='a'*40
    Assert-Publication ($null -eq (Get-FactoryPendingSourceCompletion $ordinary $cfg)) 'Mismatched publication released source closure.'
    $ordinary.integration.taskCommit=$head
    $ordinary.source.id='999';Assert-Publication ($null -eq (Get-FactoryPendingSourceCompletion $ordinary $cfg)) 'Foreign Asana identity was accepted.';$ordinary.source.id='701'
    $sourceProof=Join-Path $fixture 'source-proof.json'
    $beforeConfirmation=Read-FactoryJson $one.statePath
    Write-FactoryJsonAtomic $sourceProof @{fingerprint=$pending.fingerprint;url=$pending.url;completed=$false;observedText='Task is open'}
    $badProof=Invoke-PublicationCli @('source','confirm','701','-File',$sourceProof,'-Repository',$one.repositoryRoot)
    Assert-Publication ($badProof.exitCode -ne 0) 'Source confirmation accepted an open card.'
    Write-FactoryJsonAtomic $sourceProof @{fingerprint=$pending.fingerprint;url=$pending.url;completed=$true;observedText='Completed - Ordinary Asana add (701)'}
    $success=Invoke-PublicationCli @('source','confirm','701','-File',$sourceProof,'-Repository',$one.repositoryRoot)
    Assert-Publication ($success.exitCode -eq 0 -and ($success.stdout|ConvertFrom-Json).confirmed) "Source closure receipt failed: $($success.output)"
    $replay=Invoke-PublicationCli @('source','confirm','701','-File',$sourceProof,'-Repository',$one.repositoryRoot)
    Assert-Publication ($replay.exitCode -eq 0 -and ($replay.stdout|ConvertFrom-Json).alreadyConfirmed) 'Source closure receipt was not idempotent.'
    $final=Read-FactoryJson $one.statePath
    Assert-Publication ([bool]$final.active -eq [bool]$beforeConfirmation.active -and [bool]$final.paused -eq [bool]$beforeConfirmation.paused -and -not [bool](@($final.tasks|Where-Object id -eq '701')[0].asanaMode)) 'Source completion changed Factory activity, pause or worker mode.'
    Assert-Publication ($null -eq (Get-FactoryPendingSourceCompletion @($final.tasks|Where-Object id -eq '701')[0] $cfg)) 'Confirmed source completion kept waking the orchestrator.'
    Write-Output 'ROCK factory publication agreement and ordinary Asana source completion tests passed.'
}finally{
    $env:CLAUDE_FACTORY_HOME=$savedHome
    $absolute=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\factory-publication-tests-'
    if($absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
