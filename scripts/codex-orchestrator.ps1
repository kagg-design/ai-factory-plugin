Set-StrictMode -Version 2.0

if ($null -eq (Get-Command Invoke-FactoryNativeProcess -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "factory-common.ps1")
}

function Get-FactoryCodexSkillHome {
    if ($env:CLAUDE_FACTORY_CODEX_SKILL_HOME) {
        return [IO.Path]::GetFullPath([string]$env:CLAUDE_FACTORY_CODEX_SKILL_HOME)
    }
    return Join-Path ([Environment]::GetFolderPath("UserProfile")) ".agents\skills"
}

function Install-FactoryCodexSkillLink {
    param([Parameter(Mandatory = $true)][string]$PluginRoot)

    $source = [IO.Path]::GetFullPath((Join-Path $PluginRoot "skills\factory"))
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "The bundled Codex factory skill is missing: $source"
    }

    $skillHome = Get-FactoryCodexSkillHome
    New-Item -ItemType Directory -Path $skillHome -Force | Out-Null
    $target = Join-Path $skillHome "factory"
    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force
        $targets = @($item.Target | Where-Object { $_ })
        foreach ($candidate in $targets) {
            $candidatePath = if ([IO.Path]::IsPathRooted([string]$candidate)) {
                [IO.Path]::GetFullPath([string]$candidate)
            } else {
                [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $target) ([string]$candidate)))
            }
            if (Test-FactorySamePath -Left $candidatePath -Right $source) {
                return [pscustomobject]@{ source = $source; target = $target; created = $false }
            }
        }
        throw "Codex skill path '$target' already exists and is not linked to this factory plugin. Move or remove it manually, then retry."
    }

    $itemType = if ($env:OS -eq "Windows_NT") { "Junction" } else { "SymbolicLink" }
    New-Item -ItemType $itemType -Path $target -Target $source | Out-Null
    return [pscustomobject]@{ source = $source; target = $target; created = $true }
}

function Write-FactoryCodexOrchestratorIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$LegacySessionId = ""
    )

    Write-FactoryJsonAtomic -Path $Path -Value ([ordered]@{
        version = 2
        runtime = "codex"
        backend = "app-server"
        repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
        sessionId = $SessionId
        legacySessionId = if ($LegacySessionId) { $LegacySessionId } else { $null }
        updatedAt = Get-FactoryUtcTimestamp
    })
}

function Get-FactoryCodexThreadId {
    param([Parameter(Mandatory = $true)][string]$Jsonl)

    foreach ($line in @($Jsonl -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ([string]$event.type -eq "thread.started" -and [string]$event.thread_id) {
            return [string]$event.thread_id
        }
    }
    return ""
}

function Write-FactoryCodexAppServerTranscriptLine {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Direction,
        [Parameter(Mandatory = $true)][string]$Line
    )

    if (-not [string]$Client.transcriptPath) { return }
    $record = [ordered]@{
        timestamp = Get-FactoryUtcTimestamp
        direction = $Direction
        payload = $Line
    } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText(
        [string]$Client.transcriptPath,
        $record + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Start-FactoryCodexAppServerClient {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [string]$TranscriptPath = ""
    )

    $resolved = Get-Command $CodexCommand -ErrorAction Stop
    $executable = if ([string]$resolved.Source) { [string]$resolved.Source } else { [string]$resolved.Path }
    if ($TranscriptPath) {
        Remove-Item -LiteralPath $TranscriptPath -Force -ErrorAction SilentlyContinue
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = "app-server --stdio"
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Codex app-server process did not start." }
    return [pscustomobject]@{
        process = $process
        stderrTask = $process.StandardError.ReadToEndAsync()
        transcriptPath = $TranscriptPath
        nextRequestId = 1
        bufferedNotifications = New-Object Collections.Generic.List[object]
    }
}

function Send-FactoryCodexAppServerRequest {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)]$Params
    )

    $requestId = [int]$Client.nextRequestId
    $Client.nextRequestId = $requestId + 1
    $line = [ordered]@{ method = $Method; id = $requestId; params = $Params } |
        ConvertTo-Json -Depth 30 -Compress
    Write-FactoryCodexAppServerTranscriptLine -Client $Client -Direction "request" -Line $line
    $Client.process.StandardInput.WriteLine($line)
    $Client.process.StandardInput.Flush()
    return $requestId
}

function Send-FactoryCodexAppServerNotification {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Method
    )

    $line = [ordered]@{ method = $Method } | ConvertTo-Json -Compress
    Write-FactoryCodexAppServerTranscriptLine -Client $Client -Direction "notification" -Line $line
    $Client.process.StandardInput.WriteLine($line)
    $Client.process.StandardInput.Flush()
}

function Read-FactoryCodexAppServerMessage {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][DateTime]$Deadline
    )

    $remaining = [int][Math]::Max(1, [Math]::Ceiling(($Deadline - [DateTime]::UtcNow).TotalMilliseconds))
    if ($remaining -le 1 -and [DateTime]::UtcNow -ge $Deadline) {
        throw "Timed out waiting for Codex app-server."
    }
    $readTask = $Client.process.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait($remaining)) {
        throw "Timed out waiting for Codex app-server."
    }
    $line = $readTask.Result
    if ($null -eq $line) {
        $stderr = if ($Client.stderrTask.IsCompleted) { [string]$Client.stderrTask.Result } else { "" }
        throw "Codex app-server closed its output unexpectedly. $($stderr.Trim())".Trim()
    }
    Write-FactoryCodexAppServerTranscriptLine -Client $Client -Direction "response" -Line $line
    try { return $line | ConvertFrom-Json } catch {
        throw "Codex app-server returned malformed JSON: $line"
    }
}

function Receive-FactoryCodexAppServerResponse {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][int]$RequestId,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $message = Read-FactoryCodexAppServerMessage -Client $Client -Deadline $deadline
        $method = if ($null -ne $message.PSObject.Properties["method"]) { [string]$message.method } else { "" }
        $messageId = if ($null -ne $message.PSObject.Properties["id"]) { [string]$message.id } else { "" }
        if ($method -and $messageId) {
            throw "Codex app-server requested unsupported bootstrap operation '$method'."
        }
        if ($method) {
            $Client.bufferedNotifications.Add($message)
            continue
        }
        if ($messageId -ne [string]$RequestId) { continue }
        if ($null -ne $message.PSObject.Properties["error"] -and $null -ne $message.error) {
            $detail = if ($null -ne $message.error.PSObject.Properties["message"]) { [string]$message.error.message } else { $message.error | ConvertTo-Json -Compress }
            throw "Codex app-server request $RequestId failed: $detail"
        }
        if ($null -eq $message.PSObject.Properties["result"]) {
            throw "Codex app-server response $RequestId contained no result."
        }
        return $message.result
    }
    throw "Timed out waiting for Codex app-server response $RequestId."
}

function Initialize-FactoryCodexAppServerClient {
    param([Parameter(Mandatory = $true)]$Client)

    $requestId = Send-FactoryCodexAppServerRequest -Client $Client -Method "initialize" -Params ([ordered]@{
        clientInfo = [ordered]@{ name = "claude-factory-plugin"; title = "Claude Factory Plugin"; version = "3.1.0" }
        capabilities = [ordered]@{ experimentalApi = $true }
    })
    $null = Receive-FactoryCodexAppServerResponse -Client $Client -RequestId $requestId
    Send-FactoryCodexAppServerNotification -Client $Client -Method "initialized"
}

function Stop-FactoryCodexAppServerClient {
    param([AllowNull()]$Client)

    if ($null -eq $Client) { return }
    try { $Client.process.StandardInput.Close() } catch {}
    try {
        if (-not $Client.process.WaitForExit(3000)) {
            $Client.process.Kill()
            $Client.process.WaitForExit(3000)
        }
    } catch {}
    try { $Client.process.Dispose() } catch {}
}

function Get-FactoryCodexAppProjectId {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $cursor = $null
    for ($page = 0; $page -lt 20; $page++) {
        $params = [ordered]@{ limit = 100 }
        if ($cursor) { $params.cursor = $cursor }
        $requestId = Send-FactoryCodexAppServerRequest -Client $Client -Method "project/list" -Params $params
        $result = Receive-FactoryCodexAppServerResponse -Client $Client -RequestId $requestId
        foreach ($project in @($result.data)) {
            foreach ($root in @($project.roots)) {
                if ([string]$root.path -and (Test-FactorySamePath -Left ([string]$root.path) -Right $RepositoryRoot)) {
                    return [string]$project.id
                }
            }
        }
        $cursor = if ($null -ne $result.PSObject.Properties["nextCursor"]) { [string]$result.nextCursor } else { "" }
        if (-not $cursor) { break }
    }
    return ""
}

function Wait-FactoryCodexAppServerTurn {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId,
        [int]$TimeoutSeconds = 120
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $message = if ($Client.bufferedNotifications.Count -gt 0) {
            $buffered = $Client.bufferedNotifications[0]
            $Client.bufferedNotifications.RemoveAt(0)
            $buffered
        } else {
            Read-FactoryCodexAppServerMessage -Client $Client -Deadline $deadline
        }
        $method = if ($null -ne $message.PSObject.Properties["method"]) { [string]$message.method } else { "" }
        $messageId = if ($null -ne $message.PSObject.Properties["id"]) { [string]$message.id } else { "" }
        if ($method -and $messageId) {
            throw "Codex app-server requested unsupported bootstrap operation '$method'."
        }
        if ($method -ne "turn/completed") { continue }
        $eventThreadId = [string](Get-FactoryNestedValue -Target $message.params -Name "threadId" -Default "")
        $eventTurn = Get-FactoryNestedValue -Target $message.params -Name "turn"
        $eventTurnId = [string](Get-FactoryNestedValue -Target $eventTurn -Name "id" -Default "")
        if ($eventThreadId -ne $ThreadId -or $eventTurnId -ne $TurnId) { continue }
        $status = [string](Get-FactoryNestedValue -Target $eventTurn -Name "status" -Default "")
        if ($status -ne "completed") {
            $error = Get-FactoryNestedValue -Target $eventTurn -Name "error"
            $detail = [string](Get-FactoryNestedValue -Target $error -Name "message" -Default $status)
            throw "Codex app-server bootstrap turn ended as '$status': $detail"
        }
        return $eventTurn
    }
    throw "Timed out waiting for Codex app-server bootstrap turn '$TurnId'."
}

function Test-FactoryCodexAppThread {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [hashtable]$Environment = @{},
        [string]$TranscriptPath = ""
    )

    $client = $null
    try {
        $client = Start-FactoryCodexAppServerClient -CodexCommand $CodexCommand -WorkingDirectory $RepositoryRoot -Environment $Environment -TranscriptPath $TranscriptPath
        Initialize-FactoryCodexAppServerClient -Client $client
        $requestId = Send-FactoryCodexAppServerRequest -Client $client -Method "thread/read" -Params ([ordered]@{
            threadId = $ThreadId
            includeTurns = $false
        })
        $result = Receive-FactoryCodexAppServerResponse -Client $client -RequestId $requestId
        return [bool]([string](Get-FactoryNestedValue -Target $result.thread -Name "id" -Default "") -eq $ThreadId)
    } finally {
        Stop-FactoryCodexAppServerClient -Client $client
    }
}

function New-FactoryCodexAppThread {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Model = "",
        [hashtable]$Environment = @{},
        [string]$TranscriptPath = ""
    )

    $client = $null
    $threadId = ""
    try {
        $repositoryRoot = [IO.Path]::GetFullPath([string]$Context.repositoryRoot)
        $runtimeHome = [IO.Path]::GetFullPath([string]$Context.runtimeHome)
        $worktreeRoot = [IO.Path]::GetFullPath([string]$Context.worktreeRoot)
        $client = Start-FactoryCodexAppServerClient -CodexCommand $CodexCommand -WorkingDirectory $repositoryRoot -Environment $Environment -TranscriptPath $TranscriptPath
        Initialize-FactoryCodexAppServerClient -Client $client
        $projectId = Get-FactoryCodexAppProjectId -Client $client -RepositoryRoot $repositoryRoot
        $developerInstructions = @"
You are the Factory Orchestrator for '$repositoryRoot'. On every operator request, load the factory skill explicitly with `$factory before acting and follow its canonical protocol. Coordinate native factory state and isolated workers; never implement application changes directly in the main repository. The Factory plugin root is '$([IO.Path]::GetFullPath($PluginRoot))', its private runtime home is '$runtimeHome', and its worktree root is '$worktreeRoot'. Phone-hosted turns may not inherit the terminal environment; if the `factory` launcher is unavailable, invoke '$([IO.Path]::GetFullPath((Join-Path $PluginRoot 'factory.ps1')))' with `-Repository '$repositoryRoot'`. Accept natural commands such as 'factory status', 'factory new', 'review <task-id>', 'go <task-id>', and 'reject <task-id>' without requiring a slash or dollar prefix.
"@.Trim()
        $threadParams = [ordered]@{
            cwd = $repositoryRoot
            ephemeral = $false
            historyMode = "paginated"
            threadSource = "vscode"
            sandbox = "workspace-write"
            approvalsReviewer = "auto_review"
            runtimeWorkspaceRoots = @($repositoryRoot, $runtimeHome, $worktreeRoot)
            developerInstructions = $developerInstructions
        }
        if ($projectId) { $threadParams.projectId = $projectId }
        if ($Model) { $threadParams.model = $Model }
        $threadRequestId = Send-FactoryCodexAppServerRequest -Client $client -Method "thread/start" -Params $threadParams
        $threadResult = Receive-FactoryCodexAppServerResponse -Client $client -RequestId $threadRequestId
        $threadId = [string](Get-FactoryNestedValue -Target $threadResult.thread -Name "id" -Default "")
        if (-not $threadId) { throw "Codex app-server created no persisted thread ID." }

        $turnRequestId = Send-FactoryCodexAppServerRequest -Client $client -Method "turn/start" -Params ([ordered]@{
            threadId = $threadId
            cwd = $repositoryRoot
            input = @([ordered]@{ type = "text"; text = $Prompt })
        })
        $turnResult = Receive-FactoryCodexAppServerResponse -Client $client -RequestId $turnRequestId
        $turnId = [string](Get-FactoryNestedValue -Target $turnResult.turn -Name "id" -Default "")
        if (-not $turnId) { throw "Codex app-server created no bootstrap turn ID." }
        $null = Wait-FactoryCodexAppServerTurn -Client $client -ThreadId $threadId -TurnId $turnId

        $repositoryName = Split-Path -Leaf $repositoryRoot
        $title = "Factory Orchestrator - $repositoryName"
        $nameRequestId = Send-FactoryCodexAppServerRequest -Client $client -Method "thread/name/set" -Params ([ordered]@{
            threadId = $threadId
            name = $title
        })
        $null = Receive-FactoryCodexAppServerResponse -Client $client -RequestId $nameRequestId
        return [pscustomobject]@{ threadId = $threadId; title = $title; projectId = $projectId; backend = "app-server" }
    } catch {
        $failure = $_
        if ($null -ne $client -and $threadId) {
            try {
                $archiveRequestId = Send-FactoryCodexAppServerRequest -Client $client -Method "thread/archive" -Params ([ordered]@{
                    threadId = $threadId
                })
                $null = Receive-FactoryCodexAppServerResponse -Client $client -RequestId $archiveRequestId -TimeoutSeconds 10
            } catch {}
        }
        throw $failure
    } finally {
        Stop-FactoryCodexAppServerClient -Client $client
    }
}

function Get-FactoryCodexOrchestratorArguments {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeHome,
        [Parameter(Mandatory = $true)][string]$WorktreeRoot,
        [string]$Model = ""
    )

    $arguments = @(
        "-C", [IO.Path]::GetFullPath($RepositoryRoot),
        "--approve-for-me",
        "--add-dir", [IO.Path]::GetFullPath($RuntimeHome),
        "--add-dir", [IO.Path]::GetFullPath($WorktreeRoot)
    )
    if ($Model) { $arguments += @("--model", $Model) }
    return $arguments
}

function Start-FactoryCodexOrchestrator {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [Parameter(Mandatory = $true)]$Context,
        [switch]$New,
        [switch]$Resume,
        [switch]$Continue,
        [string]$Model = "",
        $Rotation = $null,
        [Parameter(Mandatory = $true)][string]$ExitCodeVariableName
    )

    $skillLink = Install-FactoryCodexSkillLink -PluginRoot $PluginRoot
    if ([bool]$skillLink.created) {
        Write-Host "Codex skill linked: $($skillLink.target)" -ForegroundColor Green
    }

    $identityPath = Join-Path ([string]$Context.projectData) "codex-orchestrator-session.json"
    $identity = if (Test-Path -LiteralPath $identityPath) {
        try { Read-FactoryJson -Path $identityPath } catch { $null }
    } else { $null }
    $startNewConversation = [bool]($New -or $null -ne $Rotation)
    $identityMatchesRepository = [bool](
        $null -ne $identity -and [string](Get-FactoryNestedValue -Target $identity -Name "repositoryRoot" -Default "") -and
        (Test-FactorySamePath `
            -Left ([string](Get-FactoryNestedValue -Target $identity -Name "repositoryRoot" -Default "")) `
            -Right ([string]$Context.repositoryRoot))
    )
    $identityBackend = if ($identityMatchesRepository) {
        [string](Get-FactoryNestedValue -Target $identity -Name "backend" -Default "standalone-cli")
    } else { "" }
    $storedSessionId = if (
        -not $startNewConversation -and $identityMatchesRepository -and
        $identityBackend -eq "app-server" -and
        [string](Get-FactoryNestedValue -Target $identity -Name "sessionId" -Default "")
    ) { [string]$identity.sessionId } else { "" }
    $legacySessionId = if ($identityMatchesRepository -and $identityBackend -ne "app-server") {
        [string](Get-FactoryNestedValue -Target $identity -Name "sessionId" -Default "")
    } else {
        [string](Get-FactoryNestedValue -Target $identity -Name "legacySessionId" -Default "")
    }

    if (($Resume -or $Continue) -and -not $storedSessionId -and -not $legacySessionId) {
        throw "No stored Codex factory orchestrator exists for this repository. Run 'factory start -Agent codex' to create it."
    }

    $environment = @{
        CLAUDE_FACTORY_HOME = [string]$Context.runtimeHome
        CLAUDE_FACTORY_PLUGIN_ROOT = [IO.Path]::GetFullPath($PluginRoot)
        CLAUDE_FACTORY_REPOSITORY = [string]$Context.repositoryRoot
    }
    $sharedArguments = @(Get-FactoryCodexOrchestratorArguments `
        -RepositoryRoot ([string]$Context.repositoryRoot) `
        -RuntimeHome ([string]$Context.runtimeHome) `
        -WorktreeRoot ([string]$Context.worktreeRoot) `
        -Model $Model)

    $appServerTranscriptPath = Join-Path ([string]$Context.projectData) "codex-orchestrator-app-server.jsonl"
    if ($storedSessionId) {
        Write-Host "Validating app-backed Codex factory conversation: $storedSessionId" -ForegroundColor Green
        $available = Test-FactoryCodexAppThread `
            -CodexCommand $CodexCommand `
            -RepositoryRoot ([string]$Context.repositoryRoot) `
            -ThreadId $storedSessionId `
            -Environment $environment `
            -TranscriptPath $appServerTranscriptPath
        if (-not $available) {
            throw "Stored app-backed Codex orchestrator '$storedSessionId' is unavailable. Run 'factory start -Agent codex -New' to create a replacement."
        }
    }

    if (-not $storedSessionId) {
        $rotationPrompt = if ($null -ne $Rotation) {
            " " + (Get-FactoryOrchestratorRotationPrompt -Rotation $Rotation)
        } else { "" }
        $prompt = @"
You are the Factory Orchestrator for this repository. This bootstrap turn only establishes a resumable conversation. Do not load a skill, read a file, run a command, call a tool, or change any state during this turn. Reply exactly: Factory Orchestrator is ready. On the first later operator request, load the factory skill explicitly with `$factory before acting; its canonical protocol is authoritative. You coordinate native factory state and isolated workers and never implement application changes directly in the main repository. Accept natural commands such as "factory status", "factory new", "review <task-id>", "go <task-id>", and "reject <task-id>" without requiring a slash or a dollar prefix.
"@.Trim()
        $prompt += $rotationPrompt
        if ($legacySessionId) {
            Write-Host "Replacing standalone Codex conversation with an app-backed conversation: $legacySessionId" -ForegroundColor Yellow
        }
        Write-Host "Creating app-backed Codex factory conversation..." -ForegroundColor Green
        $created = New-FactoryCodexAppThread `
            -CodexCommand $CodexCommand `
            -PluginRoot $PluginRoot `
            -Context $Context `
            -Prompt $prompt `
            -Model $Model `
            -Environment $environment `
            -TranscriptPath $appServerTranscriptPath
        $storedSessionId = [string]$created.threadId
        Write-FactoryCodexOrchestratorIdentity `
            -Path $identityPath `
            -RepositoryRoot ([string]$Context.repositoryRoot) `
            -SessionId $storedSessionId `
            -LegacySessionId $legacySessionId
        Write-Host "Codex app task: $([string]$created.title) ($storedSessionId)" -ForegroundColor Green
        if ($null -ne $Rotation) {
            $null = Complete-FactoryOrchestratorRotation -Context $Context -Rotation $Rotation -NewSessionId $storedSessionId
        }
    } else {
        Write-Host "Resuming Codex factory conversation: $storedSessionId" -ForegroundColor Green
    }

    $resumeArguments = @("resume") + $sharedArguments + @($storedSessionId)
    $previous = @{}
    try {
        foreach ($entry in $environment.GetEnumerator()) {
            $name = [string]$entry.Key
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, "Process")
        }
        Set-Location ([string]$Context.repositoryRoot)
        & $CodexCommand @resumeArguments
        Set-Variable -Scope 1 -Name $ExitCodeVariableName -Value ([int]$LASTEXITCODE)
    } finally {
        foreach ($entry in $previous.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
        }
    }
}
