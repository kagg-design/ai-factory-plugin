[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Repository,[ValidateSet('list','confirm')][string]$Action='list',[string]$TaskId='',[string]$File='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
$context=& (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository | ConvertFrom-Json
$config=Read-FactoryJson $context.configPath
if($Action -eq 'list'){
    $state=Read-FactoryJson $context.statePath
    if([bool]$state.paused){return}
    @($state.tasks | ForEach-Object { Get-FactoryPendingSourceCompletion $_ $config } | Where-Object {$null -ne $_}) | ConvertTo-Json -Depth 10
    return
}
if(-not $TaskId -or -not $File){throw 'Use: factory source confirm TASK_ID --file BROWSER_RECEIPT'}
$receipt=Read-FactoryJson ([IO.Path]::GetFullPath($File))
$mutex=Enter-FactoryMutex ([string]$context.projectKey)
try{
    $state=Read-FactoryJson $context.statePath
    if([bool]$state.paused){throw 'Factory is paused; source completion is deferred.'}
    $task=Get-FactoryTask -State $state -TaskId $TaskId
    $previous=Get-FactoryNestedValue $task 'sourceCompletion'
    if([string]$task.status -eq 'done' -and $null -ne $previous -and [string]$previous.fingerprint -ceq [string](Get-FactoryNestedValue $receipt 'fingerprint') -and [string]$previous.commit -ceq [string]$task.commit -and [int]$previous.attempts -eq [int]$task.attempts -and [string]$previous.runId -ceq [string](Get-FactoryNestedValue $task 'runId')){
        @{taskId=$TaskId;alreadyConfirmed=$true}|ConvertTo-Json;return
    }
    $pending=Get-FactoryPendingSourceCompletion $task $config
    if($null -eq $pending -or [string](Get-FactoryNestedValue $receipt 'fingerprint') -cne [string]$pending.fingerprint){throw 'Source completion is absent or its task/run/commit evidence changed.'}
    $observed=Resolve-FactoryAsanaTaskUrl -Url ([string](Get-FactoryNestedValue $receipt 'url'))
    if([string]$observed.taskId -cne $TaskId){throw 'Observed Asana task differs from the native source.'}
    $completed=Get-FactoryNestedValue $receipt 'completed'
    $text=[string](Get-FactoryNestedValue $receipt 'observedText')
    if($completed -isnot [bool] -or -not $completed -or -not $text.Trim() -or $text.Length -gt 16000){throw 'Receipt requires freshly observed completed=true and browser evidence.'}
    Set-FactoryProperty $task 'sourceCompletion' ([pscustomobject]@{adapter='asana';taskId=$TaskId;fingerprint=$pending.fingerprint;commit=$pending.commit;attempts=$pending.attempts;runId=$pending.runId;url=[string]$observed.canonicalUrl;observedText=$text;completedAt=Get-FactoryUtcTimestamp;actor="factory:$($context.projectKey)"})
    Set-FactoryProperty $task 'asanaSyncedState' 'Done'
    Write-FactoryJsonAtomic $context.statePath $state
    @{taskId=$TaskId;confirmed=$true}|ConvertTo-Json
}finally{Exit-FactoryMutex $mutex}
