[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ConfigPath,[Parameter(Mandatory=$true)][string]$ItemId,[Parameter(Mandatory=$true)][string]$ClaimId)
$ErrorActionPreference='Stop'
try{
    [Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
    . (Join-Path $PSScriptRoot 'rock-common.ps1')
    $config=Get-FactoryRockConfiguration -ConfigPath $ConfigPath
    if($null -eq $config){throw 'Direct coordinator is disabled.'}
    $inputRecord=[Console]::In.ReadToEnd()|ConvertFrom-Json
    Invoke-FactoryRockAsanaToolHook $config $ItemId $ClaimId $inputRecord
    if([string]$inputRecord.hook_event_name -eq 'PreToolUse'){@{hookSpecificOutput=@{hookEventName='PreToolUse';permissionDecision='allow'}}|ConvertTo-Json -Compress}
    elseif([string]$inputRecord.hook_event_name -eq 'PostToolUse'){
        $audit=Read-FactoryJson (Get-FactoryRockPublisherPaths $config $ItemId $ClaimId).audit
        $context=@{taskRead=$audit.taskRead;storiesComplete=$audit.storiesComplete;nextOffset=$audit.nextOffset;humanChanged=$audit.humanChanged;markerSeen=$audit.markerSeen;mutationAttempted=$audit.mutationAttempted;proofObserved=($null -ne $audit.proof)}|ConvertTo-Json -Compress
        @{hookSpecificOutput=@{hookEventName='PostToolUse';additionalContext="Native publication inspection (no task content): $context"}}|ConvertTo-Json -Compress
    }
}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 2}
