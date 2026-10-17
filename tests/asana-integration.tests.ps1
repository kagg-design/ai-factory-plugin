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
foreach ($name in @('ConvertTo-RockTimestamp', 'Get-RockLockStatus', 'Test-RockAfter', 'Get-RockInstancePaths', 'Test-RockTaskInScope', 'Get-RockEpicUrl')) {
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
$firstPaths = Get-RockInstancePaths -StateRoot ([IO.Path]::GetTempPath()) -EpicGid '1219601019224697'
$secondPaths = Get-RockInstancePaths -StateRoot ([IO.Path]::GetTempPath()) -EpicGid '1219601069124635'
Assert-AsanaIntegration ($firstPaths.stateDir -ne $secondPaths.stateDir) 'Different epics share rock state.'
Assert-AsanaIntegration ($firstPaths.mutexName -ne $secondPaths.mutexName) 'Different epics share a rock mutex.'
Assert-AsanaIntegration ($firstPaths.mutexName -eq (Get-RockInstancePaths -StateRoot ([IO.Path]::GetTempPath()) -EpicGid '1219601019224697').mutexName) 'The same epic bypasses its mutex.'
$dependencies = @([pscustomobject]@{ gid = '123' })
Assert-AsanaIntegration (Test-RockTaskInScope -TaskGid '1219601019224697' -EpicGid '1219601019224697' -Dependencies $dependencies) 'Epic wake-up was rejected.'
Assert-AsanaIntegration (Test-RockTaskInScope -TaskGid '123' -EpicGid '1219601019224697' -Dependencies $dependencies) 'Dependency wake-up was rejected.'
Assert-AsanaIntegration (-not (Test-RockTaskInScope -TaskGid '456' -EpicGid '1219601019224697' -Dependencies $dependencies)) 'Unrelated wake-up reached an epic.'
$baseEpicUrl = (Get-Content -LiteralPath (Join-Path $PluginRoot 'rock-cycle.json') -Raw | ConvertFrom-Json).epicUrl
$selectedEpicUrl = Get-RockEpicUrl -ConfiguredUrl $baseEpicUrl -ConfiguredGid '1219601019224697' -TargetGid '1219601069124635'
Assert-AsanaIntegration ($selectedEpicUrl -eq 'https://app.asana.com/1/14748072439266/project/1215506997644941/task/1219601069124635') 'Explicit epic GID selected the wrong Asana task.'

$config.launcher.path = Join-Path $PluginRoot 'rock-cycle.ps1'
$config.launcher.epicGids = @('1219601019224697', '1219601069124635')
$script:launchArgs = New-Object Collections.Generic.List[string]
function ConvertTo-FactoryWindowsArgument { param([string]$Value) return '"' + $Value + '"' }
function Start-Process {
    param([string]$FilePath, [string]$WindowStyle, [string]$ArgumentList, [switch]$PassThru)
    $script:launchArgs.Add($ArgumentList)
    return [pscustomobject]@{ Id = 1 }
}
Start-FactoryRockCycle -Config $config -Reason 'Done' -Gid '123'
Assert-AsanaIntegration ($script:launchArgs.Count -eq 2) 'Factory wake-up did not start both rock epics.'
Assert-AsanaIntegration ($script:launchArgs[0] -like '*-EpicGid*1219601019224697*' -and $script:launchArgs[1] -like '*-EpicGid*1219601069124635*') 'Factory wake-up used the wrong epic GIDs.'
$legacyConfig = [pscustomobject]@{ launcher = [pscustomobject]@{ path = $config.launcher.path } }
Start-FactoryRockCycle -Config $legacyConfig -Reason 'Done' -Gid '123'
Assert-AsanaIntegration ($script:launchArgs.Count -eq 3 -and $script:launchArgs[2] -notlike '*-EpicGid*') 'Legacy single-epic launcher stopped working.'

foreach ($scriptName in @('rock-cycle.ps1', 'install-rock-cycle-task.ps1', 'uninstall-rock-cycle-task.ps1')) {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Process -Id $PID).Path
    $scriptPath = Join-Path $PluginRoot $scriptName
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -EpicGid invalid' -f $scriptPath
    if ($scriptName -eq 'rock-cycle.ps1') { $startInfo.Arguments += ' -DryRun' }
    $startInfo.WorkingDirectory = [IO.Path]::GetTempPath()
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    Assert-AsanaIntegration ($process.ExitCode -ne 0 -and $output -match 'GID must be numeric|Invalid epicGid') "$scriptName did not resolve its default config from another directory."
}

Write-Host 'Asana integration tests passed (Done payload, Ready ordering, search fallback, rock isolation and wake-up routing).' -ForegroundColor Green
