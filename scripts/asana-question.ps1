[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$Question,
    [Parameter(Mandatory = $true)][string]$QuestionContext,
    [Parameter(Mandatory = $true)][string]$Options,
    [ValidateSet('A', 'B')][string]$Default = 'A'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
. (Join-Path $PSScriptRoot 'asana-common.ps1')
if ($TaskId -notmatch '^\d+$') { throw 'Asana question requires a numeric task GID.' }
$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$state = Read-FactoryJson -Path $context.statePath
$task = Get-FactoryTask -State $state -TaskId $TaskId
if (-not [bool](Get-FactoryNestedValue -Target $task -Name 'asanaMode' -Default $false)) {
    throw "Task '$TaskId' is not in Asana mode."
}
if ([string]$task.status -notin @('running', 'awaiting-input', 'planning')) {
    throw "Task '$TaskId' cannot ask an Asana question from '$($task.status)'."
}
$remote = Get-FactoryAsanaTask -Config $config -Gid $TaskId
if ((Get-FactoryAsanaField -Task $remote -Gid ([string]$config.asana.fields.factory)) -ne [string]$config.asana.fields.taken) {
    throw "Asana task '$TaskId' is not Taken."
}
$message = "QUESTION (factory):`n1. $Question`n   Context: $QuestionContext`n   Options: $Options`n   Default if no answer: $Default"
$story = Add-FactoryAsanaComment -Config $config -Gid $TaskId -Text $message
Set-FactoryAsanaField -Config $config -Gid $TaskId -Field ([string]$config.asana.fields.factory) -Value ([string]$config.asana.fields.question)
Write-FactoryAsanaTransition -Context $context -Gid $TaskId -From 'Taken' -To 'Question' -WorkerId $TaskId

$mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
try {
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId
    Set-FactoryProperty -Target $task -Name 'asanaState' -Value 'Question'
    Set-FactoryProperty -Target $task -Name 'asanaQuestion' -Value ([pscustomobject][ordered]@{
        storyGid = [string]$story.gid
        askedAt = if ($story.created_at) { [string]$story.created_at } else { Get-FactoryUtcTimestamp }
        text = $message
        fallbackStartedAt = $null
    })
    Set-FactoryProperty -Target $task -Name 'updatedAt' -Value (Get-FactoryUtcTimestamp)
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state
} finally { Exit-FactoryMutex -Mutex $mutex }

try { Start-FactoryRockCycle -Config $config -Reason 'Question' -Gid $TaskId }
catch { Write-Warning "Question was posted, but rock wake-up failed: $($_.Exception.Message)" }
Write-Output "Question posted for $TaskId. Emit a blocked FACTORY_RESULT and stop until Asana returns to Taken."
