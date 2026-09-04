[CmdletBinding(DefaultParameterSetName = "Request")]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true, ParameterSetName = "Request")][string]$RequestPath,
    [Parameter(Mandatory = $true, ParameterSetName = "File")][string]$IntakePath,
    [Parameter(Mandatory = $true, ParameterSetName = "Local")][AllowEmptyString()][string]$LocalText,
    [Parameter(ParameterSetName = "Local")][ValidateSet("interactive", "auto")][string]$StartMode = "interactive",
    [string]$ClaudeCommand = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "factory-common.ps1")
if (-not $ClaudeCommand) {
    $ClaudeCommand = if ($env:CLAUDE_FACTORY_CLAUDE_COMMAND) { $env:CLAUDE_FACTORY_CLAUDE_COMMAND } else { "claude" }
}

function Test-IntakePathInsideRoot {
    param([string]$Path, [string]$Root)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $fullPath.StartsWith(
        $fullRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-NormalizedIntakeArray {
    param($InputObject, [string]$Name)

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Normalized intake is missing '$Name'." }
    if ($property.Value -is [string] -or $null -eq $property.Value) {
        throw "Normalized intake '$Name' must be an array."
    }
    $items = @($property.Value)
    if ($items.Count -gt 50) { throw "Normalized intake '$Name' may contain at most 50 entries." }
    $result = New-Object Collections.Generic.List[string]
    foreach ($item in $items) {
        $text = ([string]$item).Trim()
        if (-not $text -or $text.Length -gt 4000) {
            throw "Every normalized intake '$Name' entry must contain 1-4000 characters."
        }
        $result.Add($text)
    }
    return $result.ToArray()
}

function Resolve-NormalizedSource {
    param($Source)

    if ($null -eq $Source -or $Source -isnot [PSCustomObject]) {
        throw "Normalized intake source must be an object."
    }
    $allowed = @("adapter", "id", "url", "suppliedUrl")
    foreach ($property in $Source.PSObject.Properties) {
        if ($property.Name -notin $allowed) {
            throw "Normalized intake source contains unsupported property '$($property.Name)'."
        }
    }
    foreach ($required in @("adapter", "id", "url")) {
        if ($null -eq $Source.PSObject.Properties[$required] -or -not [string]$Source.$required) {
            throw "Normalized intake source is missing '$required'."
        }
    }
    $adapter = ([string]$Source.adapter).Trim().ToLowerInvariant()
    $sourceId = ([string]$Source.id).Trim()
    $sourceUrl = ([string]$Source.url).Trim()
    $suppliedUrl = ([string](Get-FactoryNestedValue -Target $Source -Name "suppliedUrl" -Default $sourceUrl)).Trim()
    if ($adapter -notmatch '^[a-z][a-z0-9-]{0,49}$') { throw "Invalid intake adapter '$adapter'." }
    if (-not $sourceId -or $sourceId.Length -gt 200) { throw "Intake source ID must contain 1-200 characters." }
    if ($sourceUrl.Length -gt 2000 -or $suppliedUrl.Length -gt 2000) { throw "Intake source URL may contain at most 2000 characters." }

    if ($adapter -eq "asana") {
        $resolved = Resolve-FactoryAsanaTaskUrl -Url $sourceUrl
        if ([string]$resolved.taskId -ne $sourceId) {
            throw "Asana intake source ID '$sourceId' does not match URL task '$($resolved.taskId)'."
        }
        $stateId = $sourceId
        $canonicalUrl = [string]$resolved.canonicalUrl
    } elseif ($adapter -eq "local") {
        if ($sourceId -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$') {
            throw "Invalid native local task ID '$sourceId'."
        }
        $expectedUrl = "factory://local/$sourceId"
        if ($sourceUrl -ne $expectedUrl) {
            throw "Local intake URL does not match its native task ID."
        }
        $stateId = "local`:$sourceId"
        $canonicalUrl = $expectedUrl
    } else {
        $uri = $null
        if (-not [Uri]::TryCreate($sourceUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @("http", "https") -or $uri.UserInfo) {
            throw "Intake source URL must be an absolute HTTP(S) URL without credentials."
        }
        $stateId = "$adapter`:$sourceId"
        $canonicalUrl = $sourceUrl.TrimEnd('/')
    }
    return [pscustomobject]@{
        adapter = $adapter
        sourceId = $sourceId
        stateId = $stateId
        canonicalUrl = $canonicalUrl
        suppliedUrl = $suppliedUrl
    }
}

function Test-TaskMatchesSource {
    param($Task, $Identity)

    if ([string]$Task.id -eq [string]$Identity.stateId -or [string]$Task.url -eq [string]$Identity.canonicalUrl) { return $true }
    $taskSource = Get-FactoryNestedValue -Target $Task -Name "source"
    if ($null -eq $taskSource) { return $false }
    return [string](Get-FactoryNestedValue -Target $taskSource -Name "adapter" -Default "") -eq [string]$Identity.adapter -and
        [string](Get-FactoryNestedValue -Target $taskSource -Name "id" -Default "") -eq [string]$Identity.sourceId
}

function Remove-ConsumedIntakeFiles {
    param([string[]]$Paths)

    foreach ($path in @($Paths | Select-Object -Unique)) {
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize) |
    ConvertFrom-Json
$request = $null
$consumePaths = @()
if ($PSCmdlet.ParameterSetName -eq "Local") {
    $localTextValue = $LocalText.Trim()
    if ($StartMode -eq "auto" -and -not $localTextValue) {
        throw "An automatic local task requires non-empty text."
    }
    $localId = "{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
    $localTitle = "Untitled local task"
    $localBrief = "No requirements were supplied. Ask the user what they want implemented and wait for their answer before editing files."
    $localNotes = @("Created as an intentionally empty interactive worker.")
    if ($localTextValue) {
        $firstLine = @($localTextValue -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })[0]
        $localTitle = ($firstLine -replace '\s+', ' ').Trim()
        if ($localTitle.Length -gt 120) { $localTitle = $localTitle.Substring(0, 117).TrimEnd() + "..." }
        $localBrief = $localTextValue
        $localNotes = @("Created from operator-provided local text.")
    }
    $localUrl = "factory://local/$localId"
    $normalized = [pscustomobject][ordered]@{
        version = 1
        source = [pscustomobject][ordered]@{
            adapter = "local"
            id = $localId
            url = $localUrl
            suppliedUrl = $null
        }
        startMode = $StartMode
        title = $localTitle
        brief = $localBrief
        acceptanceCriteria = @()
        sourceNotes = @($localNotes)
        sourceError = $null
    }
    $resolvedIntakePath = $null
} elseif ($PSCmdlet.ParameterSetName -eq "Request") {
    $resolvedRequestPath = [IO.Path]::GetFullPath($RequestPath)
    if (-not (Test-IntakePathInsideRoot -Path $resolvedRequestPath -Root ([string]$context.sessionsPath))) {
        throw "Intake request must be inside '$($context.sessionsPath)'."
    }
    if (-not (Test-Path -LiteralPath $resolvedRequestPath -PathType Leaf)) {
        throw "Intake request does not exist: $resolvedRequestPath"
    }
    $request = Read-FactoryJson -Path $resolvedRequestPath
    if (
        [int](Get-FactoryNestedValue -Target $request -Name "version" -Default 0) -ne 1 -or
        [string]$request.source -ne "asana" -or
        [string]$request.requestId -notmatch '^[0-9a-f]{32}$'
    ) {
        throw "Unsupported intake request."
    }
    $resolvedAsanaRequest = Resolve-FactoryAsanaTaskUrl -Url ([string]$request.suppliedUrl)
    if ([string]$resolvedAsanaRequest.taskId -ne [string]$request.taskId -or [string]$resolvedAsanaRequest.canonicalUrl -ne [string]$request.canonicalUrl) {
        throw "Intake request identity does not match its supplied Asana URL."
    }
    $resolvedIntakePath = [IO.Path]::GetFullPath([string]$request.normalizationPath)
    if (-not (Test-IntakePathInsideRoot -Path $resolvedIntakePath -Root ([string]$context.sessionsPath))) {
        throw "Normalized intake must be inside '$($context.sessionsPath)'."
    }
    $consumePaths = @($resolvedRequestPath, $resolvedIntakePath)
} else {
    $resolvedIntakePath = [IO.Path]::GetFullPath($IntakePath)
}
if ($PSCmdlet.ParameterSetName -ne "Local") {
    if (-not (Test-Path -LiteralPath $resolvedIntakePath -PathType Leaf)) {
        throw "Normalized intake does not exist: $resolvedIntakePath"
    }
    $normalized = Read-FactoryJson -Path $resolvedIntakePath
}
$allowedProperties = @("version", "source", "startMode", "title", "brief", "acceptanceCriteria", "sourceNotes", "sourceError")
foreach ($property in $normalized.PSObject.Properties) {
    if ($property.Name -notin $allowedProperties) {
        throw "Normalized intake contains unsupported property '$($property.Name)'."
    }
}
foreach ($requiredProperty in $allowedProperties) {
    if ($null -eq $normalized.PSObject.Properties[$requiredProperty]) {
        throw "Normalized intake is missing '$requiredProperty'."
    }
}
if ([int]$normalized.version -ne 1) { throw "Unsupported normalized intake version '$($normalized.version)'." }
if ([string]$normalized.startMode -notin @("interactive", "auto")) { throw "Invalid intake start mode." }
$identity = Resolve-NormalizedSource -Source $normalized.source
if ([string]$identity.adapter -eq "local" -and $PSCmdlet.ParameterSetName -ne "Local") {
    throw "The local source adapter is reserved for native 'factory new' tasks."
}
if ($null -ne $request) {
    if (
        [string]$identity.adapter -ne "asana" -or
        [string]$identity.sourceId -ne [string]$request.taskId -or
        [string]$identity.canonicalUrl -ne [string]$request.canonicalUrl -or
        [string]$normalized.startMode -ne [string]$request.startMode
    ) {
        throw "AI-normalized intake changed the native request identity or start mode."
    }
}

$title = ([string]$normalized.title).Trim()
$brief = ([string]$normalized.brief).Trim()
$sourceError = ([string]$normalized.sourceError).Trim()
if ($title.Length -gt 500) { throw "Normalized intake title may contain at most 500 characters." }
if ($brief.Length -gt 20000) { throw "Normalized intake brief may contain at most 20000 characters." }
if ($sourceError.Length -gt 4000) { throw "Normalized intake sourceError may contain at most 4000 characters." }
$acceptanceCriteria = @(Get-NormalizedIntakeArray -InputObject $normalized -Name "acceptanceCriteria")
$sourceNotes = @(Get-NormalizedIntakeArray -InputObject $normalized -Name "sourceNotes")
if (-not $sourceError -and (-not $title -or -not $brief)) {
    throw "Successful normalized intake requires non-empty title and brief."
}
if ($sourceError) {
    if (-not $title) { $title = "$($identity.adapter) task $($identity.sourceId)" }
    if (-not $brief) { $brief = $sourceError }
}

$mutex = $null
$task = $null
$duplicate = $false
try {
    $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
    $state = Read-FactoryJson -Path ([string]$context.statePath)
    $matches = @($state.tasks | Where-Object { Test-TaskMatchesSource -Task $_ -Identity $identity })
    if ($matches.Count -gt 0) {
        $task = $matches[0]
        $duplicate = $true
    } else {
        $now = Get-FactoryUtcTimestamp
        $task = [pscustomobject][ordered]@{
            id = [string]$identity.stateId
            url = [string]$identity.canonicalUrl
            title = $title
            brief = $brief
            acceptanceCriteria = @($acceptanceCriteria)
            sourceNotes = @($sourceNotes)
            source = [pscustomobject]@{
                adapter = [string]$identity.adapter
                id = [string]$identity.sourceId
                suppliedUrl = [string]$identity.suppliedUrl
                normalizedAt = $now
            }
            startMode = [string]$normalized.startMode
            status = if ($sourceError) { "blocked" } else { "queued" }
            attempts = 0
            attemptPrepared = $false
            launchStartedAt = $null
            launchCompletedAt = $null
            launchFailedAt = $null
            launchProcessId = $null
            launchProcessStartTimeUtc = $null
            agentId = $null
            backgroundSession = $null
            branch = $null
            commit = $null
            worktree = $null
            plan = $null
            workerResult = $null
            review = $null
            approval = $null
            syncPreparation = $null
            integration = $null
            production = $null
            rejectionReason = $null
            rejectedAt = $null
            reworkRequestedAt = $null
            planRecordedAt = $null
            resultRecordedAt = $null
            pendingInstructions = $null
            holdReason = $null
            answerHash = $null
            testDatabase = $null
            error = if ($sourceError) { $sourceError } else { $null }
            createdAt = $now
            updatedAt = $now
        }
        $state.tasks = @($state.tasks) + @($task)
        if (-not $sourceError) {
            Set-FactoryProperty -Target $state -Name "active" -Value $true
            Set-FactoryProperty -Target $state -Name "paused" -Value $false
        }
        Set-FactoryProperty -Target $state -Name "updatedAt" -Value $now
        Write-FactoryJsonAtomic -Path ([string]$context.statePath) -Value $state
    }
} finally {
    Exit-FactoryMutex -Mutex $mutex
}

if ($consumePaths.Count -gt 0) { Remove-ConsumedIntakeFiles -Paths $consumePaths }
$scheduler = $null
$schedulerError = $null
if (-not $duplicate -and [string]$task.status -eq "queued") {
    $schedulerRun = Invoke-FactoryNativeProcess -Command "powershell" -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "factory-scheduler.ps1"),
        "-Action", "resume",
        "-Repository", [string]$context.repositoryRoot,
        "-ClaudeCommand", $ClaudeCommand,
        "-RuntimeHome", [string]$context.runtimeHome
    )
    if ([int]$schedulerRun.exitCode -eq 0 -and [string]$schedulerRun.stdout) {
        try { $scheduler = [string]$schedulerRun.stdout | ConvertFrom-Json } catch { $schedulerError = "Scheduler returned invalid JSON." }
    } else {
        $schedulerError = if ([string]$schedulerRun.output) { [string]$schedulerRun.output } else { "Scheduler exited with code $($schedulerRun.exitCode)." }
    }
}

$taskSource = Get-FactoryNestedValue -Target $task -Name "source"
[ordered]@{
    taskId = [string]$task.id
    sourceAdapter = [string](Get-FactoryNestedValue -Target $taskSource -Name "adapter" -Default "asana")
    sourceId = [string](Get-FactoryNestedValue -Target $taskSource -Name "id" -Default ([string]$task.id))
    url = [string]$task.url
    title = [string]$task.title
    mode = [string]$task.startMode
    status = [string]$task.status
    duplicate = $duplicate
    queued = [string]$task.status -eq "queued"
    sourceError = if ([string]$task.error) { [string]$task.error } else { $null }
    scheduler = $scheduler
    schedulerError = $schedulerError
} | ConvertTo-Json -Depth 40
