[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PluginRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\asana-common.ps1')

function Assert-AsanaIntegration {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$config = Get-Content -LiteralPath (Join-Path $PluginRoot 'config.default.json') -Raw | ConvertFrom-Json
$script:calls = New-Object Collections.Generic.List[object]
function Invoke-FactoryAsana {
    param($Config, [string]$Method = 'GET', [string]$Path, $Data = $null)
    $script:calls.Add([pscustomobject]@{ method = $Method; path = $Path; data = $Data })
    return [pscustomobject]@{ data = [pscustomobject]@{ gid = '123'; created_at = '2026-10-17T00:00:00Z' } }
}

Set-FactoryAsanaDone -Config $config -Gid '123'
Assert-AsanaIntegration ($script:calls.Count -eq 1) 'Done must update task fields and completion in one request.'
$call = $script:calls[0]
Assert-AsanaIntegration ($call.method -eq 'PUT' -and $call.path -eq '/tasks/123') 'Done used the wrong Asana endpoint.'
Assert-AsanaIntegration ($call.data.completed -eq $true) 'Done did not complete the Asana task.'
Assert-AsanaIntegration ($call.data.custom_fields[[string]$config.asana.fields.factory] -eq [string]$config.asana.fields.done) 'Done did not set Factory = Done.'
Assert-AsanaIntegration ($call.data.custom_fields[[string]$config.asana.fields.resolution] -eq [string]$config.asana.fields.resolutionFixed) 'Done did not set Resolution = Fixed.'

$source = Get-Content -LiteralPath (Join-Path $PluginRoot 'scripts\asana-poller.ps1') -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
Assert-AsanaIntegration (@($parseErrors).Count -eq 0) 'Asana poller does not parse.'
foreach ($name in @('Get-AsanaPriorityRank', 'Get-ReadyTasks')) {
    $functionAst = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))[0]
    Assert-AsanaIntegration ($null -ne $functionAst) "Missing poller function $name."
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

function New-ReadyFixture {
    param([string]$Gid, [string]$Priority, [string]$CreatedAt, [bool]$Completed = $false)
    $customFields = @([pscustomobject]@{
        gid = [string]$config.asana.fields.factory
        name = 'Factory'
        enum_value = [pscustomobject]@{ gid = [string]$config.asana.fields.ready; name = 'Ready' }
    })
    if ($Priority) {
        $customFields += [pscustomobject]@{
            gid = 'priority-field'; name = 'Priority'
            enum_value = [pscustomobject]@{ gid = 'priority-option'; name = $Priority }
        }
    }
    return [pscustomobject]@{ gid = $Gid; created_at = $CreatedAt; completed = $Completed; custom_fields = $customFields }
}

$script:readyFixtures = @(
    (New-ReadyFixture -Gid '1' -Priority 'Low' -CreatedAt '2026-10-15T00:00:00Z'),
    (New-ReadyFixture -Gid '2' -Priority 'High' -CreatedAt '2026-10-16T00:00:00Z'),
    (New-ReadyFixture -Gid '3' -Priority '' -CreatedAt '2026-10-14T00:00:00Z'),
    (New-ReadyFixture -Gid '4' -Priority 'Medium' -CreatedAt '2026-10-13T00:00:00Z'),
    (New-ReadyFixture -Gid '5' -Priority 'High' -CreatedAt '2026-10-12T00:00:00Z'),
    (New-ReadyFixture -Gid '6' -Priority 'High' -CreatedAt '2026-10-11T00:00:00Z' -Completed $true)
)
$script:searchFailure = $false
$script:seenPaths = New-Object Collections.Generic.List[string]
function Get-FactoryAsanaPages {
    param($Config, [string]$Path)
    $script:seenPaths.Add($Path)
    if ($script:searchFailure -and $Path -like '/workspaces/*') { throw 'Search unavailable.' }
    return $script:readyFixtures
}

$ordered = @(Get-ReadyTasks -Config $config | ForEach-Object { [string]$_.gid })
Assert-AsanaIntegration (($ordered -join ',') -eq '5,2,4,1,3') 'Ready tasks were not sorted by priority then creation time.'
Assert-AsanaIntegration ($script:seenPaths[0] -like '/workspaces/*/tasks/search*') 'Poller did not use Asana search.'
$script:searchFailure = $true
$script:seenPaths.Clear()
$ordered = @(Get-ReadyTasks -Config $config | ForEach-Object { [string]$_.gid })
Assert-AsanaIntegration (($ordered -join ',') -eq '5,2,4,1,3') 'Fallback task query changed Ready ordering.'
Assert-AsanaIntegration ($script:seenPaths[1] -like '/projects/*/tasks*') 'Poller did not fall back to project tasks.'

$rockSource = Get-Content -LiteralPath (Join-Path $PluginRoot 'rock-cycle.ps1') -Raw
$rockAst = [Management.Automation.Language.Parser]::ParseInput($rockSource, [ref]$tokens, [ref]$parseErrors)
Assert-AsanaIntegration (@($parseErrors).Count -eq 0) 'Rock launcher does not parse.'
foreach ($name in @('Get-RockLockStatus', 'Test-RockAfter')) {
    $functionAst = @($rockAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))[0]
    Assert-AsanaIntegration ($null -ne $functionAst) "Missing rock launcher function $name."
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$lockFile = Join-Path ([IO.Path]::GetTempPath()) ("rock-lock-test-$([Guid]::NewGuid().ToString('N')).json")
try {
    Assert-AsanaIntegration ((Get-RockLockStatus -Path $lockFile -StaleMinutes 60) -eq 'absent') 'An absent rock lock was treated as busy.'
    [IO.File]::WriteAllText($lockFile, (@{ pid = $PID; startedAt = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json))
    Assert-AsanaIntegration ((Get-RockLockStatus -Path $lockFile -StaleMinutes 60) -eq 'busy') 'A live rock lock was ignored.'
    [IO.File]::WriteAllText($lockFile, (@{ pid = 2147483647; startedAt = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json))
    Assert-AsanaIntegration ((Get-RockLockStatus -Path $lockFile -StaleMinutes 60) -eq 'stale') 'A dead rock lock was not reclaimed.'
} finally { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
$boundary = [DateTimeOffset]::Parse('2026-10-17T10:00:00Z')
Assert-AsanaIntegration (Test-RockAfter -Value '2026-10-17T10:00:01Z' -Boundary $boundary) 'A new Asana change was missed.'
Assert-AsanaIntegration (-not (Test-RockAfter -Value '2026-10-17T10:00:00Z' -Boundary $boundary)) 'The last run boundary retriggered a cycle.'

Write-Host 'Asana integration tests passed (Done payload, Ready ordering, search fallback, rock lock and change boundary).' -ForegroundColor Green
