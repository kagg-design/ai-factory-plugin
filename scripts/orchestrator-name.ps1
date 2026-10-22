Set-StrictMode -Version 2.0

function Get-FactoryOrchestratorAlias {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Context,
        [string]$NameOverride = ""
    )

    $configured = Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $Config -Name 'orchestrator') -Name 'name' -Default ''
    $alias = if ($NameOverride) { $NameOverride.Trim() } else { ([string]$configured).Trim() }
    # The old default is not a project label. Use the repository folder just
    # as for configs with no explicit alias.
    if ($alias -ceq 'Claude Factory Orchestrator') { $alias = '' }
    if ($alias) {
        if ($alias -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$') {
            throw "Orchestrator name must start with a letter and contain only letters, digits, hyphens or underscores (max 32 characters): '$alias'."
        }
        return $alias
    }

    return Split-Path ([string]$Context.repositoryRoot) -Leaf
}

function Get-FactoryOrchestratorDisplayName {
    param([Parameter(Mandatory = $true)][string]$Alias)
    return 'Factory ' + $Alias
}
