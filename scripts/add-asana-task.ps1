[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Repository, [Parameter(Mandatory = $true)][string]$Url, [switch]$Force, [switch]$Auto)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
. (Join-Path $PSScriptRoot 'asana-common.ps1')
$uri = $null
if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'app.asana.com' -or $uri.AbsolutePath -notmatch '/(\d+)(?:/f)?/?$') { throw 'Expected an https://app.asana.com task URL.' }
$gid = $Matches[1]
$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository -Initialize | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$task = Get-FactoryAsanaTask -Config $config -Gid $gid
Assert-FactoryTaskRepo -Config $config -Repository $context.repositoryRoot -Notes ([string]$task.notes) -Force:$Force
$path = Join-Path $context.sessionsPath ("manual-asana-$gid-$([Guid]::NewGuid().ToString('N')).json")
try {
    Write-FactoryJsonAtomic -Path $path -Value ([pscustomobject]@{
        version = 1; source = [pscustomobject]@{ adapter = 'asana'; id = $gid; url = $Url; suppliedUrl = $Url }
        startMode = $(if ($Auto) { 'auto' } else { 'interactive' }); title = [string]$task.name
        brief = $(if ([string]$task.notes) { [string]$task.notes } else { [string]$task.name })
        acceptanceCriteria = @(); sourceNotes = @(); sourceError = $null
    })
    & (Join-Path $PSScriptRoot 'enqueue-task.ps1') -Repository $context.repositoryRoot -IntakePath $path -Force:$Force
} finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
