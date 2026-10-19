[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
. (Join-Path $PSScriptRoot 'asana-common.ps1')

function Get-AsanaPriorityRank {
    param($Task)
    $customFields = $Task.PSObject.Properties['custom_fields']
    if ($null -eq $customFields) { return 3 }
    foreach ($field in @($customFields.Value)) {
        if ($null -eq $field) { continue }
        if ([string](Get-FactoryNestedValue -Target $field -Name 'name' -Default '') -ne 'Priority') { continue }
        $enumValue = $field.PSObject.Properties['enum_value']
        $textValue = $field.PSObject.Properties['text_value']
        $value = if ($null -ne $enumValue -and $null -ne $enumValue.Value) { [string]$enumValue.Value.name } elseif ($null -ne $textValue) { [string]$textValue.Value } else { '' }
        switch ($value.ToLowerInvariant()) {
            'high' { return 0 }
            'medium' { return 1 }
            'low' { return 2 }
            default { return 3 }
        }
    }
    return 3
}

function Get-ReadyTasks {
    param($Config)
    $asana = $Config.asana
    $fields = 'gid,name,permalink_url,custom_fields.gid,custom_fields.name,custom_fields.enum_value.gid,custom_fields.enum_value.name,custom_fields.text_value,created_at,completed'
    $query = "/workspaces/$($asana.workspace)/tasks/search?projects.any=$($asana.project)&completed=false&custom_fields.$($asana.fields.factory).value=$($asana.fields.ready)&opt_fields=$fields"
    try {
        $tasks = @(Get-FactoryAsanaSearchTasks -Config $Config -Path $query -FallbackPath "/projects/$($asana.project)/tasks?limit=100&completed_since=1970-01-01T00:00:00Z&opt_fields=$fields")
    } catch {
        $fallback = "/projects/$($asana.project)/tasks?limit=100&completed_since=now&opt_fields=$fields"
        $tasks = @(Get-FactoryAsanaPages -Config $Config -Path $fallback)
    }
    return @($tasks | Where-Object {
        -not [bool]$_.completed -and
        (Get-FactoryAsanaField -Task $_ -Gid ([string]$asana.fields.factory)) -eq [string]$asana.fields.ready
    } | Sort-Object @{ Expression = { Get-AsanaPriorityRank $_ } },
        @{ Expression = { [string]$_.created_at } }, @{ Expression = { [string]$_.gid } })
}

$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository -Initialize:(-not $DryRun) | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $context.configPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $context.statePath -PathType Leaf)) {
    throw 'Factory project config and state must exist before polling.'
}
$config = Read-FactoryJson -Path $context.configPath
if (-not [bool]$config.asana.enabled) { Write-Output 'Asana polling disabled.'; return }
$state = Read-FactoryJson -Path $context.statePath
if ([bool]$state.paused -and -not $DryRun) { Write-Output 'Factory paused.'; return }

$pollMutex = $null
$ownsPollMutex = $false
try {
    if (-not $DryRun) {
        $pollMutex = New-Object Threading.Mutex($false, "Local\FactoryAsanaPoll-$($context.projectKey)")
        try { $ownsPollMutex = $pollMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsPollMutex = $true }
        if (-not $ownsPollMutex) { Write-Output 'Asana poll already running.'; return }
        $lastPoll = Get-FactoryNestedValue -Target $state -Name 'asanaPollAt'
        $minutes = [Math]::Max(1, [int]$config.poll.intervalMinutes)
        if (-not $Force -and $lastPoll -and
            ([DateTime]::UtcNow - (ConvertTo-FactoryUtcDateTime -Value $lastPoll)).TotalMinutes -lt $minutes) {
            Write-Output 'Asana poll not due.'
            return
        }
        $stateMutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
        try {
            $state = Read-FactoryJson -Path $context.statePath
            if ([bool]$state.paused) { Write-Output 'Factory paused.'; return }
            Set-FactoryProperty -Target $state -Name 'asanaPollAt' -Value (Get-FactoryUtcTimestamp)
            Write-FactoryJsonAtomic -Path $context.statePath -Value $state
        } finally { Exit-FactoryMutex -Mutex $stateMutex }
    }

    $held = @($state.tasks | Where-Object {
        [bool](Get-FactoryNestedValue -Target $_ -Name 'asanaMode' -Default $false) -and
        [string]$_.status -notin @('done', 'failed', 'rejected')
    }).Count
    $capacity = [Math]::Max(0, [int]$config.poll.maxParallelWorkers - $held)
    $ready = @(Get-ReadyTasks -Config $config)
    $selected = New-Object Collections.Generic.List[object]
    $repositorySlug = Get-FactoryOwnRepo -Config $config -Repository ([string]$context.repositoryRoot)
    foreach ($task in $ready) {
        if ($selected.Count -ge $capacity) { break }
        $gid = [string]$task.gid
        if (-not $gid) { continue }
        $existing = @($state.tasks | Where-Object { [string]$_.id -eq $gid })
        if ($existing.Count -and -not (Test-FactoryAsanaRunCanRestart -Task $existing[0])) { continue }
        $fresh = Get-FactoryAsanaTask -Config $config -Gid $gid
        if ([bool]$fresh.completed -or
            (Get-FactoryAsanaField -Task $fresh -Gid ([string]$config.asana.fields.factory)) -ne [string]$config.asana.fields.ready) {
            continue
        }
        $targetRepo = Resolve-FactoryTaskRepo -Config $config -Notes ([string]$fresh.notes)
        if ($targetRepo -ne $repositorySlug) { Write-Debug "Skipping $gid for repo $targetRepo (own repo $repositorySlug)."; continue }
        $selected.Add($fresh)
    }
    if ($DryRun) {
        foreach ($task in $selected) { Write-Output "Ready: $($task.gid) | $($task.name) | $($task.permalink_url)" }
        if ($selected.Count -eq 0) { Write-Output 'No Ready tasks fit the available capacity.' }
        return
    }

    $claimErrors = New-Object Collections.Generic.List[string]
    foreach ($task in $selected) {
        $gid = [string]$task.gid
        $safeName = ConvertTo-FactoryTaskArtifactName -TaskId $gid
        $worktreeName = "worker-$safeName-a1"
        $existing = @($state.tasks | Where-Object { [string]$_.id -eq $gid })
        if ($existing.Count -and [string]$existing[0].worktree) {
            $worktreeName = "worker-$safeName-a$([int]$existing[0].attempts + 1)"
        }
        $phase = 'claim'
        try {
            $latestState = Read-FactoryJson -Path $context.statePath
            if ([bool]$latestState.paused) { continue }
            $existing = @($latestState.tasks | Where-Object { [string]$_.id -eq $gid })
            if ($existing.Count -and -not (Test-FactoryAsanaRunCanRestart -Task $existing[0])) { continue }
            $heldNow = @($latestState.tasks | Where-Object {
                [bool](Get-FactoryNestedValue -Target $_ -Name 'asanaMode' -Default $false) -and
                [string]$_.status -notin @('done', 'failed', 'rejected')
            }).Count
            if ($heldNow -ge [int]$config.poll.maxParallelWorkers) { continue }
            # Search results are only hints. Recheck immediately before writing Taken.
            $fresh = Get-FactoryAsanaTask -Config $config -Gid $gid
            if ([bool]$fresh.completed -or
                (Get-FactoryAsanaField -Task $fresh -Gid ([string]$config.asana.fields.factory)) -ne [string]$config.asana.fields.ready) {
                continue
            }
            $targetRepo = Resolve-FactoryTaskRepo -Config $config -Notes ([string]$fresh.notes)
            if ($targetRepo -ne $repositorySlug) { Write-Debug "Skipping $gid for repo $targetRepo (own repo $repositorySlug)."; continue }
            Confirm-FactoryAsanaClaim -Config $config -Gid $gid
            $phase = 'move'
            Move-FactoryAsanaTask -Config $config -Gid $gid -Section ([string]$config.asana.sections.inProgress)
            $phase = 'comment'
            $null = Add-FactoryAsanaComment -Config $config -Gid $gid -Text "TAKEN (factory): worker $gid, worktree $worktreeName."
            Write-FactoryAsanaTransition -Context $context -Gid $gid -From 'Ready' -To 'Taken' -WorkerId $gid
            $phase = 'enqueue'
            if ($existing.Count) {
                Reset-FactoryAsanaRun -Context $context -Fresh $fresh
                Write-Output "Claimed again: $gid | $($fresh.name)"
                continue
            }
            $url = [string]$fresh.permalink_url
            if (-not $url) { $url = "https://app.asana.com/0/0/$gid" }
            $notes = [string]$fresh.notes
            if (-not $notes) { $notes = "Asana task $gid`: $([string]$fresh.name)" }
            $intake = [ordered]@{
                version = 1
                source = [ordered]@{ adapter = 'asana'; id = $gid; url = $url; suppliedUrl = $url }
                startMode = 'auto'
                title = [string]$fresh.name
                brief = $notes
                acceptanceCriteria = @()
                sourceNotes = @('Claimed by the Asana poller.')
                sourceError = $null
            }
            $intakePath = Join-Path $context.sessionsPath "asana-poll-$gid-$([Guid]::NewGuid().ToString('N')).json"
            try {
                Write-FactoryJsonAtomic -Path $intakePath -Value $intake
                $queued = & (Join-Path $PSScriptRoot 'enqueue-task.ps1') -Repository $context.repositoryRoot -IntakePath $intakePath -NoResume -AsanaMode | ConvertFrom-Json
                if ($queued.duplicate -or -not $queued.queued) { throw "Factory could not queue claimed task $gid." }
            } finally { Remove-Item -LiteralPath $intakePath -Force -ErrorAction SilentlyContinue }
            Write-Output "Claimed: $gid | $($fresh.name)"
        } catch {
            $reason = "Could not finish Asana claim during $phase`: $($_.Exception.Message)"
            # A lost claim belongs to whoever changed the field. Do not overwrite it.
            if ($phase -eq 'claim') { Write-Warning $reason; continue }
            try {
                $null = Add-FactoryAsanaComment -Config $config -Gid $gid -Text "FAILED (factory):`nReason: $reason`nTried: claim and enqueue.`nNext: inspect and re-groom this task.`nWorktree: $worktreeName"
                Set-FactoryAsanaField -Config $config -Gid $gid -Field ([string]$config.asana.fields.factory) -Value ([string]$config.asana.fields.failed)
                Write-FactoryAsanaTransition -Context $context -Gid $gid -From 'Taken' -To 'Failed' -WorkerId $gid
                Start-FactoryRockCycle -Config $config -Reason 'Failed' -Gid $gid
            } catch { Write-Warning "Could not report claim failure for Asana task $gid`: $($_.Exception.Message)" }
            $claimErrors.Add($reason)
        }
    }
    if ($claimErrors.Count) { throw ($claimErrors.ToArray() -join [Environment]::NewLine) }
} finally {
    if ($ownsPollMutex) { $pollMutex.ReleaseMutex() }
    if ($pollMutex) { $pollMutex.Dispose() }
}
