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
        version = 3
        runtime = "codex"
        backend = "shared-app-server"
        repositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
        sessionId = $SessionId
        legacySessionId = if ($LegacySessionId) { $LegacySessionId } else { $null }
        updatedAt = Get-FactoryUtcTimestamp
    })
}

function Send-FactoryCodexWebSocketText {
    param(
        [Parameter(Mandatory = $true)]$Socket,
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$TimeoutMilliseconds = 30000
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$bytes)
    $cancellation = New-Object Threading.CancellationTokenSource
    try {
        $cancellation.CancelAfter([Math]::Max(1, $TimeoutMilliseconds))
        $null = $Socket.SendAsync(
            $segment,
            [Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            $cancellation.Token
        ).GetAwaiter().GetResult()
    } catch {
        throw "Failed to write to the shared Codex app-server: $($_.Exception.Message)"
    } finally {
        $cancellation.Dispose()
    }
}

function Receive-FactoryCodexWebSocketText {
    param(
        [Parameter(Mandatory = $true)]$Socket,
        [Parameter(Mandatory = $true)][DateTime]$Deadline
    )

    $stream = New-Object IO.MemoryStream
    try {
        do {
            $remaining = [int][Math]::Max(1, [Math]::Ceiling(($Deadline - [DateTime]::UtcNow).TotalMilliseconds))
            if ($remaining -le 1 -and [DateTime]::UtcNow -ge $Deadline) {
                throw "Timed out waiting for the shared Codex app-server."
            }
            $buffer = New-Object byte[] 16384
            $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buffer)
            $cancellation = New-Object Threading.CancellationTokenSource
            try {
                $cancellation.CancelAfter($remaining)
                $result = $Socket.ReceiveAsync($segment, $cancellation.Token).GetAwaiter().GetResult()
            } catch {
                throw "Timed out waiting for the shared Codex app-server: $($_.Exception.Message)"
            } finally {
                $cancellation.Dispose()
            }
            if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                throw "The shared Codex app-server closed its WebSocket unexpectedly."
            }
            if ($result.Count -gt 0) { $stream.Write($buffer, 0, $result.Count) }
        } while (-not $result.EndOfMessage)
        return [Text.Encoding]::UTF8.GetString($stream.ToArray())
    } finally {
        $stream.Dispose()
    }
}

function Connect-FactoryCodexAppServerWebSocket {
    param(
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [int]$TimeoutMilliseconds = 10000
    )

    $socket = New-Object Net.WebSockets.ClientWebSocket
    $cancellation = New-Object Threading.CancellationTokenSource
    try {
        $cancellation.CancelAfter([Math]::Max(1, $TimeoutMilliseconds))
        $null = $socket.ConnectAsync([Uri]$Endpoint, $cancellation.Token).GetAwaiter().GetResult()
        return $socket
    } catch {
        try { $socket.Dispose() } catch {}
        throw "Could not connect to shared Codex app-server '$Endpoint': $($_.Exception.Message)"
    } finally {
        $cancellation.Dispose()
    }
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
        [string]$TranscriptPath = "",
        [string]$Endpoint = ""
    )

    if ($Endpoint) {
        return [pscustomobject]@{
            transport = "websocket"
            socket = Connect-FactoryCodexAppServerWebSocket -Endpoint $Endpoint
            process = $null
            stderrTask = $null
            transcriptPath = $TranscriptPath
            nextRequestId = 1
            bufferedNotifications = New-Object Collections.Generic.List[object]
        }
    }

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
        transport = "stdio"
        socket = $null
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
    if ([string]$Client.transport -eq "websocket") {
        Send-FactoryCodexWebSocketText -Socket $Client.socket -Text $line
    } else {
        $Client.process.StandardInput.WriteLine($line)
        $Client.process.StandardInput.Flush()
    }
    return $requestId
}

function Send-FactoryCodexAppServerNotification {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Method
    )

    $line = [ordered]@{ method = $Method } | ConvertTo-Json -Compress
    Write-FactoryCodexAppServerTranscriptLine -Client $Client -Direction "notification" -Line $line
    if ([string]$Client.transport -eq "websocket") {
        Send-FactoryCodexWebSocketText -Socket $Client.socket -Text $line
    } else {
        $Client.process.StandardInput.WriteLine($line)
        $Client.process.StandardInput.Flush()
    }
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
    if ([string]$Client.transport -eq "websocket") {
        $line = Receive-FactoryCodexWebSocketText -Socket $Client.socket -Deadline $Deadline
    } else {
        $readTask = $Client.process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) {
            throw "Timed out waiting for Codex app-server."
        }
        $line = $readTask.Result
        if ($null -eq $line) {
            $stderr = if ($Client.stderrTask.IsCompleted) { [string]$Client.stderrTask.Result } else { "" }
            throw "Codex app-server closed its output unexpectedly. $($stderr.Trim())".Trim()
        }
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
    if ([string]$Client.transport -eq "websocket") {
        # This object is a short-lived JSON-RPC client, not the shared server.
        # Abort avoids waiting for a peer close frame and leaves the server alive.
        try { $Client.socket.Abort() } catch {}
        try { $Client.socket.Dispose() } catch {}
        return
    }
    try { $Client.process.StandardInput.Close() } catch {}
    try {
        if (-not $Client.process.WaitForExit(3000)) {
            $Client.process.Kill()
            $Client.process.WaitForExit(3000)
        }
    } catch {}
    try { $Client.process.Dispose() } catch {}
}

function Get-FactoryCodexSharedServerPaths {
    param([Parameter(Mandatory = $true)][string]$RuntimeHome)

    $directory = Join-Path ([IO.Path]::GetFullPath($RuntimeHome)) "codex-app-server"
    return [pscustomobject]@{
        directory = $directory
        record = Join-Path $directory "server.json"
        stdout = Join-Path $directory "server.stdout.log"
        stderr = Join-Path $directory "server.stderr.log"
    }
}

function Get-FactoryCodexSharedServerMutexName {
    param([Parameter(Mandatory = $true)][string]$RuntimeHome)

    $normalized = ([IO.Path]::GetFullPath($RuntimeHome)).TrimEnd([IO.Path]::DirectorySeparatorChar).ToLowerInvariant()
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized)))).Replace("-", "").ToLowerInvariant().Substring(0, 16)
    } finally {
        $algorithm.Dispose()
    }
    return "Local\ClaudeFactoryCodexAppServer-$hash"
}

function Get-FactoryAvailableLoopbackPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Test-FactoryCodexSharedServerEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$RuntimeHome,
        [Parameter(Mandatory = $true)][string]$Endpoint
    )

    $client = $null
    try {
        $client = Start-FactoryCodexAppServerClient `
            -CodexCommand $CodexCommand `
            -WorkingDirectory $RuntimeHome `
            -Endpoint $Endpoint
        Initialize-FactoryCodexAppServerClient -Client $client
        return $true
    } catch {
        return $false
    } finally {
        Stop-FactoryCodexAppServerClient -Client $client
    }
}

function Get-FactoryCodexSharedServerStatus {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$RuntimeHome,
        [switch]$Probe
    )

    $paths = Get-FactoryCodexSharedServerPaths -RuntimeHome $RuntimeHome
    $record = if (Test-Path -LiteralPath $paths.record -PathType Leaf) {
        try { Read-FactoryJson -Path $paths.record } catch { $null }
    } else { $null }
    $alive = Test-FactoryRecordedProcess -ProcessRecord $record
    $endpoint = if ($null -ne $record) { [string](Get-FactoryNestedValue -Target $record -Name "endpoint" -Default "") } else { "" }
    $healthy = if ($Probe -and $alive -and $endpoint) {
        Test-FactoryCodexSharedServerEndpoint -CodexCommand $CodexCommand -RuntimeHome $RuntimeHome -Endpoint $endpoint
    } else { $alive }
    return [pscustomobject]@{
        exists = $null -ne $record
        alive = $alive
        healthy = $healthy
        endpoint = $endpoint
        pid = if ($null -ne $record) { [int](Get-FactoryNestedValue -Target $record -Name "pid" -Default 0) } else { 0 }
        processStartTimeUtc = if ($null -ne $record) { [string](Get-FactoryNestedValue -Target $record -Name "processStartTimeUtc" -Default "") } else { "" }
        codexCommand = if ($null -ne $record) { [string](Get-FactoryNestedValue -Target $record -Name "codexCommand" -Default "") } else { "" }
        recordPath = $paths.record
        stdoutPath = $paths.stdout
        stderrPath = $paths.stderr
    }
}

function Start-FactoryCodexSharedServer {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$RuntimeHome
    )

    $runtimeRoot = [IO.Path]::GetFullPath($RuntimeHome)
    $mutex = New-Object Threading.Mutex($false, (Get-FactoryCodexSharedServerMutexName -RuntimeHome $runtimeRoot))
    $ownsMutex = $false
    try {
        try { $ownsMutex = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw "Timed out waiting to manage the shared Codex app-server." }

        $current = Get-FactoryCodexSharedServerStatus -CodexCommand $CodexCommand -RuntimeHome $runtimeRoot -Probe
        if ([bool]$current.alive) {
            if (-not [bool]$current.healthy) {
                throw "The recorded shared Codex app-server PID $($current.pid) is alive but not responding at '$($current.endpoint)'. Run 'factory codex-server restart' explicitly."
            }
            $desiredCommand = Get-Command $CodexCommand -ErrorAction Stop
            $desiredExecutable = if ([string]$desiredCommand.Source) { [string]$desiredCommand.Source } else { [string]$desiredCommand.Path }
            if ([string]$current.codexCommand -and -not (Test-FactorySamePath -Left ([string]$current.codexCommand) -Right $desiredExecutable)) {
                throw "The shared Codex app-server is running from '$([string]$current.codexCommand)', but Factory resolved '$desiredExecutable'. Run 'factory codex-server restart' explicitly so other attached projects are not disconnected silently."
            }
            return [pscustomobject]@{
                created = $false; endpoint = [string]$current.endpoint; pid = [int]$current.pid
                processStartTimeUtc = [string]$current.processStartTimeUtc; recordPath = [string]$current.recordPath
            }
        }

        $paths = Get-FactoryCodexSharedServerPaths -RuntimeHome $runtimeRoot
        New-Item -ItemType Directory -Path $paths.directory -Force | Out-Null
        $endpoint = "ws://127.0.0.1:$(Get-FactoryAvailableLoopbackPort)"
        $resolved = Get-Command $CodexCommand -ErrorAction Stop
        $executable = if ([string]$resolved.Source) { [string]$resolved.Source } else { [string]$resolved.Path }
        $startParams = @{
            FilePath = $executable
            ArgumentList = @("app-server", "--listen", $endpoint)
            WorkingDirectory = $paths.directory
            RedirectStandardOutput = $paths.stdout
            RedirectStandardError = $paths.stderr
            PassThru = $true
        }
        if ($env:OS -eq "Windows_NT") { $startParams.WindowStyle = "Hidden" }
        $previousRuntimeHome = [Environment]::GetEnvironmentVariable("CLAUDE_FACTORY_HOME", "Process")
        try {
            # Tool processes for phone-hosted turns inherit from app-server, not
            # from the terminal client that attached later.
            [Environment]::SetEnvironmentVariable("CLAUDE_FACTORY_HOME", $runtimeRoot, "Process")
            $process = Start-Process @startParams
        } finally {
            [Environment]::SetEnvironmentVariable("CLAUDE_FACTORY_HOME", $previousRuntimeHome, "Process")
        }
        $record = [ordered]@{
            version = 1
            endpoint = $endpoint
            pid = [int]$process.Id
            processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString("o", [Globalization.CultureInfo]::InvariantCulture)
            codexCommand = [IO.Path]::GetFullPath($executable)
            startedAt = Get-FactoryUtcTimestamp
        }
        Write-FactoryJsonAtomic -Path $paths.record -Value $record

        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        do {
            if ($process.HasExited) {
                $detail = if (Test-Path -LiteralPath $paths.stderr) { ([IO.File]::ReadAllText($paths.stderr)).Trim() } else { "" }
                throw "The shared Codex app-server exited during startup. $detail".Trim()
            }
            if (Test-FactoryCodexSharedServerEndpoint -CodexCommand $CodexCommand -RuntimeHome $runtimeRoot -Endpoint $endpoint) {
                return [pscustomobject]@{
                    created = $true; endpoint = $endpoint; pid = [int]$process.Id
                    processStartTimeUtc = [string]$record.processStartTimeUtc; recordPath = $paths.record
                }
            }
            Start-Sleep -Milliseconds 150
        } while ([DateTime]::UtcNow -lt $deadline)
        try { $process.Kill() } catch {}
        throw "The shared Codex app-server did not become ready at '$endpoint'. See '$($paths.stderr)'."
    } finally {
        if ($ownsMutex) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Stop-FactoryCodexSharedServer {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$RuntimeHome
    )

    $mutex = New-Object Threading.Mutex($false, (Get-FactoryCodexSharedServerMutexName -RuntimeHome $RuntimeHome))
    $ownsMutex = $false
    try {
        try { $ownsMutex = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw "Timed out waiting to manage the shared Codex app-server." }
        $status = Get-FactoryCodexSharedServerStatus -CodexCommand $CodexCommand -RuntimeHome $RuntimeHome
        if (-not [bool]$status.alive) {
            return [pscustomobject]@{ stopped = $false; alreadyStopped = $true; pid = [int]$status.pid }
        }
        $process = Get-Process -Id ([int]$status.pid) -ErrorAction Stop
        $actualStart = $process.StartTime.ToUniversalTime()
        $expectedStart = [DateTime]::Parse([string]$status.processStartTimeUtc).ToUniversalTime()
        if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -ge 1) {
            throw "Refusing to stop PID $($status.pid) because its process identity no longer matches the shared Codex app-server."
        }
        $process.Kill()
        if (-not $process.WaitForExit(5000)) {
            throw "Shared Codex app-server PID $($status.pid) is still live after stop."
        }
        return [pscustomobject]@{ stopped = $true; alreadyStopped = $false; pid = [int]$status.pid }
    } finally {
        if ($ownsMutex) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

function Enable-FactoryCodexSharedRemoteControl {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$RuntimeHome,
        [Parameter(Mandatory = $true)][string]$Endpoint
    )

    $client = $null
    try {
        $client = Start-FactoryCodexAppServerClient -CodexCommand $CodexCommand -WorkingDirectory $RuntimeHome -Endpoint $Endpoint
        Initialize-FactoryCodexAppServerClient -Client $client
        $requestId = Send-FactoryCodexAppServerRequest -Client $client -Method "remoteControl/enable" -Params ([ordered]@{ ephemeral = $false })
        $result = Receive-FactoryCodexAppServerResponse -Client $client -RequestId $requestId
        return [pscustomobject]@{
            status = [string](Get-FactoryNestedValue -Target $result -Name "status" -Default "unknown")
            serverName = [string](Get-FactoryNestedValue -Target $result -Name "serverName" -Default "")
            installationId = [string](Get-FactoryNestedValue -Target $result -Name "installationId" -Default "")
        }
    } finally {
        Stop-FactoryCodexAppServerClient -Client $client
    }
}

function Get-FactoryCodexSharedRemoteControlStatus {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$RuntimeHome,
        [Parameter(Mandatory = $true)][string]$Endpoint
    )

    $client = $null
    try {
        $client = Start-FactoryCodexAppServerClient -CodexCommand $CodexCommand -WorkingDirectory $RuntimeHome -Endpoint $Endpoint
        Initialize-FactoryCodexAppServerClient -Client $client
        $requestId = Send-FactoryCodexAppServerRequest -Client $client -Method "remoteControl/status/read" -Params ([ordered]@{})
        $result = Receive-FactoryCodexAppServerResponse -Client $client -RequestId $requestId
        return [pscustomobject]@{
            status = [string](Get-FactoryNestedValue -Target $result -Name "status" -Default "unknown")
            serverName = [string](Get-FactoryNestedValue -Target $result -Name "serverName" -Default "")
        }
    } finally {
        Stop-FactoryCodexAppServerClient -Client $client
    }
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
        [string]$TranscriptPath = "",
        [string]$Endpoint = ""
    )

    $client = $null
    try {
        $client = Start-FactoryCodexAppServerClient -CodexCommand $CodexCommand -WorkingDirectory $RepositoryRoot -Environment $Environment -TranscriptPath $TranscriptPath -Endpoint $Endpoint
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

function Start-FactoryCodexContinuationTurn {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$RuntimeHome,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    $client = $null
    try {
        $client = Start-FactoryCodexAppServerClient `
            -CodexCommand $CodexCommand `
            -WorkingDirectory $RuntimeHome `
            -Endpoint $Endpoint
        Initialize-FactoryCodexAppServerClient -Client $client
        $readRequestId = Send-FactoryCodexAppServerRequest -Client $client -Method "thread/read" -Params ([ordered]@{
            threadId = $ThreadId
            includeTurns = $false
        })
        $readResult = Receive-FactoryCodexAppServerResponse -Client $client -RequestId $readRequestId -TimeoutSeconds 10
        if ([string](Get-FactoryNestedValue -Target $readResult.thread -Name "id" -Default "") -ne $ThreadId) {
            throw "Saved Codex orchestrator thread '$ThreadId' is unavailable."
        }
        $turnRequestId = Send-FactoryCodexAppServerRequest -Client $client -Method "turn/start" -Params ([ordered]@{
            threadId = $ThreadId
            cwd = [IO.Path]::GetFullPath($RepositoryRoot)
            input = @([ordered]@{ type = "text"; text = $Prompt })
        })
        $turnResult = Receive-FactoryCodexAppServerResponse -Client $client -RequestId $turnRequestId -TimeoutSeconds 10
        $turnId = [string](Get-FactoryNestedValue -Target $turnResult.turn -Name "id" -Default "")
        if (-not $turnId) { throw "Codex app-server accepted no continuation turn for '$ThreadId'." }
        return [pscustomobject]@{ threadId = $ThreadId; turnId = $turnId }
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
        [string]$TranscriptPath = "",
        [string]$Endpoint = ""
    )

    $client = $null
    $threadId = ""
    try {
        $repositoryRoot = [IO.Path]::GetFullPath([string]$Context.repositoryRoot)
        $runtimeHome = [IO.Path]::GetFullPath([string]$Context.runtimeHome)
        $worktreeRoot = [IO.Path]::GetFullPath([string]$Context.worktreeRoot)
        $client = Start-FactoryCodexAppServerClient -CodexCommand $CodexCommand -WorkingDirectory $repositoryRoot -Environment $Environment -TranscriptPath $TranscriptPath -Endpoint $Endpoint
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
        return [pscustomobject]@{ threadId = $threadId; title = $title; projectId = $projectId; backend = "shared-app-server" }
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
    $appServerBackends = @("app-server", "shared-app-server")
    $storedSessionId = if (
        -not $startNewConversation -and $identityMatchesRepository -and
        $identityBackend -in $appServerBackends -and
        [string](Get-FactoryNestedValue -Target $identity -Name "sessionId" -Default "")
    ) { [string]$identity.sessionId } else { "" }
    $legacySessionId = if ($identityMatchesRepository -and $identityBackend -notin $appServerBackends) {
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

    $sharedServer = Start-FactoryCodexSharedServer `
        -CodexCommand $CodexCommand `
        -RuntimeHome ([string]$Context.runtimeHome)
    Write-Host "Shared Codex app-server: $([string]$sharedServer.endpoint) (PID $([int]$sharedServer.pid))" -ForegroundColor Green
    try {
        $remote = Enable-FactoryCodexSharedRemoteControl `
            -CodexCommand $CodexCommand `
            -RuntimeHome ([string]$Context.runtimeHome) `
            -Endpoint ([string]$sharedServer.endpoint)
        $remoteLabel = if ([string]$remote.serverName) { " ($([string]$remote.serverName))" } else { "" }
        Write-Host "Codex Remote: $([string]$remote.status)$remoteLabel" -ForegroundColor $(if ([string]$remote.status -eq "connected") { "Green" } else { "Yellow" })
    } catch {
        Write-Warning "The shared app-server is ready, but Codex Remote could not be enabled: $($_.Exception.Message)"
    }

    $appServerTranscriptPath = Join-Path ([string]$Context.projectData) "codex-orchestrator-app-server.jsonl"
    if ($storedSessionId) {
        Write-Host "Validating app-backed Codex factory conversation: $storedSessionId" -ForegroundColor Green
        $available = Test-FactoryCodexAppThread `
            -CodexCommand $CodexCommand `
            -RepositoryRoot ([string]$Context.repositoryRoot) `
            -ThreadId $storedSessionId `
            -Environment $environment `
            -TranscriptPath $appServerTranscriptPath `
            -Endpoint ([string]$sharedServer.endpoint)
        if (-not $available) {
            throw "Stored app-backed Codex orchestrator '$storedSessionId' is unavailable. Run 'factory start -Agent codex -New' to create a replacement."
        }
        if ($identityBackend -ne "shared-app-server") {
            Write-FactoryCodexOrchestratorIdentity `
                -Path $identityPath `
                -RepositoryRoot ([string]$Context.repositoryRoot) `
                -SessionId $storedSessionId `
                -LegacySessionId $legacySessionId
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
            -TranscriptPath $appServerTranscriptPath `
            -Endpoint ([string]$sharedServer.endpoint)
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

    $resumeArguments = @("--remote", [string]$sharedServer.endpoint, "resume") + $sharedArguments + @($storedSessionId)
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
