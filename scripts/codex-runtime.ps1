if ($null -eq (Get-Command Invoke-FactoryNativeProcess -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "factory-common.ps1")
}

function Resolve-FactoryCodexCommand {
    param($Config, [string]$ExplicitCommand = "")

    if ($ExplicitCommand) { return $ExplicitCommand }
    if ($env:CLAUDE_FACTORY_CODEX_COMMAND) { return [string]$env:CLAUDE_FACTORY_CODEX_COMMAND }
    if ($null -ne $Config -and $null -ne $Config.PSObject.Properties["codexCommand"] -and [string]$Config.codexCommand) {
        return [string]$Config.codexCommand
    }
    return "codex"
}

function Get-FactoryCodexCapabilities {
    param([Parameter(Mandatory = $true)][string]$CodexCommand)

    try {
        $version = Invoke-FactoryNativeProcess -Command $CodexCommand -Arguments @("--version")
        $exec = Invoke-FactoryNativeProcess -Command $CodexCommand -Arguments @("exec", "--help")
        $execResume = Invoke-FactoryNativeProcess -Command $CodexCommand -Arguments @("exec", "resume", "--help")
        $resume = Invoke-FactoryNativeProcess -Command $CodexCommand -Arguments @("resume", "--help")
        $supported = (
            [int]$version.exitCode -eq 0 -and
            [int]$exec.exitCode -eq 0 -and [string]$exec.stdout -match '(?m)^\s+--json\b' -and
            [string]$exec.stdout -match '--output-last-message' -and
            [int]$execResume.exitCode -eq 0 -and [string]$execResume.stdout -match '\[SESSION_ID\]' -and
            [int]$resume.exitCode -eq 0 -and [string]$resume.stdout -match '--include-non-interactive'
        )
        return [pscustomobject]@{
            supported = $supported
            version = ([string]$version.stdout).Trim()
            command = $CodexCommand
            detail = if ($supported) { "exec JSONL, exec resume, and interactive resume are available" } else { "required Codex CLI session capabilities are missing" }
        }
    } catch {
        return [pscustomobject]@{ supported = $false; version = ""; command = $CodexCommand; detail = $_.Exception.Message }
    }
}

function Start-FactoryCodexWorkerProcess {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$PromptPath,
        [Parameter(Mandatory = $true)][string]$ArtifactPrefix,
        [Parameter(Mandatory = $true)][string]$SessionName,
        $Capabilities = $null,
        [hashtable]$Environment = @{},
        [string]$Model = "",
        [string]$Effort = ""
    )

    $capabilities = if ($null -ne $Capabilities) { $Capabilities } else { Get-FactoryCodexCapabilities -CodexCommand $CodexCommand }
    if (-not [bool]$capabilities.supported) {
        throw "Codex worker runtime is unavailable: $($capabilities.detail)"
    }
    $resolvedCodex = Get-Command $CodexCommand -ErrorAction Stop
    $executable = if ([string]$resolvedCodex.Source) { [string]$resolvedCodex.Source } else { [string]$resolvedCodex.Path }
    $realGit = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $jsonlPath = "$ArtifactPrefix-codex.jsonl"
    $stderrPath = "$ArtifactPrefix-codex.stderr.log"
    $lastMessagePath = "$ArtifactPrefix-codex.last-message.txt"
    $shimDirectory = "$ArtifactPrefix-codex-bin"
    New-Item -ItemType Directory -Path $shimDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PluginRoot "scripts\codex-git.cmd") -Destination (Join-Path $shimDirectory "git.cmd") -Force
    foreach ($path in @($jsonlPath, $stderrPath, $lastMessagePath)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    $arguments = @(
        "exec", "--json", "--sandbox", "workspace-write", "--approve-for-me",
        "-C", [IO.Path]::GetFullPath($Worktree),
        "--output-last-message", $lastMessagePath
    )
    if ($Model -and $Model -ne "inherit") { $arguments += @("--model", $Model) }
    if ($Effort -and $Effort -ne "inherit") {
        if ($Effort -notin @("minimal", "low", "medium", "high", "xhigh")) {
            throw "Unsupported Codex reasoning effort '$Effort'."
        }
        $arguments += @("--config", "model_reasoning_effort=`"$Effort`"")
    }
    $arguments += "-"
    $argumentLine = @($arguments | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }) -join " "

    $factoryEnvironment = @{}
    foreach ($entry in $Environment.GetEnumerator()) { $factoryEnvironment[[string]$entry.Key] = [string]$entry.Value }
    $factoryEnvironment["CLAUDE_FACTORY_PLUGIN_ROOT"] = [IO.Path]::GetFullPath($PluginRoot)
    $factoryEnvironment["CLAUDE_FACTORY_REAL_GIT"] = [string]$realGit.Source
    $factoryEnvironment["CLAUDE_FACTORY_WORKTREE"] = [IO.Path]::GetFullPath($Worktree)
    $factoryEnvironment["PATH"] = "$shimDirectory;$env:PATH"
    $previous = @{}
    try {
        foreach ($entry in $factoryEnvironment.GetEnumerator()) {
            $name = [string]$entry.Key
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
            [Environment]::SetEnvironmentVariable($name, [string]$entry.Value, "Process")
        }
        $process = Start-Process `
            -FilePath $executable `
            -ArgumentList $argumentLine `
            -WorkingDirectory ([IO.Path]::GetFullPath($Worktree)) `
            -RedirectStandardInput $PromptPath `
            -RedirectStandardOutput $jsonlPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle Hidden `
            -PassThru
    } finally {
        foreach ($entry in $previous.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
        }
    }
    return [pscustomobject]@{
        runtime = "codex"
        id = "codex-$($process.Id)"
        sessionId = $null
        name = $SessionName
        state = "working"
        processId = $process.Id
        processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString("o")
        transcriptPath = $jsonlPath
        stderrPath = $stderrPath
        lastMessagePath = $lastMessagePath
        shimDirectory = $shimDirectory
        attachCommand = $null
        cliVersion = [string]$capabilities.version
    }
}

function Get-FactoryCodexSessionSnapshot {
    param([Parameter(Mandatory = $true)]$Session)

    $threadId = if ($null -ne $Session.PSObject.Properties["sessionId"]) { [string]$Session.sessionId } else { "" }
    $lastMessage = ""
    $terminal = $false
    $eventError = ""
    $transcriptPath = [string]$Session.transcriptPath
    if ($transcriptPath -and (Test-Path -LiteralPath $transcriptPath -PathType Leaf)) {
        $transcriptLines = try { @([IO.File]::ReadAllLines($transcriptPath, (New-Object Text.UTF8Encoding($false)))) } catch { @() }
        foreach ($line in $transcriptLines) {
            if (-not $line.Trim()) { continue }
            try { $event = $line | ConvertFrom-Json } catch { continue }
            $type = [string]$event.type
            if ($type -eq "thread.started" -and [string]$event.thread_id) { $threadId = [string]$event.thread_id }
            if ($type -eq "item.completed" -and $null -ne $event.item -and [string]$event.item.type -eq "agent_message") {
                $lastMessage = [string]$event.item.text
            }
            if ($type -eq "turn.completed") { $terminal = $true }
            if ($type -in @("error", "turn.failed")) {
                $eventError = if ([string]$event.message) { [string]$event.message } else { $line }
            }
        }
    }
    $lastMessagePath = if ($null -ne $Session.PSObject.Properties["lastMessagePath"]) { [string]$Session.lastMessagePath } else { "" }
    if ($lastMessagePath -and (Test-Path -LiteralPath $lastMessagePath -PathType Leaf)) {
        $fileMessage = try { [IO.File]::ReadAllText($lastMessagePath, (New-Object Text.UTF8Encoding($false))) } catch { "" }
        if ($fileMessage.Trim()) { $lastMessage = $fileMessage }
    }
    $stderrPath = if ($null -ne $Session.PSObject.Properties["stderrPath"]) { [string]$Session.stderrPath } else { "" }
    $stderr = if ($stderrPath -and (Test-Path -LiteralPath $stderrPath -PathType Leaf)) {
        try { [IO.File]::ReadAllText($stderrPath, (New-Object Text.UTF8Encoding($false))).Trim() } catch { "" }
    } else { "" }

    $alive = $false
    $processId = if ($null -ne $Session.PSObject.Properties["processId"]) { [int]$Session.processId } else { 0 }
    if ($processId -gt 0) {
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            $expected = if ($null -ne $Session.PSObject.Properties["processStartTimeUtc"]) { [string]$Session.processStartTimeUtc } else { "" }
            $alive = -not $expected -or [Math]::Abs(($process.StartTime.ToUniversalTime() - [DateTime]::Parse($expected).ToUniversalTime()).TotalSeconds) -lt 1
        } catch { $alive = $false }
    }
    $state = if ($alive) { "working" } elseif ($eventError) { "failed" } elseif ($terminal) { "done" } else { "stopped" }
    $messageHash = if ($lastMessage) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lastMessage)))).Replace("-", "").ToLowerInvariant() } finally { $sha.Dispose() }
    } else { "" }
    return [pscustomobject]@{
        runtime = "codex"
        id = [string]$Session.id
        sessionId = $threadId
        name = [string]$Session.name
        state = $state
        status = $state
        transcriptPath = $transcriptPath
        lastAssistantMessage = $lastMessage
        messageHash = $messageHash
        error = if ($eventError) { $eventError } else { $stderr }
        processAlive = $alive
    }
}

function Stop-FactoryCodexWorkerProcess {
    param([Parameter(Mandatory = $true)]$Session)

    $processId = if ($null -ne $Session.PSObject.Properties["processId"]) { [int]$Session.processId } else { 0 }
    if ($processId -le 0) { return [pscustomobject]@{ stopped = $false; alreadyStopped = $true } }
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ stopped = $false; alreadyStopped = $true }
    }
    $expected = if ($null -ne $Session.PSObject.Properties["processStartTimeUtc"]) { [string]$Session.processStartTimeUtc } else { "" }
    if ($expected -and [Math]::Abs(($process.StartTime.ToUniversalTime() - [DateTime]::Parse($expected).ToUniversalTime()).TotalSeconds) -ge 1) {
        throw "Refusing to stop PID $processId because its process identity no longer matches the Codex worker."
    }
    $result = Invoke-FactoryNativeProcess -Command "taskkill" -Arguments @("/PID", [string]$processId, "/T", "/F")
    if ([int]$result.exitCode -ne 0) {
        try { $null = Get-Process -Id $processId -ErrorAction Stop } catch { return [pscustomobject]@{ stopped = $false; alreadyStopped = $true } }
        throw "Failed to stop Codex worker PID $processId`: $($result.output)"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        try {
            $remaining = Get-Process -Id $processId -ErrorAction Stop
            if ($expected -and [Math]::Abs(($remaining.StartTime.ToUniversalTime() - [DateTime]::Parse($expected).ToUniversalTime()).TotalSeconds) -ge 1) {
                return [pscustomobject]@{ stopped = $true; alreadyStopped = $false }
            }
        } catch {
            return [pscustomobject]@{ stopped = $true; alreadyStopped = $false }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Codex worker PID $processId is still live after taskkill and may still hold its worktree."
}

function Invoke-FactoryCodexSessionDisposition {
    param(
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [Parameter(Mandatory = $true)]$Session,
        [ValidateSet("none", "archive", "delete")][string]$Disposition = "none"
    )

    $threadId = if ($null -ne $Session.PSObject.Properties["sessionId"]) { [string]$Session.sessionId } else { "" }
    if (-not $threadId) {
        try { $threadId = [string](Get-FactoryCodexSessionSnapshot -Session $Session).sessionId } catch { $threadId = "" }
    }
    $stop = Stop-FactoryCodexWorkerProcess -Session $Session
    $warning = $null
    if ($threadId -and $Disposition -ne "none") {
        $arguments = if ($Disposition -eq "delete") { @("delete", "--force", $threadId) } else { @("archive", $threadId) }
        $result = Invoke-FactoryNativeProcess -Command $CodexCommand -Arguments $arguments
        if ([int]$result.exitCode -ne 0) { $warning = "Codex session '$threadId' could not complete disposition '$Disposition': $($result.output)" }
    }
    return [pscustomobject]@{ stopped = [bool]$stop.stopped; threadId = $threadId; disposition = $Disposition; warning = $warning }
}

function Close-FactoryTaskWorkerSessions {
    param(
        [AllowNull()]$Session = $null,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$Worktree = "",
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$CodexCommand,
        [ValidateSet("none", "archive", "delete")][string]$CodexDisposition = "archive"
    )

    $runtime = if ($null -ne $Session -and $null -ne $Session.PSObject.Properties["runtime"] -and [string]$Session.runtime) {
        [string]$Session.runtime
    } else { "claude" }
    if ($runtime -ne "codex") {
        return Remove-FactoryTaskAgentSessions -ClaudeCommand $ClaudeCommand -TaskId $TaskId -Worktree $Worktree
    }
    try {
        $result = Invoke-FactoryCodexSessionDisposition -CodexCommand $CodexCommand -Session $Session -Disposition $CodexDisposition
        $id = if ([string]$result.threadId) { [string]$result.threadId } else { [string]$Session.id }
        return [pscustomobject]@{
            matchedAgentSessions = @($id)
            stoppedAgentSessions = @($(if ([bool]$result.stopped) { $id }))
            removedAgentSessions = @($(if ($CodexDisposition -ne "none" -and [string]$result.threadId -and -not [string]$result.warning) { $id }))
            alreadyGoneAgentSessions = @()
            stopFailures = @()
            removeFailures = @($(if ([string]$result.warning) { [pscustomobject]@{ id = $id; warning = [string]$result.warning } }))
            warnings = @($(if ([string]$result.warning) { [string]$result.warning }))
        }
    } catch {
        $id = if ($null -ne $Session) { [string]$Session.id } else { "codex" }
        return [pscustomobject]@{
            matchedAgentSessions = @($id)
            stoppedAgentSessions = @()
            removedAgentSessions = @()
            alreadyGoneAgentSessions = @()
            stopFailures = @([pscustomobject]@{ id = $id; warning = $_.Exception.Message })
            removeFailures = @()
            warnings = @($_.Exception.Message)
        }
    }
}
