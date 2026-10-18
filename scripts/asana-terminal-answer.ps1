[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$Answer = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
. (Join-Path $PSScriptRoot 'asana-common.ps1')
$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$state = Read-FactoryJson -Path $context.statePath
$task = Get-FactoryTask -State $state -TaskId $TaskId
$question = Get-FactoryNestedValue -Target $task -Name 'asanaQuestion'
if (-not [bool](Get-FactoryNestedValue -Target $task -Name 'asanaMode' -Default $false) -or
    $null -eq $question -or [string]$task.status -notin @('blocked', 'held', 'awaiting-input')) {
    throw "Task $TaskId has no pending Asana question."
}
$remote = Get-FactoryAsanaTask -Config $config -Gid $TaskId
$factoryValue = Get-FactoryAsanaField -Task $remote -Gid ([string]$config.asana.fields.factory)
if ($factoryValue -notin @([string]$config.asana.fields.question, [string]$config.asana.fields.taken)) {
    throw "Asana task $TaskId is no longer in Question or Taken."
}
if (-not $Answer) {
    if ($factoryValue -ne [string]$config.asana.fields.question) {
        Write-Output "Task $TaskId is no longer waiting for an answer."
        return
    }
    Write-Output "Factory question for Asana task $TaskId ($($remote.name)):"
    Write-Output ([string](Get-FactoryNestedValue -Target $question -Name 'text' -Default ''))
    Write-Output ([string]$remote.permalink_url)
    $Answer = Read-Host 'Igor, enter the answer to post in Asana (empty cancels)'
}
if (-not $Answer.Trim()) { Write-Output 'No answer posted.'; return }

$message = "ANSWER (Igor via terminal): $Answer"
$remote = Get-FactoryAsanaTask -Config $config -Gid $TaskId
$factoryValue = Get-FactoryAsanaField -Task $remote -Gid ([string]$config.asana.fields.factory)
$comments = @(Get-FactoryAsanaComments -Config $config -Gid $TaskId)
$askedAt = ConvertTo-FactoryUtcDateTime -Value (Get-FactoryNestedValue -Target $question -Name 'askedAt')
$sameAnswer = @($comments | Where-Object {
    [string]$_.text -eq $message -and
    (ConvertTo-FactoryUtcDateTime -Value $_.created_at) -ge $askedAt
}).Count -gt 0
if ($factoryValue -eq [string]$config.asana.fields.taken -and $sameAnswer) {
    Write-Output "Answer already posted for $TaskId; the factory will resume its worker."
    return
}
if ($factoryValue -ne [string]$config.asana.fields.question) {
    throw "Task $TaskId changed while waiting; answer was not posted. Inspect the current Asana answer."
}
if (-not $sameAnswer) {
    $null = Add-FactoryAsanaComment -Config $config -Gid $TaskId -Text $message
}
Set-FactoryAsanaField -Config $config -Gid $TaskId -Field ([string]$config.asana.fields.factory) -Value ([string]$config.asana.fields.taken)
Write-FactoryAsanaTransition -Context $context -Gid $TaskId -From 'Question' -To 'Taken' -WorkerId $TaskId
$mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
try {
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId
    Set-FactoryProperty -Target $task -Name 'asanaState' -Value 'Taken'
    $pending = Get-FactoryNestedValue -Target $task -Name 'asanaQuestion'
    if ($null -ne $pending) { Set-FactoryProperty -Target $pending -Name 'lastPolledAt' -Value $null }
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state
} finally { Exit-FactoryMutex -Mutex $mutex }
Write-Output "Answer posted. Task $TaskId returned to Taken; the factory will resume its worker."
