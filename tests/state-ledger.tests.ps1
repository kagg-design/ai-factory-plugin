param([string]$PluginRoot, [switch]$NativeRace)

$ErrorActionPreference = "Stop"
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "factory-ledger-$([Guid]::NewGuid().ToString('N'))"
$fixturePlugin = Join-Path $fixtureRoot "plugin"
$fixtureRepo = Join-Path $fixtureRoot "repository"
$savedHome = $env:CLAUDE_FACTORY_HOME
$savedThreshold = $env:CLAUDE_FACTORY_LOCK_SLOW_MILLISECONDS
$writer = $null
try {
    New-Item -ItemType Directory -Path (Join-Path $fixturePlugin "scripts"), (Join-Path $fixturePlugin "resources"), $fixtureRepo -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PluginRoot "config.default.json") -Destination $fixturePlugin
    Copy-Item -LiteralPath (Join-Path $PluginRoot "resources\state.template.json") -Destination (Join-Path $fixturePlugin "resources")
    foreach ($name in @("factory-common.ps1", "project-context.ps1")) {
        Copy-Item -LiteralPath (Join-Path $PluginRoot "scripts\$name") -Destination (Join-Path $fixturePlugin "scripts")
    }
    & git init --quiet $fixtureRepo
    if ($LASTEXITCODE -ne 0) { throw "Could not initialize ledger fixture repository." }
    $env:CLAUDE_FACTORY_HOME = Join-Path $fixtureRoot "runtime"
    $env:CLAUDE_FACTORY_LOCK_SLOW_MILLISECONDS = "1"
    $initScript = Join-Path $fixturePlugin "scripts\project-context.ps1"
    $commonScript = Join-Path $fixturePlugin "scripts\factory-common.ps1"
    . $commonScript
    $fixtureContext = (& $initScript -Repository $fixtureRepo -Initialize) | ConvertFrom-Json
    $initialBackupValid = if ([IO.File]::Exists("$($fixtureContext.statePath).previous.bak")) {
        @((Read-FactoryJson -Path "$($fixtureContext.statePath).previous.bak").tasks).Count -eq 0
    } else { $false }
    $ledger = Read-FactoryJson -Path $fixtureContext.statePath
    $ledger.createdAt = "2026-07-18T09:36:00Z"
    $ledger.tasks = @(1..6 | ForEach-Object { [pscustomobject]@{
        id = "ledger-$_"; status = "held"; title = "Ledger fixture $_"
        worktree = $null; branch = $null; commit = $null
    } })
    $seedMutex = Enter-FactoryMutex -ProjectKey $fixtureContext.projectKey
    try { Write-FactoryJsonAtomic -Path $fixtureContext.statePath -Value $ledger } finally { Exit-FactoryMutex $seedMutex }

    # Force the reported missing-path interleaving only in the disposable copy.
    # Neither the existence check nor its result is mocked. NativeRace runs the
    # same two-process workload using the unmodified File.Replace implementation.
    $gapMarker = Join-Path $fixtureRoot "replace-gap"
    $restoredMarker = Join-Path $fixtureRoot "replace-restored"
    if (-not $NativeRace) {
        $commonText = [IO.File]::ReadAllText($commonScript)
        $replaceCall = '[IO.File]::Replace($temporaryPath, $fullPath, $backupPath, $true)'
        if (-not $commonText.Contains($replaceCall)) { throw "Replace interleaving fixture needs updating." }
        $commonText = $commonText.Replace($replaceCall, @'
if ($env:FACTORY_LEDGER_GAP -and [IO.Path]::GetFileName($fullPath) -eq 'state.json' -and -not [IO.File]::Exists($env:FACTORY_LEDGER_GAP)) {
    if ([IO.File]::Exists($backupPath)) { [IO.File]::Delete($backupPath) }
    [IO.File]::Move($fullPath, $backupPath)
    [IO.File]::WriteAllText($env:FACTORY_LEDGER_GAP, 'ready')
    Start-Sleep -Milliseconds 1800
    [IO.File]::Move($temporaryPath, $fullPath)
    [IO.File]::WriteAllText($env:FACTORY_LEDGER_RESTORED, 'ready')
} else {
    [IO.File]::Replace($temporaryPath, $fullPath, $backupPath, $true)
}
'@)
        [IO.File]::WriteAllText($commonScript, $commonText)
        $initText = [IO.File]::ReadAllText($initScript)
        $missingCheck = 'if (-not (Test-Path -LiteralPath $statePath)) {'
        if (-not $initText.Contains($missingCheck)) { throw "Initialize interleaving fixture needs updating." }
        $initText = $initText.Replace($missingCheck, $missingCheck + @'

        if ($env:FACTORY_LEDGER_RESTORED) {
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not [IO.File]::Exists($env:FACTORY_LEDGER_RESTORED)) {
                if ([DateTime]::UtcNow -gt $deadline) { throw 'Replace fixture timed out.' }
                Start-Sleep -Milliseconds 10
            }
        }
'@)
        [IO.File]::WriteAllText($initScript, $initText)
    }
    $stopMarker = Join-Path $fixtureRoot "stop"
    $writer = Start-Job -ScriptBlock {
        param($Common, $HomePath, $Key, $StatePath, $Gap, $Restored, $Stop, $ForceGap)
        $ErrorActionPreference = "Stop"
        $env:CLAUDE_FACTORY_HOME = $HomePath
        if ($ForceGap) { $env:FACTORY_LEDGER_GAP = $Gap; $env:FACTORY_LEDGER_RESTORED = $Restored }
        . $Common
        $writes = 0
        while (-not [IO.File]::Exists($Stop)) {
            $mutex = Enter-FactoryMutex -ProjectKey $Key
            try {
                $state = Read-FactoryJson -Path $StatePath
                $state.scheduler.heartbeatAt = Get-FactoryUtcTimestamp
                Write-FactoryJsonAtomic -Path $StatePath -Value $state
                $writes++
            } finally { Exit-FactoryMutex $mutex }
        }
        $writes
    } -ArgumentList $commonScript, $env:CLAUDE_FACTORY_HOME, $fixtureContext.projectKey, $fixtureContext.statePath, $gapMarker, $restoredMarker, $stopMarker, (-not $NativeRace)
    if (-not $NativeRace) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not [IO.File]::Exists($gapMarker)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw "Writer did not reach replacement gap: $($writer.State)" }
            Start-Sleep -Milliseconds 10
        }
        $env:FACTORY_LEDGER_RESTORED = $restoredMarker
    }
    $iterations = if ($NativeRace) { 250 } else { 12 }
    for ($iteration = 0; $iteration -lt $iterations; $iteration++) {
        $null = & $initScript -Repository $fixtureRepo -Initialize
        $observed = Read-FactoryJson -Path $fixtureContext.statePath
        if (@($observed.tasks).Count -ne 6) {
            $created = if ($null -eq $observed.createdAt) { 'null' } else { [string]$observed.createdAt }
            throw "LEDGER RACE: Initialize replaced 6 tasks with $(@($observed.tasks).Count); createdAt=$created; iteration=$iteration."
        }
    }
    [IO.File]::WriteAllText($stopMarker, 'stop')
    $null = Wait-Job $writer -Timeout 15
    $writes = Receive-Job $writer -ErrorAction Stop
    if ($writer.State -ne 'Completed') { throw "Ledger writer failed: $($writer.State)" }
    $observed = Read-FactoryJson -Path $fixtureContext.statePath
    if ($null -eq $observed.tasks[0].PSObject.Properties['syncPreparation']) { throw "Initialize did not back-fill task properties." }
    if ([string]$observed.createdAt -ne '2026-07-18T09:36:00Z') { throw "Initialize changed ledger creation time." }
    Write-Host "Ledger concurrency passed: $iterations initializations, $writes writes; native=$NativeRace."
    if (-not $initialBackupValid) { throw 'Initial creation did not retain a valid recovery copy.' }

    # Use the production helpers for boundary checks, without interleaving hooks.
    . (Join-Path $PluginRoot "scripts\factory-common.ps1")
    $stateBytes = [IO.File]::ReadAllText($fixtureContext.statePath)
    $backupPath = "$($fixtureContext.statePath).previous.bak"
    $backupBytes = [IO.File]::ReadAllText($backupPath)
    $orphanPaths = @("$($fixtureContext.statePath).c90a745db00b4ba59ed541b5dc8a69dd.tmp", "$($fixtureContext.statePath).pre-reboot-fix.bak")
    foreach ($orphanPath in $orphanPaths) { [IO.File]::WriteAllText($orphanPath, $stateBytes) }
    $refused = $false
    try { Write-FactoryJsonAtomic -Path $fixtureContext.statePath -Value $observed } catch {
        $refused = $_.Exception.Message -match 'project mutex is not held'
    }
    if (-not $refused) { throw "An unlocked state write was accepted." }
    $guardMutex = Enter-FactoryMutex -ProjectKey $fixtureContext.projectKey
    try {
        $emptyLedger = $stateBytes | ConvertFrom-Json
        $emptyLedger.tasks = @()
        foreach ($declared in @('', 'ledger-1')) {
            $refused = $false
            try { Write-FactoryJsonAtomic -Path $fixtureContext.statePath -Value $emptyLedger -RemovedTaskIds @($declared) } catch {
                $refused = $_.Exception.Message -match 'Undeclared removal of task IDs'
            }
            if (-not $refused) { throw "A destructive write was accepted; declared='$declared'." }
        }
        $renamedLedger = $stateBytes | ConvertFrom-Json
        $renamedLedger.tasks[0].id = 'replacement-id'
        $refused = $false
        try { Write-FactoryJsonAtomic -Path $fixtureContext.statePath -Value $renamedLedger } catch {
            $refused = $_.Exception.Message -match 'Undeclared removal of task IDs: ledger-1'
        }
        if (-not $refused) { throw 'The write guard checked only task count, not task IDs.' }
        if ([IO.File]::ReadAllText($fixtureContext.statePath) -cne $stateBytes -or [IO.File]::ReadAllText($backupPath) -cne $backupBytes) {
            throw "A refused write changed the ledger or recovery copy."
        }
        $observed.tasks[0].title = 'Updated fixture task'
        Write-FactoryJsonAtomic -Path $fixtureContext.statePath -Value $observed
        if ([IO.File]::ReadAllText($backupPath) -cne $stateBytes) { throw "Backup is not the preceding on-disk ledger." }
    } finally { Exit-FactoryMutex $guardMutex }
    $errorLog = [IO.File]::ReadAllText((Join-Path $fixtureContext.projectData 'scheduler.stderr.log'))
    if (-not $errorLog.Contains('state-write-refused') -or -not $errorLog.Contains('ledger-6')) { throw "State write refusal was not logged to the scheduler error log." }
    $lockLog = [IO.File]::ReadAllText((Join-Path $fixtureContext.projectData 'factory-locks.jsonl'))
    if (-not $lockLog.Contains('project-context.ps1:')) { throw "Initialization is absent from the mutex journal." }

    $beforeInit = [IO.File]::ReadAllText($fixtureContext.statePath)
    $backupBeforeInit = [IO.File]::ReadAllText($backupPath)
    $null = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $fixtureRepo -Initialize
    if ([IO.File]::ReadAllText($fixtureContext.statePath) -cne $beforeInit -or [IO.File]::ReadAllText($backupPath) -cne $backupBeforeInit) {
        throw "An idempotent initialization rewrote the ledger or backup."
    }

    $fakeClaude = Join-Path $fixtureRoot 'claude-fake.exe'
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PluginRoot 'tests\FakeClaude.cs'))) -OutputAssembly $fakeClaude -OutputType ConsoleApplication
    $reject = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PluginRoot 'scripts\reject-task.ps1') -Repository $fixtureRepo -TaskId LEDGER-1 -Yes -ClaudeCommand $fakeClaude
    if ($LASTEXITCODE -ne 0) { throw 'Legitimate reject failed.' }
    $afterReject = Read-FactoryJson -Path $fixtureContext.statePath
    if (@($afterReject.tasks).Count -ne 5 -or @($afterReject.tasks | Where-Object { $_.id -eq 'ledger-1' }).Count -ne 0) { throw 'Reject removed the wrong task IDs.' }
    if (@((Read-FactoryJson $backupPath).tasks).Count -ne 6) { throw 'Reject did not retain recoverable task history.' }
    foreach ($orphanPath in $orphanPaths) {
        if ([IO.File]::ReadAllText($orphanPath) -cne $stateBytes) { throw 'An orphaned recovery document was changed.' }
    }
    $displacedPath = Join-Path $fixtureRoot 'displaced-ledger.json'
    $backupBeforeMissing = [IO.File]::ReadAllText($backupPath)
    $missingMutex = Enter-FactoryMutex $fixtureContext.projectKey
    try {
        [IO.File]::Move($fixtureContext.statePath, $displacedPath)
        $refused = $false
        try { $null = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $fixtureRepo -Initialize } catch {
            $refused = $_.Exception.Message -match 'ledger is missing but a recovery copy exists'
        }
        if (-not $refused -or [IO.File]::Exists($fixtureContext.statePath)) { throw 'Initialization replaced a missing recoverable ledger with the blank template.' }
        if ([IO.File]::ReadAllText($backupPath) -cne $backupBeforeMissing) { throw 'Missing-state refusal changed the recovery copy.' }
    } finally {
        if ([IO.File]::Exists($displacedPath) -and -not [IO.File]::Exists($fixtureContext.statePath)) { [IO.File]::Move($displacedPath, $fixtureContext.statePath) }
        Exit-FactoryMutex $missingMutex
    }
    Write-Host 'Ledger guard, scheduler error log, mutex attribution, backup, idempotence, migration, and legitimate reject passed.'
    if (-not $NativeRace) {
        & (Join-Path $PluginRoot 'tests\scheduler-ledger.tests.ps1') -PluginRoot $PluginRoot -Repository $fixtureRepo -RuntimeHome $env:CLAUDE_FACTORY_HOME -ClaudeCommand $fakeClaude
        & (Join-Path $PluginRoot 'tests\scheduler-ledger.tests.ps1') -PluginRoot $PluginRoot -Repository $fixtureRepo -RuntimeHome $env:CLAUDE_FACTORY_HOME -ClaudeCommand $fakeClaude -Busy -Seconds 15
    }
} finally {
    if ($null -ne $writer) {
        if ($writer.State -eq 'Running') { Stop-Job $writer }
        Remove-Job $writer -Force
    }
    $env:CLAUDE_FACTORY_HOME = $savedHome
    $env:CLAUDE_FACTORY_LOCK_SLOW_MILLISECONDS = $savedThreshold
    Remove-Item Env:\FACTORY_LEDGER_RESTORED -ErrorAction SilentlyContinue
    # Preserve reproduction evidence; all files belong to this isolated fixture.
    Write-Host "Ledger fixture: $fixtureRoot"
}
