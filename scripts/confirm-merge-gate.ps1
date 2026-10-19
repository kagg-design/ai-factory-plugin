[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Repository, [Parameter(Mandatory = $true)][string]$TaskId, [switch]$Yes)
$ErrorActionPreference = 'Stop'
if (-not $Yes) { throw 'Explicit terminal confirmation requires: factory merge <id> --yes' }
. (Join-Path $PSScriptRoot 'factory-common.ps1')
. (Join-Path $PSScriptRoot 'quality-gates.ps1')
$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$task = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId $TaskId
if (-not $task.commit -or [string]$task.status -notin @('approved', 'awaiting-review', 'held')) { throw 'Merge confirmation requires a recorded, reviewed result.' }
if (Test-FactoryMergeGate -Context $context -Config $config -Task $task -TerminalYes) { Write-Output "Confirmed merge gate for $TaskId at $($task.commit)." }
