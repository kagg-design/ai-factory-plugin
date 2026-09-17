Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot "factory-common.ps1")

function Get-FactoryMatchingOrchestratorRows {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$SessionId = ""
    )

    $namePattern = '^' + [regex]::Escape($Name) + '(?: \([1-9][0-9]*\))?$'
    return @($Rows | Where-Object {
        $rowName = if ($null -ne $_.PSObject.Properties["name"]) { [string]$_.name } else { "" }
        $rowCwd = if ($null -ne $_.PSObject.Properties["cwd"]) { [string]$_.cwd } else { "" }
        $rowSession = [string](Get-FactoryNestedValue $_ 'sessionId' '')
        ($rowName -cmatch $namePattern -or ($SessionId -and $rowSession -eq $SessionId)) -and $rowCwd -and
            (Test-FactorySamePath -Left $rowCwd -Right $RepositoryRoot)
    })
}

function Select-FactoryBackgroundOrchestrator {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [string]$PreferredSessionId = ""
    )

    $backgroundRows = @($Rows | Where-Object {
        [string]$_.kind -eq "background" -and
        $null -ne $_.PSObject.Properties["id"] -and
        [string]$_.id
    })
    if ($backgroundRows.Count -eq 0) { return $null }

    if ($PreferredSessionId) {
        $preferred = @($backgroundRows | Where-Object {
            $null -ne $_.PSObject.Properties["sessionId"] -and
            [string]$_.sessionId -eq $PreferredSessionId -and
            -not (Test-FactoryTerminalAgentRow -Row $_)
        } | Select-Object -First 1)
        if ($preferred.Count -eq 1) { return $preferred[0] }
    }

    $liveRows = @($backgroundRows | Where-Object {
        -not (Test-FactoryTerminalAgentRow -Row $_)
    })
    if ($liveRows.Count -eq 0) { return $null }
    return @($liveRows | Sort-Object {
        if ($null -ne $_.PSObject.Properties["startedAt"]) { [long]$_.startedAt } else { 0 }
    } -Descending | Select-Object -First 1)[0]
}

function Write-FactoryOrchestratorIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$BackgroundId = ""
    )

    Write-FactoryJsonAtomic -Path $Path -Value ([ordered]@{
        version = 1
        repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
        name = $Name
        sessionId = $SessionId
        backgroundId = if ($BackgroundId) { $BackgroundId } else { $null }
        updatedAt = Get-FactoryUtcTimestamp
    })
}

function Start-FactoryClaudeBackgroundOrchestrator {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Arguments = @(),
        [string]$SessionId = "",
        $Rotation = $null
    )

    # A launch receipt prevents a lost/late CLI response from causing a second
    # launch on retry. It is separate from the last verified conversation UUID.
    $receiptPath = Join-Path ([string]$Context.projectData) 'orchestrator-launch.json'
    if (Test-Path -LiteralPath $receiptPath) {
        $receipt = Read-FactoryJson $receiptPath
        if (-not (Test-FactorySamePath ([string]$receipt.repositoryRoot) ([string]$Context.repositoryRoot)) -or
            [string]$receipt.name -cne $Name) {
            throw "The pending orchestrator launch belongs to another repository or name: $receiptPath"
        }
        $SessionId = [string]$receipt.requestedSessionId
        $backgroundId = [string]$receipt.backgroundId
        if ([string](Get-FactoryNestedValue $receipt 'operation' '') -eq 'respawn') {
            return Wait-FactoryRespawnedOrchestrator -ClaudeCommand $ClaudeCommand -Context $Context -Name $Name `
                -BackgroundId $backgroundId -SessionId $SessionId
        }
        if (-not $backgroundId) {
            throw "A previous Claude launch has an unknown outcome. Inspect 'claude agents' before retrying; launch receipt: $receiptPath. No second orchestrator was started."
        }
    } else {
        $receipt = [pscustomobject]@{
            repositoryRoot = [string]$Context.repositoryRoot; name = $Name
            requestedSessionId = $SessionId; backgroundId = $null
            startedAt = Get-FactoryUtcTimestamp
        }
        Write-FactoryJsonAtomic $receiptPath $receipt
        $launchArguments = @($Arguments) + @('--bg')
        if ($SessionId) { $launchArguments += @('--resume', $SessionId) }
        # --bg needs a prompt. Opening the UI must not replay the last user
        # action or authorize any new Factory/project operation.
        $launchArguments += 'You are the Factory Orchestrator. This message only opens the orchestration interface. Wait for the operator next message. Do not call tools, resume previous actions, or modify project or Factory state.'
        $result = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments $launchArguments -WorkingDirectory ([string]$Context.repositoryRoot)
        $backgroundId = Get-FactoryBackgroundId -Output $result.output
        $receipt.backgroundId = $backgroundId
        Write-FactoryJsonAtomic $receiptPath $receipt
        if ($result.exitCode -ne 0) {
            throw "Claude background orchestrator launch failed: $($result.output). Launch receipt: $receiptPath. No interactive fallback was started."
        }
        if (-not $backgroundId) {
            throw "Claude returned no background session ID: $($result.output). Inspect 'claude agents'; launch receipt: $receiptPath. No second orchestrator was started."
        }
    }

    $row = Wait-FactoryClaudeSessionVisible -ClaudeCommand $ClaudeCommand -BackgroundId $backgroundId
    $actualSessionId = [string](Get-FactoryNestedValue $row 'sessionId' '')
    $parsedSessionId = [Guid]::Empty
    if ([string](Get-FactoryNestedValue $row 'kind' '') -ne 'background' -or
        -not (Test-FactorySamePath ([string](Get-FactoryNestedValue $row 'cwd' '')) ([string]$Context.repositoryRoot)) -or
        @((Get-FactoryMatchingOrchestratorRows -Rows @($row) -RepositoryRoot $Context.repositoryRoot -Name $Name)).Count -ne 1 -or
        -not [Guid]::TryParse($actualSessionId, [ref]$parsedSessionId)) {
        throw "Claude returned an unverified orchestrator row '$backgroundId'. Saved conversation unchanged; inspect the launch receipt: $receiptPath"
    }
    if ($SessionId -and $actualSessionId -ne $SessionId) {
        throw "Claude created a copy '$actualSessionId' instead of resuming '$SessionId' (row '$backgroundId'). Saved conversation unchanged; no attachment or second launch was attempted. Inspect: $receiptPath"
    }
    if ([string](Get-FactoryNestedValue $row 'state' '') -in @('failed', 'stopped')) {
        throw "Claude orchestrator '$backgroundId' is $($row.state). Saved conversation unchanged; inspect: $receiptPath"
    }
    Write-FactoryOrchestratorIdentity -Path (Join-Path ([string]$Context.projectData) 'orchestrator-session.json') `
        -RepositoryRoot $Context.repositoryRoot -Name $Name -SessionId $actualSessionId -BackgroundId $backgroundId
    if ($null -ne $Rotation) {
        $null = Complete-FactoryOrchestratorRotation -Context $Context -Rotation $Rotation -NewSessionId $actualSessionId
    }
    Remove-Item -LiteralPath $receiptPath -Force
    return $row
}

function Resume-FactoryClaudeBackgroundOrchestrator {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutMilliseconds = 60000
    )

    $backgroundId = [string]$Row.id
    $sessionId = [string]$Row.sessionId
    if ([string](Get-FactoryNestedValue $Row 'kind' '') -ne 'background' -or
        -not (Test-FactorySamePath ([string](Get-FactoryNestedValue $Row 'cwd' '')) ([string]$Context.repositoryRoot))) {
        throw 'Cannot respawn an orchestrator outside the selected repository.'
    }
    # respawn replays the original intent if the saved transcript disappeared.
    # Require history first, so a lifecycle operation cannot replay e.g. "go".
    $transcript = [string](Get-FactoryNestedValue $Row 'transcriptPath' '')
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript -PathType Leaf)) {
        $claudeConfigRoot = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude' }
        $nativeStatePath = Join-Path $claudeConfigRoot "jobs\$backgroundId\state.json"
        if (Test-Path -LiteralPath $nativeStatePath -PathType Leaf) {
            $nativeState = Read-FactoryJson $nativeStatePath
            if ([string](Get-FactoryNestedValue $nativeState 'sessionId' '') -eq $sessionId -and
                (Test-FactorySamePath ([string](Get-FactoryNestedValue $nativeState 'cwd' '')) ([string]$Context.repositoryRoot))) {
                $transcript = [string](Get-FactoryNestedValue $nativeState 'linkScanPath' '')
            }
        }
    }
    if (-not $transcript -or -not (Test-Path -LiteralPath $transcript -PathType Leaf) -or
        [IO.Path]::GetFileNameWithoutExtension($transcript) -ne $sessionId -or
        (Get-Item -LiteralPath $transcript).Length -eq 0) {
        throw "Cannot respawn orchestrator '$backgroundId': its saved transcript is missing or unverified. Original intent will not be replayed."
    }

    $receiptPath = Join-Path ([string]$Context.projectData) 'orchestrator-launch.json'
    if (Test-Path -LiteralPath $receiptPath) { throw "An orchestrator launch is already pending: $receiptPath" }
    Write-FactoryJsonAtomic $receiptPath ([ordered]@{
        operation = 'respawn'; repositoryRoot = [string]$Context.repositoryRoot; name = $Name
        requestedSessionId = $sessionId; backgroundId = $backgroundId; startedAt = Get-FactoryUtcTimestamp
    })
    $result = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @('respawn', $backgroundId) -WorkingDirectory ([string]$Context.repositoryRoot)
    if ($result.exitCode -ne 0) {
        throw "Claude could not respawn orchestrator '$backgroundId': $($result.output). No replacement was launched. Run 'factory start' to recheck the recorded session; receipt: $receiptPath"
    }
    return Wait-FactoryRespawnedOrchestrator -ClaudeCommand $ClaudeCommand -Context $Context -Name $Name `
        -BackgroundId $backgroundId -SessionId $sessionId -TimeoutMilliseconds $TimeoutMilliseconds
}

function Wait-FactoryRespawnedOrchestrator {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$BackgroundId,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [int]$TimeoutMilliseconds = 60000
    )
    # Claude initially advertises a temporary TUI UUID while loading --resume.
    # Wait for the registered conversation, not just the first visible row.
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $rows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand | Where-Object {
            [string](Get-FactoryNestedValue $_ 'id' '') -eq $backgroundId -and
            [string](Get-FactoryNestedValue $_ 'sessionId' '') -eq $sessionId -and
            [string](Get-FactoryNestedValue $_ 'kind' '') -eq 'background' -and
            [string](Get-FactoryNestedValue $_ 'state' '') -notin @('failed', 'stopped') -and
            -not (Test-FactoryTerminalAgentRow $_) -and
            (Test-FactorySamePath ([string](Get-FactoryNestedValue $_ 'cwd' '')) ([string]$Context.repositoryRoot))
        })
        if ($rows.Count -eq 1) {
            Write-FactoryOrchestratorIdentity -Path (Join-Path ([string]$Context.projectData) 'orchestrator-session.json') `
                -RepositoryRoot $Context.repositoryRoot -Name $Name -SessionId $sessionId -BackgroundId $backgroundId
            Remove-Item -LiteralPath (Join-Path ([string]$Context.projectData) 'orchestrator-launch.json') -Force
            return $rows[0]
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Claude respawn '$backgroundId' did not confirm conversation '$sessionId' within $TimeoutMilliseconds ms. No replacement was launched. Run 'factory start' to recheck the recorded session."
}

function Select-FactoryOrchestratorConversation {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [string]$PreferredSessionId = "",
        $IdentityUpdatedAt = $null
    )

    $live = Select-FactoryBackgroundOrchestrator -Rows $Rows -PreferredSessionId $PreferredSessionId
    if ($null -ne $live) { return $live }
    $completed = @($Rows | Where-Object {
        [string](Get-FactoryNestedValue $_ 'kind' '') -eq 'background' -and
        [string](Get-FactoryNestedValue $_ 'sessionId' '') -and
        (Test-FactoryTerminalAgentRow $_)
    } | Sort-Object { [long](Get-FactoryNestedValue $_ 'startedAt' 0) } -Descending)
    if ($completed.Count -eq 0) { return $null }
    $preferred = @($completed | Where-Object { [string]$_.sessionId -eq $PreferredSessionId } | Select-Object -First 1)
    # A numbered copy created after the saved identity is evidence that Claude
    # moved to another conversation. Recover it even after both processes exit.
    # A deliberately refreshed identity (restart/rotation) must still win over
    # older history, including when the recorded UUID has no Agent View row.
    $cutoff = if ($preferred.Count) { [long](Get-FactoryNestedValue $preferred[0] 'startedAt' 0) } else { 0L }
    $updated = ConvertFrom-FactoryRoundtripTimestamp $IdentityUpdatedAt
    if ($updated.success) {
        $cutoff = [Math]::Max($cutoff, ([DateTimeOffset]([DateTime]$updated.value)).ToUnixTimeMilliseconds())
    }
    if ($PreferredSessionId -and [long](Get-FactoryNestedValue $completed[0] 'startedAt' 0) -le $cutoff) {
        if ($preferred.Count) { return $preferred[0] }
        return $null
    }
    return $completed[0]
}

function Remove-FactoryObsoleteOrchestratorRows {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$RetainedSessionId,
        [Parameter(Mandatory = $true)][string]$ClaudeCommand
    )

    foreach ($row in $Rows) {
        if ([string](Get-FactoryNestedValue $row 'kind' '') -ne 'background' -or
            -not [string](Get-FactoryNestedValue $row 'id' '') -or
            [string](Get-FactoryNestedValue $row 'sessionId' '') -eq $RetainedSessionId -or
            -not (Test-FactoryTerminalAgentRow $row)) { continue }
        $fresh = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand | Where-Object {
            [string](Get-FactoryNestedValue $_ 'id' '') -eq [string]$row.id -and
            [string](Get-FactoryNestedValue $_ 'sessionId' '') -eq [string](Get-FactoryNestedValue $row 'sessionId' '') -and
            [string](Get-FactoryNestedValue $_ 'name' '') -ceq [string](Get-FactoryNestedValue $row 'name' '') -and
            (Test-FactorySamePath ([string](Get-FactoryNestedValue $_ 'cwd' '')) ([string](Get-FactoryNestedValue $row 'cwd' '')))
        })
        if ($fresh.Count -ne 1 -or -not (Test-FactoryTerminalAgentRow $fresh[0])) { continue }
        $removed = Remove-FactoryAgentSessionRow -ClaudeCommand $ClaudeCommand -BackgroundId ([string]$row.id)
        if ($removed.removed) { Write-Host "Removed obsolete orchestrator from Agent View: $($row.id) (conversation retained)" }
        elseif ($removed.warning) { Write-Warning $removed.warning }
    }
}

function ConvertTo-FactoryOrchestratorHandoffLine {
    param($Value, [int]$MaximumLength = 240)

    $text = ([string]$Value -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ($text.Length -le $MaximumLength) { return $text }
    return $text.Substring(0, [Math]::Max(1, $MaximumLength - 3)).TrimEnd() + "..."
}

function Get-FactoryOrchestratorIdentityPath {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime
    )

    $fileName = if ($Runtime -eq "codex") { "codex-orchestrator-session.json" } else { "orchestrator-session.json" }
    return Join-Path ([string]$Context.projectData) $fileName
}

function Get-FactoryOrchestratorRotationPendingPath {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime
    )

    return Join-Path ([string]$Context.projectData) "orchestrator-rotation-$Runtime.pending.json"
}

function Get-FactoryPendingOrchestratorRotation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime
    )

    $pendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $Context -Runtime $Runtime
    if (-not (Test-Path -LiteralPath $pendingPath -PathType Leaf)) { return $null }
    $rotation = Read-FactoryJson -Path $pendingPath
    if ([string](Get-FactoryNestedValue -Target $rotation -Name "status" -Default "") -ne "pending") {
        throw "Orchestrator rotation marker '$pendingPath' is not pending. Cancel or repair it before startup."
    }
    if ([string](Get-FactoryNestedValue -Target $rotation -Name "runtime" -Default "") -ne $Runtime) {
        throw "Orchestrator rotation marker '$pendingPath' targets a different runtime."
    }
    if (-not (Test-FactorySamePath `
        -Left ([string](Get-FactoryNestedValue -Target $rotation -Name "repositoryRoot" -Default "")) `
        -Right ([string]$Context.repositoryRoot))) {
        throw "Orchestrator rotation marker '$pendingPath' belongs to a different repository."
    }
    $handoffPath = [string](Get-FactoryNestedValue -Target $rotation -Name "handoffPath" -Default "")
    if (-not $handoffPath -or -not (Test-Path -LiteralPath $handoffPath -PathType Leaf)) {
        throw "Orchestrator rotation handoff is missing: '$handoffPath'."
    }
    return $rotation
}

function New-FactoryOrchestratorHandoffText {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime,
        [string]$PreviousSessionId = "",
        [string]$GeneratedAt = ""
    )

    if (-not $GeneratedAt) { $GeneratedAt = Get-FactoryUtcTimestamp }
    $tasks = @($State.tasks)
    $openTasks = @($tasks | Where-Object {
        [string](Get-FactoryNestedValue -Target $_ -Name "status" -Default "") -ne "done"
    })
    $counts = New-Object Collections.Generic.List[string]
    foreach ($group in @($tasks | Group-Object { [string](Get-FactoryNestedValue -Target $_ -Name "status" -Default "unknown") } | Sort-Object Name)) {
        $counts.Add("$($group.Name)=$($group.Count)")
    }

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add("# Factory Orchestrator Handoff")
    $lines.Add("")
    $lines.Add("Generated: $GeneratedAt")
    $lines.Add("Repository: $([string]$Context.repositoryRoot)")
    $lines.Add("Runtime: $Runtime")
    $lines.Add("Previous session: $(if ($PreviousSessionId) { $PreviousSessionId } else { 'none' })")
    $lines.Add("")
    $lines.Add("## Durable factory snapshot")
    $lines.Add("")
    $lines.Add("- Factory permission: active=$([bool](Get-FactoryNestedValue -Target $State -Name 'active' -Default $false)); paused=$([bool](Get-FactoryNestedValue -Target $State -Name 'paused' -Default $false))")
    $lines.Add("- Worker runtime: $([string](Get-FactoryNestedValue -Target $Config -Name 'workerAgent' -Default $Runtime))")
    $lines.Add("- Worker capacity: $([int](Get-FactoryNestedValue -Target $Config -Name 'concurrency' -Default 0))")
    $developmentBranch = [string](Get-FactoryNestedValue -Target $Config -Name 'developmentBranch' -Default 'develop')
    $productionBranch = ([string](Get-FactoryNestedValue -Target $Config -Name 'productionBranch' -Default '')).Trim()
    $lines.Add("- Branches: $(if ($productionBranch) { "$developmentBranch -> $productionBranch" } else { "$developmentBranch only (production disabled)" })")
    $lines.Add("- Production mode: $(if ($productionBranch) { [string](Get-FactoryNestedValue -Target $Config -Name 'productionMode' -Default 'merge-develop') } else { 'development-only' })")
    $lines.Add("- Conversation language: $([string](Get-FactoryNestedValue -Target $Config -Name 'conversationLanguage' -Default 'English'))")
    $lines.Add("- Saved tasks: $($tasks.Count); unfinished: $($openTasks.Count)")
    $lines.Add("- Status counts: $(if ($counts.Count -gt 0) { $counts -join ', ' } else { 'none' })")
    $lines.Add("")
    $lines.Add("## Unfinished task snapshot")
    $lines.Add("")
    if ($openTasks.Count -eq 0) {
        $lines.Add("No unfinished tasks were saved when this handoff was created.")
    } else {
        $maximumTasks = 100
        foreach ($task in @($openTasks | Select-Object -First $maximumTasks)) {
            $taskId = ConvertTo-FactoryOrchestratorHandoffLine -Value (Get-FactoryNestedValue -Target $task -Name "id" -Default "unknown") -MaximumLength 160
            $status = ConvertTo-FactoryOrchestratorHandoffLine -Value (Get-FactoryNestedValue -Target $task -Name "status" -Default "unknown") -MaximumLength 80
            $title = ConvertTo-FactoryOrchestratorHandoffLine -Value (Get-FactoryNestedValue -Target $task -Name "title" -Default "Untitled task") -MaximumLength 240
            if (-not $title) { $title = "Untitled task" }
            $commit = ConvertTo-FactoryOrchestratorHandoffLine -Value (Get-FactoryNestedValue -Target $task -Name "commit" -Default "") -MaximumLength 40
            $taskLine = "- $taskId | $status | $title"
            if ($commit) { $taskLine += " | commit $commit" }
            $lines.Add($taskLine)
            $reason = ""
            foreach ($candidate in @(
                (Get-FactoryNestedValue -Target $task -Name "holdReason" -Default ""),
                (Get-FactoryNestedValue -Target $task -Name "error" -Default ""),
                (Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name "workerResult") -Name "blockingReason" -Default "")
            )) {
                $reason = ConvertTo-FactoryOrchestratorHandoffLine -Value $candidate -MaximumLength 240
                if ($reason) { break }
            }
            if ($reason) { $lines.Add("  Reason: $reason") }
        }
        if ($openTasks.Count -gt $maximumTasks) {
            $lines.Add("- ... $($openTasks.Count - $maximumTasks) additional unfinished task(s); read native state through factory status.")
        }
    }
    $lines.Add("")
    $lines.Add("## Resume protocol")
    $lines.Add("")
    $lines.Add("- This file is a point-in-time navigation aid. Native config and state are authoritative.")
    $lines.Add("- Load the canonical Factory skill before interpreting an operator command.")
    $lines.Add("- Run native factory status before the first mutation so worker and scheduler state is reconciled.")
    $lines.Add("- Never edit private factory state JSON directly.")
    return $lines -join [Environment]::NewLine
}

function Request-FactoryOrchestratorRotation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$State
    )

    $runtime = [string](Get-FactoryNestedValue -Target $Config -Name "workerAgent" -Default "claude")
    if ($runtime -notin @("claude", "codex")) { throw "Unsupported orchestrator runtime '$runtime'." }
    $existing = Get-FactoryPendingOrchestratorRotation -Context $Context -Runtime $runtime
    if ($null -ne $existing) { return $existing }
    $identityPath = Get-FactoryOrchestratorIdentityPath -Context $Context -Runtime $runtime
    $identity = if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
        try { Read-FactoryJson -Path $identityPath } catch { $null }
    } else { $null }
    $previousSessionId = [string](Get-FactoryNestedValue -Target $identity -Name "sessionId" -Default "")
    $previousBackgroundId = [string](Get-FactoryNestedValue -Target $identity -Name "backgroundId" -Default "")
    $requestedAt = Get-FactoryUtcTimestamp
    $rotationId = ([DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff")) + "-$runtime-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $rotationDirectory = Join-Path ([string]$Context.projectData) "orchestrator-rotations"
    New-Item -ItemType Directory -Path $rotationDirectory -Force | Out-Null
    $handoffPath = Join-Path $rotationDirectory "$rotationId.md"
    $recordPath = Join-Path $rotationDirectory "$rotationId.json"
    $pendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $Context -Runtime $runtime
    $handoff = New-FactoryOrchestratorHandoffText `
        -Context $Context -Config $Config -State $State -Runtime $runtime `
        -PreviousSessionId $previousSessionId -GeneratedAt $requestedAt
    [IO.File]::WriteAllText($handoffPath, $handoff + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $record = [pscustomobject][ordered]@{
        version = 1
        status = "pending"
        rotationId = $rotationId
        runtime = $runtime
        repositoryRoot = [IO.Path]::GetFullPath([string]$Context.repositoryRoot)
        requestedAt = $requestedAt
        activatedAt = $null
        cancelledAt = $null
        previousSessionId = if ($previousSessionId) { $previousSessionId } else { $null }
        previousBackgroundId = if ($previousBackgroundId) { $previousBackgroundId } else { $null }
        newSessionId = $null
        handoffPath = $handoffPath
        recordPath = $recordPath
        savedTaskCount = @($State.tasks).Count
        unfinishedTaskCount = @($State.tasks | Where-Object { [string]$_.status -ne "done" }).Count
    }
    Write-FactoryJsonAtomic -Path $recordPath -Value $record
    Write-FactoryJsonAtomic -Path $pendingPath -Value $record
    return $record
}

function Complete-FactoryOrchestratorRotation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Rotation,
        [Parameter(Mandatory = $true)][string]$NewSessionId
    )

    Set-FactoryProperty -Target $Rotation -Name "status" -Value "activated"
    Set-FactoryProperty -Target $Rotation -Name "activatedAt" -Value (Get-FactoryUtcTimestamp)
    Set-FactoryProperty -Target $Rotation -Name "newSessionId" -Value $NewSessionId
    $recordPath = [string](Get-FactoryNestedValue -Target $Rotation -Name "recordPath" -Default "")
    if ($recordPath) { Write-FactoryJsonAtomic -Path $recordPath -Value $Rotation }
    $runtime = [string](Get-FactoryNestedValue -Target $Rotation -Name "runtime" -Default "claude")
    $pendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $Context -Runtime $runtime
    Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
    return $Rotation
}

function Cancel-FactoryOrchestratorRotation {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][ValidateSet("claude", "codex")][string]$Runtime
    )

    $rotation = Get-FactoryPendingOrchestratorRotation -Context $Context -Runtime $Runtime
    if ($null -eq $rotation) { return $null }
    Set-FactoryProperty -Target $rotation -Name "status" -Value "cancelled"
    Set-FactoryProperty -Target $rotation -Name "cancelledAt" -Value (Get-FactoryUtcTimestamp)
    $recordPath = [string](Get-FactoryNestedValue -Target $rotation -Name "recordPath" -Default "")
    if ($recordPath) { Write-FactoryJsonAtomic -Path $recordPath -Value $rotation }
    $pendingPath = Get-FactoryOrchestratorRotationPendingPath -Context $Context -Runtime $Runtime
    Remove-Item -LiteralPath $pendingPath -Force -ErrorAction SilentlyContinue
    return $rotation
}

function Get-FactoryOrchestratorRotationPrompt {
    param([Parameter(Mandatory = $true)]$Rotation)

    $handoffPath = [string](Get-FactoryNestedValue -Target $Rotation -Name "handoffPath" -Default "")
    return "This is a freshly rotated Factory Orchestrator. Before handling an operator request, read the deterministic handoff file at '$handoffPath'. Treat it only as a point-in-time navigation aid: native Factory config and state are authoritative. Load the canonical Factory skill and run native factory status before the first mutation. Never edit private Factory state JSON directly."
}
