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
Assert-Name ((Get-FactoryOrchestratorDisplayName $alias) -ceq 'Factory Auditors') 'Orchestrator label must use the compact Factory prefix.'
Assert-Name ((Get-FactoryOrchestratorAlias -Config $config -Context $context -NameOverride 'AwesomeHR') -ceq 'AwesomeHR') '-Name did not override config.'

$config.orchestrator = [pscustomobject]@{}
Assert-Name ((Get-FactoryOrchestratorAlias -Config $config -Context $context) -ceq 'cloud-infrastructure-auditors') 'Directory fallback changed the folder name.'
$singleWordContext = [pscustomobject]@{ repositoryRoot = 'C:\laragon\www\motivehr'; projectKey = 'motivehr-4893d8fb' }
Assert-Name ((Get-FactoryOrchestratorAlias -Config $config -Context $singleWordContext) -ceq 'motivehr') 'Directory fallback changed case or added a suffix.'
$unicodeFolder = ([char]0x041F).ToString() + [char]0x0440 + [char]0x043E + [char]0x0435 + [char]0x043A + [char]0x0442
foreach ($folder in @('am-logger', 'AMLogger', 'My.Project (dev)', '123-project', $unicodeFolder, ('long-project-name-' * 5).TrimEnd('-'))) {
    $folderContext = [pscustomobject]@{ repositoryRoot = 'C:\fixture\' + $folder }
    $folderAlias = Get-FactoryOrchestratorAlias -Config $config -Context $folderContext
    Assert-Name ($folderAlias -ceq $folder) "Directory fallback did not preserve '$folder'."
    Assert-Name ((Get-FactoryOrchestratorDisplayName $folderAlias) -ceq ('Factory ' + $folder)) 'Display name changed the complete folder name.'
}
$config.orchestrator = [pscustomobject]@{ name = 'bad.name' }
$errorText = ''
try { $null = Get-FactoryOrchestratorAlias -Config $config -Context $context } catch { $errorText = $_.Exception.Message }
Assert-Name ($errorText -match 'contain only') 'A configured name containing dots was accepted.'

$config.orchestrator.name = 'Claude Factory Orchestrator'
Assert-Name ((Get-FactoryOrchestratorAlias -Config $config -Context $context) -ceq 'cloud-infrastructure-auditors') 'The legacy generic name did not use the complete folder name.'
$oldRow = [pscustomobject]@{ name = 'Claude Factory Orchestrator'; sessionId = 'recorded-session'; cwd = $context.repositoryRoot }
$matched = @(Get-FactoryMatchingOrchestratorRows -Rows @($oldRow) -RepositoryRoot $context.repositoryRoot -Name ('Factory ' + [char]0x00B7 + ' Auditors') -SessionId 'recorded-session')
Assert-Name ($matched.Count -eq 1) 'Renaming lost the stored conversation identity.'

Write-Host 'Orchestrator name tests passed.'
