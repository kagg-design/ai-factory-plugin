[CmdletBinding()]
param(
    [string]$PluginRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('parent', 'probe', 'write', 'read')][string]$Mode = 'parent',
    [string]$FixtureRoot = '',
    [string]$Culture = 'en-GB'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts/factory-common.ps1')
. (Join-Path $PluginRoot 'scripts/publication-ci.ps1')
. (Join-Path $PluginRoot 'scripts/codex-runtime.ps1')

$fixedUtc = '2026-09-26T10:29:50.3828889Z'
$offsetValue = '2026-09-26T13:29:50.3828889+03:00'

function Assert-Timestamp {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TimestampJournal {
    param($PublishedAt, $LastPollAt)
    $sha = 'a' * 40
    [pscustomobject]@{
        version = 1
        entries = @([pscustomobject]@{
            key = "fixture/project|develop|$sha"
            repository = 'fixture/project'; branch = 'develop'; sha = $sha
            taskId = 'local:timestamp'; title = 'Timestamp compatibility'
            publishedAt = $PublishedAt; lastPollAt = $LastPollAt
            status = 'passed'; error = ''; runs = @(); failures = @(); acknowledgements = @()
            url = 'https://github.com/fixture/project/actions'
        })
    }
}

if ($Mode -ne 'parent') {
    if (-not $FixtureRoot) { throw 'Child timestamp tests require FixtureRoot.' }
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
    [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
    $context = [pscustomobject]@{ projectKey = 'timestamp-cross-host'; projectData = $FixtureRoot; repositoryRoot = $FixtureRoot }

    if ($Mode -eq 'probe') {
        $jsonValue = ('{"publishedAt":"' + $fixedUtc + '"}' | ConvertFrom-Json).publishedAt
        Assert-Timestamp ((ConvertTo-FactoryRoundtripTimestamp -Value $jsonValue) -ceq $fixedUtc) 'JSON timestamp lost UTC or precision.'

        $utcValue = [DateTime]::SpecifyKind([DateTime]'2026-09-26T10:29:50.3828889', [DateTimeKind]::Utc)
        Assert-Timestamp ((ConvertTo-FactoryUtcDateTime -Value $utcValue) -eq $utcValue) 'UTC DateTime changed during normalization.'
        $localValue = [DateTime]::SpecifyKind([DateTime]'2026-09-26T10:29:50.3828889', [DateTimeKind]::Local)
        Assert-Timestamp ((ConvertTo-FactoryUtcDateTime -Value $localValue) -eq $localValue.ToUniversalTime()) 'Local DateTime was not converted to UTC.'
        $dateTimeOffset = [DateTimeOffset]::Parse($offsetValue, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        Assert-Timestamp ((ConvertTo-FactoryRoundtripTimestamp -Value $dateTimeOffset) -ceq $fixedUtc) 'DateTimeOffset was not normalized to UTC.'
        Assert-Timestamp ((ConvertTo-FactoryRoundtripTimestamp -Value $fixedUtc) -ceq $fixedUtc) 'Z timestamp changed during normalization.'
        Assert-Timestamp ((ConvertTo-FactoryRoundtripTimestamp -Value $offsetValue) -ceq $fixedUtc) 'Offset timestamp was not normalized to UTC.'
        Assert-Timestamp ($null -eq (ConvertTo-FactoryUtcDateTime -Value $null -AllowNull)) 'Optional null timestamp was rejected.'
        Assert-Timestamp ($null -eq (ConvertTo-FactoryUtcDateTime -Value '' -AllowNull)) 'Optional empty timestamp was rejected.'
        foreach ($invalid in @('not-a-timestamp', 42)) {
            $threw = $false
            try { $null = ConvertTo-FactoryUtcDateTime -Value $invalid } catch { $threw = $true }
            Assert-Timestamp $threw "Invalid timestamp '$invalid' was accepted."
        }

        $fixtureProcess = Start-Process -FilePath (Get-Command powershell.exe).Source `
            -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
        try {
            $processTimestamp = $fixtureProcess.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $jsonSession = ('{"processStartTimeUtc":"' + $processTimestamp + '"}' | ConvertFrom-Json)
            $session = [pscustomobject]@{
                id = 'timestamp-process'; name = 'timestamp-process'; sessionId = 'timestamp-process'
                processId = $fixtureProcess.Id; processStartTimeUtc = $jsonSession.processStartTimeUtc
                transcriptPath = ''; lastMessagePath = ''; stderrPath = ''
            }
            $snapshot = Get-FactoryCodexSessionSnapshot -Session $session
            Assert-Timestamp ($snapshot.processAlive -and $snapshot.state -eq 'working') 'JSON process timestamp made a live Codex worker look stopped.'
        } finally {
            $fixtureProcess.Refresh()
            if (-not $fixtureProcess.HasExited -and $fixtureProcess.StartTime.ToUniversalTime().Ticks -eq (ConvertTo-FactoryUtcDateTime -Value $processTimestamp).Ticks) {
                $fixtureProcess.Kill()
                $null = $fixtureProcess.WaitForExit(5000)
            }
            $fixtureProcess.Dispose()
        }

        Write-FactoryJsonAtomic -Path (Get-FactoryCiPath $context) -Value (New-TimestampJournal -PublishedAt $fixedUtc -LastPollAt $null)
        $journal = Read-FactoryCiJournal $context
        $status = Get-FactoryCiStatus $context
        Assert-Timestamp ($journal.entries.Count -eq 1 -and -not $status.error -and -not $status.blocked) 'Valid CI journal failed closed.'
        Assert-Timestamp ($journal.entries[0].publishedAt -is [string] -and $journal.entries[0].publishedAt -ceq $fixedUtc) 'Journal reader returned host-dependent timestamp types.'
        Write-Output "PROBE_OK|$($PSVersionTable.PSEdition)|$Culture|$($jsonValue.GetType().FullName)"
        return
    }

    if ($Mode -eq 'write') {
        $publishedAt = ConvertTo-FactoryRoundtripTimestamp -Value $fixedUtc
        $lastPollAt = ConvertTo-FactoryRoundtripTimestamp -Value $offsetValue
        Write-FactoryJsonAtomic -Path (Get-FactoryCiPath $context) -Value (New-TimestampJournal -PublishedAt $publishedAt -LastPollAt $lastPollAt)
        Write-Output "WRITE_OK|$($PSVersionTable.PSEdition)|$Culture"
        return
    }

    $journal = Read-FactoryCiJournal $context
    $status = Get-FactoryCiStatus $context
    Assert-Timestamp ($journal.entries.Count -eq 1 -and -not $status.error -and -not $status.blocked) 'Cross-host journal read failed closed.'
    Assert-Timestamp ($journal.entries[0].publishedAt -is [string] -and $journal.entries[0].lastPollAt -is [string]) 'Cross-host journal types differed.'
    $publishedAt = ConvertTo-FactoryRoundtripTimestamp -Value $journal.entries[0].publishedAt
    $lastPollAt = ConvertTo-FactoryRoundtripTimestamp -Value $journal.entries[0].lastPollAt
    Assert-Timestamp ($publishedAt -ceq $fixedUtc -and $lastPollAt -ceq $fixedUtc) 'Cross-host journal values changed.'
    Write-Output "READ_OK|$($PSVersionTable.PSEdition)|$Culture|$publishedAt|$lastPollAt"
    return
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('factory-timestamp-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pwshCommand = Get-Command pwsh.exe -ErrorAction Stop
$pwsh = if ([string]$pwshCommand.Source) { [string]$pwshCommand.Source } else { [string]$pwshCommand.Path }

function Invoke-TimestampChild {
    param([string]$HostPath, [string]$ChildMode, [string]$ChildCulture)
    $output = @(& $HostPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
        -PluginRoot $PluginRoot -Mode $ChildMode -FixtureRoot $fixture -Culture $ChildCulture 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$HostPath $ChildMode/$ChildCulture failed: $($output -join [Environment]::NewLine)" }
    return ($output -join [Environment]::NewLine)
}

try {
    foreach ($hostPath in @($pwsh, $windowsPowerShell)) {
        foreach ($cultureName in @('ru-RU', 'en-GB')) {
            $probe = Invoke-TimestampChild -HostPath $hostPath -ChildMode probe -ChildCulture $cultureName
            Assert-Timestamp ($probe -like 'PROBE_OK|*') "Timestamp probe returned unexpected output: $probe"
        }
    }

    $writeCore = Invoke-TimestampChild -HostPath $pwsh -ChildMode write -ChildCulture 'ru-RU'
    $readDesktop = Invoke-TimestampChild -HostPath $windowsPowerShell -ChildMode read -ChildCulture 'en-GB'
    Assert-Timestamp ($writeCore -like 'WRITE_OK|*' -and $readDesktop -like "READ_OK|*$fixedUtc|$fixedUtc") 'PowerShell 7 to 5.1 journal round trip failed.'

    $writeDesktop = Invoke-TimestampChild -HostPath $windowsPowerShell -ChildMode write -ChildCulture 'ru-RU'
    $readCore = Invoke-TimestampChild -HostPath $pwsh -ChildMode read -ChildCulture 'en-GB'
    Assert-Timestamp ($writeDesktop -like 'WRITE_OK|*' -and $readCore -like "READ_OK|*$fixedUtc|$fixedUtc") 'PowerShell 5.1 to 7 journal round trip failed.'

    $raw = [IO.File]::ReadAllText((Join-Path $fixture 'publication-ci.json'), (New-Object Text.UTF8Encoding($false)))
    Assert-Timestamp ($raw -match [regex]::Escape($fixedUtc)) 'Journal writer did not preserve ISO-8601 UTC.'
    Write-Output 'Timestamp normalization tests passed (PowerShell 5.1/7, ru-RU/en-GB, bidirectional journal round trips).'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path -Parent $resolved) -ne $tempRoot -or (Split-Path -Leaf $resolved) -notlike 'factory-timestamp-tests-*') {
        throw "Unsafe timestamp fixture cleanup: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
