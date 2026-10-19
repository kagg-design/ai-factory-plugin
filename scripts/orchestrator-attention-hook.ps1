[CmdletBinding()]
param(
    [ValidateRange(1, 82800)][int]$ConsumerSeconds = 82800,
    [ValidateRange(100, 15000)][int]$PollMilliseconds = 1000
)

$ErrorActionPreference = "Stop"
$hookStartedAtUtc = [DateTime]::UtcNow
$context = $null
$consumerToken = [Guid]::NewGuid().ToString("N")
$ownsConsumer = $false
$exitCode = 0
try {
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $inputJson = $raw | ConvertFrom-Json
    . (Join-Path $PSScriptRoot "factory-common.ps1")
    . (Join-Path $PSScriptRoot "attention-state.ps1")
    $eventName = [string](Get-FactoryNestedValue -Target $inputJson -Name "hook_event_name")
    if ($eventName -notin @("SessionStart", "Stop")) { exit 0 }
    $sessionId = [string](Get-FactoryNestedValue -Target $inputJson -Name "session_id")
    $cwd = [string](Get-FactoryNestedValue -Target $inputJson -Name "cwd")
    if (-not $sessionId -or -not $cwd -or -not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $cwd) | ConvertFrom-Json
    if (-not (Test-FactorySamePath -Left $cwd -Right ([string]$context.repositoryRoot))) { exit 0 }
    $identityPath = Join-Path ([string]$context.projectData) "orchestrator-session.json"
    # Native SessionStart can precede the launcher's verified identity write.
    # Wait only while Factory owns an in-flight launch receipt, asynchronously.
    $receiptPath = Join-Path ([string]$context.projectData) "orchestrator-launch.json"
    $identityDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ($eventName -eq "SessionStart" -and (Test-Path -LiteralPath $receiptPath) -and [DateTime]::UtcNow -lt $identityDeadline) {
        if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
            $launchIdentity = Read-FactoryJson -Path $identityPath
            if ([string]$launchIdentity.sessionId -eq $sessionId) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) { exit 0 }
    $identity = Read-FactoryJson -Path $identityPath
    if ([string]$identity.sessionId -ne $sessionId) { exit 0 }
    $config = Read-FactoryJson -Path $context.configPath
    if ([string]$config.workerAgent -ne "claude" -or
        -not [bool](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $config -Name "orchestrator") -Name "attentionBridge" -Default $true)) { exit 0 }

    $startedAt = Get-FactoryUtcTimestamp
    $processStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
    $hostProcess = Get-FactoryClaudeHookHostProcess
    $attention = Update-FactoryAttentionRecord -Context $context -Mutator {
        param($record)
        $claim = $record.claudeClaim
        $claimTime = ConvertFrom-FactoryRoundtripTimestamp -Value (Get-FactoryNestedValue -Target $claim -Name "deliveredAt")
        if ($eventName -eq "Stop" -and $null -ne $claim -and
            [bool](Get-FactoryNestedValue -Target $inputJson -Name "stop_hook_active" -Default $false) -and
            $claimTime.success -and $claimTime.value -lt $hookStartedAtUtc -and
            [string]$claim.sessionId -eq $sessionId -and [string]$claim.status -eq "delivered") {
            Set-FactoryProperty -Target $claim -Name "status" -Value "acknowledged"
            Set-FactoryProperty -Target $claim -Name "acknowledgedAt" -Value $startedAt
        }
        if (-not (Test-FactoryClaudeAttentionConsumer -Consumer $record.claudeConsumer)) {
            Set-FactoryProperty -Target $record -Name "claudeConsumer" -Value ([pscustomobject]@{
                sessionId = $sessionId; pid = $PID; processStartTimeUtc = $processStart
                heartbeatAt = $startedAt; token = $consumerToken; hostProcess = $hostProcess
            })
        }
    }
    $ownsConsumer = [string](Get-FactoryNestedValue -Target $attention.claudeConsumer -Name "token") -eq $consumerToken
    if (-not $ownsConsumer) { exit 0 }

    # A claim is not acknowledged until a subsequent turn reaches Stop. Restore
    # it on SessionStart even though its revisions were already claimed.
    if ($eventName -eq "SessionStart" -and $null -ne $attention.claudeClaim -and [string]$attention.claudeClaim.status -eq "delivered") {
        $attention = Update-FactoryAttentionRecord -Context $context -Mutator {
            param($record)
            Set-FactoryProperty -Target $record.claudeClaim -Name "sessionId" -Value $sessionId
            Set-FactoryProperty -Target $record.claudeClaim -Name "redelivered" -Value $true
            Set-FactoryProperty -Target $record.claudeClaim -Name "deliveredAt" -Value (Get-FactoryUtcTimestamp)
        }
        Write-Output (Get-FactoryClaudeAttentionPrompt -Claim $attention.claudeClaim)
        $exitCode = 2
    } else {
        $deadline = [DateTime]::UtcNow.AddSeconds($ConsumerSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($null -ne $hostProcess -and -not (Test-FactoryRecordedProcess -ProcessRecord $hostProcess)) { break }
            $identity = Read-FactoryJson -Path $identityPath
            if ([string]$identity.sessionId -ne $sessionId) { break }
            $state = Read-FactoryJson -Path $context.statePath
            $config = Read-FactoryJson -Path $context.configPath
            if ([string]$config.workerAgent -ne "claude" -or
                -not [bool](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $config -Name "orchestrator") -Name "attentionBridge" -Default $true)) { break }
            $null = Sync-FactoryAttentionState -Context $context -State $state -Config $config
            $attention = Update-FactoryAttentionRecord -Context $context -Mutator {
                param($record)
                if ([string](Get-FactoryNestedValue -Target $record.claudeConsumer -Name "token") -ne $consumerToken) { return }
                Set-FactoryProperty -Target $record.claudeConsumer -Name "heartbeatAt" -Value (Get-FactoryUtcTimestamp)
                if ($null -ne $record.claudeClaim -and [string]$record.claudeClaim.status -eq "delivered") { return }
                $pending = @(Get-FactoryClaudeDeliverableEvents -Attention $record)
                if ($pending.Count -eq 0) { return }
                Set-FactoryProperty -Target $record -Name "claudeClaim" -Value ([pscustomobject]@{
                    token = $consumerToken; sessionId = $sessionId; status = "delivered"
                    throughRevision = [long]$record.revision
                    eventRevisions = @($pending | ForEach-Object { [long]$_.revision })
                    events = $pending; deliveredAt = Get-FactoryUtcTimestamp; redelivered = $false
                })
                Set-FactoryProperty -Target $record -Name "orchestratorAcknowledgedRevision" -Value ([long]$record.revision)
            }
            if ([string](Get-FactoryNestedValue -Target $attention.claudeConsumer -Name "token") -ne $consumerToken) { break }
            if ([string](Get-FactoryNestedValue -Target $attention.claudeClaim -Name "token") -eq $consumerToken) {
                Write-Output (Get-FactoryClaudeAttentionPrompt -Claim $attention.claudeClaim)
                $exitCode = 2
                break
            }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            Write-Output "Factory attention consumer re-arm (about once per day, before the configured hook timeout). No task action is requested. Stop normally so the plugin can keep attention delivery alive; do not create a watcher."
            $exitCode = 2
        }
    }
} catch {
    # Leave unacknowledged claims durable. Status/doctor expose a dead consumer.
    if ($context) {
        try {
            $failure = $_.Exception.Message
            $null = Update-FactoryAttentionRecord -Context $context -Mutator {
                param($record)
                Set-FactoryProperty -Target $record -Name "claudeConsumerError" -Value $failure
            }
        } catch { }
    }
} finally {
    if ($ownsConsumer) {
        $null = Update-FactoryAttentionRecord -Context $context -Mutator {
            param($record)
            if ([string](Get-FactoryNestedValue -Target $record.claudeConsumer -Name "token") -eq $consumerToken) {
                Set-FactoryProperty -Target $record -Name "claudeConsumer" -Value $null
            }
        }
    }
}
exit $exitCode
