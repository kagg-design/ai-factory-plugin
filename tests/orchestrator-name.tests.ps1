param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\orchestrator-name.ps1')
. (Join-Path $PluginRoot 'scripts\orchestrator-session.ps1')

function Assert-Name([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$context = [pscustomobject]@{
    repositoryRoot = 'C:\laragon\www\Projects\cloud-infrastructure-auditors'
    projectKey = 'cloud-infrastructure-auditors-8ce0822d'
}
$config = [pscustomobject]@{ orchestrator = [pscustomobject]@{ name = 'Auditors' } }
$alias = Get-FactoryOrchestratorAlias -Config $config -Context $context
Assert-Name ($alias -ceq 'Auditors') 'Configured short name was ignored.'
Assert-Name ((Get-FactoryOrchestratorDisplayName $alias) -ceq ('Factory ' + [char]0x00B7 + ' Auditors')) 'Display name format changed.'
Assert-Name ((Get-FactoryOrchestratorAlias -Config $config -Context $context -NameOverride 'AwesomeHR') -ceq 'AwesomeHR') '-Name did not override config.'

$config.orchestrator = [pscustomobject]@{}
Assert-Name ((Get-FactoryOrchestratorAlias -Config $config -Context $context) -ceq 'CloudInfra-8ce0') 'Directory fallback is unstable or too long.'
$singleWordContext = [pscustomobject]@{ repositoryRoot = 'C:\laragon\www\motivehr'; projectKey = 'motivehr-4893d8fb' }
Assert-Name ((Get-FactoryOrchestratorAlias -Config $config -Context $singleWordContext) -ceq 'Motivehr-4893') 'Short directory fallback was truncated.'
$config.orchestrator = [pscustomobject]@{ name = 'bad.name' }
$errorText = ''
try { $null = Get-FactoryOrchestratorAlias -Config $config -Context $context } catch { $errorText = $_.Exception.Message }
Assert-Name ($errorText -match 'contain only') 'A configured name containing dots was accepted.'

$config.orchestrator.name = 'Claude Factory Orchestrator'
Assert-Name ((Get-FactoryOrchestratorDisplayName (Get-FactoryOrchestratorAlias -Config $config -Context $context)) -ceq 'Claude Factory Orchestrator') 'Legacy explicit name was changed.'
$oldRow = [pscustomobject]@{ name = 'Claude Factory Orchestrator'; sessionId = 'recorded-session'; cwd = $context.repositoryRoot }
$matched = @(Get-FactoryMatchingOrchestratorRows -Rows @($oldRow) -RepositoryRoot $context.repositoryRoot -Name ('Factory ' + [char]0x00B7 + ' Auditors') -SessionId 'recorded-session')
Assert-Name ($matched.Count -eq 1) 'Renaming lost the stored conversation identity.'

Write-Host 'Orchestrator name tests passed.'
