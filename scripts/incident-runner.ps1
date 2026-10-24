[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RuntimeHome)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'factory-incidents.ps1')
for($batch=0;$batch -lt 5;$batch++){
    $result=Invoke-FactoryIncidentRepair $RuntimeHome
    $result|ConvertTo-Json -Depth 15
    if(-not $result.started){break}
}
