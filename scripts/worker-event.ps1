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
        # Inline marker words in ordinary prose are not envelopes. Only an
        # immediately following JSON object qualifies them as markers.
        foreach ($candidate in $candidates) {
            $markerIndex = 0
            while (($markerIndex = $Message.IndexOf([string]$candidate.Marker, $markerIndex, [StringComparison]::Ordinal)) -ge 0) {
                $jsonSearchIndex = $markerIndex + ([string]$candidate.Marker).Length
                $following = $Message.Substring($jsonSearchIndex)
                $prefix = [regex]::Match($following, '^\s*(?::\s*)?(?:```(?:json)?[ \t]*\r?\n\s*)?', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $firstBrace = $jsonSearchIndex + $prefix.Length
                if ($firstBrace -ge $Message.Length -or $Message[$firstBrace] -ne '{') {
                    $markerIndex = $jsonSearchIndex
                    continue
                }
                $located.Add([pscustomobject]@{
                    Marker = [string]$candidate.Marker
                    Kind = [string]$candidate.Kind
                    Index = $markerIndex
                    JsonSearchIndex = $jsonSearchIndex
                    Standalone = $false
                })
                break
            }
        }
    }
    if ($located.Count -eq 0) {
        return [pscustomobject]@{ kind = "message"; payload = $null; marker = $null }
    }

    $chosen = @($located | Sort-Object Index | Select-Object -First 1)[0]
    $following = $Message.Substring([int]$chosen.JsonSearchIndex)
    $preview = $following.Substring(0, [Math]::Min(200, $following.Length))
    $previewText = ConvertTo-Json -InputObject $preview -Compress
    $prefix = [regex]::Match($following, '^\s*(?::\s*)?(?:```(?:json)?[ \t]*\r?\n\s*)?', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $firstBrace = [int]$chosen.JsonSearchIndex + $prefix.Length
    if ($firstBrace -ge $Message.Length -or $Message[$firstBrace] -ne '{') {
        $reason = "Marker $([string]$chosen.Marker) was found, but no JSON object starts after it."
        return [pscustomobject]@{
            kind = "invalid-marker"
            marker = [string]$chosen.Marker
            payload = [pscustomobject]@{ marker = [string]$chosen.Marker; error = "$reason Following marker: $previewText"; followingMarker = $preview }
        }
    }
    $lastBrace = Get-FactoryJsonObjectEndIndex -Text $Message -StartIndex $firstBrace
    if ($lastBrace -lt $firstBrace) {
        $reason = "Marker $([string]$chosen.Marker) was found, but its JSON object has no matching closing brace."
        return [pscustomobject]@{
            kind = "invalid-marker"
            marker = [string]$chosen.Marker
            payload = [pscustomobject]@{ marker = [string]$chosen.Marker; error = "$reason Following marker: $previewText"; followingMarker = $preview }
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
                error = "Marker $([string]$chosen.Marker) contains invalid JSON: $($_.Exception.Message). Following marker: $previewText"
                followingMarker = $preview
            }
        }
    }
}

function Publish-FactoryWorkerReply {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [AllowEmptyString()][string]$Prompt = "",
        [string]$Source = "UserPromptSubmit",
        [string]$InputSource = "",
        [string]$CommandName = "",
        [string]$MessageId = ""
    )

    if ($Prompt.TrimStart() -match '^FACTORY_PROMPT_FILE=') { return }
    $directory = Join-Path ([string]$Context.eventsPath) (ConvertTo-FactoryTaskArtifactName -TaskId ([string]$Task.id))
    $history = Join-Path $directory "history"
    New-Item -ItemType Directory -Path $history -Force | Out-Null
    $attempt = [int](Get-FactoryNestedValue -Target $Task -Name "attempts" -Default 1)
    if (-not $MessageId -or $MessageId.Length -gt 128) { $MessageId = [Guid]::NewGuid().ToString("N") }
    $inputPath = Join-Path $directory "latest-input.json"
    if (Test-Path -LiteralPath $inputPath) {
        $previous = Read-FactoryJson -Path $inputPath
        if ([string](Get-FactoryNestedValue -Target $previous -Name "messageId") -eq $MessageId -and
            [string](Get-FactoryNestedValue -Target $previous -Name "source") -eq $Source -and
            [string](Get-FactoryNestedValue -Target $previous -Name "inputSource") -ceq $InputSource -and
            [string](Get-FactoryNestedValue -Target $previous -Name "commandName") -eq $CommandName -and
            [string](Get-FactoryNestedValue -Target $previous -Name "promptSha256") -eq (Get-FactoryTextSha256 -Value $Prompt) -and
            [string]$previous.sessionId -eq $SessionId -and [int](Get-FactoryNestedValue -Target $previous -Name "attempt" -Default -1) -eq $attempt) { return $previous }
    }
    $origin = "unknown"
    $authorization = "none"
    if ($Source -eq "codex-resume") {
        # Only the Factory-owned interactive console wrapper uses this boundary.
        # An app-server user-input item is not evidence of an operator reply.
        $origin = "operator"; $authorization = "factory-codex-resume"
    } elseif ($Source -eq "UserPromptSubmit" -and $InputSource -ceq "user") {
        $origin = "operator"; $authorization = "runtime-user-source"
    } elseif ($Source -eq "UserPromptExpansion" -and $InputSource -in @("", "user") -and
        $CommandName -in @("factory", "factory:factory")) {
        # Claude expands a directly invoked worker continuation command. Peer
        # messages containing slash commands arrive as text and cannot do this.
        $origin = "operator"; $authorization = "explicit-worker-command"
    } elseif ($InputSource -in @("sdk", "system", "loop_wakeup", "schedule_wakeup", "poll_event")) {
        $origin = "automation"
    }
    $capturedAt = Get-FactoryUtcTimestamp
    $event = [pscustomobject][ordered]@{
        version = 2; taskId = [string]$Task.id; kind = $(if ($origin -eq "operator") { "reply" } else { "input" })
        sessionId = $SessionId; capturedAt = $capturedAt; source = $Source
        attempt = $attempt; messageId = $MessageId; origin = $origin; authorization = $authorization
        inputSource = $InputSource; commandName = $CommandName
        promptSha256 = Get-FactoryTextSha256 -Value $Prompt
        promptPreview = $Prompt.Substring(0, [Math]::Min(240, $Prompt.Length))
    }
    $name = "$($capturedAt -replace '[:.]', '-')-reply-$([Guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    Write-FactoryJsonAtomic -Path (Join-Path $history $name) -Value $event
    Write-FactoryJsonAtomic -Path $inputPath -Value $event
    # Stop envelopes remain authoritative for result/follow-up detection.
    if ($event.kind -eq "reply") { Write-FactoryJsonAtomic -Path (Join-Path $directory "latest-reply.json") -Value $event }
    return $event
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
