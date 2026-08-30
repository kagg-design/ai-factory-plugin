if ($null -eq (Get-Command Write-FactoryJsonAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "factory-common.ps1")
}

function Get-FactoryJsonObjectEndIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$StartIndex
    )

    $depth = 0
    $inString = $false
    $escaped = $false
    for ($index = $StartIndex; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($character -eq [char]0x5c) {
                $escaped = $true
            } elseif ($character -eq [char]0x22) {
                $inString = $false
            }
            continue
        }
        if ($character -eq [char]0x22) {
            $inString = $true
        } elseif ($character -eq [char]0x7b) {
            $depth++
        } elseif ($character -eq [char]0x7d) {
            $depth--
            if ($depth -eq 0) { return $index }
        }
    }
    return -1
}

function ConvertFrom-FactoryWorkerMarkerMessage {
    param([AllowEmptyString()][string]$Message)

    $candidates = @(
        [pscustomobject]@{ Marker = "FACTORY_RESULT"; Kind = "result" },
        [pscustomobject]@{ Marker = "FACTORY_PLAN"; Kind = "plan" }
    )
    $located = New-Object Collections.Generic.List[object]
    foreach ($candidate in $candidates) {
        $pattern = "^[ \t]*$([regex]::Escape([string]$candidate.Marker))[ \t]*\r?$"
        $match = [regex]::Match($Message, $pattern, [Text.RegularExpressions.RegexOptions]::Multiline)
        if ($match.Success) {
            $located.Add([pscustomobject]@{
                Marker = [string]$candidate.Marker
                Kind = [string]$candidate.Kind
                Index = $match.Index
                JsonSearchIndex = $match.Index + $match.Length
                Standalone = $true
            })
        }
    }
    if ($located.Count -eq 0) {
        foreach ($candidate in $candidates) {
            $markerIndex = $Message.IndexOf([string]$candidate.Marker, [StringComparison]::Ordinal)
            if ($markerIndex -ge 0) {
                $located.Add([pscustomobject]@{
                    Marker = [string]$candidate.Marker
                    Kind = [string]$candidate.Kind
                    Index = $markerIndex
                    JsonSearchIndex = $markerIndex + ([string]$candidate.Marker).Length
                    Standalone = $false
                })
            }
        }
    }
    if ($located.Count -eq 0) {
        return [pscustomobject]@{ kind = "message"; payload = $null; marker = $null }
    }

    $chosen = @($located | Sort-Object Index | Select-Object -First 1)[0]
    $firstBrace = $Message.IndexOf('{', [int]$chosen.JsonSearchIndex)
    if ($firstBrace -lt 0) {
        $reason = "Marker $([string]$chosen.Marker) was found, but no JSON object starts after it."
        return [pscustomobject]@{
            kind = "invalid-marker"
            marker = [string]$chosen.Marker
            payload = [pscustomobject]@{ marker = [string]$chosen.Marker; error = $reason }
        }
    }
    $lastBrace = Get-FactoryJsonObjectEndIndex -Text $Message -StartIndex $firstBrace
    if ($lastBrace -lt $firstBrace) {
        $reason = "Marker $([string]$chosen.Marker) was found, but its JSON object has no matching closing brace."
        return [pscustomobject]@{
            kind = "invalid-marker"
            marker = [string]$chosen.Marker
            payload = [pscustomobject]@{ marker = [string]$chosen.Marker; error = $reason }
        }
    }
    try {
        $payload = $Message.Substring($firstBrace, $lastBrace - $firstBrace + 1) | ConvertFrom-Json
        return [pscustomobject]@{
            kind = [string]$chosen.Kind
            marker = [string]$chosen.Marker
            payload = $payload
        }
    } catch {
        return [pscustomobject]@{
            kind = "invalid-marker"
            marker = [string]$chosen.Marker
            payload = [pscustomobject]@{
                marker = [string]$chosen.Marker
                error = "Marker $([string]$chosen.Marker) contains invalid JSON: $($_.Exception.Message)"
            }
        }
    }
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

    $classification = ConvertFrom-FactoryWorkerMarkerMessage -Message $Message
    $kind = [string]$classification.kind
    $payload = $classification.payload

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
