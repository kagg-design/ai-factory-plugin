Set-StrictMode -Version 2.0

function ConvertTo-FactoryWindowsArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-FactoryNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = ""
    )

    $resolvedCommand = Get-Command $Command -ErrorAction Stop
    $executable = if ([string]$resolvedCommand.Source) {
        [string]$resolvedCommand.Source
    } else {
        [string]$resolvedCommand.Path
    }
    if (-not $executable) { throw "Could not resolve executable '$Command'." }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = (@($Arguments | ForEach-Object {
        ConvertTo-FactoryWindowsArgument -Value ([string]$_)
    }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start '$executable'." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result.TrimEnd("`r", "`n")
        $stderr = $stderrTask.Result.TrimEnd("`r", "`n")
        $combined = @($stdout, $stderr) | Where-Object { $_ } | ForEach-Object { [string]$_ }
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdout
            stderr = $stderr
            output = ($combined -join [Environment]::NewLine)
        }
    } finally {
        $process.Dispose()
    }
}

function Get-FactoryBackgroundId {
    param([string]$Output)

    $plain = $Output -replace "\x1b\[[0-9;]*[A-Za-z]", ""
    $backgroundMatch = [regex]::Match($plain, '(?im)^\s*backgrounded\s+\W+\s*([A-Za-z0-9_-]+)')
    if ($backgroundMatch.Success) { return $backgroundMatch.Groups[1].Value }
    $attachMatch = [regex]::Match($plain, '(?im)claude\s+attach\s+([A-Za-z0-9_-]+)')
    if ($attachMatch.Success) { return $attachMatch.Groups[1].Value }
    return $null
}

function Test-FactoryAgentFallbackWarning {
    param([string]$Output)

    return $Output -match '(?i)(no\s+(?:such\s+)?agent|agent\s+[^\r\n]*not\s+found|using\s+(?:the\s+)?default\s+(?:agent|template)|falling\s+back[^\r\n]*(?:agent|template))'
}

function Get-FactoryClaudeAgentRows {
    param([Parameter(Mandatory = $true)][string]$ClaudeCommand)

    $result = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @("agents", "--json", "--all")
    if ($result.exitCode -ne 0) {
        throw "Failed to query Claude background sessions: $($result.output)"
    }
    if (-not $result.stdout) { return @() }
    return @(($result.stdout | ConvertFrom-Json) | ForEach-Object { $_ })
}

function Get-FactorySha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Wait-FactoryClaudeSessionVisible {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$BackgroundId,
        [int]$TimeoutMilliseconds = 5000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $rows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
        $row = @($rows | Where-Object {
            $null -ne $_.PSObject.Properties["id"] -and
            [string]$_.id -eq $BackgroundId
        } | Select-Object -First 1)
        if ($row.Count -gt 0) { return $row[0] }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Background session '$BackgroundId' was not visible in 'claude agents --json --all' within $TimeoutMilliseconds ms."
}

function New-FactoryWorkerLaunchException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Outcomes,
        [bool]$NativeAgentUnsupported = $false,
        [string[]]$Deviations = @()
    )

    $exception = New-Object InvalidOperationException($Message)
    $exception.Data["FactoryResolutionOutcomes"] = [pscustomobject]$Outcomes
    $exception.Data["FactoryNativeAgentUnsupported"] = $NativeAgentUnsupported
    $exception.Data["FactoryAgentDefinitionDeviations"] = @($Deviations)
    return $exception
}

function Stop-FactoryClaudeSessionAndWait {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$BackgroundId,
        [int]$TimeoutMilliseconds = 5000
    )

    $stopResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @("stop", $BackgroundId)
    if ($stopResult.exitCode -ne 0) {
        throw "Failed to stop stray background session '$BackgroundId': $($stopResult.output)"
    }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $rows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
        $row = @($rows | Where-Object {
            $null -ne $_.PSObject.Properties["id"] -and
            [string]$_.id -eq $BackgroundId
        } | Select-Object -First 1)
        if ($row.Count -eq 0) { return }
        $state = if ($null -ne $row[0].PSObject.Properties["state"] -and [string]$row[0].state) {
            [string]$row[0].state
        } elseif ($null -ne $row[0].PSObject.Properties["status"]) {
            [string]$row[0].status
        } else {
            ""
        }
        if ($state -in @("stopped", "done", "failed")) { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Stray background session '$BackgroundId' did not stop within $TimeoutMilliseconds ms."
}

function Read-FactoryInlineWorkerAgent {
    param([Parameter(Mandatory = $true)][string]$Path)

    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $source = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path), $utf8)
    $match = [regex]::Match($source, '\A---\r?\n(?<frontmatter>[\s\S]*?)\r?\n---\r?\n(?<body>[\s\S]*)\z')
    if (-not $match.Success) { throw "Worker agent '$Path' has invalid YAML frontmatter boundaries." }
    $descriptionMatch = [regex]::Match($match.Groups["frontmatter"].Value, '(?m)^description:\s*(?<value>.+?)\s*$')
    if (-not $descriptionMatch.Success) { throw "Worker agent '$Path' has no frontmatter description." }
    $maxTurnsMatch = [regex]::Match($match.Groups["frontmatter"].Value, '(?m)^maxTurns:\s*(?<value>\d+)\s*$')
    $toolsMatch = [regex]::Match($match.Groups["frontmatter"].Value, '(?m)^tools:\s*(?<value>.+?)\s*$')
    $body = $match.Groups["body"].Value
    if ([string]::IsNullOrWhiteSpace($body)) { throw "Worker agent '$Path' has an empty prompt body." }

    $definition = [ordered]@{
        worker = [ordered]@{
            description = $descriptionMatch.Groups["value"].Value
            prompt = $body
        }
    }
    return [pscustomobject]@{
        description = $descriptionMatch.Groups["value"].Value
        prompt = $body
        json = ($definition | ConvertTo-Json -Depth 10 -Compress)
        maxTurns = if ($maxTurnsMatch.Success) { [int]$maxTurnsMatch.Groups["value"].Value } else { $null }
        tools = if ($toolsMatch.Success) { [string]$toolsMatch.Groups["value"].Value } else { $null }
    }
}

function Invoke-FactoryWorkerLaunch {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$SessionName,
        [Parameter(Mandatory = $true)][string]$PermissionMode,
        [Parameter(Mandatory = $true)][string]$ShortPrompt,
        [Parameter(Mandatory = $true)][string]$WorkerAgentPath,
        [Parameter(Mandatory = $true)][string]$SystemPromptPath,
        [ValidateSet("plugin", "inline-fallback", "system-prompt")][string]$PreferredResolution = "plugin",
        [string]$Model = "",
        [string]$Effort = ""
    )

    $baseArguments = @("--plugin-dir", $PluginRoot)
    $tailArguments = @("--bg", "--name", $SessionName, "--permission-mode", $PermissionMode)
    if ($Model -and $Model -ne "inherit") { $tailArguments += @("--model", $Model) }
    if ($Effort) { $tailArguments += @("--effort", $Effort) }
    $tailArguments += $ShortPrompt

    $outcomes = [ordered]@{
        plugin = if ($PreferredResolution -eq "plugin") { "not-tried" } else { "cached-unsupported" }
        inlineFallback = if ($PreferredResolution -in @("plugin", "inline-fallback")) { "not-tried" } else { "cached-unsupported" }
        systemPrompt = "not-tried"
    }
    $nativeFallbackDetected = $PreferredResolution -ne "plugin"
    $workerAgent = $null
    $systemDeviations = @(
        "The worker prompt is appended to Claude's default system prompt instead of replacing it.",
        "Worker agent frontmatter name and description are not applied by the system-prompt fallback."
    )

    try {
        if ($PreferredResolution -eq "plugin") {
            $nativeArguments = @($baseArguments + @("--agent", "factory:worker") + $tailArguments)
            $nativeResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments $nativeArguments -WorkingDirectory $Worktree
            if ($nativeResult.exitCode -ne 0) {
                $outcomes.plugin = "failed"
                $failedNativeId = Get-FactoryBackgroundId -Output $nativeResult.output
                if ($failedNativeId) {
                    Stop-FactoryClaudeSessionAndWait -ClaudeCommand $ClaudeCommand -BackgroundId $failedNativeId
                }
                throw (New-FactoryWorkerLaunchException -Message "Claude background launch failed with exit code $($nativeResult.exitCode): $($nativeResult.output)" -Outcomes $outcomes)
            }
            if (-not (Test-FactoryAgentFallbackWarning -Output $nativeResult.output)) {
                $nativeId = Get-FactoryBackgroundId -Output $nativeResult.output
                if (-not $nativeId) {
                    $outcomes.plugin = "failed"
                    throw (New-FactoryWorkerLaunchException -Message "Claude started without a parseable background session ID: $($nativeResult.output)" -Outcomes $outcomes)
                }
                $outcomes.plugin = "working"
                return [pscustomobject]@{
                    backgroundId = $nativeId
                    launchOutput = $nativeResult.output
                    agentResolution = "plugin"
                    nativeFallbackDetected = $false
                    inlineAgentSha256 = $null
                    systemPromptPath = $null
                    systemPromptSha256 = $null
                    agentDefinitionDeviations = @()
                    resolutionOutcomes = [pscustomobject]$outcomes
                    authoritativeRow = $null
                }
            }

            $outcomes.plugin = "unsupported"
            $nativeFallbackDetected = $true
            $strayId = Get-FactoryBackgroundId -Output $nativeResult.output
            if (-not $strayId) {
                throw (New-FactoryWorkerLaunchException -Message "Claude fell back from factory:worker without a parseable session ID: $($nativeResult.output)" -Outcomes $outcomes -NativeAgentUnsupported $true)
            }
            Stop-FactoryClaudeSessionAndWait -ClaudeCommand $ClaudeCommand -BackgroundId $strayId
        }

        if ($PreferredResolution -ne "system-prompt") {
            $workerAgent = Read-FactoryInlineWorkerAgent -Path $WorkerAgentPath
            $inlineBytes = [Text.Encoding]::UTF8.GetBytes([string]$workerAgent.json)
            $inlineHash = Get-FactorySha256Hex -Bytes $inlineBytes
            $inlineArguments = @($baseArguments + @("--agents", [string]$workerAgent.json, "--agent", "worker") + $tailArguments)
            $inlineResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments $inlineArguments -WorkingDirectory $Worktree
            if ($inlineResult.exitCode -ne 0) {
                $outcomes.inlineFallback = "failed"
                $failedInlineId = Get-FactoryBackgroundId -Output $inlineResult.output
                if ($failedInlineId) {
                    Stop-FactoryClaudeSessionAndWait -ClaudeCommand $ClaudeCommand -BackgroundId $failedInlineId
                }
                throw (New-FactoryWorkerLaunchException -Message "Claude inline-agent launch failed with exit code $($inlineResult.exitCode): $($inlineResult.output)" -Outcomes $outcomes -NativeAgentUnsupported $nativeFallbackDetected)
            }
            if (-not (Test-FactoryAgentFallbackWarning -Output $inlineResult.output)) {
                $inlineId = Get-FactoryBackgroundId -Output $inlineResult.output
                if (-not $inlineId) {
                    $outcomes.inlineFallback = "failed"
                    throw (New-FactoryWorkerLaunchException -Message "Claude started without a parseable background session ID: $($inlineResult.output)" -Outcomes $outcomes -NativeAgentUnsupported $nativeFallbackDetected)
                }
                $outcomes.inlineFallback = "working"
                return [pscustomobject]@{
                    backgroundId = $inlineId
                    launchOutput = $inlineResult.output
                    agentResolution = "inline-fallback"
                    nativeFallbackDetected = $nativeFallbackDetected
                    inlineAgentSha256 = $inlineHash
                    systemPromptPath = $null
                    systemPromptSha256 = $null
                    agentDefinitionDeviations = @()
                    resolutionOutcomes = [pscustomobject]$outcomes
                    authoritativeRow = $null
                }
            }

            $outcomes.inlineFallback = "unsupported"
            $strayInlineId = Get-FactoryBackgroundId -Output $inlineResult.output
            if (-not $strayInlineId) {
                throw (New-FactoryWorkerLaunchException -Message "Claude rejected the inline worker agent without a parseable session ID: $($inlineResult.output)" -Outcomes $outcomes -NativeAgentUnsupported $nativeFallbackDetected)
            }
            Stop-FactoryClaudeSessionAndWait -ClaudeCommand $ClaudeCommand -BackgroundId $strayInlineId
        }

        if ($null -eq $workerAgent) {
            $workerAgent = Read-FactoryInlineWorkerAgent -Path $WorkerAgentPath
        }
        if ($null -ne $workerAgent.maxTurns) {
            $systemDeviations += "Worker agent maxTurns: $($workerAgent.maxTurns) is not enforced by the system-prompt fallback."
        }
        if ([string]$workerAgent.tools) {
            $systemDeviations += "Worker agent tools restrictions are not enforced by the system-prompt fallback: $($workerAgent.tools)"
        }

        $systemPromptBytes = [Text.Encoding]::UTF8.GetBytes([string]$workerAgent.prompt)
        $systemPromptFullPath = [IO.Path]::GetFullPath($SystemPromptPath)
        $systemPromptParent = Split-Path -Parent $systemPromptFullPath
        if ($systemPromptParent) {
            New-Item -ItemType Directory -Path $systemPromptParent -Force | Out-Null
        }
        [IO.File]::WriteAllBytes($systemPromptFullPath, $systemPromptBytes)
        $systemPromptHash = Get-FactorySha256Hex -Bytes $systemPromptBytes

        $systemArguments = @($baseArguments + @("--append-system-prompt-file", $systemPromptFullPath) + $tailArguments)
        $systemResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments $systemArguments -WorkingDirectory $Worktree
        if ($systemResult.exitCode -ne 0) {
            $outcomes.systemPrompt = "failed"
            $failedSystemId = Get-FactoryBackgroundId -Output $systemResult.output
            if ($failedSystemId) {
                Stop-FactoryClaudeSessionAndWait -ClaudeCommand $ClaudeCommand -BackgroundId $failedSystemId
            }
            throw (New-FactoryWorkerLaunchException -Message "Claude system-prompt launch failed with exit code $($systemResult.exitCode): $($systemResult.output)" -Outcomes $outcomes -NativeAgentUnsupported $nativeFallbackDetected -Deviations $systemDeviations)
        }
        $systemId = Get-FactoryBackgroundId -Output $systemResult.output
        if (-not $systemId) {
            $outcomes.systemPrompt = "failed"
            throw (New-FactoryWorkerLaunchException -Message "Claude system-prompt launch started without a parseable background session ID: $($systemResult.output)" -Outcomes $outcomes -NativeAgentUnsupported $nativeFallbackDetected -Deviations $systemDeviations)
        }
        try {
            $systemRow = Wait-FactoryClaudeSessionVisible -ClaudeCommand $ClaudeCommand -BackgroundId $systemId
        } catch {
            $outcomes.systemPrompt = "failed"
            try {
                Stop-FactoryClaudeSessionAndWait -ClaudeCommand $ClaudeCommand -BackgroundId $systemId
            } catch {
                # Preserve the visibility failure; cleanup is best effort here.
            }
            throw (New-FactoryWorkerLaunchException -Message $_.Exception.Message -Outcomes $outcomes -NativeAgentUnsupported $nativeFallbackDetected -Deviations $systemDeviations)
        }
        $outcomes.systemPrompt = "working"
        return [pscustomobject]@{
            backgroundId = $systemId
            launchOutput = $systemResult.output
            agentResolution = "system-prompt"
            nativeFallbackDetected = $nativeFallbackDetected
            inlineAgentSha256 = $null
            systemPromptPath = $systemPromptFullPath
            systemPromptSha256 = $systemPromptHash
            agentDefinitionDeviations = @($systemDeviations)
            resolutionOutcomes = [pscustomobject]$outcomes
            authoritativeRow = $systemRow
        }
    } catch {
        if ($null -eq $_.Exception.Data["FactoryResolutionOutcomes"]) {
            $_.Exception.Data["FactoryResolutionOutcomes"] = [pscustomobject]$outcomes
        }
        if ($null -eq $_.Exception.Data["FactoryNativeAgentUnsupported"]) {
            $_.Exception.Data["FactoryNativeAgentUnsupported"] = $nativeFallbackDetected
        }
        if ($null -eq $_.Exception.Data["FactoryAgentDefinitionDeviations"]) {
            $_.Exception.Data["FactoryAgentDefinitionDeviations"] = @($systemDeviations)
        }
        throw
    }
}
