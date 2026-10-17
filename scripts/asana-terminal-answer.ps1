[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$TaskId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
. (Join-Path $PSScriptRoot 'asana-common.ps1')
$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$remote = Get-FactoryAsanaTask -Config $config -Gid $TaskId
if ((Get-FactoryAsanaField -Task $remote -Gid ([string]$config.asana.fields.factory)) -ne [string]$config.asana.fields.question) {
    Write-Output "Task $TaskId is no longer waiting for an answer."
    return
}
Write-Output "Factory question timed out for Asana task $TaskId ($($remote.name))."
Write-Output ([string]$remote.permalink_url)
$answer = Read-Host 'Igor, enter the answer to post in Asana (empty cancels)'
if (-not $answer.Trim()) { Write-Output 'No answer posted.'; return }
$remote = Get-FactoryAsanaTask -Config $config -Gid $TaskId
if ((Get-FactoryAsanaField -Task $remote -Gid ([string]$config.asana.fields.factory)) -ne [string]$config.asana.fields.question) {
    Write-Output 'Task changed while waiting; answer was not posted.'
    return
}
$null = Add-FactoryAsanaComment -Config $config -Gid $TaskId -Text "ANSWER (Igor via factory terminal): $answer"
Set-FactoryAsanaField -Config $config -Gid $TaskId -Field ([string]$config.asana.fields.factory) -Value ([string]$config.asana.fields.taken)
Write-FactoryAsanaTransition -Context $context -Gid $TaskId -From 'Question' -To 'Taken' -WorkerId $TaskId
$mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
try {
    $state = Read-FactoryJson -Path $context.statePath
    $task = Get-FactoryTask -State $state -TaskId $TaskId
    Set-FactoryProperty -Target $task -Name 'asanaState' -Value 'Taken'
    Write-FactoryJsonAtomic -Path $context.statePath -Value $state
} finally { Exit-FactoryMutex -Mutex $mutex }
Write-Output "Answer posted. Task $TaskId returned to Taken; the factory will resume its worker."
