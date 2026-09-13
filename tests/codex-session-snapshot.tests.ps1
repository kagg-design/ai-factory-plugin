param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\codex-runtime.ps1')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-codex-snapshot-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$encoding = New-Object Text.UTF8Encoding($false)
$session = [pscustomobject]@{
    id = 'codex-snapshot-test'; name = 'snapshot-test'; sessionId = $null
    processId = 0; processStartTimeUtc = $null
    transcriptPath = Join-Path $fixtureRoot 'events.jsonl'
    lastMessagePath = Join-Path $fixtureRoot 'last-message.txt'
    stderrPath = Join-Path $fixtureRoot 'stderr.log'
}

function Assert-SnapshotValue {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) { throw "$Message Expected '$Expected', got '$Actual'." }
}
function Read-SnapshotFixture {
    param([string[]]$Lines)
    [IO.File]::WriteAllLines($session.transcriptPath, $Lines, $encoding)
    return Get-FactoryCodexSessionSnapshot -Session $session
}

try {
    # Real Codex failures contain a flat error followed by a nested turn.failed.
    # StrictMode must not let one failed worker abort reconciliation of the queue.
    $failed = Read-SnapshotFixture @(
        '{"type":"thread.started","thread_id":"failed-thread"}',
        '{"type":"error","message":"request rejected"}',
        '{"type":"turn.failed","error":{"message":"request rejected"}}'
    )
    Assert-SnapshotValue 'failed' $failed.state 'Nested failure state.'
    Assert-SnapshotValue 'request rejected' $failed.error 'Nested failure diagnostic.'
    Assert-SnapshotValue 'failed-thread' $failed.sessionId 'Failure lost the thread identity.'
    Assert-SnapshotValue $false $failed.processAlive 'Stopped fixture reported as alive.'

    foreach ($line in @(
        '{"type":"error","message":"flat failure"}',
        '{"type":"turn.failed","message":"flat failure"}'
    )) {
        $flat = Read-SnapshotFixture @($line)
        Assert-SnapshotValue 'failed' $flat.state 'Legacy flat failure state.'
        Assert-SnapshotValue 'flat failure' $flat.error 'Legacy flat failure diagnostic.'
    }
    $nested = Read-SnapshotFixture @('{"type":"turn.failed","error":{"message":"nested only"}}')
    Assert-SnapshotValue 'nested only' $nested.error 'Nested-only failure diagnostic.'

    foreach ($line in @(
        '{"type":"turn.failed"}',
        '{"type":"turn.failed","error":null}',
        '{"type":"turn.failed","error":{"code":"unknown"}}',
        '{"type":"error","message":"  "}'
    )) {
        $unknown = Read-SnapshotFixture @($line)
        Assert-SnapshotValue 'failed' $unknown.state 'Unknown failure became success.'
        Assert-SnapshotValue $line $unknown.error 'Unknown failure lost its raw diagnostic.'
    }

    $healthy = Read-SnapshotFixture @(
        '', 'not json',
        '{"type":"thread.started","thread_id":"healthy-thread"}',
        '{"type":"item.completed","item":{"type":"agent_message","text":"finished normally"}}',
        '{"type":"turn.completed"}'
    )
    Assert-SnapshotValue 'done' $healthy.state 'A later healthy worker was not processed.'
    Assert-SnapshotValue '' $healthy.error 'Failure leaked into a healthy worker.'
    Assert-SnapshotValue 'healthy-thread' $healthy.sessionId 'Healthy thread identity.'
    Assert-SnapshotValue 'finished normally' $healthy.lastAssistantMessage 'Successful result capture.'
    if ([string]$healthy.messageHash -notmatch '^[a-f0-9]{64}$') { throw 'Missing message hash.' }

    [IO.File]::WriteAllText($session.lastMessagePath, 'saved final message', $encoding)
    $saved = Get-FactoryCodexSessionSnapshot -Session $session
    Assert-SnapshotValue 'saved final message' $saved.lastAssistantMessage 'Final-message file precedence.'
    if ($saved.messageHash -eq $healthy.messageHash) { throw 'Final-message hash did not change.' }
    Write-Host 'Codex session snapshot regressions passed.' -ForegroundColor Green
} finally {
    # Only remove the unique, locally created fixture directory.
    $fullFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path -Parent $fullFixture) -ne $tempRoot -or (Split-Path -Leaf $fullFixture) -notlike 'factory-codex-snapshot-*') {
        throw "Unsafe snapshot fixture cleanup: $fullFixture"
    }
    Remove-Item -LiteralPath $fullFixture -Recurse -Force
}
