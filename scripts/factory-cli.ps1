[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Command,
    [string]$Target = "",
    [string[]]$Remaining = @(),
    [switch]$Yes,
    [switch]$Keep,
    [switch]$Force,
    [switch]$New,
    [switch]$ResumeSession,
    [switch]$Continue,
    [string]$Model = "",
    [string]$Agent = "",
    [string]$File = "",
    [switch]$Auto,
    [switch]$Direct,
    [switch]$NoOpen,
    [ValidateRange(1, 1000)][int]$Limit = 50,
    [Parameter(Mandatory = $true)][string]$Repository,
    [string]$ClaudeCommand = "claude",
    [string]$CodexCommand = "",
    [switch]$NoReconcile
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "factory-common.ps1")
. (Join-Path $PSScriptRoot "completed-archive.ps1")
. (Join-Path $PSScriptRoot "orchestrator-session.ps1")
. (Join-Path $PSScriptRoot "codex-runtime.ps1")
. (Join-Path $PSScriptRoot "codex-orchestrator.ps1")

$script:Tree = @{
    Top = [char]0x256D
    Vertical = [char]0x2502
    Branch = [char]0x251C
    Last = [char]0x2514
    Bottom = [char]0x2570
    Horizontal = [char]0x2500
    Arrow = [char]0x2192
}

$script:FactoryStates = @(
    "queued", "starting", "planning", "awaiting-input", "running", "syncing",
    "awaiting-review", "approved", "integrating", "production", "cleaning", "held",
    "rejected", "blocked", "failed", "done"
)
$script:CliExitCode = 0

function Get-CliProperty {
    param($InputObject, [string]$Name, $Default = $null)

    if ($null -eq $InputObject -or $null -eq $InputObject.PSObject.Properties[$Name]) {
        return $Default
    }
    $value = $InputObject.$Name
    if ($null -eq $value) { return $Default }
    return $value
}

function ConvertTo-CliLine {
    param($Value, [string]$Fallback = "")

    if ($null -eq $Value) { return $Fallback }
    $text = [string]$Value
    $mojibakeMarkers = @([char]0x2568, [char]0x2564, [char]0x0393, [char]0x252C)
    if (@($mojibakeMarkers | Where-Object { $text.IndexOf($_) -ge 0 }).Count -gt 0) {
        try {
            $cp437 = [Text.Encoding]::GetEncoding(
                437,
                (New-Object Text.EncoderExceptionFallback),
                (New-Object Text.DecoderExceptionFallback)
            )
            $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
            $text = $strictUtf8.GetString($cp437.GetBytes($text))
        } catch {
            # A genuine Unicode value that merely contains a marker is left alone.
        }
    }
    $line = ($text -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if (-not $line) { return $Fallback }
    return $line
}

function Get-CliShortId {
    param($Value)

    $text = ConvertTo-CliLine -Value $Value
    if ($text.Length -le 8) { return $text }
    return $text.Substring(0, 8)
}

function Format-CliDuration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return "$Seconds s" }
    if ($Seconds -lt 3600) { return "$([Math]::Floor($Seconds / 60)) min" }
    return "$([Math]::Floor($Seconds / 3600)) h $([Math]::Floor(($Seconds % 3600) / 60)) min"
}

function Get-CliShortSummary {
    param($Value, [int]$MaximumLength = 200)

    $text = ConvertTo-CliLine -Value $Value
    if ($text.Length -le $MaximumLength) { return $text }
    $cut = $text.Substring(0, $MaximumLength - 3)
    $lastSpace = $cut.LastIndexOf(' ')
    if ($lastSpace -ge [Math]::Floor($MaximumLength * 0.65)) {
        $cut = $cut.Substring(0, $lastSpace)
    }
    return $cut.TrimEnd() + "..."
}

function Add-CliWrappedLine {
    param(
        [Collections.Generic.List[string]]$Lines,
        [string]$FirstPrefix,
        [string]$ContinuationPrefix,
        [string]$Text,
        [int]$Width = 120
    )

    $remaining = ConvertTo-CliLine -Value $Text
    if (-not $remaining) {
        $Lines.Add($FirstPrefix.TrimEnd())
        return
    }

    $prefix = $FirstPrefix
    while ($remaining) {
        $available = [Math]::Max(24, $Width - $prefix.Length)
        if ($remaining.Length -le $available) {
            $Lines.Add($prefix + $remaining)
            break
        }
        $cut = $remaining.Substring(0, $available)
        $lastSpace = $cut.LastIndexOf(' ')
        if ($lastSpace -lt [Math]::Floor($available * 0.55)) {
            $nextSpace = $remaining.IndexOf(' ', $available)
            if ($nextSpace -lt 0) {
                $Lines.Add($prefix + $remaining)
                break
            }
            $lastSpace = $nextSpace
        }
        $Lines.Add($prefix + $remaining.Substring(0, $lastSpace).TrimEnd())
        $remaining = $remaining.Substring($lastSpace).TrimStart()
        $prefix = $ContinuationPrefix
    }
}

function Get-CliContext {
    $contextText = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $Repository -Initialize | Out-String).Trim()
    if (-not $contextText) { throw "Factory project context returned no data." }
    return $contextText | ConvertFrom-Json
}

function Invoke-CliReconcile {
    param($Context)

    if ($NoReconcile) { return "" }
    try {
        $reconcileArguments = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "reconcile-worker-sessions.ps1"),
            "-Repository", [string]$Context.repositoryRoot, "-ClaudeCommand", $ClaudeCommand
        )
        if ($CodexCommand) { $reconcileArguments += @("-CodexCommand", $CodexCommand) }
        $null = (& powershell @reconcileArguments | Out-String)
        if ($LASTEXITCODE -ne 0) {
            return "Session reconciliation exited with code $LASTEXITCODE; showing saved state."
        }
        return ""
    } catch {
        return "Session reconciliation failed: $($_.Exception.Message); showing saved state."
    }
}

function Get-CliTaskReason {
    param($Task)

    $session = Get-CliProperty -InputObject $Task -Name "backgroundSession"
    $blockedReason = if ((Get-CliEffectiveStatus -Task $Task) -eq "session-blocked") {
        Get-CliProperty -InputObject $session -Name "blockedReason"
    } else { $null }
    foreach ($candidate in @(
        $blockedReason,
        (Get-CliProperty -InputObject $Task -Name "holdReason"),
        (Get-CliProperty -InputObject $Task -Name "error"),
        (Get-CliProperty -InputObject (Get-CliProperty -InputObject $Task -Name "workerResult") -Name "blockingReason"),
        (Get-CliProperty -InputObject $Task -Name "pendingInstructions")
    )) {
        $text = ConvertTo-CliLine -Value $candidate
        if ($text) { return $text }
    }

    if ([string](Get-CliProperty -InputObject $Task -Name "status") -eq "awaiting-input") {
        $plan = Get-CliProperty -InputObject $Task -Name "plan"
        $questions = @(Get-CliProperty -InputObject $plan -Name "questions" -Default @())
        if ($questions.Count -gt 0) {
            return ConvertTo-CliLine -Value $questions[0]
        }
    }
    return ""
}

function Get-CliEffectiveStatus {
    param($Task)

    $status = [string](Get-CliProperty -InputObject $Task -Name "status")
    $session = Get-CliProperty -InputObject $Task -Name "backgroundSession"
    $sessionState = [string](Get-CliProperty -InputObject $session -Name "state")
    if ($sessionState -eq "blocked" -and $status -in @("starting", "planning", "running")) {
        return "session-blocked"
    }
    if ($status -eq "awaiting-review" -and (Test-FactoryTaskHasActiveSession -Task $Task)) {
        return "review-session-active"
    }
    if ($status -eq "awaiting-review" -and (Test-FactoryTaskHasCurrentApprovedReview -Task $Task)) {
        return "awaiting-approval"
    }
    if ($status -eq "cleaning") {
        $cleanup = Get-CliProperty -InputObject $Task -Name "cleanup"
        if (-not (Test-FactoryRecordedProcess -ProcessRecord $cleanup)) {
            return "cleanup-interrupted"
        }
    }
    return $status
}

function Get-CliBlockedSessionAge {
    param($Task)

    $session = Get-CliProperty -InputObject $Task -Name "backgroundSession"
    $blockedAt = Get-CliProperty -InputObject $session -Name "blockedAt"
    $parsed = ConvertFrom-FactoryRoundtripTimestamp -Value $blockedAt
    if (-not [bool]$parsed.success) { return 0 }
    return [Math]::Max(0, [int]([DateTime]::UtcNow - ([DateTime]$parsed.value)).TotalSeconds)
}

function Get-CliSessionInfo {
    param($Task)

    $session = Get-CliProperty -InputObject $Task -Name "backgroundSession"
    if ($null -eq $session) {
        return [pscustomobject]@{ Exists = $false; Runtime = ""; Id = ""; ShortId = ""; Name = ""; State = "none"; AttachCommand = "" }
    }
    $id = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $session -Name "id")
    if (-not $id) {
        $id = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $session -Name "sessionId")
    }
    return [pscustomobject]@{
        Exists = [bool]$id
        Runtime = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $session -Name "runtime") -Fallback "claude"
        Id = $id
        ShortId = Get-CliShortId -Value $id
        Name = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $session -Name "name")
        State = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $session -Name "state") -Fallback "unknown"
        AttachCommand = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $session -Name "attachCommand")
    }
}

function Get-CliTaskSourceInfo {
    param($Task)

    $source = Get-CliProperty -InputObject $Task -Name "source"
    $adapter = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $source -Name "adapter")
    $sourceId = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $source -Name "id")
    $url = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Task -Name "url")
    if (-not $url) { $url = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $source -Name "url") }
    return [pscustomobject]@{
        Adapter = $adapter
        Id = $sourceId
        Url = $url
        IsLocal = $adapter -eq "local"
    }
}

function Get-CliStateText {
    param([string]$Status)

    $text = switch ($Status) {
        "queued" { "queued for automatic start" }
        "starting" { "worker is starting" }
        "planning" { "worker is preparing a plan" }
        "awaiting-input" { "waiting for your answer" }
        "running" { "implementation is running" }
        "syncing" { "rebased result needs validation" }
        "awaiting-review" { "validated commit is ready for review" }
        "review-session-active" { "validated result captured; worker session is still closing" }
        "awaiting-approval" { "approved review is waiting for your go decision" }
        "approved" { "approved commit is queued for integration" }
        "integrating" { "integration into development is running" }
        "production" { "production promotion is running" }
        "cleaning" { "published artifacts are being removed" }
        "cleanup-interrupted" { "cleanup was interrupted and can be resumed" }
        "held" { "retained and on hold" }
        "rejected" { "rejected but retained" }
        "blocked" { "blocked" }
        "session-blocked" { "worker session is blocked" }
        "failed" { "failed" }
        "done" { "completed" }
        default { if ($Status) { $Status } else { "unknown" } }
    }
    return $text
}

function Get-CliStateLabel {
    param([string]$Status)

    $label = switch ($Status) {
        "awaiting-review" { "REVIEW" }
        "review-session-active" { "FINISHING" }
        "awaiting-approval" { "GO" }
        "awaiting-input" { "INPUT" }
        "syncing" { "SYNC" }
        "integrating" { "INTEGRATING" }
        "production" { "PRODUCTION" }
        "cleaning" { "CLEANUP" }
        "cleanup-interrupted" { "CLEANUP INTERRUPTED" }
        "session-blocked" { "SESSION BLOCKED" }
        default { $Status.ToUpperInvariant() }
    }
    return $label
}

function Get-CliGroup {
    param([string]$Status)

    if ($Status -in @("awaiting-input", "syncing", "awaiting-review", "awaiting-approval", "held", "rejected")) { return "Needs your action" }
    if ($Status -in @("starting", "planning", "running", "approved", "integrating", "production", "cleaning")) { return "Working" }
    if ($Status -in @("queued", "review-session-active")) { return "Waiting" }
    if ($Status -in @("blocked", "failed", "session-blocked", "cleanup-interrupted")) { return "Problems" }
    return "Other"
}

function Get-CliNextAction {
    param($Task, $State, $Config)

    $id = [string](Get-CliProperty -InputObject $Task -Name "id")
    $status = [string](Get-CliProperty -InputObject $Task -Name "status")
    $session = Get-CliSessionInfo -Task $Task
    $commit = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Task -Name "commit")
    $workerResult = Get-CliProperty -InputObject $Task -Name "workerResult"
    $resultCommit = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $workerResult -Name "commit")
    $reason = Get-CliTaskReason -Task $Task
    $isMachineHeld = $status -eq "held" -and $reason -match '(?i)background session stopped|without a FACTORY_RESULT|recoverable|launch failed'
    $runtime = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Config -Name "workerAgent") -Fallback "claude"
    $prompt = if ($runtime -eq "codex") { "factory" } else { "/factory" }
    $requiresFreshReview = Test-FactoryTaskRequiresFreshReview -Task $Task
    $reviewSessionActive = $status -eq "awaiting-review" -and (Test-FactoryTaskHasActiveSession -Task $Task)
    $cleanup = Get-CliProperty -InputObject $Task -Name "cleanup"
    $cleanupFailed = [string](Get-CliProperty -InputObject $cleanup -Name "status") -eq "failed"

    $primary = switch ($status) {
        "queued" {
            if ([bool](Get-CliProperty -InputObject $State -Name "paused" -Default $false) -or -not [bool](Get-CliProperty -InputObject $State -Name "active" -Default $false)) {
                "$prompt resume"
            } else {
                "automatic when worker capacity is available"
            }
        }
        { $_ -in @("starting", "planning", "running", "awaiting-input") } { "$prompt chat $id" }
        "syncing" { "$prompt sync $id" }
        "awaiting-review" {
            $review = Get-CliProperty -InputObject $Task -Name "review"
            if ($reviewSessionActive) {
                "$prompt chat $id"
            } elseif (-not $requiresFreshReview -and
                [string](Get-CliProperty -InputObject $review -Name "verdict") -eq "approved" -and
                [string](Get-CliProperty -InputObject $review -Name "commit") -eq $commit -and
                $null -ne (Get-CliProperty -InputObject $review -Name "integrationPlan")) {
                "$prompt go $id"
            } else { "$prompt review $id" }
        }
        { $_ -in @("approved", "integrating", "production") } { "automatic; the factory will continue" }
        "cleaning" {
            $cleanupOwner = Get-CliProperty -InputObject $Task -Name "cleanup"
            if (Test-FactoryRecordedProcess -ProcessRecord $cleanupOwner) {
                "automatic; artifact cleanup is running"
            } else {
                "$prompt cleanup $id"
            }
        }
        "held" {
            $review = Get-CliProperty -InputObject $Task -Name "review"
            $hasApprovedPlan = -not $requiresFreshReview -and
                [string](Get-CliProperty -InputObject $review -Name "verdict") -eq "approved" -and
                [string](Get-CliProperty -InputObject $review -Name "commit") -eq $commit -and
                $null -ne (Get-CliProperty -InputObject $review -Name "integrationPlan")
            if ($commit -and $resultCommit -eq $commit -and $hasApprovedPlan) { "$prompt go $id" }
            elseif ($commit -and $resultCommit -eq $commit) { "$prompt review $id" }
            elseif ($isMachineHeld) { "$prompt retry $id" }
            else { "$prompt inspect $id" }
        }
        { $_ -in @("blocked", "failed") } {
            if ($cleanupFailed) { "$prompt cleanup $id" }
            elseif (Test-FactoryRecoverableFailedReworkLaunch -Task $Task) { "$prompt retry $id" }
            else { "$prompt inspect $id" }
        }
        "rejected" { "$prompt inspect $id" }
        "done" { "$prompt inspect $id" }
        default { "$prompt inspect $id" }
    }

    $alternative = ""
    if ($status -eq "awaiting-input") { $alternative = "$prompt answer $id --text `"...`"" }
    elseif ($status -eq "awaiting-review" -and -not $reviewSessionActive) {
        $review = Get-CliProperty -InputObject $Task -Name "review"
        $reviewVerdict = [string](Get-CliProperty -InputObject $review -Name "verdict")
        $directReadiness = Get-FactoryDirectApprovalReadiness -Config $Config -State $State -Task $Task -RepositoryRoot ([string]$Repository)
        if ($reviewVerdict -notin @("approved", "changes-required", "blocked") -and [bool]$directReadiness.ready) {
            $alternative = "!factory go $id --direct"
        }
    }
    elseif ($status -eq "held" -and -not $commit -and -not $isMachineHeld) { $alternative = "$prompt answer $id --text `"Continue`"" }
    elseif ($status -eq "held" -and $commit -and $resultCommit -eq $commit) {
        $review = Get-CliProperty -InputObject $Task -Name "review"
        $reviewVerdict = [string](Get-CliProperty -InputObject $review -Name "verdict")
        $directReadiness = Get-FactoryDirectApprovalReadiness -Config $Config -State $State -Task $Task -RepositoryRoot ([string]$Repository)
        if ($reviewVerdict -notin @("approved", "changes-required", "blocked") -and [bool]$directReadiness.ready) {
            $alternative = "!factory go $id --direct"
        }
    }
    elseif ($status -in @("blocked", "failed") -and $session.Exists) { $alternative = "$prompt chat $id" }
    elseif ($status -eq "rejected") { $alternative = "$prompt reject $id" }

    return [pscustomobject]@{ Primary = $primary; Alternative = $alternative; Prompt = $prompt }
}

function Add-CliTaskTree {
    param(
        [Collections.Generic.List[string]]$Lines,
        $Task,
        $State,
        $Config,
        [bool]$IsLast
    )

    $id = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Task -Name "id") -Fallback "unknown-id"
    $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Task -Name "title") -Fallback "Untitled task"
    $status = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Task -Name "status") -Fallback "unknown"
    $effectiveStatus = Get-CliEffectiveStatus -Task $Task
    $taskConnector = if ($IsLast) { "$($script:Tree.Last)$($script:Tree.Horizontal)" } else { "$($script:Tree.Branch)$($script:Tree.Horizontal)" }
    $detailPrefix = if ($IsLast) { "$($script:Tree.Vertical)     " } else { "$($script:Tree.Vertical)  $($script:Tree.Vertical)  " }
    Add-CliWrappedLine `
        -Lines $Lines `
        -FirstPrefix "$($script:Tree.Vertical)  $taskConnector " `
        -ContinuationPrefix $detailPrefix `
        -Text "$(Get-CliStateLabel -Status $effectiveStatus) $($script:Tree.Horizontal) $id $($script:Tree.Horizontal) $title"

    $details = New-Object Collections.Generic.List[string]
    $source = Get-CliTaskSourceInfo -Task $Task
    if ($source.IsLocal) {
        $details.Add("Source: local / $($source.Id)")
    } else {
        $details.Add("URL: $(if ($source.Url) { $source.Url } else { 'unavailable' })")
    }
    $brief = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Task -Name "brief")
    if ($brief -and $brief -ne $title -and $title.Length -lt 80) {
        $details.Add("What: $(Get-CliShortSummary -Value $brief)")
    }
    if ($effectiveStatus -eq "session-blocked") {
        $details.Add("State: worker session blocked for $(Format-CliDuration -Seconds (Get-CliBlockedSessionAge -Task $Task)); task state is $status")
    } else {
        $details.Add("State: $(Get-CliStateText -Status $effectiveStatus)")
    }
    $reason = Get-CliTaskReason -Task $Task
    if ($reason) { $details.Add("Reason: $(Get-CliShortSummary -Value $reason -MaximumLength 260)") }
    $commit = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Task -Name "commit")
    if ($commit) { $details.Add("Commit: $commit") }
    $session = Get-CliSessionInfo -Task $Task
    if ($session.Exists) {
        $sessionName = if ($session.Name) { "$($session.Name) $($script:Tree.Horizontal) " } else { "" }
        $details.Add("Session: $($session.Runtime) $sessionName$($session.ShortId) / $($session.State)")
    } else {
        $details.Add("Session: none")
    }
    $worktree = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Task -Name "worktree")
    if ($worktree -and $status -notin @("approved", "integrating", "production", "cleaning", "done")) {
        $details.Add("View in browser: factory preview $id")
    }
    $action = Get-CliNextAction -Task $Task -State $State -Config $Config
    $details.Add("$($script:Tree.Arrow) Next in orchestrator: $($action.Primary)")
    if ($session.Exists -and $action.Primary -ne "$($action.Prompt) chat $id") { $details.Add("Open: $($action.Prompt) chat $id") }
    if ($action.Alternative) { $details.Add("Alternative: $($action.Alternative)") }

    for ($index = 0; $index -lt $details.Count; $index++) {
        $connector = if ($index -eq $details.Count - 1) { "$($script:Tree.Last)$($script:Tree.Horizontal)" } else { "$($script:Tree.Branch)$($script:Tree.Horizontal)" }
        $continuation = if ($index -eq $details.Count - 1) { "$detailPrefix   " } else { "$detailPrefix$($script:Tree.Vertical)  " }
        Add-CliWrappedLine -Lines $Lines -FirstPrefix "$detailPrefix$connector " -ContinuationPrefix $continuation -Text $details[$index]
    }
}

function Add-CliDoneTree {
    param(
        [Collections.Generic.List[string]]$Lines,
        [object[]]$Tasks,
        [int]$Total,
        [int]$RowCount
    )

    $Lines.Add("$($script:Tree.Branch)$($script:Tree.Horizontal) COMPLETED $($script:Tree.Horizontal) $Total distinct task IDs")
    if ($Tasks.Count -eq 0) {
        $Lines.Add("$($script:Tree.Vertical)  $($script:Tree.Last)$($script:Tree.Horizontal) No completed tasks.")
        return
    }
    $Lines.Add("$($script:Tree.Vertical)  Showing $($Tasks.Count) of $RowCount completion rows, newest first (limit $Limit).")
    for ($index = 0; $index -lt $Tasks.Count; $index++) {
        $task = $Tasks[$index]
        $id = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "id") -Fallback "unknown-id"
        $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "title") -Fallback "Untitled task"
        $source = Get-CliTaskSourceInfo -Task $task
        $taskConnector = if ($index -eq $Tasks.Count - 1) { "$($script:Tree.Last)$($script:Tree.Horizontal)" } else { "$($script:Tree.Branch)$($script:Tree.Horizontal)" }
        $detailPrefix = if ($index -eq $Tasks.Count - 1) { "$($script:Tree.Vertical)     " } else { "$($script:Tree.Vertical)  $($script:Tree.Vertical)  " }
        Add-CliWrappedLine -Lines $Lines -FirstPrefix "$($script:Tree.Vertical)  $taskConnector " -ContinuationPrefix $detailPrefix -Text "DONE $($script:Tree.Horizontal) $id $($script:Tree.Horizontal) $title"
        $sourceText = if ($source.IsLocal) { "Source: local / $($source.Id)" } else { "URL: $(if ($source.Url) { $source.Url } else { 'unavailable' })" }
        Add-CliWrappedLine -Lines $Lines -FirstPrefix "$detailPrefix$($script:Tree.Branch)$($script:Tree.Horizontal) " -ContinuationPrefix "$detailPrefix$($script:Tree.Vertical)  " -Text $sourceText
        $landedAt = ConvertTo-CliLine -Value $task.landedAt -Fallback 'date unavailable'
        $commit = ConvertTo-CliLine -Value $task.commit -Fallback 'unavailable'
        Add-CliWrappedLine -Lines $Lines -FirstPrefix "$detailPrefix$($script:Tree.Last)$($script:Tree.Horizontal) " -ContinuationPrefix "$detailPrefix   " -Text "$($task.outcome) / $landedAt / commit $commit"
    }
}

function Write-CliStatus {
    param($Context, $Config, $State, [string]$Filter, [string]$ReconcileWarning, $TestLease, [string]$TestLeaseError)

    if ($Filter -and $Filter -ne "all" -and $Filter -notin $script:FactoryStates) {
        throw "Unknown status filter '$Filter'. Use one of: $($script:FactoryStates -join ', '), all."
    }

    $allTasks = @($State.tasks)
    $history = Get-FactoryCompletedHistory -Context $Context -State $State -Config $Config
    $unfinished = @($allTasks | Where-Object { [string]$_.status -ne "done" })
    $showDoneRows = $Filter -in @("done", "all")
    $selected = @(
        if ($Filter -eq "done") {
            # Completed rows are rendered separately below.
        } elseif ($Filter -and $Filter -ne "all") {
            $unfinished | Where-Object {
                [string]$_.status -eq $Filter -or ($Filter -eq "blocked" -and (Get-CliEffectiveStatus -Task $_) -eq "session-blocked")
            }
        } else {
            $unfinished | ForEach-Object { $_ }
        }
    )

    $runnableStates = @("queued", "starting", "planning", "running", "approved", "integrating", "production")
    $activeWorkers = Get-FactoryLaunchedWorkerCount -State $State
    $runnable = @($allTasks | Where-Object {
        [string]$_.status -in $runnableStates -or
        ([string]$_.status -eq "awaiting-review" -and (Test-FactoryTaskHasActiveSession -Task $_))
    }).Count
    $nativeRunnable = @($allTasks | Where-Object { [string]$_.status -in @("queued", "approved") }).Count
    $concurrency = Get-FactoryCodingConcurrency -Config $Config
    $paused = [bool](Get-CliProperty -InputObject $State -Name "paused" -Default $false)
    $active = [bool](Get-CliProperty -InputObject $State -Name "active" -Default $false)
    $schedulerState = Get-CliProperty -InputObject $State -Name "scheduler"
    $schedulerStatus = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $schedulerState -Name "status") -Fallback "stopped"
    $schedulerPid = [int](Get-CliProperty -InputObject $schedulerState -Name "pid" -Default 0)
    $schedulerActivity = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $schedulerState -Name "activity") -Fallback "idle"
    $schedulerTaskId = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $schedulerState -Name "activityTaskId")
    $schedulerTaskTitle = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $schedulerState -Name "activityTaskTitle")
    $schedulerError = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $schedulerState -Name "lastError")
    $schedulerFailureAt = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $schedulerState -Name "lastFailureAt")
    $schedulerAlive = Test-FactoryRecordedProcess -ProcessRecord $schedulerState
    $attentionEvents = @(Get-FactoryOperatorActionEvents -State $State -Config $Config)
    $aiActions = @($attentionEvents | Where-Object { [bool](Get-CliProperty -InputObject $_ -Name "aiActionable" -Default $false) })
    $humanDecisions = @($attentionEvents | Where-Object { [bool](Get-CliProperty -InputObject $_ -Name "humanDecision" -Default $false) })
    $blockedTaskCount = @($allTasks | Where-Object { [string]$_.status -eq "blocked" }).Count
    $cronId = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $State -Name "cronJobId")
    $activity = if ($paused) { "paused" } elseif ($activeWorkers -gt 0) { "working" } else { "idle" }
    $scheduler = if ($paused -and $schedulerStatus -in @("running", "busy")) {
        "native $schedulerStatus but factory paused (PID $schedulerPid)"
    } elseif ($schedulerStatus -eq "busy") {
        $busyTarget = @(@($schedulerTaskId, $schedulerTaskTitle) | Where-Object { $_ })
        $busySuffix = if ($busyTarget.Count -gt 0) { " " + ($busyTarget -join " - ") } else { "" }
        "native busy: $schedulerActivity$busySuffix (PID $schedulerPid)"
    } elseif ($schedulerStatus -eq "failed") {
        "native failed$(if ($schedulerPid -gt 0) { ' (PID ' + $schedulerPid + '; retrying)' } else { '' })"
    } elseif ($schedulerStatus -eq "running") {
        if ($runnable -eq 0 -and $aiActions.Count -gt 0) { "native sleeping; waiting for AI orchestration ($($aiActions.Count)) (PID $schedulerPid)" }
        elseif ($runnable -eq 0 -and $humanDecisions.Count -gt 0) { "native sleeping; waiting for human decision ($($humanDecisions.Count)) (PID $schedulerPid)" }
        elseif ($runnable -eq 0) { "native sleeping (PID $schedulerPid)" }
        else { "native running (PID $schedulerPid)" }
    } elseif ($cronId) {
        "legacy cron $cronId"
    } elseif ($runnable -eq 0) {
        "native stopped; nothing runnable"
    } else {
        "native stopped"
    }
    $schedulerProblem = $runnable -gt 0 -and ($paused -or -not $schedulerAlive)
    $projectName = Split-Path ([string]$Context.repositoryRoot) -Leaf

    $lines = New-Object Collections.Generic.List[string]
    $lines.Add("$($script:Tree.Top)$($script:Tree.Horizontal) Factory $($script:Tree.Horizontal) $projectName")
    $workerRuntime = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Config -Name "workerAgent") -Fallback "claude"
    $lines.Add("$($script:Tree.Vertical)  $activity $($script:Tree.Horizontal) runtime $workerRuntime $($script:Tree.Horizontal) coding slots $activeWorkers/$concurrency $($script:Tree.Horizontal) scheduler $scheduler")
    $lines.Add("$($script:Tree.Vertical)  attention $($script:Tree.Horizontal) AI actions $($aiActions.Count) $($script:Tree.Horizontal) human decisions $($humanDecisions.Count) $($script:Tree.Horizontal) blocked tasks $blockedTaskCount")
    try {
        if ($TestLeaseError) { throw $TestLeaseError }
        if ($null -eq $TestLease) { throw "Test lease status returned no data." }
        $leaseHolder = Get-CliProperty -InputObject $testLease -Name "holder"
        $leaseQueue = @(Get-CliProperty -InputObject $testLease -Name "queue" -Default @())
        if ($null -eq $leaseHolder) {
            $lines.Add("$($script:Tree.Vertical)  test lane free $($script:Tree.Horizontal) queue $($leaseQueue.Count)")
        } else {
            $leaseAge = Format-CliDuration -Seconds ([int](Get-CliProperty -InputObject $testLease -Name "holderAgeSeconds" -Default 0))
            $leaseWarning = if (-not [bool](Get-CliProperty -InputObject $testLease -Name "heartbeatReadable" -Default $true)) {
                "HEARTBEAT UNREADABLE"
            } elseif ([bool](Get-CliProperty -InputObject $testLease -Name "heartbeatStalled" -Default $false)) {
                "HEARTBEAT STALLED"
            } elseif (
                [bool](Get-CliProperty -InputObject $testLease -Name "holderProcessAlive" -Default $false) -and
                -not [bool](Get-CliProperty -InputObject $testLease -Name "heartbeatPidAlive" -Default $false)
            ) {
                "HEARTBEAT PROCESS DOWN"
            } elseif ([bool](Get-CliProperty -InputObject $testLease -Name "stale" -Default $false)) {
                "STALE"
            } else { "" }
            $warningSuffix = if ($leaseWarning) { " $($script:Tree.Horizontal) $leaseWarning" } else { "" }
            $lines.Add("$($script:Tree.Vertical)  test lane $([string]$leaseHolder.phase) $($script:Tree.Horizontal) $([string]$leaseHolder.taskId) $($script:Tree.Horizontal) $leaseAge$warningSuffix")
        }
        if ($leaseQueue.Count -gt 0) {
            $queueItems = @($leaseQueue | Select-Object -First 5 | ForEach-Object { "$([string]$_.phase):$([string]$_.taskId)" })
            $queueTail = if ($leaseQueue.Count -gt 5) { " (+$($leaseQueue.Count - 5) more)" } else { "" }
            Add-CliWrappedLine -Lines $lines -FirstPrefix "$($script:Tree.Vertical)  test queue $($script:Tree.Horizontal) " -ContinuationPrefix "$($script:Tree.Vertical)               " -Text (($queueItems -join ", ") + $queueTail)
        }
    } catch {
        $lines.Add("$($script:Tree.Vertical)  test lane unavailable $($script:Tree.Horizontal) $(ConvertTo-CliLine -Value $_.Exception.Message)")
    }
    if ($cronId -and $schedulerStatus -eq "running") {
        $lines.Add("$($script:Tree.Vertical)  Legacy Claude cron $cronId will remove itself on its next one-shot tick.")
    }
    if ($ReconcileWarning) { $lines.Add("$($script:Tree.Vertical)  Warning: $ReconcileWarning") }

    $groups = @(
        [pscustomobject]@{ Name = "NEEDS YOUR ACTION"; Key = "Needs your action" },
        [pscustomobject]@{ Name = "WORKING"; Key = "Working" },
        [pscustomobject]@{ Name = "WAITING"; Key = "Waiting" },
        [pscustomobject]@{ Name = "PROBLEMS"; Key = "Problems" },
        [pscustomobject]@{ Name = "OTHER"; Key = "Other" }
    )
    foreach ($group in $groups) {
        $groupTasks = @($selected | Where-Object { (Get-CliGroup -Status (Get-CliEffectiveStatus -Task $_)) -eq $group.Key })
        $schedulerRows = if ($group.Key -eq "Needs your action" -and $schedulerProblem) { 1 } else { 0 }
        $groupCount = $groupTasks.Count + $schedulerRows
        if ($groupCount -eq 0) { continue }
        $lines.Add("$($script:Tree.Branch)$($script:Tree.Horizontal) $($group.Name) $($script:Tree.Horizontal) $groupCount")
        if ($schedulerRows -gt 0) {
            $schedulerProblemStatus = if ($paused) { "paused" } else { $schedulerStatus }
            $schedulerConnector = if ($groupTasks.Count -eq 0) { $script:Tree.Last } else { $script:Tree.Branch }
            $schedulerDetailPrefix = if ($groupTasks.Count -eq 0) { "$($script:Tree.Vertical)     " } else { "$($script:Tree.Vertical)  $($script:Tree.Vertical)  " }
            Add-CliWrappedLine `
                -Lines $lines `
                -FirstPrefix "$($script:Tree.Vertical)  $schedulerConnector$($script:Tree.Horizontal) " `
                -ContinuationPrefix $schedulerDetailPrefix `
                -Text "SCHEDULER $($script:Tree.Horizontal) $schedulerProblemStatus $($script:Tree.Horizontal) runnable work is not being processed"
            $schedulerReason = if ($paused) {
                "Factory is paused; the scheduler will not launch or publish tasks."
            } elseif ($schedulerError) { $schedulerError } else { "No live native scheduler owns this project." }
            Add-CliWrappedLine -Lines $lines -FirstPrefix "$schedulerDetailPrefix$($script:Tree.Branch)$($script:Tree.Horizontal) " -ContinuationPrefix "$schedulerDetailPrefix$($script:Tree.Vertical)  " -Text "Reason: $schedulerReason"
            if ($schedulerFailureAt) {
                Add-CliWrappedLine -Lines $lines -FirstPrefix "$schedulerDetailPrefix$($script:Tree.Branch)$($script:Tree.Horizontal) " -ContinuationPrefix "$schedulerDetailPrefix$($script:Tree.Vertical)  " -Text "Detected: $schedulerFailureAt"
            }
            $schedulerDiagnostic = if ($paused -and $schedulerStatus -in @("running", "busy")) {
                "Process: running (PID $schedulerPid); pause is intentional state, not process failure."
            } else {
                "Log: $(Join-Path ([string]$Context.projectData) 'scheduler.stderr.log')"
            }
            Add-CliWrappedLine -Lines $lines -FirstPrefix "$schedulerDetailPrefix$($script:Tree.Branch)$($script:Tree.Horizontal) " -ContinuationPrefix "$schedulerDetailPrefix$($script:Tree.Vertical)  " -Text $schedulerDiagnostic
            $schedulerNext = if ($paused) { "factory resume" } elseif ($schedulerStatus -in @("stopped", "failed")) { "factory scheduler start" } else { "factory scheduler status" }
            Add-CliWrappedLine -Lines $lines -FirstPrefix "$schedulerDetailPrefix$($script:Tree.Last)$($script:Tree.Horizontal) " -ContinuationPrefix "$schedulerDetailPrefix   " -Text "$($script:Tree.Arrow) Next: $schedulerNext"
        }
        for ($index = 0; $index -lt $groupTasks.Count; $index++) {
            Add-CliTaskTree -Lines $lines -Task $groupTasks[$index] -State $State -Config $Config -IsLast ($index -eq $groupTasks.Count - 1)
        }
    }

    if ($Filter -and $Filter -notin @("all", "done") -and $selected.Count -eq 0) {
        $lines.Add("$($script:Tree.Branch)$($script:Tree.Horizontal) NO TASKS MATCH '$Filter'")
    }

    if ($showDoneRows) {
        Add-CliDoneTree -Lines $lines -Tasks @($history.rows | Select-Object -First $Limit) -Total $history.count -RowCount $history.rows.Count
    } else {
        $lines.Add("$($script:Tree.Branch)$($script:Tree.Horizontal) COMPLETED $($script:Tree.Horizontal) $($history.count) distinct task IDs")
        $lines.Add("$($script:Tree.Vertical)  $($script:Tree.Last)$($script:Tree.Horizontal) History: factory status done")
    }
    if (-not $history.archiveExists) {
        $lines.Add("$($script:Tree.Vertical)  Archive missing: showing $($history.count) live completed task IDs only. Run factory archive:seed.")
    }
    foreach ($warning in $history.warnings) {
        Add-CliWrappedLine -Lines $lines -FirstPrefix "$($script:Tree.Vertical)  WARNING: " -ContinuationPrefix "$($script:Tree.Vertical)  " -Text $warning
    }

    $factoryMode = if ($paused) { "paused" } elseif ($active) { "enabled" } else { "idle" }
    $lines.Add("$($script:Tree.Bottom)$($script:Tree.Horizontal) Factory $factoryMode $($script:Tree.Horizontal) $($allTasks.Count) saved task(s) $($script:Tree.Horizontal) native runnable $nativeRunnable $($script:Tree.Horizontal) AI $($aiActions.Count) $($script:Tree.Horizontal) human $($humanDecisions.Count) $($script:Tree.Horizontal) scheduler $scheduler")
    $lines | Write-Output
}

function Add-CliInspectLine {
    param([Collections.Generic.List[string]]$Lines, [string]$Text)
    if ($Text) {
        Add-CliWrappedLine `
            -Lines $Lines `
            -FirstPrefix "$($script:Tree.Branch)$($script:Tree.Horizontal) " `
            -ContinuationPrefix "$($script:Tree.Vertical)  " `
            -Text $Text
    }
}

function Write-CliInspect {
    param($Context, $Config, $State, [string]$TaskId, [string]$ReconcileWarning)

    if (-not $TaskId) { throw "inspect requires a task ID: factory inspect <task-id>" }
    $matches = @($State.tasks | Where-Object { [string]$_.id -eq $TaskId })
    if ($matches.Count -eq 0) { throw "Task '$TaskId' was not found in this factory." }
    $task = $matches[0]
    $id = [string]$task.id
    $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "title") -Fallback "Untitled task"
    $status = [string](Get-CliProperty -InputObject $task -Name "status")
    $action = Get-CliNextAction -Task $task -State $State -Config $Config
    $lines = New-Object Collections.Generic.List[string]
    Add-CliWrappedLine `
        -Lines $lines `
        -FirstPrefix "$($script:Tree.Top)$($script:Tree.Horizontal) " `
        -ContinuationPrefix "$($script:Tree.Vertical)  " `
        -Text "Task $id $($script:Tree.Horizontal) $title"
    $source = Get-CliTaskSourceInfo -Task $task
    if ($source.IsLocal) {
        Add-CliInspectLine -Lines $lines -Text "Source: local / $($source.Id)"
    } else {
        Add-CliInspectLine -Lines $lines -Text "URL: $(if ($source.Url) { $source.Url } else { 'unavailable' })"
    }
    Add-CliInspectLine -Lines $lines -Text "State: $(Get-CliStateText -Status $status) ($status)"
    Add-CliInspectLine -Lines $lines -Text "Mode: $(ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name 'startMode') -Fallback 'unknown')"
    Add-CliInspectLine -Lines $lines -Text "Brief: $(ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name 'brief') -Fallback 'unavailable')"
    foreach ($criterion in @(Get-CliProperty -InputObject $task -Name "acceptanceCriteria" -Default @())) {
        Add-CliInspectLine -Lines $lines -Text "Acceptance: $(ConvertTo-CliLine -Value $criterion)"
    }
    $reason = Get-CliTaskReason -Task $task
    if ($reason) { Add-CliInspectLine -Lines $lines -Text "Reason: $reason" }
    $session = Get-CliSessionInfo -Task $task
    if ($session.Exists) {
        Add-CliInspectLine -Lines $lines -Text "Session: $($session.Runtime) / $($session.Id) / $($session.State)"
        if ($session.Name) { Add-CliInspectLine -Lines $lines -Text "Session name: $($session.Name)" }
        $inspectAttach = if ($session.AttachCommand) { $session.AttachCommand } elseif ($session.Runtime -eq "codex") { "codex resume --include-non-interactive --all" } else { "claude attach $($session.ShortId)" }
        Add-CliInspectLine -Lines $lines -Text "Attach: $inspectAttach"
    } else {
        Add-CliInspectLine -Lines $lines -Text "Session: none"
    }
    foreach ($field in @(
        [pscustomobject]@{ Label = "Branch"; Value = Get-CliProperty -InputObject $task -Name "branch" },
        [pscustomobject]@{ Label = "Commit"; Value = Get-CliProperty -InputObject $task -Name "commit" },
        [pscustomobject]@{ Label = "Worktree"; Value = Get-CliProperty -InputObject $task -Name "worktree" }
    )) {
        $value = ConvertTo-CliLine -Value $field.Value
        if ($value) { Add-CliInspectLine -Lines $lines -Text "$($field.Label): $value" }
    }
    $previewWorktree = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "worktree")
    if ($previewWorktree -and $status -notin @("approved", "integrating", "production", "cleaning", "done")) {
        Add-CliInspectLine -Lines $lines -Text "Browser preview: factory preview $TaskId"
    }
    $plan = Get-CliProperty -InputObject $task -Name "plan"
    foreach ($name in @("summary", "approach")) {
        $value = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $plan -Name $name)
        if ($value) { Add-CliInspectLine -Lines $lines -Text "Plan $name`: $value" }
    }
    foreach ($question in @(Get-CliProperty -InputObject $plan -Name "questions" -Default @())) {
        Add-CliInspectLine -Lines $lines -Text "Question: $(ConvertTo-CliLine -Value $question)"
    }
    $result = Get-CliProperty -InputObject $task -Name "workerResult"
    $resultNotes = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $result -Name "notes")
    if ($resultNotes) { Add-CliInspectLine -Lines $lines -Text "Result: $resultNotes" }
    foreach ($file in @(Get-CliProperty -InputObject $result -Name "changedFiles" -Default @())) {
        Add-CliInspectLine -Lines $lines -Text "Changed: $(ConvertTo-CliLine -Value $file)"
    }
    foreach ($test in @(Get-CliProperty -InputObject $result -Name "tests" -Default @())) {
        $testCommand = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $test -Name "command") -Fallback "unnamed check"
        $testStatus = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $test -Name "status") -Fallback "unknown"
        Add-CliInspectLine -Lines $lines -Text "Test: $testStatus $($script:Tree.Horizontal) $testCommand"
    }
    $review = Get-CliProperty -InputObject $task -Name "review"
    $reviewVerdict = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $review -Name "verdict")
    $reviewMode = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $review -Name "mode")
    if ($reviewMode -eq "operator-direct") {
        Add-CliInspectLine -Lines $lines -Text "Review: skipped by operator (--direct)"
    } elseif ($reviewVerdict) {
        Add-CliInspectLine -Lines $lines -Text "Review: $reviewVerdict"
    }
    $reviewSummary = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $review -Name "summary")
    if ($reviewSummary) { Add-CliInspectLine -Lines $lines -Text "Review summary: $reviewSummary" }
    foreach ($risk in @(Get-CliProperty -InputObject $review -Name "riskNotes" -Default @())) {
        Add-CliInspectLine -Lines $lines -Text "Review risk: $(ConvertTo-CliLine -Value $risk)"
    }
    $integrationPlan = Get-CliProperty -InputObject $review -Name "integrationPlan"
    $integrationPlanHash = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $integrationPlan -Name "planHash")
    if ($integrationPlanHash) {
        Add-CliInspectLine -Lines $lines -Text "Integration plan: $(Get-CliShortId -Value $integrationPlanHash) $($script:Tree.Horizontal) $([string](Get-CliProperty -InputObject $integrationPlan -Name 'remote'))/$([string](Get-CliProperty -InputObject $integrationPlan -Name 'developmentBranch')) at $(Get-CliShortId -Value (Get-CliProperty -InputObject $integrationPlan -Name 'developmentBase'))"
        foreach ($command in @(Get-CliProperty -InputObject $integrationPlan -Name "integrationTestCommands" -Default @())) {
            Add-CliInspectLine -Lines $lines -Text "Integration check: $(ConvertTo-CliLine -Value $command)"
        }
        foreach ($command in @(Get-CliProperty -InputObject $integrationPlan -Name "releaseTestCommands" -Default @())) {
            Add-CliInspectLine -Lines $lines -Text "Release check: $(ConvertTo-CliLine -Value $command)"
        }
    }
    $approval = Get-CliProperty -InputObject $task -Name "approval"
    $approvedCommit = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $approval -Name "commit")
    if ($approvedCommit) { Add-CliInspectLine -Lines $lines -Text "Approved commit: $approvedCommit" }
    $approvalMode = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $approval -Name "mode")
    if ($approvalMode) { Add-CliInspectLine -Lines $lines -Text "Approval mode: $approvalMode" }
    foreach ($stageName in @("integration", "production", "cleanup")) {
        $stage = Get-CliProperty -InputObject $task -Name $stageName
        $stageStatus = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $stage -Name "status")
        if ($stageStatus) { Add-CliInspectLine -Lines $lines -Text "$stageName`: $stageStatus" }
    }
    if ($ReconcileWarning) { Add-CliInspectLine -Lines $lines -Text "Warning: $ReconcileWarning" }
    Add-CliInspectLine -Lines $lines -Text "Updated: $(ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name 'updatedAt') -Fallback 'unknown')"
    $lines.Add("$($script:Tree.Bottom)$($script:Tree.Horizontal) Next in orchestrator: $($action.Primary)")
    $lines | Write-Output
}

function Write-CliDoctor {
    param($Context)

    $doctorArguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "factory-doctor.ps1"),
        "-Repository", [string]$Context.repositoryRoot, "-ClaudeCommand", $ClaudeCommand
    )
    if ($CodexCommand) { $doctorArguments += @("-CodexCommand", $CodexCommand) }
    $doctorText = (& powershell @doctorArguments | Out-String).Trim()
    if (-not $doctorText) { throw "Factory doctor returned no data." }
    $doctor = $doctorText | ConvertFrom-Json
    Write-Output "Factory doctor - $($doctor.projectKey)"
    foreach ($check in @($doctor.checks)) {
        $marker = if ([bool]$check.passed) { "OK" } elseif ([string]$check.severity -eq "warning") { "WARN" } else { "FAIL" }
        Write-Output ("[{0}] {1}: {2}" -f $marker, [string]$check.name, (ConvertTo-CliLine -Value $check.detail))
    }
    Write-Output $(if ([bool]$doctor.healthy) {
        "Healthy - $($doctor.warnings) warning(s)."
    } else {
        "Unhealthy - $($doctor.requiredFailures) required failure(s), $($doctor.warnings) warning(s)."
    })
    if (-not [bool]$doctor.healthy) { $script:CliExitCode = 2 }
}

function Get-CliTask {
    param($State, [string]$TaskId, [string]$CommandName)

    if (-not $TaskId) { throw "$CommandName requires a task ID: factory $CommandName <task-id>" }
    $matches = @($State.tasks | Where-Object { [string]$_.id -eq $TaskId })
    if ($matches.Count -eq 0) { throw "Task '$TaskId' was not found in this factory." }
    return $matches[0]
}

function Invoke-CliJsonScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string[]]$Arguments = @()
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    $native = Invoke-FactoryNativeProcess -Command "powershell" -Arguments (@(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath
    ) + @($Arguments))
    if ([int]$native.exitCode -ne 0) {
        $detail = ConvertTo-CliLine -Value $native.output -Fallback "no diagnostic output"
        throw "$ScriptName exited with code $($native.exitCode): $detail"
    }
    $output = ([string]$native.stdout).Trim()
    if (-not $output) { throw "$ScriptName returned no data." }
    try {
        return $output | ConvertFrom-Json
    } catch {
        throw "$ScriptName returned invalid JSON: $(Get-CliShortSummary -Value $output -MaximumLength 300)"
    }
}

function Write-CliChat {
    param($State, [string]$TaskId, [string]$ReconcileWarning)

    $task = Get-CliTask -State $State -TaskId $TaskId -CommandName "chat"
    $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "title") -Fallback "Untitled task"
    $status = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "status") -Fallback "unknown"
    $session = Get-CliSessionInfo -Task $task
    $lines = New-Object Collections.Generic.List[string]
    Add-CliWrappedLine -Lines $lines -FirstPrefix "$($script:Tree.Top)$($script:Tree.Horizontal) " -ContinuationPrefix "$($script:Tree.Vertical)  " -Text "Task $TaskId $($script:Tree.Horizontal) $title"
    Add-CliInspectLine -Lines $lines -Text "State: $(Get-CliStateText -Status $status) ($status)"
    if ($session.Exists) {
        Add-CliInspectLine -Lines $lines -Text "Session: $($session.Runtime) / $($session.Id) / $($session.State)"
        if ($session.Name) { Add-CliInspectLine -Lines $lines -Text "Session name: $($session.Name)" }
        $attachCommand = $session.AttachCommand
        if (-not $attachCommand) { $attachCommand = if ($session.Runtime -eq "codex") { "codex resume --include-non-interactive --all" } else { "claude attach $($session.ShortId)" } }
        Add-CliInspectLine -Lines $lines -Text "PowerShell: $attachCommand"
        Add-CliInspectLine -Lines $lines -Text "Orchestrator: /factory chat $TaskId"
    } else {
        Add-CliInspectLine -Lines $lines -Text "Session: none; there is nothing to attach."
    }
    if ($ReconcileWarning) { Add-CliInspectLine -Lines $lines -Text "Warning: $ReconcileWarning" }
    $lines.Add("$($script:Tree.Bottom)$($script:Tree.Horizontal) This command resolves the session; run the printed PowerShell command outside the orchestrator.")
    $lines | Write-Output
}

function Write-CliHold {
    param($State, [string]$TaskId)

    $task = Get-CliTask -State $State -TaskId $TaskId -CommandName "hold"
    $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "title") -Fallback "Untitled task"
    $result = Invoke-CliJsonScript -ScriptName "task-action.ps1" -Arguments @(
        "-Repository", [string]$Repository,
        "-Action", "hold",
        "-TaskId", $TaskId,
        "-ClaudeCommand", $ClaudeCommand
    )
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Held $($script:Tree.Horizontal) $TaskId $($script:Tree.Horizontal) $title"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) State: $([string]$result.status)"
    $resume = if ([string](Get-CliProperty -InputObject $result -Name "heldFromStatus") -eq "queued") {
        "/factory release $TaskId"
    } else {
        "/factory answer $TaskId --text `"Continue`""
    }
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Resume later: $resume"
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) No AI call was used."
}

function Write-CliRetry {
    param($State, [string]$TaskId)

    $task = Get-CliTask -State $State -TaskId $TaskId -CommandName "retry"
    $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "title") -Fallback "Untitled task"
    $result = Invoke-CliJsonScript -ScriptName "task-action.ps1" -Arguments @(
        "-Repository", [string]$Repository,
        "-Action", "retry",
        "-TaskId", $TaskId,
        "-ClaudeCommand", $ClaudeCommand,
        "-CodexCommand", $CodexCommand
    )
    $schedulerResult = Invoke-CliJsonScript -ScriptName "factory-scheduler.ps1" -Arguments @(
        "-Action", "resume",
        "-Repository", [string]$Repository,
        "-ClaudeCommand", $ClaudeCommand
    )
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Retry queued $($script:Tree.Horizontal) $TaskId $($script:Tree.Horizontal) $title"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) State: $([string]$result.status)"
    $schedulerNote = if ([bool](Get-CliProperty -InputObject $schedulerResult -Name "wakeRequested" -Default $false)) {
        "wake requested"
    } elseif (-not [bool](Get-CliProperty -InputObject $schedulerResult -Name "resumed" -Default $true)) {
        "already busy; queued work will be picked up after the current operation"
    } else { "running" }
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Scheduler: $([string]$schedulerResult.scheduler.status); $schedulerNote"
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Monitor: factory inspect $TaskId"
}

function Write-CliGo {
    param($Context, $Config, $State, [string]$TaskId, [bool]$DirectApproval)

    $task = Get-CliTask -State $State -TaskId $TaskId -CommandName "go"
    $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "title") -Fallback "Untitled task"
    if ($DirectApproval) {
        $readiness = Get-FactoryDirectApprovalReadiness -Config $Config -State $State -Task $task -RepositoryRoot ([string]$Repository)
        if (-not [bool]$readiness.ready) {
            throw "Direct approval is unavailable: $(@($readiness.blockers) -join '; '). Run 'factory config edit', then retry."
        }
    }
    $result = if ($DirectApproval) {
        Invoke-CliJsonScript -ScriptName "approve-direct.ps1" -Arguments @(
            "-Repository", [string]$Repository,
            "-TaskId", $TaskId,
            "-ClaudeCommand", $ClaudeCommand
        )
    } else {
        Invoke-CliJsonScript -ScriptName "task-action.ps1" -Arguments @(
            "-Repository", [string]$Repository,
            "-Action", "go",
            "-TaskId", $TaskId,
            "-ClaudeCommand", $ClaudeCommand
        )
    }
    $schedulerResult = Invoke-CliJsonScript -ScriptName "factory-scheduler.ps1" -Arguments @(
        "-Action", "start",
        "-Repository", [string]$Context.repositoryRoot,
        "-ClaudeCommand", $ClaudeCommand,
        "-RuntimeHome", [string]$Context.runtimeHome
    )
    $scheduler = Get-CliProperty -InputObject $schedulerResult -Name "scheduler"
    $heading = if ($DirectApproval) { "Approved directly" } else { "Approved" }
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) $heading $($script:Tree.Horizontal) $TaskId $($script:Tree.Horizontal) $title"
    if ($DirectApproval) {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Review: skipped by explicit operator request"
    }
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Commit: $([string]$result.approvedCommit)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Review plan: $(Get-CliShortId -Value $result.approvedPlanHash)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Native scheduler: $([string]$scheduler.status)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Publication runs asynchronously; monitor: factory inspect $TaskId"
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Candidate checks run in parallel; verified branch pushes remain sequential."
}

function Write-CliAdd {
    param($Context, [string]$Path)

    if (-not $Path) { throw "add requires a normalized intake file: factory add --file <task.json>" }
    $result = Invoke-CliJsonScript -ScriptName "enqueue-task.ps1" -Arguments @(
        "-Repository", [string]$Context.repositoryRoot,
        "-IntakePath", $Path,
        "-ClaudeCommand", $ClaudeCommand
    )
    $heading = if ([bool]$result.duplicate) { "Already saved" } elseif ([string]$result.status -eq "blocked") { "Saved as blocked" } else { "Added" }
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) $heading $($script:Tree.Horizontal) $([string]$result.taskId) $($script:Tree.Horizontal) $([string]$result.title)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Source: $([string]$result.sourceAdapter) / $([string]$result.sourceId)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) URL: $([string]$result.url)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) State: $([string]$result.status); mode: $([string]$result.mode)"
    if ([string]$result.sourceError) { Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Source error: $(ConvertTo-CliLine -Value $result.sourceError)" }
    if ([string]$result.schedulerError) { Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Scheduler warning: $(ConvertTo-CliLine -Value $result.schedulerError)" }
    $footer = if ([bool]$result.duplicate) { "No queue entry was added." } elseif ([string]$result.status -eq "queued") { "Native scheduler was notified; use factory status to follow the task." } else { "Inspect the saved blocker with factory inspect $([string]$result.taskId)." }
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) $footer"
}

function Test-CliLocalFileArgument {
    param([string]$Value)

    if (-not $Value) { return $false }
    if (Test-Path -LiteralPath $Value -ErrorAction SilentlyContinue) { return $true }
    # Recognize explicit paths and plain spec filenames even when missing;
    # keep ordinary prose such as "Update README.md" as inline task text.
    return $Value -match '^(?:[A-Za-z]:|[\\/]|\.{1,2}[\\/])|^\S+\.(?:md|markdown|txt)$'
}

function Write-CliNew {
    param($Context, [string]$Text, [bool]$Automatic, [string]$TaskFile = "", [string]$TaskTitle = "")

    if ($Automatic -and -not $TaskFile -and -not $Text.Trim()) {
        throw "An automatic local task requires text or a file: factory new --auto <file> [title] | factory new --auto <text>"
    }
    $mode = if ($Automatic) { "auto" } else { "interactive" }
    $arguments = @(
        "-Repository", [string]$Context.repositoryRoot,
        "-StartMode", $mode,
        "-ClaudeCommand", $ClaudeCommand
    )
    if ($TaskFile) {
        # Resolve against the caller's location before starting a child process.
        $resolvedFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TaskFile)
        $arguments += @("-LocalFile", $resolvedFile)
        if ($TaskTitle) { $arguments += @("-FileTitle", $TaskTitle) }
    } else {
        $arguments += @("-LocalText", $Text)
    }
    $result = Invoke-CliJsonScript -ScriptName "enqueue-task.ps1" -Arguments $arguments
    $taskId = [string]$result.taskId
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Local task added $($script:Tree.Horizontal) $taskId $($script:Tree.Horizontal) $([string]$result.title)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) State: $([string]$result.status); mode: $([string]$result.mode)"
    if ([string]$result.schedulerError) {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Scheduler warning: $(ConvertTo-CliLine -Value $result.schedulerError)"
    }
    if ($TaskFile) {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) File: $resolvedFile (contents preserved)"
    }
    if (-not $TaskFile -and -not $Text.Trim()) {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) The worker will ask what you want implemented."
    } elseif ($Automatic) {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) The worker was told to begin implementation immediately."
    } else {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) The worker will propose a plan and wait for your approval."
    }
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Open: factory chat $taskId"
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) No JSON file or AI intake was used."
}

function Write-CliRejectResult {
    param($Result)

    $taskId = [string](Get-CliProperty -InputObject $Result -Name "taskId")
    $action = [string](Get-CliProperty -InputObject $Result -Name "action")
    if ($action -eq "keep") {
        Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Rejected and retained $($script:Tree.Horizontal) $taskId"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Artifacts: preserved"
        Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Remove later: factory reject $taskId -Yes"
        return
    }
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Rejected and forgotten $($script:Tree.Horizontal) $taskId"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Removed from factory state: $([bool](Get-CliProperty -InputObject $Result -Name 'removedFromState' -Default $false))"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Worktree removed: $([bool](Get-CliProperty -InputObject $Result -Name 'removedWorktree' -Default $false))"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Branch deleted: $([bool](Get-CliProperty -InputObject $Result -Name 'deletedBranch' -Default $false))"
    $warning = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Result -Name "agentSessionWarning")
    if ($warning) { Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Warning: $warning" }
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) The factory no longer knows this task."
}

function Write-CliReject {
    param($State, [string]$TaskId, [string]$Reason, [bool]$Confirm, [bool]$Preserve)

    $task = Get-CliTask -State $State -TaskId $TaskId -CommandName "reject"
    if ($Confirm -and $Preserve) { throw "Use either -Yes (discard) or -Keep (retain), not both." }
    $arguments = @(
        "-Repository", [string]$Repository,
        "-TaskId", $TaskId,
        "-ClaudeCommand", $ClaudeCommand
    )
    if ($Reason) { $arguments += @("-Reason", $Reason) }
    if ($Confirm) { $arguments += "-Yes" }
    if ($Preserve) { $arguments += "-Keep" }
    $result = Invoke-CliJsonScript -ScriptName "reject-task.ps1" -Arguments $arguments
    if ([bool](Get-CliProperty -InputObject $result -Name "confirmationRequired" -Default $false) -and -not $Confirm) {
        $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $result -Name "title") -Fallback "Untitled task"
        Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Reject preview $($script:Tree.Horizontal) $TaskId $($script:Tree.Horizontal) $title"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) State: $([string]$result.status)"
        foreach ($field in @(
            [pscustomobject]@{ Label = "Session"; Value = Get-CliProperty -InputObject $result -Name "sessionId" },
            [pscustomobject]@{ Label = "Worktree"; Value = Get-CliProperty -InputObject $result -Name "worktree" },
            [pscustomobject]@{ Label = "Branch"; Value = Get-CliProperty -InputObject $result -Name "branch" },
            [pscustomobject]@{ Label = "Commit"; Value = Get-CliProperty -InputObject $result -Name "commit" },
            [pscustomobject]@{ Label = "Test database"; Value = Get-CliProperty -InputObject $result -Name "testDatabase" }
        )) {
            $value = ConvertTo-CliLine -Value $field.Value
            if ($value) { Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) $($field.Label): $value" }
        }
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Confirm discard: factory reject $TaskId -Yes"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Reject but retain: factory reject $TaskId -Keep"
        Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Nothing was removed."
        return
    }
    Write-CliRejectResult -Result $result
}

function Write-CliCleanup {
    param($State, [string]$TaskId)

    $task = Get-CliTask -State $State -TaskId $TaskId -CommandName "cleanup"
    $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $task -Name "title") -Fallback "Untitled task"
    $result = Invoke-CliJsonScript -ScriptName "cleanup-task.ps1" -Arguments @(
        "-Repository", [string]$Repository,
        "-TaskId", $TaskId,
        "-ClaudeCommand", $ClaudeCommand
    )
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Cleanup complete $($script:Tree.Horizontal) $TaskId $($script:Tree.Horizontal) $title"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) State: $([string]$result.status)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Commit retained in configured branches: $([string]$result.commit)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Worktree removed: $([bool]$result.removedWorktree)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Branch deleted: $([bool]$result.deletedBranch)"
    $warning = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $result -Name "agentSessionWarning")
    if ($warning) { Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Warning: $warning" }
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Factory history is retained as done."
}

function Write-CliConcurrency {
    param($Context, $Config, $State, [string]$Value)

    $current = Get-FactoryCodingConcurrency -Config $Config
    $maximum = [int](Get-CliProperty -InputObject $Config -Name "maxConcurrency" -Default 20)
    if (-not $Value) {
        Write-Output "Factory coding concurrency: $current (maximum $maximum; test lane is fixed at 1)"
        Write-Output "Set it with: factory concurrency <1-$maximum>"
        return
    }
    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed)) {
        throw "Concurrency must be an integer; received '$Value'."
    }
    $result = Invoke-CliJsonScript -ScriptName "set-concurrency.ps1" -Arguments @(
        "-Repository", [string]$Repository,
        "-Value", [string]$parsed
    )
    Write-Output "Factory coding concurrency: $([int]$result.previous) $($script:Tree.Arrow) $([int]$result.current) (maximum $([int]$result.maximum); test lane 1)"
    Write-Output (ConvertTo-CliLine -Value $result.note)
    $queuedCount = @($State.tasks | Where-Object { [string]$_.status -eq "queued" }).Count
    $schedulerState = Get-CliProperty -InputObject $State -Name "scheduler"
    $schedulerStatus = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $schedulerState -Name "status") -Fallback "stopped"
    if ([bool]$result.increased -and $queuedCount -gt 0 -and [bool]$State.active -and -not [bool]$State.paused -and $schedulerStatus -eq "running") {
        Invoke-CliSchedulerAction -Context $Context -Action "tick"
    } elseif ($queuedCount -gt 0 -and $schedulerStatus -ne "running") {
        Write-Output "Queued tasks exist but changing the limit never resumes the factory. Run explicitly: factory resume"
    }
}

function Write-CliCompletion {
    param([string]$Action)

    $completionAction = if ($Action) { $Action.ToLowerInvariant() } else { "status" }
    if ($completionAction -notin @("status", "enable")) {
        throw "Unknown completion action '$Action'. Use: factory completion [status|enable]"
    }
    $psReadLine = Get-Module -ListAvailable PSReadLine | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $psReadLine) { throw "PSReadLine is not installed, so interactive Tab completion cannot be configured." }
    Import-Module PSReadLine -ErrorAction Stop
    if ($completionAction -eq "enable") {
        Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    }
    $handler = Get-PSReadLineKeyHandler -Bound | Where-Object { @($_.Key) -contains "Tab" } | Select-Object -First 1
    $functionName = if ($handler) { [string]$handler.Function } else { "unbound" }
    Write-Output "Factory completion: available"
    Write-Output "PowerShell: $($PSVersionTable.PSVersion); PSReadLine: $($psReadLine.Version)"
    Write-Output "Tab binding: $functionName"
    if ($completionAction -eq "enable") {
        Write-Output "Menu completion is enabled for this terminal session."
    } elseif ($functionName -ne "MenuComplete") {
        Write-Output "Enable the completion menu now: factory completion enable"
    }
    Write-Output "Persistent opt-in (your profile is not changed automatically):"
    Write-Output "  Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete"
}

function Write-CliPaths {
    param($Context)

    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Factory paths $($script:Tree.Horizontal) $([string]$Context.projectKey)"
    foreach ($item in @(
        [pscustomobject]@{ Label = "Repository"; Value = $Context.repositoryRoot },
        [pscustomobject]@{ Label = "Config"; Value = $Context.configPath },
        [pscustomobject]@{ Label = "State"; Value = $Context.statePath },
        [pscustomobject]@{ Label = "Sessions"; Value = $Context.sessionsPath },
        [pscustomobject]@{ Label = "Events"; Value = $Context.eventsPath },
        [pscustomobject]@{ Label = "Preview"; Value = $Context.previewPath },
        [pscustomobject]@{ Label = "Worktrees"; Value = $Context.worktreeRoot }
    )) {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) $($item.Label): $([string]$item.Value)"
    }
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Inspect runtime placement and cleanup risk: factory runtime"
}

function Write-CliRuntime {
    param($Context, [string]$Action)

    $runtimeAction = if ($Action) { $Action.ToLowerInvariant() } else { "status" }
    if ($runtimeAction -notin @("status", "migrate")) { throw "Unknown runtime action '$Action'. Use: factory runtime [status|migrate]" }
    if ($runtimeAction -eq "migrate") {
        $result = Invoke-CliJsonScript -ScriptName "migrate-runtime.ps1" -Arguments @(
            "-Repository", [string]$Context.repositoryRoot,
            "-ClaudeCommand", $ClaudeCommand
        )
        if ([bool](Get-CliProperty -InputObject $result -Name "alreadyExternal" -Default $false)) {
            Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Factory runtime already external $($script:Tree.Horizontal) $([string]$Context.projectKey)"
            Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Location: $([string]$result.destination)"
            Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Nothing was copied or removed."
            return
        }
        Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Factory runtime migrated $($script:Tree.Horizontal) $([string]$result.projectKey)"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Verified: $([int]$result.files) file(s), $([long]$result.bytes) byte(s)"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Active copy: $([string]$result.destination)"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Legacy copy retained: $([string]$result.source)"
        if ([string]$result.warning) { Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Warning: $([string]$result.warning)" }
        Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Start the factory again after verifying: factory runtime"
        return
    }

    $runtimeHome = [IO.Path]::GetFullPath([string]$Context.runtimeHome).TrimEnd('\', '/')
    $pluginRootPath = [IO.Path]::GetFullPath([string]$Context.pluginRoot).TrimEnd('\', '/')
    $pluginPrefix = $pluginRootPath + [IO.Path]::DirectorySeparatorChar
    $insidePluginCheckout = (
        $runtimeHome.Equals($pluginRootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $runtimeHome.StartsWith($pluginPrefix, [StringComparison]::OrdinalIgnoreCase)
    )
    $bytes = 0L
    $files = 0
    if (Test-Path -LiteralPath ([string]$Context.projectData) -PathType Container) {
        foreach ($item in @(Get-ChildItem -LiteralPath ([string]$Context.projectData) -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $bytes += [long]$item.Length
            $files++
        }
    }
    $size = if ($bytes -ge 1GB) { "{0:N2} GiB" -f ($bytes / 1GB) } elseif ($bytes -ge 1MB) { "{0:N1} MiB" -f ($bytes / 1MB) } elseif ($bytes -ge 1KB) { "{0:N1} KiB" -f ($bytes / 1KB) } else { "$bytes bytes" }
    $ownerPath = Join-Path ([string]$Context.projectData) "factory-lock-owner.json"
    $lockLogPath = Join-Path ([string]$Context.projectData) "factory-locks.jsonl"
    $ownerText = "none"
    if (Test-Path -LiteralPath $ownerPath -PathType Leaf) {
        try {
            $owner = Read-FactoryJson -Path $ownerPath
            $ownerLiveness = if (Test-FactoryRecordedProcess -ProcessRecord $owner) { "live" } else { "stale record; process is not live" }
            $ownerText = "PID $([int]$owner.pid), $([string]$owner.caller), since $([string]$owner.acquiredAt) ($ownerLiveness)"
        } catch {
            $ownerText = "unreadable: $($_.Exception.Message)"
        }
    }
    $externalHome = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "ClaudeFactory" } else { "an external non-repository directory" }

    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Factory runtime $($script:Tree.Horizontal) $([string]$Context.projectKey)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Home: $runtimeHome"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Resolution: $([string]$Context.runtimeSource)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Project data: $([string]$Context.projectData)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Stored: $files file(s), $size"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) State: $([string]$Context.statePath)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Current state-lock owner: $ownerText"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Slow lock/timeout log: $lockLogPath"
    if ($insidePluginCheckout) {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Risk: runtime is inside the plugin checkout and ignored by Git; git clean -x can erase it."
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Recommended external home: $externalHome"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) No data was moved. Stop and back up the factory before changing CLAUDE_FACTORY_HOME."
    } else {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Placement: outside the plugin checkout."
        if (Test-Path -LiteralPath ([string]$Context.legacyProjectData) -PathType Container) {
            Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Retained legacy copy: $([string]$Context.legacyProjectData)"
        }
    }
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Project mapping is automatic from the canonical repository path; no manual project-directory mapping is required."
}

function Write-CliPreview {
    param($Context, [string]$Action, [string]$TaskId = "", [bool]$SuppressBrowser = $false)

    $previewParameters = @{
        Action = $Action
        Repository = [string]$Context.repositoryRoot
        RuntimeHome = [string]$Context.runtimeHome
    }
    if ($TaskId) { $previewParameters.TaskId = $TaskId }
    if ($SuppressBrowser) { $previewParameters.NoOpen = $true }
    $previewOutput = (& (Join-Path $PSScriptRoot "factory-preview.ps1") @previewParameters | Out-String).Trim()
    if (-not $previewOutput) { throw "factory-preview.ps1 returned no data." }
    try {
        $result = $previewOutput | ConvertFrom-Json
    } catch {
        throw "factory-preview.ps1 returned invalid JSON: $(Get-CliShortSummary -Value $previewOutput -MaximumLength 300)"
    }

    if ($Action -eq "stop") {
        if ([bool](Get-CliProperty -InputObject $result -Name "taskMismatch" -Default $false)) {
            Write-Output "Active preview belongs to task $([string]$result.taskId); nothing was stopped."
        } elseif ([bool](Get-CliProperty -InputObject $result -Name "alreadyStopped" -Default $false)) {
            Write-Output "Factory preview: stopped"
        } else {
            Write-Output "Factory preview stopped: $([string]$result.taskId)"
        }
        return
    }

    if ($Action -eq "status") {
        if (-not [bool](Get-CliProperty -InputObject $result -Name "exists" -Default $false)) {
            $staleText = if ([bool](Get-CliProperty -InputObject $result -Name "staleCleaned" -Default $false)) {
                " (stale runtime cleaned)"
            } else { "" }
            Write-Output "Factory preview: stopped$staleText"
            Write-Output "Start one with: factory preview <task-id>"
            return
        }
    }

    $taskIdValue = [string](Get-CliProperty -InputObject $result -Name "taskId")
    $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $result -Name "title") -Fallback "Untitled task"
    $running = [bool](Get-CliProperty -InputObject $result -Name "running" -Default $false)
    $stateText = if ($running) { "running" } elseif ([bool](Get-CliProperty -InputObject $result -Name "degraded" -Default $false)) { "degraded" } else { "starting" }
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Preview $($script:Tree.Horizontal) $taskIdValue $($script:Tree.Horizontal) $title"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) State: $stateText"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) App: $([string]$result.url)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Worktree: $([string]$result.worktree)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Processes: Laravel $([int]$result.app.pid) / Vite $([int]$result.assets.pid)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Ports: app $([int]$result.appPort) / assets $([int]$result.assetPort)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Database: project development environment (not the isolated test database)"
    $switchedFrom = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $result -Name "switchedFrom")
    if ($switchedFrom) { Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Switched: stopped preview $switchedFrom" }
    if ([bool](Get-CliProperty -InputObject $result -Name "reused" -Default $false)) {
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Reused the existing preview processes."
    }
    $browserWarning = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $result -Name "browserWarning")
    if ($browserWarning) { Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Browser warning: $browserWarning" }
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Logs: $([string]$result.artifactRoot)"
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Stop: factory preview stop"
}

function Write-CliConfig {
    param($Context, [string]$Action)

    $configAction = if ($Action) { $Action.ToLowerInvariant() } else { "path" }
    if ($configAction -notin @("path", "edit")) { throw "Unknown config action '$Action'. Use: factory config [path|edit]" }
    if ($configAction -eq "path") {
        Write-Output ([string]$Context.configPath)
        return
    }
    & (Join-Path $pluginRoot "edit-project-config.ps1") -Repository ([string]$Context.repositoryRoot) -RuntimeHome ([string]$Context.runtimeHome)
}

function Write-CliSchedulerResult {
    param($Result, [string]$Action)

    if ($Action -eq "tick") {
        Write-Output "Native tick: integrated $([int](Get-CliProperty -InputObject $Result -Name 'integratedCount' -Default 0)); launched $([int](Get-CliProperty -InputObject $Result -Name 'launchedCount' -Default 0)); active $([int](Get-CliProperty -InputObject $Result -Name 'activeWorkers' -Default 0)); queued $([int](Get-CliProperty -InputObject $Result -Name 'queued' -Default 0))"
        foreach ($pipeline in @(Get-CliProperty -InputObject $Result -Name "integrated" -Default @())) {
            Write-Output "  published $([string]$pipeline.taskId): $([string]$pipeline.commit)"
        }
        foreach ($launch in @(Get-CliProperty -InputObject $Result -Name "launched" -Default @())) {
            $session = Get-CliProperty -InputObject $launch -Name "backgroundSession"
            $attach = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $session -Name "attachCommand")
            if (-not $attach) { $attach = "session $(Get-CliShortId -Value (Get-CliProperty -InputObject $session -Name 'id')) is starting" }
            Write-Output "  launched $([string]$launch.taskId): $attach"
        }
        foreach ($errorText in @(Get-CliProperty -InputObject $Result -Name "errors" -Default @())) {
            Write-Output "  error: $(ConvertTo-CliLine -Value $errorText)"
        }
        return
    }
    $scheduler = Get-CliProperty -InputObject $Result -Name "scheduler"
    if ($null -eq $scheduler) { $scheduler = $Result }
    Write-Output "Native scheduler: $([string]$scheduler.status)"
    Write-Output "Factory: $(if ([bool]$scheduler.paused) { 'paused' } elseif ([bool]$scheduler.active) { 'active' } else { 'idle' })"
    if ([bool]$scheduler.running) { Write-Output "Process: PID $([int]$scheduler.pid); interval $([int]$scheduler.intervalSeconds)s" }
    if ([string]$scheduler.activity -and [string]$scheduler.activity -ne "idle") {
        Write-Output "Activity: $([string]$scheduler.activity) $([string]$scheduler.activityTaskId) $([string]$scheduler.activityTaskTitle) since $([string]$scheduler.activitySince)"
    }
    if ([string]$scheduler.heartbeatAt) { Write-Output "Heartbeat: $([string]$scheduler.heartbeatAt)" }
    if ([string]$scheduler.lastTickAt) { Write-Output "Last tick: $([string]$scheduler.lastTickAt)" }
    if ([string]$scheduler.lastError) { Write-Output "Last error: $(ConvertTo-CliLine -Value $scheduler.lastError)" }
    $warning = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $Result -Name "warning")
    $problem = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $scheduler -Name "problem")
    if ($warning) {
        Write-Output "Problem: $warning"
    } elseif ($problem) {
        Write-Output "Problem: $problem"
    }
    if ([string]$scheduler.lastExitReason) { Write-Output "Last exit: $(ConvertTo-CliLine -Value $scheduler.lastExitReason)" }
    if ([string]$scheduler.stdoutPath) { Write-Output "Tick log: $([string]$scheduler.stdoutPath)" }
    if ([string]$scheduler.stderrPath) { Write-Output "Error log: $([string]$scheduler.stderrPath)" }
}

function Invoke-CliSchedulerAction {
    param($Context, [string]$Action)

    $result = Invoke-CliJsonScript -ScriptName "factory-scheduler.ps1" -Arguments @(
        "-Action", $Action,
        "-Repository", [string]$Context.repositoryRoot,
        "-ClaudeCommand", $ClaudeCommand,
        "-RuntimeHome", [string]$Context.runtimeHome
    )
    if ($Action -eq "resume") {
        if ($null -ne (Get-CliProperty -InputObject $result -Name "resumed") -and -not [bool](Get-CliProperty -InputObject $result -Name "resumed" -Default $true)) {
            Write-Output "Resume refused: $(ConvertTo-CliLine -Value (Get-CliProperty -InputObject $result -Name 'reason'))"
        }
        Write-CliSchedulerResult -Result (Get-CliProperty -InputObject $result -Name "scheduler") -Action "status"
        $tickResult = Get-CliProperty -InputObject $result -Name "tick"
        if ($null -ne $tickResult) { Write-CliSchedulerResult -Result $tickResult -Action "tick" }
        return
    }
    Write-CliSchedulerResult -Result $result -Action $Action
}

function Get-CliResolvedCodexCommand {
    param($Context)

    $config = Read-FactoryJson -Path ([string]$Context.configPath)
    $configured = Get-FactoryConfiguredCodexCommand -Config $config -ExplicitCommand $CodexCommand
    $resolved = Resolve-FactoryCodexCommand -Config $config -ExplicitCommand $configured
    $capabilities = Get-FactoryCodexCapabilities -CodexCommand $resolved
    if (-not [bool]$capabilities.supported) {
        throw "Codex shared-session runtime is unavailable: $($capabilities.detail)"
    }
    return $resolved
}

function Write-CliCodexServer {
    param($Context, [string]$Action)

    $actionKey = if ($Action) { $Action.ToLowerInvariant() } else { "status" }
    if ($actionKey -notin @("status", "start", "stop", "restart")) {
        throw "Unknown codex-server action '$Action'. Use: factory codex-server [status|start|stop|restart]"
    }
    $resolved = Get-CliResolvedCodexCommand -Context $Context
    if ($actionKey -eq "stop" -or $actionKey -eq "restart") {
        $stop = Stop-FactoryCodexSharedServer -CodexCommand $resolved -RuntimeHome ([string]$Context.runtimeHome)
        Write-Output "Shared Codex app-server: $(if ([bool]$stop.alreadyStopped) { 'already stopped' } else { "stopped PID $([int]$stop.pid)" })"
        if ($actionKey -eq "stop") { return }
    }
    if ($actionKey -eq "start" -or $actionKey -eq "restart") {
        $server = Start-FactoryCodexSharedServer -CodexCommand $resolved -RuntimeHome ([string]$Context.runtimeHome)
        $remote = $null
        try {
            $remote = Enable-FactoryCodexSharedRemoteControl -CodexCommand $resolved -RuntimeHome ([string]$Context.runtimeHome) -Endpoint ([string]$server.endpoint)
        } catch {
            Write-Warning "Server started, but Codex Remote could not be enabled: $($_.Exception.Message)"
        }
        Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Shared Codex app-server $($script:Tree.Horizontal) $(if ([bool]$server.created) { 'started' } else { 'already running' })"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Endpoint: $([string]$server.endpoint)"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) PID: $([int]$server.pid)"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Remote: $(if ($null -ne $remote) { [string]$remote.status } else { 'unavailable' })"
        Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Agent dashboard: factory agents"
        return
    }

    $status = Get-FactoryCodexSharedServerStatus -CodexCommand $resolved -RuntimeHome ([string]$Context.runtimeHome) -Probe
    $remoteStatus = "unavailable"
    if ([bool]$status.healthy) {
        try {
            $remote = Get-FactoryCodexSharedRemoteControlStatus -CodexCommand $resolved -RuntimeHome ([string]$Context.runtimeHome) -Endpoint ([string]$status.endpoint)
            $remoteStatus = [string]$remote.status
        } catch {
            $remoteStatus = "unavailable ($($_.Exception.Message))"
        }
    }
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Shared Codex app-server $($script:Tree.Horizontal) $(if ([bool]$status.healthy) { 'running' } elseif ([bool]$status.alive) { 'unhealthy' } else { 'stopped' })"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Endpoint: $(ConvertTo-CliLine -Value $status.endpoint -Fallback 'none')"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) PID: $(if ([int]$status.pid -gt 0) { [int]$status.pid } else { 'none' })"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Remote: $remoteStatus"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Record: $([string]$status.recordPath)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Output: $([string]$status.stdoutPath)"
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Errors: $([string]$status.stderrPath)"
}

function Start-CliCodexAgents {
    param($Context)

    if ($env:CLAUDE_FACTORY_ORCHESTRATOR) {
        throw "'factory agents' opens an interactive TUI. Run it from a separate PowerShell window, not from inside the orchestrator."
    }
    $resolved = Get-CliResolvedCodexCommand -Context $Context
    $server = Start-FactoryCodexSharedServer -CodexCommand $resolved -RuntimeHome ([string]$Context.runtimeHome)
    try {
        $null = Enable-FactoryCodexSharedRemoteControl -CodexCommand $resolved -RuntimeHome ([string]$Context.runtimeHome) -Endpoint ([string]$server.endpoint)
    } catch {
        Write-Warning "The agent dashboard is available locally, but Codex Remote could not be enabled: $($_.Exception.Message)"
    }
    & $resolved agents --remote ([string]$server.endpoint) -C ([string]$Context.repositoryRoot)
    $script:CliExitCode = [int]$LASTEXITCODE
}

function Start-CliFactory {
    param($Context)

    $arguments = @{
        Repository = [string]$Context.repositoryRoot
        ClaudeCommand = $ClaudeCommand
        CodexCommand = $CodexCommand
        RuntimeHome = [string]$Context.runtimeHome
    }
    if ($New) { $arguments.New = $true }
    if ($ResumeSession) { $arguments.Resume = $true }
    if ($Continue) { $arguments.Continue = $true }
    if ($Model) { $arguments.Model = $Model }
    if ($Agent) { $arguments.Agent = $Agent }
    & (Join-Path $pluginRoot "start-factory.ps1") @arguments
    $script:CliExitCode = $LASTEXITCODE
}

function Restart-CliFactoryOrchestrator {
    param($Context)

    if ($env:CLAUDECODE) {
        throw "'factory restart' cannot run inside a Claude orchestrator tool call because CLAUDECODE is set. Exit the orchestrator TUI to PowerShell, then run 'factory restart'; no session ID is required."
    }
    if ($env:CLAUDE_FACTORY_ORCHESTRATOR) {
        throw "'factory restart' cannot run inside an orchestrator. CLAUDE_FACTORY_ORCHESTRATOR is set in this shell. If the TUI is closed, this is a stale value from an earlier 'factory start' in this window - clear it and retry: Remove-Item Env:CLAUDE_FACTORY_ORCHESTRATOR. Or open a new PowerShell window. No session ID is required."
    }

    $config = Read-FactoryJson -Path ([string]$Context.configPath)
    $runtime = [string](Get-CliProperty -InputObject $config -Name "workerAgent" -Default "claude")
    if ($runtime -notin @("claude", "codex")) { throw "Unsupported orchestrator runtime '$runtime'." }

    $pendingRotation = Get-FactoryPendingOrchestratorRotation -Context $Context -Runtime $runtime
    if ($null -ne $pendingRotation) {
        throw "A $runtime orchestrator rotation is pending. Run 'factory rotate cancel' to restart the same conversation, or exit the TUI and run the start command printed by 'factory rotate status' to activate the fresh handoff."
    }

    if ($runtime -eq "claude") {
        if (Test-Path -LiteralPath (Join-Path ([string]$Context.projectData) 'orchestrator-launch.json')) {
            throw "A Claude orchestrator launch is unresolved. Run 'factory start' to recover its recorded row before restarting. No sessions were stopped."
        }
        $identityPath = Get-FactoryOrchestratorIdentityPath -Context $Context -Runtime "claude"
        $identity = if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
            try { Read-FactoryJson -Path $identityPath } catch { $null }
        } else { $null }
        $name = if (
            $null -ne $identity -and
            [string](Get-CliProperty -InputObject $identity -Name "name") -and
            (Test-FactorySamePath `
                -Left ([string](Get-CliProperty -InputObject $identity -Name "repositoryRoot")) `
                -Right ([string]$Context.repositoryRoot))
        ) { [string]$identity.name } else { "Claude Factory Orchestrator" }
        $storedSessionId = if (
            $null -ne $identity -and
            [string](Get-CliProperty -InputObject $identity -Name "sessionId") -and
            [string](Get-CliProperty -InputObject $identity -Name "name") -ceq $name -and
            (Test-FactorySamePath `
                -Left ([string](Get-CliProperty -InputObject $identity -Name "repositoryRoot")) `
                -Right ([string]$Context.repositoryRoot))
        ) { [string]$identity.sessionId } else { "" }

        $rows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
        $matchingRows = @(Get-FactoryMatchingOrchestratorRows `
            -Rows $rows `
            -RepositoryRoot ([string]$Context.repositoryRoot) `
            -Name $name -SessionId $storedSessionId)
        $interactiveRows = @($matchingRows | Where-Object {
            [string](Get-CliProperty -InputObject $_ -Name "kind") -eq "interactive" -and
            -not (Test-FactoryTerminalAgentRow -Row $_)
        })
        if ($interactiveRows.Count -gt 0) {
            throw "The Claude orchestrator is still open interactively. Exit that TUI to PowerShell, then run 'factory restart' again; no session ID is required."
        }

        $liveBackgroundRows = @($matchingRows | Where-Object {
            [string](Get-CliProperty -InputObject $_ -Name "kind") -eq "background" -and
            [string](Get-CliProperty -InputObject $_ -Name "id") -and
            -not (Test-FactoryTerminalAgentRow -Row $_)
        })
        $selected = Select-FactoryOrchestratorConversation -Rows $matchingRows -PreferredSessionId $storedSessionId -IdentityUpdatedAt (Get-CliProperty -InputObject $identity -Name 'updatedAt')
        if ($null -ne $selected) {
            $storedSessionId = [string](Get-CliProperty -InputObject $selected -Name "sessionId")
        }
        if ($liveBackgroundRows.Count -gt 0 -and -not $storedSessionId) {
            throw "The live Claude orchestrator has no resumable session UUID. Stop it manually only after preserving its conversation; Factory refused to replace it."
        }

        foreach ($row in $liveBackgroundRows) {
            Stop-FactoryClaudeSessionAndWait `
                -ClaudeCommand $ClaudeCommand `
                -BackgroundId ([string]$row.id)
        }
        if ($storedSessionId) {
            Write-FactoryOrchestratorIdentity `
                -Path $identityPath `
                -RepositoryRoot ([string]$Context.repositoryRoot) `
                -Name $name `
                -SessionId $storedSessionId
        }

        Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Factory orchestrator restart $($script:Tree.Horizontal) claude"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Stopped: $(if ($liveBackgroundRows.Count -gt 0) { @($liveBackgroundRows | ForEach-Object { [string]$_.id }) -join ', ' } else { 'no live background row' })"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Conversation: $(if ($storedSessionId) { "resume $storedSessionId" } else { 'start a new stored conversation' })"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Preserved: scheduler, workers, tasks, worktrees, and previews"
        Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Starting the orchestrator with the currently resolved Claude executable..."
    } else {
        Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Factory orchestrator restart $($script:Tree.Horizontal) codex"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Codex has no external Agent View process to stop by ID."
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Preserved: scheduler, workers, tasks, worktrees, and previews"
        Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Resuming the stored Codex orchestrator thread..."
    }

    $arguments = @{
        Repository = [string]$Context.repositoryRoot
        ClaudeCommand = $ClaudeCommand
        CodexCommand = $CodexCommand
        RuntimeHome = [string]$Context.runtimeHome
        Agent = $runtime
    }
    if ($runtime -eq "claude") { $arguments.Name = $name }
    & (Join-Path $pluginRoot "start-factory.ps1") @arguments
    $script:CliExitCode = $LASTEXITCODE
}

function Write-CliRotate {
    param($Context, [string]$Action)

    $config = Read-FactoryJson -Path ([string]$Context.configPath)
    $runtime = [string](Get-CliProperty -InputObject $config -Name "workerAgent" -Default "claude")
    if ($runtime -notin @("claude", "codex")) { throw "Unsupported orchestrator runtime '$runtime'." }
    $rotationAction = if ($Action) { $Action.ToLowerInvariant() } else { "request" }
    if ($rotationAction -notin @("request", "status", "cancel")) {
        throw "Unknown rotate action '$Action'. Use: factory rotate [status|cancel]"
    }

    if ($rotationAction -eq "status") {
        $pending = Get-FactoryPendingOrchestratorRotation -Context $Context -Runtime $runtime
        if ($null -eq $pending) {
            Write-Output "No $runtime orchestrator rotation is pending."
            return
        }
        Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Orchestrator rotation pending $($script:Tree.Horizontal) $runtime"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Requested: $([string]$pending.requestedAt)"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Previous session: $(ConvertTo-CliLine -Value $pending.previousSessionId -Fallback 'none')"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Handoff: $([string]$pending.handoffPath)"
        Write-Output "$($script:Tree.Last)$($script:Tree.Horizontal) Next: $(if ($runtime -eq 'codex') { 'factory start -Agent codex' } else { 'factory start' })"
        return
    }

    if ($rotationAction -eq "cancel") {
        $cancelled = Cancel-FactoryOrchestratorRotation -Context $Context -Runtime $runtime
        if ($null -eq $cancelled) {
            Write-Output "No $runtime orchestrator rotation was pending."
        } else {
            Write-Output "Cancelled $runtime orchestrator rotation '$([string]$cancelled.rotationId)'. The saved handoff and old session were retained."
        }
        return
    }

    $state = Read-FactoryJson -Path ([string]$Context.statePath)
    $rotation = Request-FactoryOrchestratorRotation -Context $Context -Config $config -State $state
    $nextCommand = if ($runtime -eq "codex") { "factory start -Agent codex" } else { "factory start" }
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Orchestrator rotation prepared $($script:Tree.Horizontal) $runtime"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Previous session: $(ConvertTo-CliLine -Value $rotation.previousSessionId -Fallback 'none')"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Handoff: $([string]$rotation.handoffPath)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Saved tasks: $([int]$rotation.savedTaskCount); unfinished: $([int]$rotation.unfinishedTaskCount)"
    Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Exit the current orchestrator if it is open. Tasks, workers, worktrees, and the scheduler stay intact."
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Next: $nextCommand"
}

function Write-CliWait {
    param($Context, [int]$TimeoutSeconds, [long]$Cursor = -1)

    $arguments = @(
        "-Repository", [string]$Context.repositoryRoot,
        "-TimeoutSeconds", [string]$TimeoutSeconds
    )
    if ($Cursor -ge 0) { $arguments += @("-Cursor", [string]$Cursor) }
    $result = Invoke-CliJsonScript -ScriptName "wait-factory.ps1" -Arguments $arguments
    if (-not [bool](Get-CliProperty -InputObject $result -Name "signaled" -Default $false)) {
        Write-Output "No new factory attention edge became ready before the wait timeout. Cursor: $([long](Get-CliProperty -InputObject $result -Name 'cursor' -Default 0))."
        return
    }

    $actions = @(Get-CliProperty -InputObject $result -Name "actions" -Default @())
    Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Factory needs attention $($script:Tree.Horizontal) $($actions.Count)"
    for ($index = 0; $index -lt $actions.Count; $index++) {
        $action = $actions[$index]
        $connector = if ($index -eq $actions.Count - 1) { $script:Tree.Last } else { $script:Tree.Branch }
        $detailPrefix = if ($index -eq $actions.Count - 1) { "   " } else { "$($script:Tree.Vertical)  " }
        $taskId = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $action -Name "taskId")
        $title = ConvertTo-CliLine -Value (Get-CliProperty -InputObject $action -Name "title") -Fallback "Factory"
        $identity = if ($taskId) { "$taskId $($script:Tree.Horizontal) $title" } else { $title }
        $actionLines = New-Object Collections.Generic.List[string]
        Add-CliWrappedLine -Lines $actionLines -FirstPrefix "$connector$($script:Tree.Horizontal) " -ContinuationPrefix "$detailPrefix   " -Text "$([string]$action.kind) $($script:Tree.Horizontal) $identity"
        Add-CliWrappedLine -Lines $actionLines -FirstPrefix "$detailPrefix$($script:Tree.Branch)$($script:Tree.Horizontal) " -ContinuationPrefix "$detailPrefix$($script:Tree.Vertical)  " -Text "Reason: $([string]$action.reason)"
        if ([string]$action.occurredAt) {
            Add-CliWrappedLine -Lines $actionLines -FirstPrefix "$detailPrefix$($script:Tree.Branch)$($script:Tree.Horizontal) " -ContinuationPrefix "$detailPrefix$($script:Tree.Vertical)  " -Text "Since: $([string]$action.occurredAt)"
        }
        Add-CliWrappedLine -Lines $actionLines -FirstPrefix "$detailPrefix$($script:Tree.Last)$($script:Tree.Horizontal) " -ContinuationPrefix "$detailPrefix   " -Text "$($script:Tree.Arrow) Next: $([string]$action.command)"
        $actionLines | Write-Output
    }
    Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Signal detected $($script:Tree.Horizontal) cursor $([long]$result.cursor) $($script:Tree.Horizontal) $([string]$result.detectedAt)"
}

function Write-CliPurge {
    param($Context, [bool]$Confirm, [bool]$ForceRemoval)

    $registered = New-Object Collections.Generic.List[string]
    foreach ($line in @(& git -C ([string]$Context.repositoryRoot) worktree list --porcelain)) {
        if ($line -like "worktree *") {
            $path = [IO.Path]::GetFullPath($line.Substring(9))
            if ($path.StartsWith([string]$Context.worktreeRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $registered.Add($path)
            }
        }
    }
    if (-not $Confirm) {
        Write-Output "$($script:Tree.Top)$($script:Tree.Horizontal) Project purge preview $($script:Tree.Horizontal) $([string]$Context.projectKey)"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Private runtime: $([string]$Context.projectData)"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Worktree root: $([string]$Context.worktreeRoot)"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Registered factory worktrees: $($registered.Count)"
        foreach ($path in $registered) { Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Worktree: $path" }
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Safe confirmation: factory purge -Yes"
        Write-Output "$($script:Tree.Branch)$($script:Tree.Horizontal) Emergency dirty-worktree removal: factory purge -Yes -Force"
        Write-Output "$($script:Tree.Bottom)$($script:Tree.Horizontal) Nothing was removed."
        return
    }
    $cleanupArguments = @("-Repository", [string]$Context.repositoryRoot, "-RuntimeHome", [string]$Context.runtimeHome)
    if ($ForceRemoval) { $cleanupArguments += "-Force" }
    & (Join-Path $pluginRoot "cleanup-project.ps1") @cleanupArguments
    if ($LASTEXITCODE -ne 0) { throw "Project cleanup failed with exit code $LASTEXITCODE." }
}

function Write-CliHelp {
    param([string]$Topic)

    $topicKey = $Topic.ToLowerInvariant()
    if (-not $topicKey) {
        @(
            "Factory CLI - deterministic local commands (no AI interpretation)",
            "",
            "PowerShell:",
            "  factory start [-New|-Resume|-Continue] [-Model name] [-Agent claude|codex]",
            "  factory restart",
            "  factory rotate [status|cancel]",
            "  factory agents",
            "  factory codex-server [status|start|stop|restart]",
            "  factory status [state|all] [-Limit 50]",
            "  factory archive:seed [--preview]",
            "  factory inspect <task-id>",
            "  factory preview [<task-id>|stop] [-NoOpen]",
            "  factory chat <task-id>",
            "  factory new [--auto] <file> [title] | factory new [--auto] [text]",
            "  factory add --file <task.json>",
            "  factory go <task-id> [--direct]",
            "  factory hold <task-id>",
            "  factory retry <task-id>",
            "  factory reject <task-id> [-Yes|-Keep] [reason]",
            "  factory cleanup <task-id>",
            "  factory concurrency [number]",
            "  factory doctor",
            "  factory completion [status|enable]",
            "  factory paths",
            "  factory runtime [status|migrate]",
            "  factory config [path|edit]",
            "  factory scheduler [status|start|stop|tick]",
            "  factory wait [timeout-seconds]",
            "  factory pause|resume|stop",
            "  factory purge [-Yes] [-Force]",
            "  factory help [command]",
            "",
            "Orchestrator native shell mode (Claude or Codex):",
            "  !factory status",
            "  !factory inspect <task-id>",
            "  !factory preview <task-id>",
            "",
            "PowerShell completes commands, status filters, and saved task IDs with Tab.",
            "AI is used for planning, implementation, conflict-aware sync, and normal review; direct approval and publication are native.",
            "Run 'factory help <command>' for command-specific details."
        ) | Write-Output
        return
    }

    switch ($topicKey) {
        "status" {
            @(
                "factory status [state|all] [-NoReconcile] [-Limit 50]",
                "Shows the actionable workflow tree from private factory state.",
                "COMPLETED counts distinct produced task IDs across archive and live state; rejected outcomes are excluded.",
                "Default hides completed rows; use 'factory status done --limit 25' for newest history rows.",
                "Missing archives are reported explicitly; use 'factory archive:seed' to recover history.",
                "Reconciliation updates session-derived state first unless -NoReconcile is supplied."
            ) | Write-Output
        }
        "inspect" {
            @(
                "factory inspect <task-id> [-NoReconcile]",
                "Shows identity, requirements, session, artifacts, result, tests, and next action.",
                "Task IDs have dynamic Tab completion in PowerShell."
            ) | Write-Output
        }
        "preview" {
            @(
                "factory preview [<task-id>|stop] [-NoOpen]",
                "Starts Laravel and Vite from one worker worktree and opens its private loopback URL.",
                "Only one preview runs per project: starting another task stops the previous preview first.",
                "With no argument it shows the active preview; 'factory preview stop' stops it.",
                "Preview uses the project development environment, not the isolated worker test database."
            ) | Write-Output
        }
        "chat" {
            @(
                "factory chat <task-id>",
                "Resolves the saved Claude or Codex worker session and prints the exact attach command.",
                "Run the printed command in PowerShell; the orchestrator does not start a nested interactive process."
            ) | Write-Output
        }
        "hold" {
            @(
                "factory hold <task-id>",
                "Moves an awaiting-review, approved, or awaiting-input task to held without AI."
            ) | Write-Output
        }
        "retry" {
            @(
                "factory retry <task-id>",
                "Queues another worker attempt for a machine failure without AI.",
                "It also accepts starting or planning tasks that have no recorded background session.",
                "The retained worktree is reused when present, and the native scheduler is woken asynchronously."
            ) | Write-Output
        }
        "go" {
            @(
                "factory go <task-id> [--direct]",
                "Approves the exact commit and immutable publication plan without AI interpretation.",
                "--direct skips independent AI code review but still requires passed worker checks, a clean current-base commit, and trusted integration commands.",
                "It refuses to override an existing changes-required or blocked review.",
                "A failed publication attempt requires a fresh review; the previous immutable plan cannot be retried.",
                "The native scheduler checks both prepared candidates in parallel, then pushes the verified branches sequentially.",
                "Publication runs asynchronously; monitor it with 'factory inspect <task-id>'."
            ) | Write-Output
        }
        "add" {
            @(
                "factory add --file <task.json>",
                "Validates and imports a normalized task envelope without AI or a source connector.",
                "The file follows resources/intake.schema.json; successful queued work wakes the native scheduler."
            ) | Write-Output
        }
        "new" {
            @(
                "factory new [--auto] <file> [title]",
                "factory new [--auto] [text]",
                "Creates a native local task without AI, Asana, or an intermediate JSON file.",
                "File first, optional quoted title second. By default the title is the filename without its extension.",
                "Reads the UTF-8 file verbatim (up to 20000 characters), without modifying or deleting it.",
                "The default is interactive planning. With no input, the worker asks what to implement; --auto requires text or a non-empty file.",
                "The native scheduler starts or wakes automatically. Open the worker with 'factory chat <task-id>'."
            ) | Write-Output
        }
        "reject" {
            @(
                "factory reject <task-id> [reason]",
                "Previews destructive removal when task artifacts exist.",
                "Confirm with -Yes (or --yes); preserve artifacts with -Keep (or --keep).",
                "A confirmed reject removes the task from state plus its isolated worktree, branch, sessions, metadata, and test database."
            ) | Write-Output
        }
        "cleanup" {
            @(
                "factory cleanup <task-id>",
                "Safely removes published worker artifacts and retains the task as done history.",
                "Cleanup refuses unpublished commits, dirty worktrees, active tasks, or commits missing from configured remote branches."
            ) | Write-Output
        }
        "concurrency" {
            @(
                "factory concurrency [number]",
                "Shows or changes the worker concurrency limit without AI.",
                "Changing the limit does not create a missing scheduler; use /factory resume when prompted."
            ) | Write-Output
        }
        "completion" {
            @(
                "factory completion [status|enable]",
                "Diagnoses the current PowerShell Tab binding.",
                "'enable' selects PSReadLine MenuComplete for this terminal only; it never edits your profile."
            ) | Write-Output
        }
        "start" {
            @(
                "factory start [-New|-Resume|-Continue] [-Model name] [-Agent claude|codex]",
                "Starts or reuses the repository's Factory Orchestrator and starts its native scheduler.",
                "Without -Agent, both orchestrator and new workers use Claude. '-Agent codex' selects Codex for both.",
                "Existing worker attempts keep the runtime with which they were launched.",
                "Run this from PowerShell, not from inside an already open orchestrator."
            ) | Write-Output
        }
        "restart" {
            @(
                "factory restart",
                "Restarts only this repository's selected orchestrator and resumes its exact stored conversation.",
                "For Claude, it discovers and stops the matching background orchestrator itself; no Agent View ID is required.",
                "Scheduler, workers, tasks, worktrees, and previews stay intact.",
                "Exit the current orchestrator TUI first and run this command from PowerShell."
            ) | Write-Output
        }
        "rotate" {
            @(
                "factory rotate [status|cancel]",
                "Prepares a deterministic handoff and makes the next normal start create a fresh orchestrator conversation.",
                "Run it inside the current orchestrator, exit that TUI, then run the exact printed factory start command.",
                "Tasks, workers, worktrees, scheduler state, and the previous resumable conversation are retained.",
                "Use 'status' to inspect a pending rotation or 'cancel' to keep using the stored conversation."
            ) | Write-Output
        }
        "paths" {
            @(
                "factory paths",
                "Shows the repository, private config/state/session paths, and external worktree root."
            ) | Write-Output
        }
        "runtime" {
            @(
                "factory runtime [status|migrate]",
                "Shows the exact private runtime home/project path, size, current mutex owner, and slow-lock log.",
                "migrate requires an exited orchestrator, stopped scheduler, no live workers or publication, and a free test lane.",
                "It copies and SHA-256 verifies the project runtime under LocalAppData, switches automatic resolution, and retains the legacy source copy."
            ) | Write-Output
        }
        "config" {
            @(
                "factory config [path|edit]",
                "Prints the private per-project config path or opens it in the configured editor."
            ) | Write-Output
        }
        "agents" {
            @(
                "factory agents",
                "Opens Codex's shared agent-session dashboard against the Factory-managed app-server.",
                "Run it in a separate PowerShell window; it is an interactive TUI, not an orchestrator subcommand."
            ) | Write-Output
        }
        "codex-server" {
            @(
                "factory codex-server [status|start|stop|restart]",
                "Controls the persistent loopback Codex app-server shared by Factory projects in the same runtime home.",
                "Codex orchestrators and 'factory agents' connect to this server; Remote is enabled for phone visibility.",
                "Stopping or restarting it disconnects every attached Factory Codex terminal under that runtime home."
            ) | Write-Output
        }
        "scheduler" {
            @(
                "factory scheduler [status|start|stop|tick]",
                "Controls only the deterministic local scheduler process; start/stop do not change the factory pause flag.",
                "Use factory pause/resume to suspend or permit launches and publication.",
                "'tick' reconciles workers, integrates one formally approved commit, and fills worker capacity once."
            ) | Write-Output
        }
        "wait" {
            @(
                "factory wait [timeout-seconds] [--cursor <revision>]",
                "Blocks without AI until a new task or scheduler attention edge is recorded.",
                "It returns for awaiting-input, blocked, failed, a stalled launch, a stopped scheduler with runnable work, or awaiting-review after the worker session closes.",
                "Repeated default waits acknowledge an edge and do not replay it. Pass a saved cursor for an explicit stateless consumer. Omit timeout for an indefinite wait."
            ) | Write-Output
        }
        "purge" {
            @(
                "factory purge [-Yes] [-Force]",
                "Previews removal of this project's entire private runtime and all factory worktrees.",
                "-Yes performs guarded cleanup; -Force additionally permits dirty/unpublished worktree loss."
            ) | Write-Output
        }
        { $_ -in @("tick", "pause", "resume", "stop") } {
            @(
                "factory tick | factory pause | factory resume | factory stop",
                "Controls the native scheduler without an AI request.",
                "pause keeps the process but suspends factory work; resume permits work, starts the process if needed, and requests an asynchronous wake.",
                "stop ends only the scheduler process and preserves active/paused; start never clears an explicit pause."
            ) | Write-Output
        }
        "doctor" {
            @(
                "factory doctor",
                "Runs deterministic local diagnostics and prints OK/WARN/FAIL checks.",
                "It inspects Git remote refs, verifies the selected Claude or Codex runtime, and may connect to the configured test database."
            ) | Write-Output
        }
        "archive:seed" {
            @(
                "factory archive:seed [--preview]",
                "Append summary rows from retained snapshots, the legacy archive, live terminal tasks, and all reachable publication fix/feat subjects.",
                "Rows are unique by (id, commit); COMPLETED counts distinct produced IDs. All source files remain unchanged.",
                "--preview reports candidates without appending. Repeating a seed adds only missing rows."
            ) | Write-Output
        }
        "help" { Write-CliHelp -Topic "" }
        default { throw "Unknown help topic '$Topic'. Run 'factory help' for available commands." }
    }
}

$normalizedCommand = $Command.ToLowerInvariant()
if ($normalizedCommand -eq 'status') {
    $statusTokens = @($Target) + @($Remaining)
    $statusPositionals = New-Object 'Collections.Generic.List[string]'
    for ($index = 0; $index -lt $statusTokens.Count; $index++) {
        if ($statusTokens[$index] -eq '--limit') {
            if ($index + 1 -ge $statusTokens.Count -or -not [int]::TryParse($statusTokens[$index + 1], [ref]$Limit) -or $Limit -lt 1 -or $Limit -gt 1000) {
                throw 'status --limit requires an integer from 1 to 1000.'
            }
            $index++
        } elseif ($statusTokens[$index]) { $statusPositionals.Add($statusTokens[$index]) }
    }
    if ($statusPositionals.Count -gt 1) { throw 'status accepts one state filter and --limit <rows>.' }
    $Target = if ($statusPositionals.Count) { $statusPositionals[0] } else { '' }
    $Remaining = @()
}
$waitCursor = -1L
if ($normalizedCommand -eq "wait") {
    $waitTokens = New-Object Collections.Generic.List[string]
    if ($Target) { $waitTokens.Add([string]$Target) }
    foreach ($value in @($Remaining)) { $waitTokens.Add([string]$value) }
    $positionalWait = New-Object Collections.Generic.List[string]
    for ($index = 0; $index -lt $waitTokens.Count; $index++) {
        if ([string]$waitTokens[$index] -eq "--cursor") {
            if ($index + 1 -ge $waitTokens.Count -or -not [long]::TryParse([string]$waitTokens[$index + 1], [ref]$waitCursor) -or $waitCursor -lt 0) {
                throw "wait --cursor requires a non-negative integer revision."
            }
            $index++
            continue
        }
        $positionalWait.Add([string]$waitTokens[$index])
    }
    if ($positionalWait.Count -gt 1) { throw "wait accepts one optional timeout and --cursor <revision>." }
    $Target = if ($positionalWait.Count -eq 1) { [string]$positionalWait[0] } else { "" }
    $Remaining = @()
}
$remainingValues = New-Object Collections.Generic.List[string]
foreach ($value in @($Remaining)) {
    if ($value -eq "--yes") { $Yes = $true }
    elseif ($value -eq "--keep") { $Keep = $true }
    elseif ($value -eq "--force") { $Force = $true }
    elseif ($value -eq "--new") { $New = $true }
    elseif ($value -eq "--resume") { $ResumeSession = $true }
    elseif ($value -eq "--continue") { $Continue = $true }
    elseif ($value -eq "--auto") { $Auto = $true }
    elseif ($value -eq "--direct") { $Direct = $true }
    elseif ($value -eq "--no-open") { $NoOpen = $true }
    else { $remainingValues.Add([string]$value) }
}
$startOptionsUsed = [bool]($New -or $ResumeSession -or $Continue -or $Model -or $Agent)
$anyDestructiveOptionsUsed = [bool]($Yes -or $Keep -or $Force)
$fileOptionUsed = [bool]$File
$autoOptionUsed = [bool]$Auto
$directOptionUsed = [bool]$Direct
$noOpenOptionUsed = [bool]$NoOpen

if ($autoOptionUsed -and $normalizedCommand -ne "new") {
    throw "--auto is accepted only by: factory new [--auto] <file> [title] | factory new [--auto] [text]"
}
if ($directOptionUsed -and $normalizedCommand -ne "go") {
    throw "--direct is accepted only by: factory go <task-id> [--direct]"
}
if ($noOpenOptionUsed -and $normalizedCommand -ne "preview") {
    throw "--no-open is accepted only by: factory preview <task-id> [--no-open]"
}

if ($normalizedCommand -eq "help") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "help accepts only one command topic." }
    Write-CliHelp -Topic $Target
    exit 0
}

if ($normalizedCommand -eq "completion") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "completion accepts only status or enable." }
    Write-CliCompletion -Action $Target
    exit 0
}

if ($normalizedCommand -eq "status") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "status accepts at most one state filter." }
    $statusArguments = @("-Repository", $Repository, "-ClaudeCommand", $ClaudeCommand)
    if ($CodexCommand) { $statusArguments += @("-CodexCommand", $CodexCommand) }
    if ($NoReconcile) { $statusArguments += "-NoReconcile" }
    $liveStatus = Invoke-CliJsonScript -ScriptName "get-factory-status.ps1" -Arguments $statusArguments
    Write-CliStatus -Context $liveStatus.context -Config $liveStatus.config -State $liveStatus.state `
        -Filter $Target.ToLowerInvariant() -ReconcileWarning $liveStatus.reconcileWarning `
        -TestLease $liveStatus.testLease -TestLeaseError $liveStatus.testLeaseError
    exit 0
}

$context = Get-CliContext
if ($normalizedCommand -eq 'archive:seed') {
    $seedOptions = @(@($Target) + @($remainingValues) | Where-Object { $_ })
    if ($seedOptions.Count -gt 1 -or ($seedOptions.Count -eq 1 -and $seedOptions[0] -notin @('--preview', 'preview')) -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) {
        throw 'archive:seed accepts only optional --preview.'
    }
    $seedArguments = @('-Repository', [string]$context.repositoryRoot)
    if ($seedOptions.Count) { $seedArguments += '-Preview' }
    $result = Invoke-CliJsonScript -ScriptName 'seed-completed-archive.ps1' -Arguments $seedArguments
    $verb = if ($result.preview) { 'Would append' } else { 'Appended' }
    Write-Output "$verb $($result.added) rows; $($result.rows) archive rows; $($result.completedDistinctIds) distinct completed task IDs; $($result.rejectedDistinctIds) rejected IDs."
    foreach ($source in $result.sources) {
        Write-Output "$($source.source): scanned $($source.scanned), eligible $($source.eligible), added $($source.added), duplicates $($source.duplicates), skipped $($source.skipped)."
    }
    $gitSource = @($result.sources | Where-Object { $_.source -like 'git:*' })[0]
    Write-Output "Git subjects contain $($gitSource.distinctSubjectIds) distinct IDs; the archive preserves the union of source IDs, including snapshot IDs absent from those subjects."
    Write-Output $result.gitHistory
    Write-Output $result.legacyFiles
    foreach ($warning in $result.warnings) { Write-Warning $warning }
    Write-Output "Archive: $($result.archivePath)"
    exit 0
}
if ($normalizedCommand -eq "codex-server") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "codex-server accepts only status, start, stop, or restart." }
    Write-CliCodexServer -Context $context -Action $Target
    exit 0
}

if ($normalizedCommand -eq "agents") {
    if ($Target -or $remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "agents does not accept arguments. Use: factory agents" }
    Start-CliCodexAgents -Context $context
    exit $script:CliExitCode
}

if ($normalizedCommand -eq "doctor") {
    if ($Target -or $remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "doctor does not accept arguments. Use: factory doctor" }
    Write-CliDoctor -Context $context
    exit $script:CliExitCode
}

if ($normalizedCommand -eq "start") {
    if ($Target -or $remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $fileOptionUsed) { throw "start accepts only -New, -Resume, -Continue, -Model, -Agent, and -CodexCommand." }
    if (@(@($New, $ResumeSession, $Continue) | Where-Object { $_ }).Count -gt 1) { throw "-New, -Resume, and -Continue are mutually exclusive." }
    Start-CliFactory -Context $context
    exit $script:CliExitCode
}

if ($normalizedCommand -eq "restart") {
    if ($Target -or $remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "restart does not accept arguments. Use: factory restart" }
    Restart-CliFactoryOrchestrator -Context $context
    exit $script:CliExitCode
}

if ($normalizedCommand -eq "rotate") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "rotate accepts only status, cancel, or no argument." }
    Write-CliRotate -Context $context -Action $Target
    exit 0
}

if ($normalizedCommand -eq "paths") {
    if ($Target -or $remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "paths does not accept arguments." }
    Write-CliPaths -Context $context
    exit 0
}

if ($normalizedCommand -eq "runtime") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "runtime accepts only status or migrate." }
    Write-CliRuntime -Context $context -Action $Target
    exit 0
}

if ($normalizedCommand -eq "config") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "config accepts only path or edit." }
    Write-CliConfig -Context $context -Action $Target
    exit 0
}

if ($normalizedCommand -eq "add") {
    if ($Target -or $remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "add accepts only --file <task.json>." }
    Write-CliAdd -Context $context -Path $File
    exit 0
}
if ($normalizedCommand -eq "new") {
    if ($anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "new accepts optional --auto and <file> [title] or task text." }
    $textParts = New-Object Collections.Generic.List[string]
    if ($Target) { $textParts.Add($Target) }
    foreach ($value in $remainingValues) { $textParts.Add([string]$value) }
    if ($textParts.Count -gt 0 -and (Test-CliLocalFileArgument -Value $textParts[0])) {
        if ($textParts.Count -gt 2) { throw 'Use: factory new <file> ["title"]. Quote the title if it contains spaces.' }
        $taskTitle = if ($textParts.Count -eq 2) { [string]$textParts[1] } else { "" }
        Write-CliNew -Context $context -TaskFile $textParts[0] -TaskTitle $taskTitle -Automatic $autoOptionUsed
    } else {
        if ($textParts.Count -eq 2 -and (Test-CliLocalFileArgument -Value $textParts[1])) {
            throw 'The file goes first: factory new <file> ["title"].'
        }
        Write-CliNew -Context $context -Text (($textParts.ToArray() -join " ").Trim()) -Automatic $autoOptionUsed
    }
    exit 0
}
if ($fileOptionUsed) { throw "--file is accepted only by: factory add --file <task.json>" }

if ($normalizedCommand -eq "scheduler") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "scheduler accepts only status, start, stop, or tick." }
    $schedulerAction = if ($Target) { $Target.ToLowerInvariant() } else { "status" }
    if ($schedulerAction -notin @("status", "start", "stop", "tick")) { throw "Unknown scheduler action '$Target'." }
    Invoke-CliSchedulerAction -Context $context -Action $schedulerAction
    exit 0
}

if ($normalizedCommand -eq "wait") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) {
        throw "wait accepts one optional timeout and --cursor <revision>."
    }
    $waitTimeout = 0
    if ($Target -and (-not [int]::TryParse($Target, [ref]$waitTimeout) -or $waitTimeout -lt 0)) {
        throw "wait timeout must be zero or a positive integer number of seconds."
    }
    Write-CliWait -Context $context -TimeoutSeconds $waitTimeout -Cursor $waitCursor
    exit 0
}

if ($normalizedCommand -eq "preview") {
    if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) {
        throw "preview accepts one task ID, 'stop', or no argument; optional -NoOpen only."
    }
    $previewAction = if (-not $Target -or $Target.ToLowerInvariant() -eq "status") {
        "status"
    } elseif ($Target.ToLowerInvariant() -eq "stop") {
        "stop"
    } else {
        "start"
    }
    $previewTaskId = if ($previewAction -eq "start") { $Target } else { "" }
    Write-CliPreview -Context $context -Action $previewAction -TaskId $previewTaskId -SuppressBrowser $noOpenOptionUsed
    exit 0
}

if ($normalizedCommand -in @("tick", "pause", "resume", "stop")) {
    if ($Target -or $remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed -or $fileOptionUsed) { throw "$normalizedCommand does not accept arguments." }
    if ($normalizedCommand -eq "stop") {
        Write-CliPreview -Context $context -Action "stop"
    }
    Invoke-CliSchedulerAction -Context $context -Action $normalizedCommand
    exit 0
}

if ($normalizedCommand -eq "purge") {
    if ($Target -or $remainingValues.Count -gt 0 -or $Keep -or $startOptionsUsed -or $fileOptionUsed) { throw "purge accepts only -Yes and optional -Force." }
    Write-CliPurge -Context $context -Confirm ([bool]$Yes) -ForceRemoval ([bool]$Force)
    exit 0
}

$reconcileWarning = Invoke-CliReconcile -Context $context
$state = Read-FactoryJson -Path ([string]$context.statePath)
$config = Read-FactoryJson -Path ([string]$context.configPath)

switch ($normalizedCommand) {
    "inspect" {
        if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "inspect accepts exactly one task ID." }
        Write-CliInspect -Context $context -Config $config -State $state -TaskId $Target -ReconcileWarning $reconcileWarning
    }
    "chat" {
        if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "chat accepts exactly one task ID." }
        Write-CliChat -State $state -TaskId $Target -ReconcileWarning $reconcileWarning
    }
    "go" {
        if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "go accepts exactly one task ID." }
        Write-CliGo -Context $context -Config $config -State $state -TaskId $Target -DirectApproval $directOptionUsed
    }
    "hold" {
        if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "hold accepts exactly one task ID." }
        Write-CliHold -State $state -TaskId $Target
    }
    "retry" {
        if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "retry accepts exactly one task ID." }
        Write-CliRetry -State $state -TaskId $Target
    }
    "reject" {
        if ($startOptionsUsed -or $Force) { throw "reject accepts -Yes or -Keep, not -Force or start options." }
        $reason = ($remainingValues -join " ").Trim()
        Write-CliReject -State $state -TaskId $Target -Reason $reason -Confirm ([bool]$Yes) -Preserve ([bool]$Keep)
    }
    "cleanup" {
        if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "cleanup accepts exactly one task ID." }
        Write-CliCleanup -State $state -TaskId $Target
    }
    "concurrency" {
        if ($remainingValues.Count -gt 0 -or $anyDestructiveOptionsUsed -or $startOptionsUsed) { throw "concurrency accepts at most one number." }
        Write-CliConcurrency -Context $context -Config $config -State $state -Value $Target
    }
    default { throw "Unknown command '$Command'. Run 'factory help'." }
}
