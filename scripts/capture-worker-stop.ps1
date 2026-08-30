$ErrorActionPreference = "Stop"

$utf8NoBom = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $inputJson = $raw | ConvertFrom-Json
    $cwd = [string]$inputJson.cwd
    if (-not $cwd -or -not (Test-Path -LiteralPath $cwd)) { exit 0 }

    $branch = (& git -C $cwd branch --show-current 2>$null).Trim()
    if ($branch -notlike "factory-worker/*") { exit 0 }

    . (Join-Path $PSScriptRoot "factory-common.ps1")
    . (Join-Path $PSScriptRoot "worker-event.ps1")
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $cwd) |
        ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $context.statePath)) { exit 0 }

    $state = Read-FactoryJson -Path $context.statePath
    $sessionId = [string]$inputJson.session_id
    $taskMatches = @($state.tasks | Where-Object {
        [string]$_.branch -eq $branch -or
        (
            $null -ne $_.backgroundSession -and
            [string]$_.backgroundSession.sessionId -eq $sessionId
        )
    })
    if ($taskMatches.Count -ne 1) { exit 0 }

    $task = $taskMatches[0]
    $taskId = [string]$task.id
    $safeTaskId = ConvertTo-FactoryTaskArtifactName -TaskId $taskId
    $message = [string]$inputJson.last_assistant_message
    $transcriptPath = if ($null -ne $inputJson.PSObject.Properties["agent_transcript_path"] -and [string]$inputJson.agent_transcript_path) {
        [string]$inputJson.agent_transcript_path
    } else {
        [string]$inputJson.transcript_path
    }
    $event = Publish-FactoryWorkerEvent `
        -Context $context `
        -Task $task `
        -SessionId $sessionId `
        -Worktree $cwd `
        -Message $message `
        -TranscriptPath $transcriptPath `
        -EventName ([string]$inputJson.hook_event_name)

    $metadataPath = Join-Path $context.sessionsPath "$safeTaskId.json"
    if (Test-Path -LiteralPath $metadataPath) {
        $metadata = Read-FactoryJson -Path $metadataPath
        Set-FactoryProperty -Target $metadata -Name "transcriptPath" -Value $transcriptPath
        Set-FactoryProperty -Target $metadata -Name "lastAssistantMessage" -Value $message
        Set-FactoryProperty -Target $metadata -Name "lastEventAt" -Value ([string]$event.capturedAt)
        Write-FactoryJsonAtomic -Path $metadataPath -Value $metadata
    }
} catch {
    if ($env:CLAUDE_FACTORY_HOOK_DEBUG) {
        Write-Error $_
        exit 1
    }
    # Capture hooks are observational. Never block a worker because persistence
    # failed; reconciliation will fall back to Claude's session state.
}

exit 0
