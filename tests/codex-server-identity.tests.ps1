param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\codex-orchestrator.ps1')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-server-identity-' + [Guid]::NewGuid().ToString('N'))
$paths = Get-FactoryCodexSharedServerPaths -RuntimeHome $fixtureRoot
New-Item -ItemType Directory -Path $paths.directory -Force | Out-Null
$originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
$fixtureProcess = $null
$fixtureProcessStart = $null

function Start-IdentityFixtureProcess {
    $script:fixtureProcess = Start-Process -FilePath (Get-Command powershell).Source `
        -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
    $script:fixtureProcessStart = $fixtureProcess.StartTime.ToUniversalTime()
}
function Stop-IdentityFixtureProcess {
    if ($null -eq $fixtureProcess) { return }
    $fixtureProcess.Refresh()
    if (-not $fixtureProcess.HasExited) {
        if ($fixtureProcess.StartTime.ToUniversalTime() -ne $fixtureProcessStart) { throw 'Fixture process identity changed.' }
        $fixtureProcess.Kill()
        if (-not $fixtureProcess.WaitForExit(5000)) { throw 'Fixture process did not stop.' }
    }
    $fixtureProcess.Dispose()
    $script:fixtureProcess = $null
}
function Write-IdentityFixtureRecord {
    param($Timestamp)
    Write-FactoryJsonAtomic -Path $paths.record -Value ([pscustomobject]@{
        version = 1; pid = $fixtureProcess.Id; processStartTimeUtc = $Timestamp
        endpoint = 'ws://127.0.0.1:1'; codexCommand = 'fixture-only'
    })
}

try {
    foreach ($culture in @('en-US', 'en-GB', 'ru-RU')) {
        [Threading.Thread]::CurrentThread.CurrentCulture = New-Object Globalization.CultureInfo($culture)
        Start-IdentityFixtureProcess
        $expected = $fixtureProcessStart.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Write-IdentityFixtureRecord -Timestamp $expected
        $status = Get-FactoryCodexSharedServerStatus -CodexCommand 'fixture-only' -RuntimeHome $fixtureRoot
        if (-not $status.alive) { throw "Matching process was not recognized in $culture." }
        if ([string]$status.processStartTimeUtc -cne $expected) { throw "Status lost UTC/precision in $culture`: '$($status.processStartTimeUtc)' versus '$expected'." }
        $stopped = Stop-FactoryCodexSharedServer -CodexCommand 'fixture-only' -RuntimeHome $fixtureRoot
        if (-not $stopped.stopped -or $stopped.alreadyStopped) { throw "Matching process was not stopped in $culture." }
        $fixtureProcess.Refresh()
        if (-not $fixtureProcess.HasExited) { throw 'Matching process survived stop.' }
        Stop-IdentityFixtureProcess
    }

    Start-IdentityFixtureProcess
    foreach ($timestamp in @(
        $fixtureProcessStart.AddHours(-1).ToString('o', [Globalization.CultureInfo]::InvariantCulture),
        'invalid timestamp'
    )) {
        Write-IdentityFixtureRecord -Timestamp $timestamp
        $stopped = Stop-FactoryCodexSharedServer -CodexCommand 'fixture-only' -RuntimeHome $fixtureRoot
        if ($stopped.stopped -or -not $stopped.alreadyStopped) { throw 'Mismatched process was stopped.' }
        $fixtureProcess.Refresh()
        if ($fixtureProcess.HasExited) { throw 'Mismatched live process was killed.' }
    }

    # A missing timestamp may be reported alive for compatibility, but the
    # destructive operation must still refuse an unverifiable identity.
    Write-IdentityFixtureRecord -Timestamp $null
    $refused = $false
    try { $null = Stop-FactoryCodexSharedServer -CodexCommand 'fixture-only' -RuntimeHome $fixtureRoot }
    catch { $refused = $true }
    if (-not $refused) { throw 'Stop accepted a missing process timestamp.' }
    $fixtureProcess.Refresh()
    if ($fixtureProcess.HasExited) { throw 'Unverifiable process was killed.' }

    # Exercise the second identity check after status succeeds (PID reuse race).
    $originalStatusFunction = ${function:Get-FactoryCodexSharedServerStatus}
    try {
        function Get-FactoryCodexSharedServerStatus {
            param($CodexCommand, $RuntimeHome)
            [pscustomobject]@{
                alive = $true; pid = $fixtureProcess.Id
                processStartTimeUtc = $fixtureProcessStart.AddHours(-1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }
        }
        $refused = $false
        try { $null = Stop-FactoryCodexSharedServer -CodexCommand 'fixture-only' -RuntimeHome $fixtureRoot }
        catch { $refused = $_.Exception.Message -like 'Refusing to stop PID*' }
        if (-not $refused) { throw 'Second identity check did not refuse a mismatch.' }
        $fixtureProcess.Refresh()
        if ($fixtureProcess.HasExited) { throw 'Second identity check killed a mismatched process.' }
    } finally { Set-Item -Path Function:\Get-FactoryCodexSharedServerStatus -Value $originalStatusFunction }
    Write-Host 'Codex shared-server identity regressions passed.' -ForegroundColor Green
} finally {
    Stop-IdentityFixtureProcess
    [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    $fullFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path -Parent $fullFixture) -ne $tempRoot -or (Split-Path -Leaf $fullFixture) -notlike 'factory-server-identity-*') {
        throw "Unsafe identity fixture cleanup: $fullFixture"
    }
    Remove-Item -LiteralPath $fullFixture -Recurse -Force
}
