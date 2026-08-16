[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Url,
    [ValidateSet("interactive", "auto")][string]$Mode = "interactive"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$source = Resolve-FactoryAsanaTaskUrl -Url $Url
$mutex = $null
try {
    $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
    $state = Read-FactoryJson -Path ([string]$context.statePath)
    $duplicates = @($state.tasks | Where-Object {
        [string]$_.id -eq [string]$source.taskId -or
        ([string]$_.url -and [string]$_.url -eq [string]$source.canonicalUrl)
    })
    if ($duplicates.Count -gt 0) {
        $existing = $duplicates[0]
        [ordered]@{
            prepared = $false
            duplicate = $true
            taskId = [string]$source.taskId
            canonicalUrl = [string]$source.canonicalUrl
            existing = [ordered]@{
                id = [string]$existing.id
                title = [string]$existing.title
                status = [string]$existing.status
                url = [string]$existing.url
            }
            requestPath = $null
            normalizationPath = $null
        } | ConvertTo-Json -Depth 20
        exit 0
    }

    $requestId = [Guid]::NewGuid().ToString("N")
    $stem = "intake-$($source.taskId)-$requestId"
    $requestPath = Join-Path ([string]$context.sessionsPath) "$stem.request.json"
    $normalizationPath = Join-Path ([string]$context.sessionsPath) "$stem.normalized.json"
    $request = [pscustomobject][ordered]@{
        version = 1
        requestId = $requestId
        source = "asana"
        taskId = [string]$source.taskId
        canonicalUrl = [string]$source.canonicalUrl
        suppliedUrl = [string]$source.suppliedUrl
        startMode = $Mode
        normalizationPath = [IO.Path]::GetFullPath($normalizationPath)
        createdAt = Get-FactoryUtcTimestamp
    }
    Write-FactoryJsonAtomic -Path $requestPath -Value $request
    Write-FactoryJsonAtomic -Path $normalizationPath -Value ([pscustomobject][ordered]@{
        version = 1
        source = [pscustomobject][ordered]@{
            adapter = "asana"
            id = [string]$source.taskId
            url = [string]$source.canonicalUrl
            suppliedUrl = [string]$source.suppliedUrl
        }
        startMode = $Mode
        title = ""
        brief = ""
        acceptanceCriteria = @()
        sourceNotes = @()
        sourceError = $null
    })

    [ordered]@{
        prepared = $true
        duplicate = $false
        taskId = [string]$source.taskId
        canonicalUrl = [string]$source.canonicalUrl
        suppliedUrl = [string]$source.suppliedUrl
        startMode = $Mode
        requestPath = [IO.Path]::GetFullPath($requestPath)
        normalizationPath = [IO.Path]::GetFullPath($normalizationPath)
    } | ConvertTo-Json -Depth 20
} finally {
    Exit-FactoryMutex -Mutex $mutex
}
