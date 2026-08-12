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

function Read-FactoryJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json
}

function Write-FactoryJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 100
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $utf8)

    try {
        Read-FactoryJson -Path $temporaryPath | Out-Null
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Add-MissingFactoryProperties {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)]$Defaults
    )

    foreach ($defaultProperty in $Defaults.PSObject.Properties) {
        $existingProperty = $Target.PSObject.Properties[$defaultProperty.Name]
        if ($null -eq $existingProperty) {
            $copy = $defaultProperty.Value |
                ConvertTo-Json -Depth 100 |
                ConvertFrom-Json
            $Target | Add-Member -NotePropertyName $defaultProperty.Name -NotePropertyValue $copy
            continue
        }

        $existingValue = $existingProperty.Value
        $defaultValue = $defaultProperty.Value
        if (
            $null -ne $existingValue -and
            $null -ne $defaultValue -and
            $existingValue -is [PSCustomObject] -and
            $defaultValue -is [PSCustomObject]
        ) {
            Add-MissingFactoryProperties -Target $existingValue -Defaults $defaultValue
        }
    }
}

function Set-FactoryProperty {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($null -eq $Target.PSObject.Properties[$Name]) {
        $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $Target.$Name = $Value
    }
}

function Enter-FactoryMutex {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectKey,
        [int]$TimeoutMilliseconds = 30000
    )

    $safeKey = $ProjectKey -replace '[^A-Za-z0-9_.-]', '-'
    $mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeFactory-$safeKey")
    try {
        if (-not $mutex.WaitOne($TimeoutMilliseconds)) {
            throw "Timed out waiting for the factory state lock for '$ProjectKey'."
        }
    } catch [System.Threading.AbandonedMutexException] {
        # Ownership is granted when the previous process abandoned the mutex.
    }
    return $mutex
}

function Exit-FactoryMutex {
    param($Mutex)

    if ($null -eq $Mutex) { return }
    try {
        $Mutex.ReleaseMutex()
    } catch {
        # The caller may be unwinding before it acquired ownership.
    } finally {
        $Mutex.Dispose()
    }
}

function Get-FactoryTask {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$TaskId
    )

    $matches = @($State.tasks | Where-Object { [string]$_.id -eq $TaskId })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one factory task with ID '$TaskId'; found $($matches.Count)."
    }
    return $matches[0]
}

function Get-FactoryUtcTimestamp {
    return [DateTime]::UtcNow.ToString("o")
}

function Get-FactoryFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-FactorySafeName {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$Fallback = "task"
    )

    $safe = ($Value.ToLowerInvariant() -replace '[^a-z0-9._-]', '-')
    $safe = ($safe -replace '-+', '-').Trim('-', '.')
    if (-not $safe) { return $Fallback }
    return $safe
}

function Test-FactorySamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    try {
        $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd('\', '/')
        $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd('\', '/')
        return $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-FactoryTerminalAgentRow {
    param([Parameter(Mandatory = $true)]$Row)

    $terminal = @("done", "stopped", "failed")
    $state = if ($null -ne $Row.PSObject.Properties["state"]) { [string]$Row.state } else { "" }
    $status = if ($null -ne $Row.PSObject.Properties["status"]) { [string]$Row.status } else { "" }
    return $state -in $terminal -or $status -in $terminal
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

function Stop-FactoryClaudeSessionAndWait {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$BackgroundId,
        [int]$TimeoutMilliseconds = 5000
    )

    $stopResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @("stop", $BackgroundId)
    if ($stopResult.exitCode -ne 0) {
        throw "Failed to stop background session '$BackgroundId': $($stopResult.output)"
    }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $rows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
        $row = @($rows | Where-Object {
            $null -ne $_.PSObject.Properties["id"] -and
            [string]$_.id -eq $BackgroundId
        } | Select-Object -First 1)
        if ($row.Count -eq 0) { return }
        $hasPid = (
            $null -ne $row[0].PSObject.Properties["pid"] -and
            [long]$row[0].pid -gt 0
        )
        if (-not $hasPid -and (Test-FactoryTerminalAgentRow -Row $row[0])) { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Background session '$BackgroundId' is still live after $TimeoutMilliseconds ms and may still hold its worktree."
}

function Remove-FactoryAgentSessionRow {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$BackgroundId
    )

    $removeResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @("rm", $BackgroundId)
    if ($removeResult.exitCode -eq 0) {
        return [pscustomobject]@{ id = $BackgroundId; removed = $true; alreadyGone = $false; warning = $null }
    }

    try {
        $stillPresent = @(
            Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand |
                Where-Object {
                    $null -ne $_.PSObject.Properties["id"] -and
                    [string]$_.id -eq $BackgroundId
                }
        ).Count -gt 0
        if (-not $stillPresent) {
            return [pscustomobject]@{ id = $BackgroundId; removed = $true; alreadyGone = $true; warning = $null }
        }
    } catch {
        # Preserve the original rm failure below; the verification query is best effort.
    }

    $detail = if ($removeResult.output) { $removeResult.output } else { "exit code $($removeResult.exitCode)" }
    return [pscustomobject]@{
        id = $BackgroundId
        removed = $false
        alreadyGone = $false
        warning = "Agent View session '$BackgroundId' could not be removed: $detail"
    }
}

function Remove-FactoryTaskAgentSessions {
    <#
    Removes only background Agent View rows owned by one factory task. `claude
    rm` removes the Agent View index row but, as verified with Claude Code
    2.1.228, leaves the JSONL transcript under ~/.claude/projects intact.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$Worktree = "",
        [string]$KeepId = ""
    )

    $safeTaskId = ConvertTo-FactorySafeName -Value $TaskId
    $sessionNamePrefix = "factory-$safeTaskId-"
    $candidates = @()
    foreach ($row in @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)) {
        $kind = if ($null -ne $row.PSObject.Properties["kind"]) { [string]$row.kind } else { "" }
        if ($kind -ne "background") { continue }
        if ($null -eq $row.PSObject.Properties["id"] -or -not [string]$row.id) { continue }

        $rowId = [string]$row.id
        if ($KeepId -and $rowId -eq $KeepId) { continue }
        $rowName = if ($null -ne $row.PSObject.Properties["name"]) { [string]$row.name } else { "" }
        if ($rowName -ceq "Claude Factory Orchestrator") { continue }
        $rowCwd = if ($null -ne $row.PSObject.Properties["cwd"]) { [string]$row.cwd } else { "" }
        $matchesWorktree = [bool]($Worktree -and $rowCwd -and (Test-FactorySamePath -Left $rowCwd -Right $Worktree))
        $matchesName = $rowName.StartsWith($sessionNamePrefix, [StringComparison]::OrdinalIgnoreCase)
        if ($matchesWorktree -or $matchesName) { $candidates += $row }
    }

    $stopped = @()
    $removed = @()
    $alreadyGone = @()
    $stopFailures = @()
    $removeFailures = @()

    # Stop every live process before removing any Agent View row. If a process
    # survives, callers can abort before touching the worktree.
    foreach ($row in @($candidates)) {
        $hasPid = $null -ne $row.PSObject.Properties["pid"] -and [long]$row.pid -gt 0
        if (-not $hasPid -and (Test-FactoryTerminalAgentRow -Row $row)) { continue }
        $rowId = [string]$row.id
        try {
            Stop-FactoryClaudeSessionAndWait -ClaudeCommand $ClaudeCommand -BackgroundId $rowId
            $stopped += $rowId
        } catch {
            $stopFailures += [pscustomobject]@{ id = $rowId; warning = $_.Exception.Message }
        }
    }

    if ($stopFailures.Count -eq 0) {
        foreach ($row in @($candidates)) {
            $rowId = [string]$row.id
            $result = Remove-FactoryAgentSessionRow -ClaudeCommand $ClaudeCommand -BackgroundId $rowId
            if ($result.removed) {
                $removed += $rowId
                if ($result.alreadyGone) { $alreadyGone += $rowId }
            } else {
                $removeFailures += [pscustomobject]@{ id = $rowId; warning = [string]$result.warning }
            }
        }
    }

    return [pscustomobject]@{
        matchedAgentSessions = @($candidates | ForEach-Object { [string]$_.id })
        stoppedAgentSessions = @($stopped)
        removedAgentSessions = @($removed)
        alreadyGoneAgentSessions = @($alreadyGone)
        stopFailures = @($stopFailures)
        removeFailures = @($removeFailures)
        warnings = @(@($stopFailures) + @($removeFailures) | ForEach-Object { [string]$_.warning })
    }
}
