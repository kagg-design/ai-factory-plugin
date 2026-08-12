Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot "factory-common.ps1")

function Get-FactoryMatchingOrchestratorRows {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return @($Rows | Where-Object {
        $rowName = if ($null -ne $_.PSObject.Properties["name"]) { [string]$_.name } else { "" }
        $rowCwd = if ($null -ne $_.PSObject.Properties["cwd"]) { [string]$_.cwd } else { "" }
        $rowName -ceq $Name -and $rowCwd -and
            (Test-FactorySamePath -Left $rowCwd -Right $RepositoryRoot)
    })
}

function Select-FactoryBackgroundOrchestrator {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [string]$PreferredSessionId = ""
    )

    $backgroundRows = @($Rows | Where-Object {
        [string]$_.kind -eq "background" -and
        $null -ne $_.PSObject.Properties["id"] -and
        [string]$_.id
    })
    if ($backgroundRows.Count -eq 0) { return $null }

    if ($PreferredSessionId) {
        $preferred = @($backgroundRows | Where-Object {
            $null -ne $_.PSObject.Properties["sessionId"] -and
            [string]$_.sessionId -eq $PreferredSessionId
        } | Select-Object -First 1)
        if ($preferred.Count -eq 1) { return $preferred[0] }
    }

    $liveRows = @($backgroundRows | Where-Object {
        -not (Test-FactoryTerminalAgentRow -Row $_)
    })
    if ($liveRows.Count -eq 0) { return $null }
    return @($liveRows | Sort-Object {
        if ($null -ne $_.PSObject.Properties["startedAt"]) { [long]$_.startedAt } else { 0 }
    } -Descending | Select-Object -First 1)[0]
}

function Write-FactoryOrchestratorIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$BackgroundId = ""
    )

    Write-FactoryJsonAtomic -Path $Path -Value ([ordered]@{
        version = 1
        repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
        name = $Name
        sessionId = $SessionId
        backgroundId = if ($BackgroundId) { $BackgroundId } else { $null }
        updatedAt = Get-FactoryUtcTimestamp
    })
}
