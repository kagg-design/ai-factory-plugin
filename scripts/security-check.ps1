[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Repository, [Parameter(Mandatory = $true)][string]$TaskId)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
. (Join-Path $PSScriptRoot 'quality-gates.ps1')
$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$task = Get-FactoryTask -State (Read-FactoryJson -Path $context.statePath) -TaskId $TaskId
$security = Invoke-FactorySecurityCheck -Config $config -Repository $context.repositoryRoot -Worktree $task.worktree
Save-FactoryGateProperty -Context $context -Task $task -Name 'security' -Value $security
Write-Output "Security: $($security.summary)"
if ($security.exitCode -ne 0) { exit 1 }
