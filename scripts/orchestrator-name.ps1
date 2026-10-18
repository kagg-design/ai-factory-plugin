Set-StrictMode -Version 2.0

function Get-FactoryOrchestratorAlias {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Context,
        [string]$NameOverride = ""
    )

    $configured = Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $Config -Name 'orchestrator') -Name 'name' -Default ''
    $alias = if ($NameOverride) { $NameOverride.Trim() } else { ([string]$configured).Trim() }
    if ($alias) {
        # Existing callers may have supplied the former full display name.
        if ($alias -ceq 'Claude Factory Orchestrator') { return $alias }
        if ($alias -cnotmatch '^[A-Za-z][A-Za-z0-9_-]{0,31}$') {
            throw "Orchestrator name must start with a letter and contain only letters, digits, hyphens or underscores (max 32 characters): '$alias'."
        }
        return $alias
    }

    $repositoryName = Split-Path ([string]$Context.repositoryRoot) -Leaf
    $parts = @($repositoryName -split '[^A-Za-z0-9]+' | Where-Object { $_ })
    $short = ''
    $fragmentLimit = if ($parts.Count -eq 1) { 12 } else { 5 }
    foreach ($part in @($parts | Select-Object -First 2)) {
        $fragment = $part.Substring(0, [Math]::Min($fragmentLimit, $part.Length)).ToLowerInvariant()
        $short += $fragment.Substring(0, 1).ToUpperInvariant() + $fragment.Substring(1)
    }
    if (-not $short) { $short = 'Project' }
    $key = [string]$Context.projectKey
    $match = [regex]::Match($key, '-([0-9a-fA-F]{8})$')
    if (-not $match.Success) { throw "Project key has no stable hash: '$key'." }
    return "$short-$($match.Groups[1].Value.Substring(0, 4).ToLowerInvariant())"
}

function Get-FactoryOrchestratorDisplayName {
    param([Parameter(Mandatory = $true)][string]$Alias)
    if ($Alias -ceq 'Claude Factory Orchestrator') { return $Alias }
    return ('Factory ' + [char]0x00B7 + ' ' + $Alias)
}
