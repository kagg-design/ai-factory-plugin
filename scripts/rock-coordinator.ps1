# Loaded by rock-common after the per-goal memory primitives are defined.
function Initialize-FactoryRockCoordinatorConfiguration {
    param($Configuration)
    $coordinatorId = [string](Get-FactoryNestedValue $Configuration.direct 'coordinatorId' 'default')
    if ($coordinatorId -cnotmatch '^[a-z][a-z0-9_-]{0,63}$') { throw 'Invalid direct.coordinatorId.' }
    Set-FactoryProperty $Configuration.direct 'coordinatorId' $coordinatorId
    $nodes = @{}
    foreach ($goal in @($Configuration.orchestrators)) {
        foreach ($binding in @((Get-FactoryNestedValue $goal 'ownedTasks' @()))) { $nodes[[string]$binding.taskId] = $binding }
    }
    foreach ($binding in @($nodes.Values)) {
        if ([string](Get-FactoryNestedValue $binding 'mode' 'execute') -cnotin @('execute', 'observe')) { throw 'Owned binding mode must be execute or observe.' }
        $seen = @{}
        foreach ($dependency in @((Get-FactoryNestedValue $binding 'prerequisites' @()))) {
            $id = [string](Get-FactoryNestedValue $dependency 'taskId')
            if (-not $nodes.ContainsKey($id) -or $id -ceq [string]$binding.taskId -or $seen.ContainsKey($id)) { throw 'Prerequisites must reference distinct owned tasks, never the task itself.' }
            if (-not (Test-FactorySamePath ([string]$dependency.repository) ([string]$nodes[$id].repository))) { throw 'Prerequisite repository does not match its trusted owner.' }
            $stage = [string](Get-FactoryNestedValue $dependency 'stage' 'done')
            if ($stage -cnotin @('done', 'development', 'production')) { throw 'Prerequisite stage must be done, development or production; deployment is not inferred.' }
            $expected = [string](Get-FactoryNestedValue $dependency 'commit' '')
            if ($expected -and $expected -cnotmatch '^[0-9a-f]{40}$') { throw 'A pinned prerequisite requires an exact 40-character commit.' }
            $seen[$id] = $true
        }
    }
    $marks = @{}
    function Visit-FactoryRockPrerequisite {
        param([string]$Id)
        if ($marks[$Id] -eq 'visiting') { throw 'ROCK prerequisite graph contains a cycle.' }
        if ($marks[$Id] -eq 'visited') { return }
        $marks[$Id] = 'visiting'
        foreach ($dependency in @((Get-FactoryNestedValue $nodes[$Id] 'prerequisites' @()))) { Visit-FactoryRockPrerequisite ([string]$dependency.taskId) }
        $marks[$Id] = 'visited'
    }
    foreach ($id in @($nodes.Keys)) { Visit-FactoryRockPrerequisite $id }
    $projection = Get-FactoryNestedValue $Configuration.direct 'browserProjection'
    if ([string](Get-FactoryNestedValue $projection 'consumerMode' 'orchestrator') -cnotin @('orchestrator','external')) { throw 'Browser consumerMode must be orchestrator or external.' }
    if ([bool](Get-FactoryNestedValue $projection 'enabled' $false)) {
        $consumer = [string](Get-FactoryNestedValue $projection 'consumerRepository')
        $repositories = @($Configuration.orchestrators | ForEach-Object { @((Get-FactoryNestedValue $_ 'ownedTasks' @())) } | ForEach-Object { [string]$_.repository } | Select-Object -Unique)
        if (-not $consumer -and $repositories.Count) { $consumer = $repositories[0] }
        if (-not @($repositories | Where-Object { Test-FactorySamePath $_ $consumer }).Count) { throw 'Browser consumer must be a participating canonical repository.' }
        Set-FactoryProperty $projection 'consumerRepository' ([IO.Path]::GetFullPath($consumer))
    }
}

function Get-FactoryRockCoordinatorPaths {
    param($Configuration)
    $root = Join-Path ([string]$Configuration.direct.memoryDir) "_coordinator\$($Configuration.direct.coordinatorId)"
    foreach ($path in @((Split-Path -Parent $root), $root, (Join-Path $root 'outbox'))) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Coordinator directory may not be a reparse point.' }
    }
    $key = Get-FactoryTextSha256 "$(([string]$Configuration.direct.memoryDir).ToLowerInvariant())/$($Configuration.direct.coordinatorId)"
    return [pscustomobject]@{ root = $root; memory = Join-Path $root 'memory.json'; outbox = Join-Path $root 'outbox'; mutexName = "Local\ClaudeFactory-RockCoordinator-$key" }
}

function Read-FactoryRockCoordinatorMemory {
    param($Configuration)
    $paths = Get-FactoryRockCoordinatorPaths $Configuration
    $goalIds = @($Configuration.orchestrators | ForEach-Object { [string]$_.epicGid } | Sort-Object)
    if (Test-Path -LiteralPath $paths.memory) {
        $record = Read-FactoryJson $paths.memory
        if ([int]$record.version -ne 1 -or [string]$record.coordinatorId -cne [string]$Configuration.direct.coordinatorId -or
            (@($record.goalIds | Sort-Object) -join ',') -cne ($goalIds -join ',')) { throw 'Coordinator memory identity/membership mismatch; migrate explicitly.' }
        return $record
    }
    if (Test-Path -LiteralPath "$($paths.memory).previous.bak") { throw 'Coordinator memory is missing but a recovery copy exists.' }
    return [pscustomobject][ordered]@{ version = 1; coordinatorId = [string]$Configuration.direct.coordinatorId; goalIds = $goalIds; revision = 0; paused = $false; summary = ''; decisions = @(); appliedEvents = @() }
}

function Update-FactoryRockCoordinatorMemory {
    param($Configuration, [scriptblock]$Mutator)
    $paths = Get-FactoryRockCoordinatorPaths $Configuration
    $mutex = Enter-FactoryMutex -ProjectKey "rock-coordinator-memory-$([IO.Path]::GetFileName($paths.root))-$((Get-FactoryTextSha256 $paths.root).Substring(0,16))"
    try {
        $record = Read-FactoryRockCoordinatorMemory $Configuration
        & $Mutator $record
        $record.revision = [long]$record.revision + 1
        Write-FactoryRockJson $paths.memory $record
        return $record
    } finally { Exit-FactoryMutex $mutex }
}

function Get-FactoryRockOwnedBinding {
    param($Configuration, [string]$TaskId, [string]$Repository)
    $owner = Get-FactoryRockOwner $Configuration $TaskId $Repository
    if ($null -eq $owner) { throw 'Task has no trusted ROCK owner.' }
    return @($owner.ownedTasks | Where-Object { [string]$_.taskId -ceq $TaskId -and (Test-FactorySamePath ([string]$_.repository) $Repository) })[0]
}

function Get-FactoryRockTaskView {
    param($Binding, [hashtable]$Cache = @{})
    $repository = [IO.Path]::GetFullPath([string]$Binding.repository)
    $id = [string]$Binding.taskId
    try {
        if (-not $Cache.ContainsKey($repository)) {
            $context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $repository | ConvertFrom-Json
            if (-not (Test-FactorySamePath $repository ([string]$context.repositoryRoot))) { throw 'Binding must name the canonical main repository.' }
            $ledger = Read-FactoryJson $context.statePath
            $Cache[$repository] = @{ context = $context; state = $ledger }
        }
        $project = $Cache[$repository]
        $matches = @($project.state.tasks | Where-Object { [string]$_.id -ceq $id })
        if ($matches.Count -gt 1) { throw 'Ambiguous task ledger identity.' }
        if ($matches.Count -eq 1) {
            $task = $matches[0]
            return [pscustomobject]@{ taskId = $id; repository = $repository; available = $true; origin = 'ledger'; status = [string]$task.status; title = [string]$task.title; commit = [string](Get-FactoryNestedValue $task 'commit'); runId = [string](Get-FactoryNestedValue $task 'runId'); attempts = [int](Get-FactoryNestedValue $task 'attempts' 0); development = [string](Get-FactoryNestedValue (Get-FactoryNestedValue $task 'integration') 'status'); production = [string](Get-FactoryNestedValue (Get-FactoryNestedValue $task 'production') 'status'); developmentCommit = [string](Get-FactoryNestedValue (Get-FactoryNestedValue $task 'integration') 'taskCommit'); productionCommit = [string](Get-FactoryNestedValue (Get-FactoryNestedValue $task 'production') 'taskCommit'); questionId = [string](Get-FactoryNestedValue (Get-FactoryNestedValue $task 'asanaQuestion') 'storyGid'); error = [string](Get-FactoryNestedValue $task 'error') }
        }
        if ($null -eq (Get-Command Read-FactoryCompletedArchive -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'completed-archive.ps1') }
        if (-not $project.ContainsKey('archive')) { $project.archive = Read-FactoryCompletedArchive $project.context }
        if (@($project.archive.warnings).Count) { throw 'Completed archive has an incomplete or invalid row; prerequisite cannot be inferred.' }
        $row = @($project.archive.rows | Where-Object { [string]$_.id -ceq $id } | Sort-Object archivedAt -Descending | Select-Object -First 1)
        if ($row.Count) {
            return [pscustomobject]@{ taskId = $id; repository = $repository; available = $true; origin = 'archive'; status = $(if ($row[0].outcome -eq 'rejected') { 'rejected' } else { 'done' }); title = [string]$row[0].title; commit = [string]$row[0].commit; runId = ''; attempts = [int]$row[0].attempts; development = $(if ($row[0].outcome -ne 'rejected') { 'published' } else { '' }); production = $(if ($row[0].outcome -eq 'production') { 'published' } else { '' }); questionId = ''; error = '' }
        }
        throw 'Task is absent from both ledger and completed archive.'
    } catch {
        return [pscustomobject]@{ taskId = $id; repository = $repository; available = $false; status = 'unknown'; error = $_.Exception.Message; commit = ''; runId = '' }
    }
}

function Test-FactoryRockPrerequisites {
    param($Configuration, [string]$TaskId, [string]$Repository, [hashtable]$Cache = @{})
    $blockers = New-Object 'Collections.Generic.List[string]'
    $evidence = New-Object 'Collections.Generic.List[object]'
    try {
        $binding = Get-FactoryRockOwnedBinding $Configuration $TaskId $Repository
        foreach ($dependency in @((Get-FactoryNestedValue $binding 'prerequisites' @()))) {
            $view = Get-FactoryRockTaskView $dependency $Cache
            $evidence.Add($view)
            $stage = [string](Get-FactoryNestedValue $dependency 'stage' 'done')
            $ready = [bool]$view.available -and [string]$view.commit -cmatch '^[0-9a-f]{40}$' -and [string]$view.status -cnotin @('failed','rejected','held','blocked')
            if ($ready) {
                $ready = switch ($stage) {
                    'development' { $view.development -ceq 'published' -and ($view.origin -eq 'archive' -or $view.developmentCommit -ceq $view.commit) }
                    'production' { $view.production -ceq 'published' -and ($view.origin -eq 'archive' -or $view.productionCommit -ceq $view.commit) }
                    default { $view.status -ceq 'done' }
                }
            }
            $pin = [string](Get-FactoryNestedValue $dependency 'commit')
            $run = [string](Get-FactoryNestedValue $dependency 'runId')
            if (($pin -and $pin -cne $view.commit) -or ($run -and $run -cne $view.runId)) { $ready = $false }
            if (-not $ready) { $blockers.Add("$($dependency.taskId) in $($dependency.repository) requires $stage; observed $($view.status). $($view.error)") }
        }
    } catch { $blockers.Add($_.Exception.Message) }
    return [pscustomobject]@{ ready = $blockers.Count -eq 0; blockers = $blockers.ToArray(); evidence = $evidence.ToArray() }
}

function Test-FactoryRockTaskLaunchPrerequisites {
    param($Context, $Config, $Task)
    if (-not [string](Get-FactoryNestedValue $Task 'rockId')) { return [pscustomobject]@{ ready = $true; blockers = @(); evidence = @() } }
    if ([string](Get-FactoryNestedValue (Get-FactoryNestedValue $Task 'backgroundSession') 'id')) { return [pscustomobject]@{ ready = $true; blockers = @(); evidence = @() } }
    try {
        $configuration = Get-FactoryRockConfiguration -Config $Config
        if ($null -eq $configuration) { throw 'Direct ROCK configuration is disabled or missing.' }
        $owner = Get-FactoryRockOwner $configuration ([string]$Task.id) ([string]$Context.repositoryRoot)
        if ($null -eq $owner -or [string]$owner.epicGid -cne [string]$Task.rockId) { throw 'Direct task ownership changed or is missing.' }
        $binding = Get-FactoryRockOwnedBinding $configuration ([string]$Task.id) ([string]$Context.repositoryRoot)
        if ([string](Get-FactoryNestedValue $binding 'mode' 'execute') -ceq 'observe') { throw 'Observation-only ROCK binding cannot launch a worker.' }
        if ([bool](Read-FactoryRockMemory $configuration ([string]$owner.epicGid)).paused -or [bool](Read-FactoryRockCoordinatorMemory $configuration).paused) { throw 'ROCK coordinator or goal is paused.' }
        return Test-FactoryRockPrerequisites $configuration ([string]$Task.id) ([string]$Context.repositoryRoot)
    } catch { return [pscustomobject]@{ ready = $false; blockers = @($_.Exception.Message); evidence = @() } }
}

function Get-FactoryRockJointContext {
    param($Configuration)
    $goals = New-Object 'Collections.Generic.List[object]'
    $cache = @{}
    foreach ($goal in @($Configuration.orchestrators)) {
        try { $memory = Read-FactoryRockMemory $Configuration ([string]$goal.epicGid) }
        catch { $goals.Add([pscustomobject]@{ rockId = [string]$goal.epicGid; name = [string]$goal.name; available = $false; error = $_.Exception.Message }); continue }
        $views = @(@((Get-FactoryNestedValue $goal 'ownedTasks' @())) + @((Get-FactoryNestedValue $goal 'watchedTasks' @())) | ForEach-Object { Get-FactoryRockTaskView $_ $cache })
        $sourceAt = Get-FactoryNestedValue $memory 'sourcesUpdatedAt'
        $sourceFresh = $sourceAt -and ([DateTimeOffset]::UtcNow - (ConvertTo-FactoryRockDateTimeOffset $sourceAt)).TotalMinutes -lt 60
        $goals.Add([pscustomobject]@{ rockId = [string]$goal.epicGid; name = [string]$goal.name; memoryPath = (Get-FactoryRockPaths $Configuration ([string]$goal.epicGid)).memory; paused = [bool]$memory.paused; summary = [string]$memory.summary; decisions = @($memory.decisions | Select-Object -Last 20); questions = @($memory.questions | Where-Object status -eq 'open'); sources = @($memory.sources); sourcesUpdatedAt = $sourceAt; sourcesFresh = [bool]$sourceFresh; tasks = $views; ownedTasks = @($goal.ownedTasks); watchedTasks = @($goal.watchedTasks) })
    }
    $shared = Read-FactoryRockCoordinatorMemory $Configuration
    return [pscustomobject]@{ coordinatorId = [string]$shared.coordinatorId; memoryPath = (Get-FactoryRockCoordinatorPaths $Configuration).memory; summary = [string]$shared.summary; decisions = @($shared.decisions | Select-Object -Last 40); rocks = $goals.ToArray() }
}

function Invoke-FactoryRockCoordinatorCycle {
    param($Configuration, [string]$Epic = '', [string]$Reason = '', [scriptblock]$ModelInvoker)
    $paths = Get-FactoryRockCoordinatorPaths $Configuration
    $mutex = New-Object Threading.Mutex($false, $paths.mutexName)
    $owns = $false
    $processed = 0; $completed = 0; $failed = 0
    try {
        try { $owns = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns = $true }
        if (-not $owns) { return [pscustomobject]@{ busy = $true; processed = 0; completed = 0; failed = 0 } }
        if ([bool](Read-FactoryRockCoordinatorMemory $Configuration).paused) { return [pscustomobject]@{ paused = $true; processed = 0; completed = 0; failed = 0 } }
        Sync-FactoryRockCoordinatorInputs $Configuration
        $pending = New-Object 'Collections.Generic.List[object]'
        foreach ($goal in @($Configuration.orchestrators)) {
            if ($Epic -and $Epic -cne [string]$goal.name -and $Epic -cne [string]$goal.epicGid) { continue }
            $goalPaths = Get-FactoryRockPaths $Configuration ([string]$goal.epicGid)
            # Schedule wakes inspect inputs; unchanged time buckets cost no model call.
            if ($Reason -and $Reason -cne 'schedule') {
                $contextHash = Get-FactoryTextSha256 ((Get-FactoryRockJointContext $Configuration) | ConvertTo-Json -Depth 60 -Compress)
                $null = Add-FactoryRockEvent $Configuration ([string]$goal.epicGid) "explicit/$Reason/$contextHash" @{ kind = $Reason; taskId = ''; repository = ''; owner = $false }
            }
            if (Test-Path -LiteralPath $goalPaths.events) {
                foreach ($file in @(Get-ChildItem -LiteralPath $goalPaths.events -File -Filter '*.json')) {
                    $record = Read-FactoryJson $file.FullName
                    if ($record.status -eq 'pending' -and (-not $record.retryAt -or (ConvertTo-FactoryRockDateTimeOffset $record.retryAt) -le [DateTimeOffset]::UtcNow)) {
                        $pending.Add([pscustomobject]@{ goal = $goal; path = $file.FullName; createdAt = [string]$record.createdAt; id = [string]$record.id })
                    }
                }
            }
        }
        foreach ($work in @($pending | Sort-Object createdAt, id | Select-Object -First 20)) {
            if ([bool](Read-FactoryRockCoordinatorMemory $Configuration).paused) { break }
            Invoke-FactoryRockEvent $Configuration $work.goal $work.path -ModelInvoker $ModelInvoker
            $record = Read-FactoryJson $work.path
            $processed++
            if ($record.status -eq 'completed') { $completed++ }
            if ($record.status -eq 'failed') { $failed++ }
        }
        return [pscustomobject]@{ coordinatorId = [string]$Configuration.direct.coordinatorId; processed = $processed; completed = $completed; failed = $failed; browserPending = @(Get-FactoryRockBrowserItems $Configuration | Where-Object { $_.status -in @('pending', 'claimed', 'blocked') }).Count }
    } finally { if ($owns) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

function Sync-FactoryRockCoordinatorInputs {
    param($Configuration)
    $repositories = @($Configuration.orchestrators | ForEach-Object { @($_.ownedTasks) + @($_.watchedTasks) } | ForEach-Object { [string]$_.repository } | Sort-Object -Unique)
    foreach ($repository in $repositories) {
        try {
            $context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $repository | ConvertFrom-Json
            $config = Read-FactoryJson $context.configPath
            $ledger = Read-FactoryJson $context.statePath
            if ([bool](Get-FactoryNestedValue (Get-FactoryNestedValue $config 'rocks') 'enabled' $false)) { Sync-FactoryRockTaskEvents $context $config $ledger }
        } catch { Write-Warning "ROCK input unavailable for $repository`: $($_.Exception.Message)" }
    }
    foreach ($goal in @($Configuration.orchestrators)) {
        foreach ($binding in @($goal.ownedTasks)) {
            if (-not @((Get-FactoryNestedValue $binding 'prerequisites' @())).Count) { continue }
            $check = Test-FactoryRockPrerequisites $Configuration ([string]$binding.taskId) ([string]$binding.repository)
            $fingerprint = Get-FactoryTextSha256 ($check | ConvertTo-Json -Depth 20 -Compress)
            $null = Add-FactoryRockEvent $Configuration ([string]$goal.epicGid) "prerequisites/$($binding.taskId)/$fingerprint" @{ kind = 'prerequisite-change'; taskId = [string]$binding.taskId; repository = [string]$binding.repository; owner = $true; prerequisites = $check }
        }
    }
}
