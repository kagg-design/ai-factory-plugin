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
    $safeTaskId = ConvertTo-FactorySafeName -Value $taskId
    $eventDirectory = Join-Path $context.eventsPath $safeTaskId
    $historyDirectory = Join-Path $eventDirectory "history"
    New-Item -ItemType Directory -Path $historyDirectory -Force | Out-Null

    $message = [string]$inputJson.last_assistant_message
    $kind = "message"
    $payload = $null

    foreach ($candidate in @(
        [pscustomobject]@{ Marker = "FACTORY_RESULT"; Kind = "result" },
        [pscustomobject]@{ Marker = "FACTORY_PLAN"; Kind = "plan" }
    )) {
        $markerIndex = $message.LastIndexOf(
            [string]$candidate.Marker,
            [StringComparison]::Ordinal
        )
        if ($markerIndex -lt 0) { continue }

        $jsonText = $message.Substring($markerIndex + ([string]$candidate.Marker).Length).Trim()
        if ($jsonText.StartsWith('```')) {
            $jsonText = $jsonText -replace '^```(?:json)?\s*', ''
            $jsonText = $jsonText -replace '\s*```\s*$', ''
        }
        $firstBrace = $jsonText.IndexOf('{' )
        $lastBrace = $jsonText.LastIndexOf('}' )
        if ($firstBrace -lt 0 -or $lastBrace -lt $firstBrace) { continue }

        try {
            $payload = $jsonText.Substring($firstBrace, $lastBrace - $firstBrace + 1) |
                ConvertFrom-Json
            $kind = [string]$candidate.Kind
            break
        } catch {
            $kind = "invalid-marker"
            $payload = [pscustomobject]@{
                marker = [string]$candidate.Marker
                error = $_.Exception.Message
            }
            break
        }
    }

    $transcriptPath = if ($null -ne $inputJson.PSObject.Properties["agent_transcript_path"] -and [string]$inputJson.agent_transcript_path) {
        [string]$inputJson.agent_transcript_path
    } else {
        [string]$inputJson.transcript_path
    }
    $capturedAt = Get-FactoryUtcTimestamp
    $event = [ordered]@{
        version = 1
        taskId = $taskId
        kind = $kind
        capturedAt = $capturedAt
        hookEventName = [string]$inputJson.hook_event_name
        sessionId = $sessionId
        branch = $branch
        worktree = [IO.Path]::GetFullPath($cwd)
        transcriptPath = $transcriptPath
        lastAssistantMessage = $message
        payload = $payload
    }

    $historyName = "$($capturedAt -replace '[:.]', '-')-$([Guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    Write-FactoryJsonAtomic -Path (Join-Path $historyDirectory $historyName) -Value $event
    Write-FactoryJsonAtomic -Path (Join-Path $eventDirectory "latest.json") -Value $event
    if ($kind -eq "result") {
        Write-FactoryJsonAtomic -Path (Join-Path $eventDirectory "latest-result.json") -Value $event
    } elseif ($kind -eq "plan") {
        Write-FactoryJsonAtomic -Path (Join-Path $eventDirectory "latest-plan.json") -Value $event
    }

    $metadataPath = Join-Path $context.sessionsPath "$safeTaskId.json"
    if (Test-Path -LiteralPath $metadataPath) {
        $metadata = Read-FactoryJson -Path $metadataPath
        Set-FactoryProperty -Target $metadata -Name "transcriptPath" -Value $transcriptPath
        Set-FactoryProperty -Target $metadata -Name "lastAssistantMessage" -Value $message
        Set-FactoryProperty -Target $metadata -Name "lastEventAt" -Value $capturedAt
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
