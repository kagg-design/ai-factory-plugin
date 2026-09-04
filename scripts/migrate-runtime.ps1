[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$RuntimeHome = "",
    [string]$DestinationRuntimeHome = "",
    [string]$ClaudeCommand = "claude"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
if ($RuntimeHome) { $env:CLAUDE_FACTORY_HOME = [IO.Path]::GetFullPath($RuntimeHome) }

$contextText = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository | Out-String).Trim()
if (-not $contextText) { throw "Factory project context returned no data." }
$context = $contextText | ConvertFrom-Json
$sourceRoot = [IO.Path]::GetFullPath([string]$context.projectData).TrimEnd('\', '/')
$destinationHome = if ($DestinationRuntimeHome) {
    [IO.Path]::GetFullPath($DestinationRuntimeHome).TrimEnd('\', '/')
} else {
    [IO.Path]::GetFullPath([string]$context.recommendedRuntimeHome).TrimEnd('\', '/')
}
$destinationProjects = Join-Path $destinationHome "projects"
$destinationRoot = Join-Path $destinationProjects ([string]$context.projectKey)
$pluginRoot = [IO.Path]::GetFullPath([string]$context.pluginRoot).TrimEnd('\', '/')
$sourceProjects = [IO.Path]::GetFullPath((Join-Path ([string]$context.runtimeHome) "projects")).TrimEnd('\', '/')

if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Factory runtime does not exist: '$sourceRoot'."
}
if (-not (Test-FactoryPathWithin -Path $sourceRoot -Parent $sourceProjects)) {
    throw "Source project runtime '$sourceRoot' is not below '$sourceProjects'."
}
if (Test-FactorySamePath -Left $sourceRoot -Right $destinationRoot) {
    [ordered]@{
        migrated = $false; alreadyExternal = $true; projectKey = [string]$context.projectKey
        source = $sourceRoot; destination = $destinationRoot; sourceRetained = $true
        selectionWillUseDestination = $true
    } | ConvertTo-Json -Depth 10
    exit 0
}
if ((Test-FactorySamePath -Left $destinationHome -Right $pluginRoot) -or (Test-FactoryPathWithin -Path $destinationHome -Parent $pluginRoot)) {
    throw "Destination runtime must be outside the plugin checkout: '$destinationHome'."
}
if (
    (Test-FactoryPathWithin -Path $destinationRoot -Parent $sourceRoot) -or
    (Test-FactoryPathWithin -Path $sourceRoot -Parent $destinationRoot)
) {
    throw "Source and destination runtime trees must not contain one another."
}
$destinationDriveRoot = [IO.Path]::GetPathRoot($destinationHome).TrimEnd('\', '/')
if ($destinationHome.Equals($destinationDriveRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Destination runtime home must not be a filesystem root: '$destinationHome'."
}
if (Test-Path -LiteralPath $destinationRoot) {
    throw "Destination runtime already exists: '$destinationRoot'. Refusing to merge or overwrite runtime trees."
}

function Test-RuntimeMutexHeld {
    param([Parameter(Mandatory = $true)][string]$Name)

    $probe = New-Object Threading.Mutex($false, $Name)
    $acquired = $false
    try {
        try {
            $acquired = $probe.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if ($acquired) {
            try { $probe.ReleaseMutex() } catch {}
            return $false
        }
        return $true
    } finally {
        $probe.Dispose()
    }
}

$safeProjectKey = ([string]$context.projectKey) -replace '[^A-Za-z0-9_.-]', '-'
if (Test-RuntimeMutexHeld -Name "Local\ClaudeFactorySession-$safeProjectKey") {
    throw "Exit the active factory orchestrator before runtime migration, then run the command from PowerShell."
}
if (Test-RuntimeMutexHeld -Name "Local\ClaudeFactoryNativeScheduler-$safeProjectKey") {
    throw "Stop the native scheduler before runtime migration: factory scheduler stop"
}

$state = Read-FactoryJson -Path ([string]$context.statePath)
$config = Read-FactoryJson -Path ([string]$context.configPath)
$claudeRows = @()
try {
    $claudeRows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
} catch {
    $claudeStatePresent = (
        [string](Get-FactoryNestedValue -Target $config -Name "workerAgent" -Default "claude") -eq "claude" -or
        (Test-Path -LiteralPath (Join-Path $sourceRoot "orchestrator-session.json") -PathType Leaf) -or
        @($state.tasks | Where-Object {
            $session = Get-FactoryNestedValue -Target $_ -Name "backgroundSession"
            $null -ne $session -and [string](Get-FactoryNestedValue -Target $session -Name "runtime" -Default "claude") -eq "claude"
        }).Count -gt 0
    )
    if ($claudeStatePresent) {
        throw "Cannot verify that Claude factory sessions are stopped: $($_.Exception.Message)"
    }
}
$liveClaudeRows = @(
    $claudeRows | Where-Object {
        if (Test-FactoryTerminalAgentRow -Row $_) { return $false }
        $kind = [string](Get-FactoryNestedValue -Target $_ -Name "kind" -Default "")
        if ($kind -ne "background") { return $false }
        $rowName = [string](Get-FactoryNestedValue -Target $_ -Name "name" -Default "")
        $rowCwd = [string](Get-FactoryNestedValue -Target $_ -Name "cwd" -Default "")
        $isOrchestrator = $rowName -ceq "Claude Factory Orchestrator" -and $rowCwd -and
            (Test-FactorySamePath -Left $rowCwd -Right ([string]$context.repositoryRoot))
        $isWorker = $rowCwd -and (Test-FactoryPathWithin -Path $rowCwd -Parent ([string]$context.worktreeRoot))
        return $isOrchestrator -or $isWorker
    }
)
if ($liveClaudeRows.Count -gt 0) {
    $sessionDetails = @($liveClaudeRows | ForEach-Object {
        $rowId = [string](Get-FactoryNestedValue -Target $_ -Name "id" -Default "unknown")
        $rowState = [string](Get-FactoryNestedValue -Target $_ -Name "state" -Default (
            Get-FactoryNestedValue -Target $_ -Name "status" -Default "unknown"
        ))
        $rowName = [string](Get-FactoryNestedValue -Target $_ -Name "name" -Default "unnamed")
        "$rowId ($rowState, $rowName)"
    }) -join "; "
    $stopCommands = @($liveClaudeRows | ForEach-Object {
        "claude stop $([string](Get-FactoryNestedValue -Target $_ -Name 'id' -Default ''))"
    }) -join "; "
    throw "Runtime migration requires all Claude factory sessions to be stopped. Live sessions: $sessionDetails. Stop commands: $stopCommands"
}
$scheduler = Get-FactoryNestedValue -Target $state -Name "scheduler"
if (Test-FactoryRecordedProcess -ProcessRecord $scheduler) {
    throw "Stop the native scheduler before runtime migration: factory scheduler stop"
}
$activeTasks = @($state.tasks | Where-Object {
    [string](Get-FactoryNestedValue -Target $_ -Name "status" -Default "") -in @("starting", "planning", "awaiting-input", "running", "integrating", "production") -or
    (Test-FactoryTaskHasActiveSession -Task $_)
})
if ($activeTasks.Count -gt 0) {
    throw "Runtime migration requires no live workers or publication tasks. Still active: $(@($activeTasks | ForEach-Object { [string]$_.id }) -join ', ')."
}
if (Test-Path -LiteralPath ([string]$context.testLeasePath) -PathType Leaf) {
    $lease = Read-FactoryJson -Path ([string]$context.testLeasePath)
    if ($null -ne (Get-FactoryNestedValue -Target $lease -Name "holder")) {
        throw "Runtime migration requires a free test lane. Release or reclaim its holder first."
    }
}
if (Test-Path -LiteralPath ([string]$context.previewPath) -PathType Leaf) {
    try {
        $preview = Read-FactoryJson -Path ([string]$context.previewPath)
        $previewProcesses = @(
            (Get-FactoryNestedValue -Target $preview -Name "app")
            (Get-FactoryNestedValue -Target $preview -Name "assets")
        )
        foreach ($processRecord in $previewProcesses) {
            if (Test-FactoryRecordedProcess -ProcessRecord $processRecord) {
                throw "Stop the browser preview before runtime migration: factory preview stop"
            }
        }
    } catch {
        if ($_.Exception.Message -match "Stop the browser preview") { throw }
    }
}

function Get-RuntimeInventory {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object {
            $relative = $_.FullName.Substring($rootPrefix.Length).Replace('\', '/')
            [pscustomobject]@{
                path = $relative
                length = [long]$_.Length
                sha256 = [string](Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        } | Sort-Object path
    )
}

$temporaryRoot = Join-Path $destinationProjects (".migrating-$([string]$context.projectKey)-$([Guid]::NewGuid().ToString('N'))")
try {
    New-Item -ItemType Directory -Path $destinationProjects -Force | Out-Null
    Copy-Item -LiteralPath $sourceRoot -Destination $temporaryRoot -Recurse
    $sourceInventory = @(Get-RuntimeInventory -Root $sourceRoot)
    $destinationInventory = @(Get-RuntimeInventory -Root $temporaryRoot)
    if ($sourceInventory.Count -ne $destinationInventory.Count) {
        throw "Runtime copy verification failed: source has $($sourceInventory.Count) file(s), destination has $($destinationInventory.Count)."
    }
    for ($index = 0; $index -lt $sourceInventory.Count; $index++) {
        $left = $sourceInventory[$index]
        $right = $destinationInventory[$index]
        if ([string]$left.path -ne [string]$right.path -or [long]$left.length -ne [long]$right.length -or [string]$left.sha256 -ne [string]$right.sha256) {
            throw "Runtime copy verification failed at '$([string]$left.path)'."
        }
    }
    Move-Item -LiteralPath $temporaryRoot -Destination $destinationRoot
    $temporaryRoot = $null
    $receipt = [ordered]@{
        version = 1
        migratedAt = Get-FactoryUtcTimestamp
        projectKey = [string]$context.projectKey
        repository = [string]$context.repositoryRoot
        source = $sourceRoot
        destination = $destinationRoot
        files = $sourceInventory.Count
        bytes = [long](($sourceInventory | Measure-Object -Property length -Sum).Sum)
        sourceRetained = $true
    }
    Write-FactoryJsonAtomic -Path (Join-Path $destinationRoot "runtime-migration.json") -Value $receipt
    $explicitOverride = [string]$context.runtimeSource -eq "explicit"
    [ordered]@{
        migrated = $true
        alreadyExternal = $false
        projectKey = [string]$context.projectKey
        source = $sourceRoot
        destination = $destinationRoot
        files = $sourceInventory.Count
        bytes = [long]$receipt.bytes
        verified = $true
        sourceRetained = $true
        selectionWillUseDestination = (-not $explicitOverride)
        warning = if ($explicitOverride) { "CLAUDE_FACTORY_HOME explicitly selects the source runtime; unset or update it before restarting the factory." } else { $null }
    } | ConvertTo-Json -Depth 10
} finally {
    if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
        $temporaryFull = [IO.Path]::GetFullPath($temporaryRoot)
        if (
            (Test-FactoryPathWithin -Path $temporaryFull -Parent $destinationProjects) -and
            (Split-Path $temporaryFull -Leaf).StartsWith(".migrating-", [StringComparison]::OrdinalIgnoreCase)
        ) {
            Remove-Item -LiteralPath $temporaryFull -Recurse -Force
        }
    }
}
