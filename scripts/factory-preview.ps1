[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("status", "start", "stop")]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$TaskId = "",
    [string]$RuntimeHome = "",
    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "factory-common.ps1")

if ($RuntimeHome) { $env:CLAUDE_FACTORY_HOME = [IO.Path]::GetFullPath($RuntimeHome) }
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository) |
    ConvertFrom-Json
$config = Read-FactoryJson -Path ([string]$context.configPath)
$previewConfig = Get-FactoryNestedValue -Target $config -Name "preview"
$previewPath = if ([string](Get-FactoryNestedValue -Target $context -Name "previewPath" -Default "")) {
    [string]$context.previewPath
} else {
    Join-Path ([string]$context.projectData) "preview.json"
}
$previewRoot = if ([string](Get-FactoryNestedValue -Target $context -Name "previewRoot" -Default "")) {
    [string]$context.previewRoot
} else {
    Join-Path ([string]$context.projectData) "preview"
}

function Get-PreviewProperty {
    param($InputObject, [string]$Name, $Default = $null)

    if ($null -eq $InputObject -or $null -eq $InputObject.PSObject.Properties[$Name]) { return $Default }
    $value = $InputObject.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

function Test-PreviewPathInsideRoot {
    param([string]$Path, [string]$Root)

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Expand-PreviewTemplate {
    param([string]$Value, [hashtable]$Values)

    $expanded = $Value
    foreach ($entry in $Values.GetEnumerator()) {
        $expanded = $expanded.Replace("{$([string]$entry.Key)}", [string]$entry.Value)
    }
    if ($expanded -match '\{(?:host|appPort|assetPort|taskId|worktree|repository)\}') {
        throw "Preview template contains an unresolved placeholder: $Value"
    }
    return $expanded
}

function Test-PreviewProcess {
    param($Record)

    $processId = [int](Get-PreviewProperty -InputObject $Record -Name "pid" -Default 0)
    if ($processId -le 0) { return $false }
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        $expectedText = [string](Get-PreviewProperty -InputObject $Record -Name "processStartTimeUtc" -Default "")
        if (-not $expectedText) { return $false }
        $expected = [DateTime]::Parse($expectedText).ToUniversalTime()
        return [Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -lt 1
    } catch {
        return $false
    }
}

function Stop-PreviewProcess {
    param($Record)

    if (-not (Test-PreviewProcess -Record $Record)) {
        return [pscustomobject]@{ stopped = $false; alreadyStopped = $true }
    }
    $processId = [int]$Record.pid
    $result = Invoke-FactoryNativeProcess -Command "taskkill" -Arguments @("/PID", [string]$processId, "/T", "/F")
    if ([int]$result.exitCode -ne 0 -and (Test-PreviewProcess -Record $Record)) {
        throw "Failed to stop preview PID $processId`: $($result.output)"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-PreviewProcess -Record $Record)) {
            return [pscustomobject]@{ stopped = $true; alreadyStopped = $false }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Preview PID $processId is still running after taskkill."
}

function Stop-PreviewWorktreeProcesses {
    param([string]$Worktree)

    if (-not $Worktree) { return @() }
    $fullWorktree = [IO.Path]::GetFullPath($Worktree).TrimEnd('\', '/')
    if (-not (Test-PreviewPathInsideRoot -Path $fullWorktree -Root ([string]$context.worktreeRoot))) {
        throw "Refusing to stop preview processes outside the factory worktree root: $fullWorktree"
    }
    $allowedNames = @("powershell.exe", "pwsh.exe", "node.exe", "esbuild.exe", "php.exe", "npm.exe", "npx.exe")
    $stopped = New-Object Collections.Generic.List[int]
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $matches = @(
            Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
                [int]$_.ProcessId -ne $PID -and
                [string]$_.Name -in $allowedNames -and
                [string]$_.CommandLine -and
                ([string]$_.CommandLine).IndexOf($fullWorktree, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        )
        if ($matches.Count -eq 0) { return @($stopped.ToArray()) }
        foreach ($match in $matches) {
            $matchedPid = [int]$match.ProcessId
            if ($stopped -contains $matchedPid) { continue }
            $kill = Invoke-FactoryNativeProcess -Command "taskkill" -Arguments @("/PID", [string]$matchedPid, "/T", "/F")
            if ([int]$kill.exitCode -ne 0) {
                try { $null = Get-Process -Id $matchedPid -ErrorAction Stop } catch { continue }
                throw "Failed to stop residual preview process '$([string]$match.Name)' PID $matchedPid for '$fullWorktree': $($kill.output)"
            }
            $stopped.Add($matchedPid)
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)

    $remaining = @(
        Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            [string]$_.Name -in $allowedNames -and [string]$_.CommandLine -and
            ([string]$_.CommandLine).IndexOf($fullWorktree, [StringComparison]::OrdinalIgnoreCase) -ge 0
        } | ForEach-Object { "$($_.Name) PID $($_.ProcessId)" }
    )
    throw "Preview processes still reference '$fullWorktree': $($remaining -join ', ')"
}

function Test-PreviewPortOpen {
    param([string]$HostName, [int]$Port, [int]$TimeoutMilliseconds = 200)

    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Get-PreviewFreePort {
    param([string]$HostName, [int]$Start, [int]$End, [int[]]$Excluded = @())

    if ($Start -lt 1024 -or $End -gt 65535 -or $End -lt $Start) {
        throw "Invalid preview port range $Start-$End."
    }
    $address = [Net.IPAddress]::Parse($HostName)
    foreach ($port in $Start..$End) {
        if ($port -in $Excluded) { continue }
        $listener = New-Object Net.Sockets.TcpListener($address, $port)
        try {
            $listener.Start()
            return $port
        } catch {
            continue
        } finally {
            try { $listener.Stop() } catch {}
        }
    }
    throw "No free preview port is available in $Start-$End."
}

function Remove-PreviewDependencyLinks {
    param($Preview)

    $removed = New-Object Collections.Generic.List[string]
    $records = @((Get-PreviewProperty -InputObject $Preview -Name "createdDependencyLinks" -Default @()))
    [Array]::Reverse($records)
    foreach ($record in $records) {
        $path = [string](Get-PreviewProperty -InputObject $record -Name "path" -Default "")
        $target = [string](Get-PreviewProperty -InputObject $record -Name "target" -Default "")
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { continue }
        $actualTarget = @($item.Target | ForEach-Object { [IO.Path]::GetFullPath([string]$_) })
        if ($target -and @($actualTarget | Where-Object { $_.Equals([IO.Path]::GetFullPath($target), [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
            continue
        }
        if ($item.PSIsContainer) { [IO.Directory]::Delete($path, $false) } else { [IO.File]::Delete($path) }
        $removed.Add($path)
    }
    return @($removed.ToArray())
}

function Remove-PreviewHotFile {
    param($Preview)

    $worktree = [string](Get-PreviewProperty -InputObject $Preview -Name "worktree" -Default "")
    $assetPort = [int](Get-PreviewProperty -InputObject $Preview -Name "assetPort" -Default 0)
    if (-not $worktree -or $assetPort -le 0) { return $false }
    $hotPath = Join-Path $worktree "public\hot"
    if (-not (Test-Path -LiteralPath $hotPath -PathType Leaf)) { return $false }
    $content = try { [IO.File]::ReadAllText($hotPath) } catch { "" }
    if ($content -notmatch ":$assetPort(?:/|$)") { return $false }
    Remove-Item -LiteralPath $hotPath -Force
    return $true
}

function Get-PreviewSnapshot {
    if (-not (Test-Path -LiteralPath $previewPath -PathType Leaf)) { return $null }
    $preview = Read-FactoryJson -Path $previewPath
    $appLive = Test-PreviewProcess -Record (Get-PreviewProperty -InputObject $preview -Name "app")
    $assetsLive = Test-PreviewProcess -Record (Get-PreviewProperty -InputObject $preview -Name "assets")
    Set-FactoryProperty -Target $preview -Name "appLive" -Value $appLive
    Set-FactoryProperty -Target $preview -Name "assetsLive" -Value $assetsLive
    Set-FactoryProperty -Target $preview -Name "running" -Value ($appLive -and $assetsLive)
    Set-FactoryProperty -Target $preview -Name "degraded" -Value ($appLive -xor $assetsLive)
    return $preview
}

function Stop-CurrentPreview {
    param([string]$ExpectedTaskId = "")

    $preview = Get-PreviewSnapshot
    if ($null -eq $preview) {
        return [ordered]@{ stopped = $false; alreadyStopped = $true; taskId = $null }
    }
    if ($ExpectedTaskId -and [string]$preview.taskId -ne $ExpectedTaskId) {
        return [ordered]@{
            stopped = $false
            alreadyStopped = $false
            taskMismatch = $true
            taskId = [string]$preview.taskId
        }
    }
    $assetsStop = Stop-PreviewProcess -Record (Get-PreviewProperty -InputObject $preview -Name "assets")
    $appStop = Stop-PreviewProcess -Record (Get-PreviewProperty -InputObject $preview -Name "app")
    $residualPids = @(Stop-PreviewWorktreeProcesses -Worktree ([string]$preview.worktree))
    $hotRemoved = Remove-PreviewHotFile -Preview $preview
    $removedLinks = @(Remove-PreviewDependencyLinks -Preview $preview)
    Remove-Item -LiteralPath $previewPath -Force -ErrorAction SilentlyContinue
    return [ordered]@{
        stopped = [bool]($assetsStop.stopped -or $appStop.stopped)
        alreadyStopped = [bool]($assetsStop.alreadyStopped -and $appStop.alreadyStopped)
        taskId = [string]$preview.taskId
        title = [string]$preview.title
        worktree = [string]$preview.worktree
        url = [string]$preview.url
        appPort = [int]$preview.appPort
        assetPort = [int]$preview.assetPort
        stoppedResidualPids = $residualPids
        removedDependencyLinks = $removedLinks
        removedHotFile = $hotRemoved
    }
}

function Assert-PreviewDependencyLockMatch {
    param([string]$RelativePath, [string]$RepositoryRoot, [string]$Worktree)

    $lockName = switch ($RelativePath.Replace('\', '/').Trim('/').ToLowerInvariant()) {
        "vendor" { "composer.lock" }
        "node_modules" { "package-lock.json" }
        default { "" }
    }
    if (-not $lockName) { return }
    $repositoryLock = Join-Path $RepositoryRoot $lockName
    $worktreeLock = Join-Path $Worktree $lockName
    if (-not (Test-Path -LiteralPath $repositoryLock -PathType Leaf) -or -not (Test-Path -LiteralPath $worktreeLock -PathType Leaf)) { return }
    if ((Get-FactoryFileSha256 -Path $repositoryLock) -ne (Get-FactoryFileSha256 -Path $worktreeLock)) {
        throw "Cannot reuse '$RelativePath': $lockName differs in the worker. Install dependencies inside the worktree or change preview.dependencyLinks."
    }
}

function New-PreviewDependencyLinks {
    param([string]$RepositoryRoot, [string]$Worktree)

    $created = New-Object Collections.Generic.List[object]
    try {
        foreach ($relativeValue in @((Get-FactoryNestedValue -Target $previewConfig -Name "dependencyLinks" -Default @()))) {
            $relative = ([string]$relativeValue).Trim().TrimStart('\', '/')
            if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "Unsafe preview dependency link path '$relativeValue'."
            }
            $source = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relative))
            $destination = [IO.Path]::GetFullPath((Join-Path $Worktree $relative))
            if (-not (Test-PreviewPathInsideRoot -Path $source -Root $RepositoryRoot) -or -not (Test-PreviewPathInsideRoot -Path $destination -Root $Worktree)) {
                throw "Preview dependency link '$relative' leaves its allowed root."
            }
            if (Test-Path -LiteralPath $destination) { continue }
            if (-not (Test-Path -LiteralPath $source -PathType Container)) {
                throw "Preview dependency directory '$relative' is absent from both the worker and the main repository."
            }
            Assert-PreviewDependencyLockMatch -RelativePath $relative -RepositoryRoot $RepositoryRoot -Worktree $Worktree
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            New-Item -ItemType Junction -Path $destination -Target $source | Out-Null
            $created.Add([pscustomobject]@{ relative = $relative; path = $destination; target = $source })
        }
    } catch {
        $createdRecords = @($created.ToArray())
        [Array]::Reverse($createdRecords)
        foreach ($createdRecord in $createdRecords) {
            $createdPath = [string]$createdRecord.path
            if (Test-Path -LiteralPath $createdPath) {
                $createdItem = Get-Item -LiteralPath $createdPath -Force
                if (($createdItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    if ($createdItem.PSIsContainer) { [IO.Directory]::Delete($createdPath, $false) } else { [IO.File]::Delete($createdPath) }
                }
            }
        }
        throw
    }
    return @($created.ToArray())
}

function Resolve-PreviewCommand {
    param($Definition, [string]$Label, [hashtable]$Values)

    $command = [string](Get-FactoryNestedValue -Target $Definition -Name "command" -Default "")
    if (-not $command) { throw "preview.$Label.command is required." }
    $resolved = Get-Command $command -ErrorAction Stop
    $path = if ([string]$resolved.Source) { [string]$resolved.Source } else { [string]$resolved.Path }
    if (-not $path) { throw "Could not resolve preview $Label command '$command'." }
    return [pscustomobject]@{
        command = $path
        arguments = @((Get-FactoryNestedValue -Target $Definition -Name "arguments" -Default @()) | ForEach-Object {
            Expand-PreviewTemplate -Value ([string]$_) -Values $Values
        })
    }
}

function Start-PreviewService {
    param([string]$Name, $Command, [string]$Worktree, [string]$ArtifactRoot, [hashtable]$Environment)

    $stdoutPath = Join-Path $ArtifactRoot "$Name.stdout.log"
    $stderrPath = Join-Path $ArtifactRoot "$Name.stderr.log"
    $definitionPath = Join-Path $ArtifactRoot "$Name.definition.json"
    [IO.File]::WriteAllText($stdoutPath, "", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($stderrPath, "", (New-Object Text.UTF8Encoding($false)))
    Write-FactoryJsonAtomic -Path $definitionPath -Value ([ordered]@{
        command = [string]$Command.command
        arguments = @($Command.arguments)
        workingDirectory = $Worktree
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        environment = $Environment
    })
    $argumentLine = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "factory-preview-service.ps1"),
        "-DefinitionPath", $definitionPath
    ) | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }
    $process = Start-Process `
        -FilePath (Get-Command powershell -ErrorAction Stop).Source `
        -ArgumentList ($argumentLine -join " ") `
        -WorkingDirectory $Worktree `
        -WindowStyle Hidden `
        -PassThru
    return [pscustomobject]@{
        pid = $process.Id
        processStartTimeUtc = $process.StartTime.ToUniversalTime().ToString("o")
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        definitionPath = $definitionPath
    }
}

function Get-PreviewLogTail {
    param($Preview)

    $parts = New-Object Collections.Generic.List[string]
    foreach ($serviceName in @("app", "assets")) {
        $service = Get-PreviewProperty -InputObject $Preview -Name $serviceName
        $stderrPath = [string](Get-PreviewProperty -InputObject $service -Name "stderrPath" -Default "")
        if ($stderrPath -and (Test-Path -LiteralPath $stderrPath -PathType Leaf)) {
            $tail = @([IO.File]::ReadAllLines($stderrPath) | Select-Object -Last 5) -join " | "
            if ($tail) { $parts.Add("$serviceName`: $tail") }
        }
    }
    return ($parts -join "; ")
}

function Start-TaskPreview {
    param([string]$RequestedTaskId)

    if (-not [bool](Get-FactoryNestedValue -Target $previewConfig -Name "enabled" -Default $false)) {
        throw "Browser preview is disabled in the private project config."
    }
    if (-not $RequestedTaskId) { throw "Preview start requires a task ID." }
    $hostName = [string](Get-FactoryNestedValue -Target $previewConfig -Name "host" -Default "127.0.0.1")
    if ($hostName -ne "127.0.0.1") {
        throw "Preview host must be 127.0.0.1; refusing to expose a worker application on '$hostName'."
    }

    $current = Get-PreviewSnapshot
    if ($null -ne $current -and [string]$current.taskId -eq $RequestedTaskId -and [bool]$current.running) {
        $browserWarning = $null
        $browserOpened = $false
        if (-not $NoOpen -and [bool](Get-FactoryNestedValue -Target $previewConfig -Name "openBrowser" -Default $true)) {
            try { Start-Process ([string]$current.url); $browserOpened = $true } catch { $browserWarning = $_.Exception.Message }
        }
        Set-FactoryProperty -Target $current -Name "reused" -Value $true
        Set-FactoryProperty -Target $current -Name "browserOpened" -Value $browserOpened
        Set-FactoryProperty -Target $current -Name "browserWarning" -Value $browserWarning
        return $current
    }

    $state = Read-FactoryJson -Path ([string]$context.statePath)
    $task = Get-FactoryTask -State $state -TaskId $RequestedTaskId
    $worktree = [string](Get-PreviewProperty -InputObject $task -Name "worktree" -Default "")
    if (-not $worktree -or -not (Test-Path -LiteralPath $worktree -PathType Container)) {
        throw "Task '$RequestedTaskId' has no existing worker worktree to preview."
    }
    $worktree = [IO.Path]::GetFullPath($worktree)
    if (-not (Test-PreviewPathInsideRoot -Path $worktree -Root ([string]$context.worktreeRoot))) {
        throw "Task '$RequestedTaskId' worktree is outside the factory worktree root."
    }
    if ([string]$task.status -in @("approved", "integrating", "production", "done")) {
        throw "Task '$RequestedTaskId' is '$($task.status)' and its worktree may be integrating or already removed. Preview it before approval."
    }

    $switchedFrom = if ($null -ne $current) { [string]$current.taskId } else { "" }
    if ($null -ne $current) { $null = Stop-CurrentPreview }

    $appPort = Get-PreviewFreePort `
        -HostName $hostName `
        -Start ([int](Get-FactoryNestedValue -Target $previewConfig -Name "appPortStart" -Default 18000)) `
        -End ([int](Get-FactoryNestedValue -Target $previewConfig -Name "appPortEnd" -Default 18999))
    $assetPort = Get-PreviewFreePort `
        -HostName $hostName `
        -Start ([int](Get-FactoryNestedValue -Target $previewConfig -Name "assetPortStart" -Default 19000)) `
        -End ([int](Get-FactoryNestedValue -Target $previewConfig -Name "assetPortEnd" -Default 19999)) `
        -Excluded @($appPort)
    $values = @{
        host = $hostName
        appPort = $appPort
        assetPort = $assetPort
        taskId = $RequestedTaskId
        worktree = $worktree
        repository = [string]$context.repositoryRoot
    }
    $url = Expand-PreviewTemplate `
        -Value ([string](Get-FactoryNestedValue -Target $previewConfig -Name "urlTemplate" -Default "http://{host}:{appPort}")) `
        -Values $values
    $artifactRoot = Join-Path $previewRoot (ConvertTo-FactoryTaskArtifactName -TaskId $RequestedTaskId)
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
    $createdLinks = @()
    $preview = [pscustomobject][ordered]@{
        version = 1
        status = "starting"
        projectKey = [string]$context.projectKey
        taskId = $RequestedTaskId
        title = [string](Get-PreviewProperty -InputObject $task -Name "title" -Default "Untitled task")
        taskStatus = [string]$task.status
        worktree = $worktree
        url = $url
        host = $hostName
        appPort = $appPort
        assetPort = $assetPort
        startedAt = Get-FactoryUtcTimestamp
        app = $null
        assets = $null
        createdDependencyLinks = @()
        artifactRoot = $artifactRoot
        switchedFrom = if ($switchedFrom) { $switchedFrom } else { $null }
    }
    Write-FactoryJsonAtomic -Path $previewPath -Value $preview
    try {
        $createdLinks = @(New-PreviewDependencyLinks -RepositoryRoot ([string]$context.repositoryRoot) -Worktree $worktree)
        Set-FactoryProperty -Target $preview -Name "createdDependencyLinks" -Value $createdLinks
        Write-FactoryJsonAtomic -Path $previewPath -Value $preview

        $appCommand = Resolve-PreviewCommand -Definition (Get-FactoryNestedValue -Target $previewConfig -Name "app") -Label "app" -Values $values
        $assetCommand = Resolve-PreviewCommand -Definition (Get-FactoryNestedValue -Target $previewConfig -Name "assets") -Label "assets" -Values $values
        $sessionCookie = "factory_preview_" + (ConvertTo-FactorySafeName -Value $RequestedTaskId -Fallback "task")
        $appEnvironment = @{
            APP_URL = $url
            SESSION_COOKIE = $sessionCookie
        }
        $appProcess = Start-PreviewService -Name "app" -Command $appCommand -Worktree $worktree -ArtifactRoot $artifactRoot -Environment $appEnvironment
        Set-FactoryProperty -Target $preview -Name "app" -Value $appProcess
        Write-FactoryJsonAtomic -Path $previewPath -Value $preview

        $assetProcess = Start-PreviewService -Name "assets" -Command $assetCommand -Worktree $worktree -ArtifactRoot $artifactRoot -Environment @{}
        Set-FactoryProperty -Target $preview -Name "assets" -Value $assetProcess
        Write-FactoryJsonAtomic -Path $previewPath -Value $preview

        $timeoutSeconds = [int](Get-FactoryNestedValue -Target $previewConfig -Name "startupTimeoutSeconds" -Default 30)
        if ($timeoutSeconds -lt 1 -or $timeoutSeconds -gt 300) { throw "preview.startupTimeoutSeconds must be between 1 and 300." }
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
        do {
            $appReady = Test-PreviewPortOpen -HostName $hostName -Port $appPort
            $assetsReady = Test-PreviewPortOpen -HostName $hostName -Port $assetPort
            if ($appReady -and $assetsReady) { break }
            if (-not (Test-PreviewProcess -Record $preview.app) -or -not (Test-PreviewProcess -Record $preview.assets)) {
                $tail = Get-PreviewLogTail -Preview $preview
                $detail = if ($tail) { " $tail" } else { "" }
                throw "A preview process exited during startup.$detail"
            }
            Start-Sleep -Milliseconds 200
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $appReady -or -not $assetsReady) {
            $tail = Get-PreviewLogTail -Preview $preview
            $detail = if ($tail) { " $tail" } else { "" }
            throw "Preview ports did not become ready within $timeoutSeconds seconds.$detail"
        }

        Set-FactoryProperty -Target $preview -Name "status" -Value "running"
        Set-FactoryProperty -Target $preview -Name "running" -Value $true
        Set-FactoryProperty -Target $preview -Name "appLive" -Value $true
        Set-FactoryProperty -Target $preview -Name "assetsLive" -Value $true
        Set-FactoryProperty -Target $preview -Name "readyAt" -Value (Get-FactoryUtcTimestamp)
        $browserWarning = $null
        $browserOpened = $false
        if (-not $NoOpen -and [bool](Get-FactoryNestedValue -Target $previewConfig -Name "openBrowser" -Default $true)) {
            try { Start-Process $url; $browserOpened = $true } catch { $browserWarning = $_.Exception.Message }
        }
        Set-FactoryProperty -Target $preview -Name "browserOpened" -Value $browserOpened
        Set-FactoryProperty -Target $preview -Name "browserWarning" -Value $browserWarning
        Set-FactoryProperty -Target $preview -Name "reused" -Value $false
        Write-FactoryJsonAtomic -Path $previewPath -Value $preview
        return $preview
    } catch {
        $failure = $_.Exception.Message
        try { $null = Stop-CurrentPreview } catch {}
        throw $failure
    }
}

$previewMutex = $null
try {
    $previewMutex = Enter-FactoryMutex -ProjectKey "$([string]$context.projectKey)-preview"
    switch ($Action) {
        "status" {
            $snapshot = Get-PreviewSnapshot
            if ($null -eq $snapshot) {
                [ordered]@{ running = $false; exists = $false; projectKey = [string]$context.projectKey } | ConvertTo-Json -Depth 20
                break
            }
            if (-not [bool]$snapshot.appLive -and -not [bool]$snapshot.assetsLive) {
                $stale = Stop-CurrentPreview
                [ordered]@{
                    running = $false
                    exists = $false
                    staleCleaned = $true
                    previousTaskId = [string]$stale.taskId
                    projectKey = [string]$context.projectKey
                } | ConvertTo-Json -Depth 20
                break
            }
            Set-FactoryProperty -Target $snapshot -Name "exists" -Value $true
            $snapshot | ConvertTo-Json -Depth 30
        }
        "start" { Start-TaskPreview -RequestedTaskId $TaskId | ConvertTo-Json -Depth 30 }
        "stop" { Stop-CurrentPreview -ExpectedTaskId $TaskId | ConvertTo-Json -Depth 30 }
    }
} finally {
    Exit-FactoryMutex -Mutex $previewMutex
}
