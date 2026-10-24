# Private, durable ROCK memory. Task/Git mutations remain native Factory operations.
if ($null -eq (Get-Command Read-FactoryJson -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'factory-common.ps1')
}
# Public CLI children can inherit the native-process function from their parent
# while its script-scoped encoding is absent in the child script scope.
$script:FactoryUtf8NoBom = New-Object Text.UTF8Encoding($false)

function ConvertTo-FactoryRockDateTimeOffset {
    param($Value)
    # JSON dates are DateTime on newer PowerShell and strings on Windows PS.
    # Casting DateTime to string first loses its kind and uses the current culture.
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
    return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-FactoryRockConfiguration {
    param($Config, [string]$ConfigPath = '')
    if (-not $ConfigPath) {
        $settings = Get-FactoryNestedValue $Config 'rocks'
        if (-not [bool](Get-FactoryNestedValue $settings 'enabled' $false)) { return $null }
        $ConfigPath = [string](Get-FactoryNestedValue $settings 'configPath' '')
        if (-not $ConfigPath) { throw 'rocks.configPath is required when direct ROCK is enabled.' }
    }
    $resolved = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    $rock = Read-FactoryJson -Path $resolved
    if (-not [bool](Get-FactoryNestedValue (Get-FactoryNestedValue $rock 'direct') 'enabled' $false)) { return $null }
    if ([int]$rock.timeoutMinutes -lt 1 -or [int]$rock.timeoutMinutes -gt 120 -or -not [string]$rock.claudePath) { throw 'Direct ROCK requires claudePath and timeoutMinutes between 1 and 120.' }
    $modelTimeout = [int](Get-FactoryNestedValue $rock.direct 'timeoutSeconds' 900)
    if ($modelTimeout -lt 1 -or $modelTimeout -gt 3600) { throw 'direct.timeoutSeconds must be between 1 and 3600.' }
    Set-FactoryProperty $rock.direct 'timeoutSeconds' $modelTimeout
    $root = [Environment]::ExpandEnvironmentVariables([string]$rock.direct.memoryDir)
    if (-not $root -or $root.Contains('%') -or -not [IO.Path]::IsPathRooted($root)) { throw 'direct.memoryDir must be an absolute, expanded private path.' }
    $root = [IO.Path]::GetFullPath($root)
    # Refuse a Git checkout, including ignored runtime directories inside one.
    $ancestor = $root
    while ($ancestor) {
        if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) { throw 'ROCK memory must live outside Git checkouts.' }
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'ROCK memory may not traverse reparse points.' }
        $ancestor = Split-Path -Parent $ancestor
    }
    Set-FactoryProperty $rock 'configurationPath' $resolved
    Set-FactoryProperty $rock.direct 'memoryDir' $root
    $owners = @{}
    $epics = @{}
    foreach ($item in @($rock.orchestrators)) {
        $gid = [string]$item.epicGid
        if ($gid -notmatch '^\d+$' -or $epics.ContainsKey($gid)) { throw 'ROCK IDs must be unique numeric epic GIDs.' }
        $epics[$gid] = $true
        if ([string]$item.name -notmatch '^[a-z][a-z0-9_-]*$' -or -not [IO.Path]::IsPathRooted([string]$item.repoPath)) { throw 'ROCK needs a safe name and an absolute read-only checkout.' }
        $bindings = @{}
        foreach ($binding in @((Get-FactoryNestedValue $item 'ownedTasks' @())) + @((Get-FactoryNestedValue $item 'watchedTasks' @()))) {
            if ([string]$binding.taskId -notmatch '^\d+$' -or -not [IO.Path]::IsPathRooted([string]$binding.repository)) { throw 'ROCK task bindings require a numeric taskId and absolute repository.' }
            $bindingKey = "$($binding.taskId)|$([IO.Path]::GetFullPath([string]$binding.repository).TrimEnd('\','/').ToLowerInvariant())"
            if ($bindings.ContainsKey($bindingKey)) { throw 'Duplicate ROCK ownership/watch binding.' }
            $bindings[$bindingKey] = $true
        }
        foreach ($binding in @((Get-FactoryNestedValue $item 'ownedTasks' @()))) {
            $key = [string]$binding.taskId
            if ($owners.ContainsKey($key)) { throw "Task $key has multiple ROCK owners." }
            $owners[$key] = $gid
        }
    }
    Initialize-FactoryRockCoordinatorConfiguration $rock
    return $rock
}

function Get-FactoryRockPaths {
    param($Configuration, [string]$EpicGid)
    if ($EpicGid -notmatch '^\d+$') { throw 'Invalid ROCK identity.' }
    $root = Join-Path ([string]$Configuration.direct.memoryDir) $EpicGid
    foreach ($path in @($root, (Join-Path $root 'events'), (Join-Path $root 'cycles'), (Join-Path $root 'sources'))) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'ROCK directory may not be a reparse point.' }
    }
    return [pscustomobject]@{ root = $root; memory = Join-Path $root 'memory.json'; events = Join-Path $root 'events'; cycles = Join-Path $root 'cycles' }
}

function Get-FactoryRockOrchestrator {
    param($Configuration, [string]$EpicGid)
    $matches = @($Configuration.orchestrators | Where-Object { [string]$_.epicGid -ceq $EpicGid })
    if ($matches.Count -ne 1) { throw "Unknown ROCK $EpicGid." }
    return $matches[0]
}

function Test-FactoryRockBinding {
    param($Orchestrator, [string]$TaskId, [string]$Repository, [switch]$IncludeWatched)
    $bindings = @((Get-FactoryNestedValue $Orchestrator 'ownedTasks' @()))
    if ($IncludeWatched) { $bindings += @((Get-FactoryNestedValue $Orchestrator 'watchedTasks' @())) }
    return @($bindings | Where-Object { [string]$_.taskId -ceq $TaskId -and (Test-FactorySamePath -Left ([string]$_.repository) -Right $Repository) }).Count -eq 1
}

function Get-FactoryRockOwner {
    param($Configuration, [string]$TaskId, [string]$Repository)
    foreach ($item in @($Configuration.orchestrators)) {
        if (Test-FactoryRockBinding $item $TaskId $Repository) { return $item }
    }
    return $null
}

function Read-FactoryRockMemory {
    param($Configuration, [string]$EpicGid)
    $paths = Get-FactoryRockPaths $Configuration $EpicGid
    if (Test-Path -LiteralPath $paths.memory) {
        $memory = Read-FactoryJson -Path $paths.memory
        if ([int]$memory.version -ne 1 -or [string]$memory.rockId -cne $EpicGid) { throw 'ROCK memory identity/version mismatch.' }
        return $memory
    }
    if (Test-Path -LiteralPath "$($paths.memory).previous.bak") { throw 'ROCK memory is missing but a recovery copy exists; restore it explicitly.' }
    return [pscustomobject][ordered]@{ version = 1; rockId = $EpicGid; revision = 0; summary = ''; decisions = @(); questions = @(); sources = @(); sourcesUpdatedAt = $null; sourceRefreshRequired = $false; appliedCycles = @(); paused = $false }
}

function Write-FactoryRockJson {
    param([string]$Path, $Value)
    # Preserve a valid preceding revision; never silently reset corrupt memory.
    if (Test-Path -LiteralPath $Path) {
        $previous = Read-FactoryJson -Path $Path
        Write-FactoryJsonAtomic -Path "$Path.previous.bak" -Value $previous
    }
    Write-FactoryJsonAtomic -Path $Path -Value $Value
}

function Update-FactoryRockMemory {
    param($Configuration, [string]$EpicGid, [scriptblock]$Mutator)
    $paths = Get-FactoryRockPaths $Configuration $EpicGid
    $mutex = Enter-FactoryMutex -ProjectKey "rock-memory-$EpicGid"
    try {
        $memory = Read-FactoryRockMemory $Configuration $EpicGid
        & $Mutator $memory
        $memory.revision = [long]$memory.revision + 1
        Write-FactoryRockJson -Path $paths.memory -Value $memory
        return $memory
    } finally { Exit-FactoryMutex -Mutex $mutex }
}

function Add-FactoryRockEvent {
    param($Configuration, [string]$EpicGid, [string]$Key, $Payload)
    $paths = Get-FactoryRockPaths $Configuration $EpicGid
    $id = Get-FactoryTextSha256 -Value $Key
    $path = Join-Path $paths.events "$id.json"
    $mutex = Enter-FactoryMutex -ProjectKey "rock-memory-$EpicGid"
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            $event = [ordered]@{ version = 1; id = $id; rockId = $EpicGid; createdAt = Get-FactoryUtcTimestamp; status = 'pending'; attempts = 0; applyAttempts = 0; sourcesUpdatedAt = $null; retryAt = $null; error = $null; payload = $Payload; result = $null; receipts = @() }
            if (Test-Path -LiteralPath "$path.previous.bak") { throw 'ROCK event is missing but its recovery copy exists.' }
            Write-FactoryRockJson -Path $path -Value $event
        }
    } finally { Exit-FactoryMutex -Mutex $mutex }
    return $path
}

function Sync-FactoryRockTaskEvents {
    param($Context, $Config, $State)
    $rock = Get-FactoryRockConfiguration -Config $Config
    if ($null -eq $rock) { return }
    Sync-FactoryRockBrowserStatuses $rock $Context $State
    foreach ($task in @($State.tasks)) {
        $answer = Get-FactoryNestedValue $task 'rockAnswer'
        if ($null -ne $answer -and [string]$answer.actor -ceq 'operator') {
            $owner = Get-FactoryRockOwner $rock ([string]$task.id) ([string]$Context.repositoryRoot)
            if ($null -ne $owner) {
                if (-not @((Read-FactoryRockMemory $rock ([string]$owner.epicGid)).decisions | Where-Object { [string](Get-FactoryNestedValue $_ 'actionId') -ceq [string]$answer.actionId }).Count) {
                    $null = Update-FactoryRockMemory $rock ([string]$owner.epicGid) {
                        param($memory)
                        if (-not @($memory.decisions | Where-Object { [string](Get-FactoryNestedValue $_ 'actionId') -ceq [string]$answer.actionId }).Count) {
                            $memory.decisions = @($memory.decisions) + @([pscustomobject]@{ actor = 'operator'; actionId = [string]$answer.actionId; questionId = [string]$answer.questionId; text = [string]$answer.text; createdAt = [string]$answer.at })
                        }
                    }
                }
                $null = Add-FactoryRockEvent $rock ([string]$owner.epicGid) "operator-task-answer/$($answer.actionId)" @{ kind = 'operator-answer'; taskId = [string]$task.id; text = [string]$answer.text; repository = [string]$Context.repositoryRoot; owner = $true }
            }
        }
        $question = Get-FactoryNestedValue $task 'asanaQuestion'
        $kind = if ($null -ne $question -and [string](Get-FactoryNestedValue $question 'channel') -eq 'rock') { 'Question' } elseif ([string]$task.status -in @('done', 'failed')) { [string]$task.status } else { '' }
        if (-not $kind) { continue }
        $identity = if ($kind -eq 'Question') { [string]$question.storyGid } else { "$(Get-FactoryNestedValue $task 'runId')/$([int]$task.attempts)/$([string]$task.commit)" }
        foreach ($item in @($rock.orchestrators)) {
            if (-not (Test-FactoryRockBinding $item ([string]$task.id) ([string]$Context.repositoryRoot) -IncludeWatched)) { continue }
            $payload = [ordered]@{ kind = $kind; taskId = [string]$task.id; repository = [string]$Context.repositoryRoot; title = [string]$task.title; brief = [string](Get-FactoryNestedValue $task 'brief'); acceptanceCriteria = @((Get-FactoryNestedValue $task 'acceptanceCriteria' @())); workerResult = Get-FactoryNestedValue $task 'workerResult'; attempts = [int]$task.attempts; commit = [string]$task.commit; question = $question; error = Get-FactoryNestedValue $task 'error'; owner = Test-FactoryRockBinding $item ([string]$task.id) ([string]$Context.repositoryRoot) }
            $null = Add-FactoryRockEvent $rock ([string]$item.epicGid) "$($Context.projectKey)/$($task.id)/$kind/$identity" $payload
        }
    }
}

function Get-FactoryRockAttentionEvents {
    param($Context, $Config)
    $rock = Get-FactoryRockConfiguration -Config $Config
    if ($null -eq $rock) { return }
    if (Test-FactoryRockCoordinatorPublication $rock) {
        foreach ($review in @(Get-FactoryRockPublicationReviews $rock ([string]$Context.repositoryRoot))) {
            [pscustomobject]@{ kind = 'rock-publication-review'; taskId = $null; title = 'ROCK proposed Asana update'; status = 'awaiting-factory-review'; identity = "$($review.id)/$($review.revision)/$($review.factsHash)"; audience = 'orchestrator'; aiActionable = $true; humanDecision = $false; includeInDefaultWait = $true; reason = 'Review only this factory facts and the proposed human digest. Approve, correct or reject using factory rock publication review. This is not a merge/GO approval and the factory must not post to Asana.'; occurredAt = ''; command = 'factory rock publication list' }
        }
        foreach ($blocked in @(Get-FactoryRockBrowserItems $rock | Where-Object status -eq 'blocked')) {
            $goal = Get-FactoryRockOrchestrator $rock ([string]$blocked.rockId)
            $relevant = @(@($goal.ownedTasks) + @($goal.watchedTasks) | Where-Object { Test-FactorySamePath ([string]$_.repository) ([string]$Context.repositoryRoot) }).Count -gt 0
            if ($relevant) {
                [pscustomobject]@{kind='rock-publication-blocked';taskId=$null;title='ROCK publication needs inspection';status='blocked';identity="$($blocked.id)/$($blocked.claimId)";audience='orchestrator';aiActionable=$true;humanDecision=$false;includeInDefaultWait=$true;reason="Inspect the coordinator's retained publication evidence: $($blocked.error). Preserve uncertainty; a failed/lost write must not be repeated before exact readback/absence verification. Do not publish a replacement from this factory.";occurredAt='';command='factory rock publication pending'}
            }
        }
    }
    $browserWork = @(Get-FactoryRockBrowserItems $rock | Where-Object { $_.status -in @('pending', 'claimed', 'blocked') })
    if (-not (Test-FactoryRockCoordinatorPublication $rock) -and $browserWork.Count -and [string](Get-FactoryNestedValue (Get-FactoryNestedValue $rock.direct 'browserProjection') 'consumerMode' 'orchestrator') -eq 'orchestrator' -and (Test-FactorySamePath ([string]$Context.repositoryRoot) ([string](Get-FactoryNestedValue (Get-FactoryNestedValue $rock.direct 'browserProjection') 'consumerRepository')))) {
        $browserIdentity = Get-FactoryTextSha256 (($browserWork | ForEach-Object { "$($_.id)/$($_.status)/$($_.claimId)" }) -join ',')
        [pscustomobject]@{ kind = 'rock-browser-work'; taskId = $null; title = 'ROCK board updates'; status = 'pending'; identity = $browserIdentity; audience = 'orchestrator'; aiActionable = $true; humanDecision = $false; includeInDefaultWait = $true; reason = 'Claim the durable browser outbox. Read the exact Asana task through the browser, check markers and human holds, apply the requested update, then record freshly observed evidence. Never use an Asana connector or token.'; occurredAt = ''; command = 'factory rock browser claim' }
    }
    $state = Read-FactoryJson -Path ([string]$Context.statePath)
    if (-not [bool]$state.active -and (Test-FactoryRockHasPendingWork -Config $Config)) {
        [pscustomobject]@{ kind = 'rock-factory-inactive'; taskId = $null; title = 'ROCK waits for Factory'; status = 'inactive'; identity = [string]$Context.projectKey; audience = 'human'; aiActionable = $false; humanDecision = $true; includeInDefaultWait = $true; reason = 'Direct ROCK has pending work; the inactive Factory requires an explicit operator resume.'; occurredAt = ''; command = 'factory resume' }
    }
    foreach ($item in @($rock.orchestrators)) {
        $relevant = @(@((Get-FactoryNestedValue $item 'ownedTasks' @())) + @((Get-FactoryNestedValue $item 'watchedTasks' @())) | Where-Object { Test-FactorySamePath -Left ([string]$_.repository) -Right ([string]$Context.repositoryRoot) }).Count -gt 0
        if (-not $relevant) { continue }
        $memory = Read-FactoryRockMemory $rock ([string]$item.epicGid)
        if ([bool](Get-FactoryNestedValue $memory 'sourceRefreshRequired' $false)) {
            $refreshReason = if (Test-FactoryRockCoordinatorPublication $rock) { 'Refresh the exact ROCK epic, decisions and relevant requirements through existing authorized Asana access: Claude may use the existing ROCK connection; this Codex chat uses its browser. Save actual source material as UTF-8 and import it with factory rock import. Do not add a new connector or REST/token path, and do not publish a ROCK update from the factory.' } else { 'Read the ROCK epic, decisions and relevant task requirements through the open browser. Save a UTF-8 source snapshot and import it with factory rock import. Do not use an Asana connector or token.' }
            [pscustomobject]@{ kind = 'rock-source-refresh'; taskId = $null; title = "ROCK $($item.name)"; status = 'blocked'; identity = "sources-$($item.epicGid)"; audience = 'orchestrator'; aiActionable = $true; humanDecision = $false; includeInDefaultWait = $true; reason = $refreshReason; occurredAt = ''; command = "factory rock import $($item.epicGid) --file SNAPSHOT" }
        }
        foreach ($question in @($memory.questions | Where-Object { $_.status -eq 'open' })) {
            [pscustomobject]@{ kind = 'rock-question'; taskId = $null; title = "ROCK $($item.name)"; status = 'awaiting-input'; identity = [string]$question.id; audience = 'human'; aiActionable = $false; humanDecision = $true; includeInDefaultWait = $true; reason = [string]$question.text; occurredAt = [string]$question.createdAt; command = "factory rock questions" }
        }
    }
}

function Start-FactoryRockService {
    param($Context, $Config)
    $rock = Get-FactoryRockConfiguration -Config $Config
    if ($null -eq $rock) { return }
    if (-not [bool](Get-FactoryNestedValue (Get-FactoryNestedValue $Config 'nativeScheduler') 'enabled' $true)) { return }
    if ([bool](Read-FactoryRockCoordinatorMemory $rock).paused) { return }
    $pending = $false
    foreach ($item in @($rock.orchestrators)) {
        if ([bool](Read-FactoryRockMemory $rock ([string]$item.epicGid)).paused) { continue }
        $paths = Get-FactoryRockPaths $rock ([string]$item.epicGid)
        if (Test-Path -LiteralPath $paths.events) {
            foreach ($file in @(Get-ChildItem -LiteralPath $paths.events -Filter '*.json' -File)) {
                $event = Read-FactoryJson -Path $file.FullName
                if ($event.status -eq 'pending' -and (-not $event.retryAt -or (ConvertTo-FactoryRockDateTimeOffset $event.retryAt) -le [DateTimeOffset]::UtcNow)) { $pending = $true; break }
            }
        }
    }
    if (-not $pending -and (Test-FactoryRockCoordinatorPublication $rock) -and [string](Get-FactoryNestedValue (Get-FactoryNestedValue $rock.direct 'publication') 'transport' 'disabled') -ne 'disabled') {
        Sync-FactoryRockPublicationProposals $rock
        foreach($item in @(Get-FactoryRockBrowserItems $rock|Where-Object status -eq 'pending')){if(-not [bool](Read-FactoryRockMemory $rock ([string]$item.rockId)).paused -and (Test-FactoryRockPublicationApproved $rock $item)){$pending=$true;break}}
    }
    if (-not $pending) { return }
    $receiptPath = Join-Path ([string]$Context.projectData) 'rock-service.json'
    $mutex = Enter-FactoryMutex -ProjectKey "$($Context.projectKey)-rock-service"
    try {
        if (Test-Path -LiteralPath $receiptPath) {
            $receipt = Read-FactoryJson -Path $receiptPath
            try {
                $process = Get-Process -Id ([int]$receipt.pid) -ErrorAction Stop
                if ($process.StartTime.ToUniversalTime().ToString('o') -eq [string]$receipt.startedAt) { return }
            } catch { }
        }
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'rock-direct-cycle.ps1'), '-ConfigPath', [string]$rock.configurationPath)
        $argumentLine = (@($arguments | ForEach-Object { ConvertTo-FactoryWindowsArgument ([string]$_) }) -join ' ')
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $argumentLine -WindowStyle Hidden -RedirectStandardOutput (Join-Path ([string]$Context.projectData) 'rock-service.stdout.log') -RedirectStandardError (Join-Path ([string]$Context.projectData) 'rock-service.stderr.log') -PassThru
        Write-FactoryJsonAtomic -Path $receiptPath -Value @{ pid = $process.Id; startedAt = $process.StartTime.ToUniversalTime().ToString('o') }
    } finally { Exit-FactoryMutex -Mutex $mutex }
}

function Test-FactoryRockHasPendingWork {
    param($Config)
    $rock = Get-FactoryRockConfiguration -Config $Config
    if ($null -eq $rock) { return $false }
    if (@(Get-FactoryRockBrowserItems $rock | Where-Object { $_.status -in @('pending', 'claimed', 'blocked') }).Count) { return $true }
    foreach ($item in @($rock.orchestrators)) {
        $memory = Read-FactoryRockMemory $rock ([string]$item.epicGid)
        if (@($memory.questions | Where-Object status -eq 'open').Count -gt 0 -or [bool](Get-FactoryNestedValue $memory 'sourceRefreshRequired' $false)) { return $true }
        $paths = Get-FactoryRockPaths $rock ([string]$item.epicGid)
        if (Test-Path -LiteralPath $paths.events) {
            foreach ($file in @(Get-ChildItem -LiteralPath $paths.events -Filter '*.json' -File)) {
                if ((Read-FactoryJson -Path $file.FullName).status -eq 'pending') { return $true }
            }
        }
    }
    return $false
}

function ConvertFrom-FactoryRockResult {
    param([string]$Output, [string]$EventId)
    if ($Output.Length -gt 1000000) { throw 'ROCK output exceeds 1000000 characters.' }
    $Output = $Output.Trim() -replace '^ROCK_RESULT\s*', '' -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
    $outer = $Output | ConvertFrom-Json
    if ([bool](Get-FactoryNestedValue $outer 'is_error' $false)) { throw 'ROCK model reported an error.' }
    $value = if ($null -ne $outer.PSObject.Properties['result']) { [string]$outer.result } else { $Output }
    $value = $value.Trim() -replace '^ROCK_RESULT\s*', '' -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
    $result = $value | ConvertFrom-Json
    $allowed = @('version', 'eventId', 'summary', 'decisions', 'actions')
    foreach ($name in @($result.PSObject.Properties.Name)) { if ($name -cnotin $allowed) { throw "Unknown ROCK result field '$name'." } }
    if ([int]$result.version -ne 1 -or [string]$result.eventId -cne $EventId) { throw 'ROCK result does not match its event.' }
    if ([string]$result.summary -eq '' -or ([string]$result.summary).Length -gt 16000) { throw 'ROCK summary must contain 1-16000 characters.' }
    foreach ($field in @('decisions', 'actions')) {
        if ($null -eq $result.PSObject.Properties[$field] -or $result.$field -is [string] -or $null -eq $result.$field -or @($result.$field).Count -gt 50) { throw "ROCK $field must be an array of at most 50 entries." }
    }
    foreach ($decision in @($result.decisions)) { if ($decision -isnot [string] -or -not $decision.Trim() -or $decision.Length -gt 8000) { throw 'Invalid ROCK decision.' } }
    $ids = @{}
    foreach ($action in @($result.actions)) {
        foreach ($name in @($action.PSObject.Properties.Name)) { if ($name -cnotin @('id', 'type', 'taskId', 'repository', 'questionId', 'text', 'title', 'brief', 'acceptanceCriteria')) { throw "Unknown ROCK action field '$name'." } }
        if ([string]$action.id -notmatch '^[a-zA-Z0-9_-]{1,64}$' -or $ids.ContainsKey([string]$action.id)) { throw 'ROCK action IDs must be unique and safe.' }
        $ids[[string]$action.id] = $true
        if ([string]$action.type -cnotin @('answer', 'dispatch', 'escalate', 'report', 'refresh')) { throw 'Unsupported ROCK action; approvals and shell commands are forbidden.' }
        if ($action.type -eq 'dispatch') {
            if (-not [string]$action.title -or ([string]$action.title).Length -gt 500 -or -not [string]$action.brief -or ([string]$action.brief).Length -gt 50000) { throw 'Dispatch needs bounded title and brief.' }
        } elseif (-not [string]$action.text -or ([string]$action.text).Length -gt 16000) { throw 'Action needs bounded text.' }
    }
    return $result
}

. (Join-Path $PSScriptRoot 'rock-coordinator.ps1')
. (Join-Path $PSScriptRoot 'rock-browser.ps1')
. (Join-Path $PSScriptRoot 'rock-publication.ps1')
. (Join-Path $PSScriptRoot 'rock-asana-publisher.ps1')
