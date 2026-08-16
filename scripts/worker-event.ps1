if ($null -eq (Get-Command Write-FactoryJsonAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "factory-common.ps1")
}

function Publish-FactoryWorkerEvent {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [AllowEmptyString()][string]$Message,
        [string]$TranscriptPath = "",
        [string]$EventName = "WorkerStop"
    )

    $taskId = [string]$Task.id
    $safeTaskId = ConvertTo-FactoryTaskArtifactName -TaskId $taskId
    $eventDirectory = Join-Path ([string]$Context.eventsPath) $safeTaskId
    $historyDirectory = Join-Path $eventDirectory "history"
    New-Item -ItemType Directory -Path $historyDirectory -Force | Out-Null

    $kind = "message"
    $payload = $null
    foreach ($candidate in @(
        [pscustomobject]@{ Marker = "FACTORY_RESULT"; Kind = "result" },
        [pscustomobject]@{ Marker = "FACTORY_PLAN"; Kind = "plan" }
    )) {
        $markerIndex = $Message.LastIndexOf([string]$candidate.Marker, [StringComparison]::Ordinal)
        if ($markerIndex -lt 0) { continue }
        $jsonText = $Message.Substring($markerIndex + ([string]$candidate.Marker).Length).Trim()
        if ($jsonText.StartsWith('```')) {
            $jsonText = $jsonText -replace '^```(?:json)?\s*', ''
            $jsonText = $jsonText -replace '\s*```\s*$', ''
        }
        $firstBrace = $jsonText.IndexOf('{')
        $lastBrace = $jsonText.LastIndexOf('}')
        if ($firstBrace -lt 0 -or $lastBrace -lt $firstBrace) { continue }
        try {
            $payload = $jsonText.Substring($firstBrace, $lastBrace - $firstBrace + 1) | ConvertFrom-Json
            $kind = [string]$candidate.Kind
            break
        } catch {
            $kind = "invalid-marker"
            $payload = [pscustomobject]@{ marker = [string]$candidate.Marker; error = $_.Exception.Message }
            break
        }
    }

    $branch = (& git -C $Worktree branch --show-current 2>$null | Out-String).Trim()
    $capturedAt = Get-FactoryUtcTimestamp
    $event = [ordered]@{
        version = 1
        taskId = $taskId
        kind = $kind
        capturedAt = $capturedAt
        hookEventName = $EventName
        sessionId = $SessionId
        branch = $branch
        worktree = [IO.Path]::GetFullPath($Worktree)
        transcriptPath = $TranscriptPath
        lastAssistantMessage = $Message
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
    return [pscustomobject]$event
}
