[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Repository,[ValidateSet('configure','report','list','status','run','retry')][string]$Action='list',[string]$File='',[string]$Id='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'factory-incidents.ps1')
$context=& (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository|ConvertFrom-Json
$paths=Get-FactoryIncidentPaths $context.runtimeHome
if($Action -eq 'configure'){
    if(-not $File){throw 'Incident configure requires a reviewed policy file.'}
    Set-FactoryIncidentPolicy $context $File|ConvertTo-Json -Depth 10
    return
}
if($Action -eq 'report'){
    if(-not $File){throw 'Incident report requires a structured evidence file.'}
    Add-FactoryIncident $context (Read-FactoryJson ([IO.Path]::GetFullPath($File)))|ConvertTo-Json -Depth 10
    Start-FactoryIncidentService $context.runtimeHome
    return
}
if($Id -and $Id -cnotmatch '^[a-f0-9]{64}$'){throw 'Incident ID must be an exact SHA-256 identity.'}
if($Action -eq 'retry'){
    if(-not $Id){throw 'Incident retry requires an exact ID.'}
    $policy=Get-FactoryIncidentPolicy $context.runtimeHome
    if($null -eq $policy){throw 'Incident handoff is disabled.'}
    $mutex=Enter-FactoryMutex $paths.mutex
    try{
        $path=Join-Path $paths.queue "$Id.json";$item=Read-FactoryJson $path
        if($item.status -notin @('failed','interrupted') -or [int]$item.attempts -ge [int]$policy.maxAttempts){throw 'Only an inspected failed/interrupted attempt within the configured budget may be retried.'}
        $item.status='queued';Write-FactoryJsonAtomic $path $item
    }finally{Exit-FactoryMutex $mutex}
    Start-FactoryIncidentService $context.runtimeHome
    return
}
if($Action -eq 'run'){Invoke-FactoryIncidentRepair $context.runtimeHome $Id|ConvertTo-Json -Depth 20;return}
$policy=Get-FactoryIncidentPolicy $context.runtimeHome
[pscustomobject]@{enabled=($null -ne $policy);policyPath=$paths.policy;incidents=@(Get-FactoryIncidents $context.runtimeHome|Where-Object {-not $Id -or $_.id -ceq $Id})}|ConvertTo-Json -Depth 25
