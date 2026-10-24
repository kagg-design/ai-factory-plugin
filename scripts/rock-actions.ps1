. (Join-Path $PSScriptRoot 'rock-common.ps1')
. (Join-Path $PSScriptRoot 'asana-common.ps1')

function Write-FactoryRockCodeEvidence {
    param($Orchestrator, $Event, [string]$Path)
    $commit = [string](Get-FactoryNestedValue $Event.payload 'commit')
    if ($commit -notmatch '^[0-9a-fA-F]{40}$') { return $null }
    $repository = [string](Get-FactoryNestedValue $Event.payload 'repository')
    if (-not (Test-FactoryRockBinding $Orchestrator ([string]$Event.payload.taskId) $repository -IncludeWatched)) { throw 'Code evidence does not belong to a configured ROCK task.' }
    # Read the shared local Git object database after worker cleanup. No fetch,
    # checkout, filters, external diff commands, or network access is involved.
    $result = Invoke-FactoryNativeProcess -Command 'git' -Arguments @('-C', $repository, 'show', '--no-ext-diff', '--no-textconv', '--format=fuller', '--stat', '--patch', '--unified=15', $commit, '--') -TimeoutSeconds 30
    $text = [string]$result.stdout
    $truncated = $text.Length -gt 1000000
    if ($truncated) { $text = $text.Substring(0, 1000000) }
    $files = New-Object 'Collections.Generic.List[object]'
    $names = Invoke-FactoryNativeProcess -Command git -Arguments @('-C', $repository, 'diff-tree', '--root', '--no-commit-id', '--name-only', '-z', '-r', $commit, '--') -TimeoutSeconds 30
    $budget = 500000
    foreach ($relative in @(([string]$names.stdout).Split([char]0) | Where-Object { $_ } | Select-Object -First 30)) {
        $entry = [ordered]@{ path = $relative; content = $null; omitted = '' }
        $object = "$commit`:$relative"
        $size = Invoke-FactoryNativeProcess -Command git -Arguments @('-C', $repository, 'cat-file', '-s', $object) -TimeoutSeconds 30
        $bytes = 0
        if ($size.exitCode -ne 0) { $entry.omitted = 'Deleted or unavailable at this commit.' }
        elseif ([IO.Path]::GetExtension($relative) -notin @('.php','.ps1','.cs','.ts','.tsx','.js','.jsx','.json','.md','.yml','.yaml','.txt','.sql','.css','.scss') -or -not [int]::TryParse([string]$size.stdout,[ref]$bytes) -or $bytes -gt 200000 -or $bytes -gt $budget) { $entry.omitted = 'Binary, large or beyond the bounded snapshot budget.' }
        else {
            $blob = Invoke-FactoryNativeProcess -Command git -Arguments @('-C', $repository, 'show', '--no-ext-diff', '--no-textconv', $object) -TimeoutSeconds 30
            if ($blob.exitCode -eq 0) { $entry.content = [string]$blob.stdout; $budget -= $bytes } else { $entry.omitted = 'Blob unavailable.' }
        }
        $files.Add([pscustomobject]$entry)
    }
    Write-FactoryJsonAtomic -Path $Path -Value @{ commit = $commit; available = [int]$result.exitCode -eq 0; truncated = $truncated; diff = $text; files = $files.ToArray(); note = 'Exact local task commit, with bounded full-file blobs. Other read-only checkouts may be stale. This is code-inspection evidence, not deployment or live-service verification.' }
    return $Path
}

function Invoke-FactoryRockAction {
    param($Configuration, $Orchestrator, $Event, $Action)
    $rockId = [string]$Orchestrator.epicGid
    $actionKey = "$($Event.id)/$($Action.id)"
    if ($Action.type -eq 'refresh') {
        $null = Update-FactoryRockMemory $Configuration $rockId { param($memory) Set-FactoryProperty $memory 'sourceRefreshRequired' $true; Set-FactoryProperty $memory 'sourceRefreshReason' ([string]$Action.text) }
        return
    }
    if ($Action.type -eq 'report') {
        $null = Add-FactoryRockBrowserItem -Configuration $Configuration -EpicGid $rockId -Key $actionKey -Text ([string]$Action.text)
        return
    }
    if ($Action.type -eq 'escalate') {
        $null = Update-FactoryRockMemory $Configuration $rockId {
            param($memory)
            if (-not @($memory.questions | Where-Object { $_.id -ceq $actionKey }).Count) {
                $memory.questions = @($memory.questions) + @([pscustomobject]@{ id = $actionKey; text = [string]$Action.text; status = 'open'; createdAt = Get-FactoryUtcTimestamp; answer = $null })
            }
        }
        $null = Add-FactoryRockBrowserItem -Configuration $Configuration -EpicGid $rockId -Key $actionKey -Text "[${rockId} coordinator] Question for Igor: $($Action.text)"
        return
    }
    if (-not (Test-FactoryRockBinding $Orchestrator ([string]$Action.taskId) ([string]$Action.repository))) { throw 'ROCK action targets a task outside its configured ownership.' }
    $authority = Get-FactoryRockOwnedBinding $Configuration ([string]$Action.taskId) ([string]$Action.repository)
    if ([string](Get-FactoryNestedValue $authority 'mode' 'execute') -ceq 'observe') { throw 'Observation-only ROCK binding cannot answer or dispatch tasks.' }
    $context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository ([string]$Action.repository) | ConvertFrom-Json
    $config = Read-FactoryJson -Path $context.configPath
    $projectRock = Get-FactoryRockConfiguration -Config $config
    if ($null -eq $projectRock -or -not (Test-FactorySamePath -Left ([string]$projectRock.configurationPath) -Right ([string]$Configuration.configurationPath))) { throw 'Target project has not enabled this ROCK configuration.' }
    $state = Read-FactoryJson -Path $context.statePath
    if ([bool]$state.paused -or -not [bool]$state.active) { throw 'Deferred: target factory is paused or inactive.' }
    $current = @($state.tasks | Where-Object { [string]$_.id -ceq [string]$Action.taskId })
    if ($Action.type -eq 'answer') {
        if ([string]$Event.payload.kind -cne 'Question' -or -not [bool]$Event.payload.owner -or
            [string]$Event.payload.taskId -cne [string]$Action.taskId -or
            -not (Test-FactorySamePath -Left ([string]$Event.payload.repository) -Right ([string]$Action.repository)) -or
            [string]$Event.payload.question.storyGid -cne [string]$Action.questionId) { throw 'Answer does not correlate with the originating owned question.' }
        $null = & (Join-Path $PSScriptRoot 'answer-task.ps1') -Repository ([string]$context.repositoryRoot) -TaskId ([string]$Action.taskId) -Text ([string]$Action.text) -FromRock -RockId $rockId -RockQuestionId ([string]$Action.questionId) -RockActionId $actionKey
    } elseif ($Action.type -eq 'dispatch') {
        if ($current.Count) {
            if ([string](Get-FactoryNestedValue $current[0] 'rockDispatchId') -ceq $actionKey) { return }
            throw 'ROCK dispatch cannot replace an existing task/run; inspect it or propose a new follow-up.'
        }
        $prerequisites = Test-FactoryRockPrerequisites $Configuration ([string]$Action.taskId) ([string]$Action.repository)
        if (-not $prerequisites.ready) { throw "Deferred: prerequisites: $($prerequisites.blockers -join '; ')" }
        $brief = [string]$Action.brief
        if (-not (Get-FactoryAsanaTaskRepo -Notes $brief)) {
            $repoSlug = [string]$config.repo
            if ($repoSlug -notmatch '/') { $repoSlug = "local/$(Get-FactoryOwnRepo -Config $config -Repository ([string]$context.repositoryRoot))" }
            $brief = "Repo: $repoSlug`n$brief"
        }
        $binding = @($Orchestrator.ownedTasks | Where-Object { [string]$_.taskId -ceq [string]$Action.taskId })[0]
        if ([bool](Get-FactoryNestedValue $binding 'requiresMergeGate' $true)) { $brief += "`n`nMerge gate: ask Igor before merging" }
        $intake = [ordered]@{ version = 1; source = @{ adapter = 'asana'; id = [string]$Action.taskId; url = "https://app.asana.com/0/0/$($Action.taskId)" }; startMode = 'auto'; title = [string]$Action.title; brief = $brief; acceptanceCriteria = @((Get-FactoryNestedValue $Action 'acceptanceCriteria' @())); sourceNotes = @("Direct ROCK $rockId, action $actionKey; source remains Asana."); sourceError = $null }
        $intakePath = Join-Path ([string]$context.sessionsPath) "rock-$([Guid]::NewGuid().ToString('N')).json"
        try {
            Write-FactoryJsonAtomic -Path $intakePath -Value $intake
            $null = & (Join-Path $PSScriptRoot 'enqueue-task.ps1') -Repository ([string]$context.repositoryRoot) -IntakePath $intakePath -NoResume -RockId $rockId -RockActionId $actionKey
        } finally { if (Test-Path -LiteralPath $intakePath) { Remove-Item -LiteralPath $intakePath } }
    }
    # A native wake preserves pause; other repositories may have sleeping schedulers.
    [IO.File]::WriteAllText((Join-Path ([string]$context.projectData) 'scheduler.wake'), (Get-FactoryUtcTimestamp), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-FactoryRockEvent {
    param($Configuration, $Orchestrator, [string]$EventPath, [scriptblock]$ModelInvoker)
    $rockId = [string]$Orchestrator.epicGid
    $paths = Get-FactoryRockPaths $Configuration $rockId
    $memory = Read-FactoryRockMemory $Configuration $rockId
    if ([bool]$memory.paused -or [bool](Read-FactoryRockCoordinatorMemory $Configuration).paused) { return }
    $event = Read-FactoryJson -Path $EventPath
    if ($event.status -ne 'pending' -or ($event.retryAt -and (ConvertTo-FactoryRockDateTimeOffset $event.retryAt) -gt [DateTimeOffset]::UtcNow)) { return }
    if ([string]$event.rockId -cne $rockId -or [string]$event.id -cne [IO.Path]::GetFileNameWithoutExtension($EventPath)) { throw 'ROCK event identity mismatch.' }
    try {
        $sourceAt = Get-FactoryNestedValue $memory 'sourcesUpdatedAt' ''
        $sourcesStale = -not $sourceAt -or ([DateTimeOffset]::UtcNow - (ConvertTo-FactoryRockDateTimeOffset $sourceAt)).TotalMinutes -ge 60
        if ($null -eq $ModelInvoker -and $null -eq $event.result -and ($sourcesStale -or @((Get-FactoryNestedValue $memory 'sources' @())).Count -eq 0)) {
            $null = Update-FactoryRockMemory $Configuration $rockId { param($record) Set-FactoryProperty $record 'sourceRefreshRequired' $true }
            $event.retryAt = [DateTimeOffset]::UtcNow.AddSeconds(60).ToString('o')
            Write-FactoryRockJson -Path $EventPath -Value $event
            return
        }
        if ([string]$event.payload.kind -ceq 'Question' -and [bool]$event.payload.owner) {
            $context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository ([string]$event.payload.repository) | ConvertFrom-Json
            $state = Read-FactoryJson -Path $context.statePath
            $task = Get-FactoryTask -State $state -TaskId ([string]$event.payload.taskId)
            $question = Get-FactoryNestedValue $task 'asanaQuestion'
            $alreadyApplied = @((Get-FactoryNestedValue $task 'rockAppliedActions' @()) | Where-Object { $_.StartsWith("$($event.id)/", [StringComparison]::Ordinal) }).Count -gt 0
            if (-not $alreadyApplied -and ($null -eq $question -or [string]$question.storyGid -cne [string]$event.payload.question.storyGid)) {
                $event.status = 'superseded'
                Write-FactoryRockJson -Path $EventPath -Value $event
                return
            }
        }
        if ($null -eq $event.result) {
            if ([int]$event.attempts -ge 3) { throw 'Model attempt limit reached after interrupted launches.' }
            $event.attempts = [int]$event.attempts + 1
            $event.sourcesUpdatedAt = $sourceAt
            # Persist the attempt before the model starts. A killed runner leaves a retriable event.
            Write-FactoryRockJson -Path $EventPath -Value $event
            $cycleId = "$($event.id)-$($event.attempts)-$([Guid]::NewGuid().ToString('N'))"
            $requestPath = Join-Path $paths.cycles "$cycleId.request.json"
            $outputPath = Join-Path $paths.cycles "$cycleId.output.json"
            $compactMemory = @{ summary = $memory.summary; revision = $memory.revision; decisions = @($memory.decisions | Select-Object -Last 20); questions = @($memory.questions | Where-Object status -eq 'open') + @($memory.questions | Where-Object status -in @('answered','withdrawn') | Select-Object -Last 10); sources = @((Get-FactoryNestedValue $memory 'sources' @())) }
            $codeEvidencePath = Write-FactoryRockCodeEvidence -Orchestrator $Orchestrator -Event $event -Path (Join-Path $paths.cycles "$cycleId.code.json")
            $request = [ordered]@{ version = 1; rock = $Orchestrator; memory = $compactMemory; memoryPath = $paths.memory; codeEvidencePath = $codeEvidencePath; event = $event; coordination = Get-FactoryRockJointContext $Configuration }
            Write-FactoryJsonAtomic -Path $requestPath -Value $request
            $instructionsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'resources\rock-direct-instructions.md'
            $prompt = "Read $instructionsPath and $requestPath. You are the ONE shared coordinator for both ROCKs. Consider both goals and their shared history. Process this durable event; preserve the exact owner and prerequisite boundaries. Your result eventId must be $($event.id). Return the JSON result only."
            if ($null -ne $ModelInvoker) {
                $output = & $ModelInvoker $prompt $request
            } else {
                $tools = @('Read', 'Grep', 'Glob', 'WebSearch')
                # Native browser snapshots are imported into memory. This planner
                # has no connectors, custom hooks, shell, or mutation tools.
                $codeDirectories = @($Configuration.orchestrators | ForEach-Object { [string]$_.repoPath; @($_.extraDirs) } | Where-Object { $_ } | Sort-Object -Unique)
                $arguments = @('-p', $prompt, '--safe-mode', '--restricted', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--tools', ($tools -join ','), '--permission-mode', 'dontAsk', '--allowedTools') + $tools + @('--add-dir', [string]$Configuration.direct.memoryDir, (Split-Path -Parent $instructionsPath)) + $codeDirectories + @('--output-format', 'json')
                $environment = @{}
                $tokenName = [string](Get-FactoryNestedValue $Configuration 'tokenEnv' '')
                if ($tokenName) { $environment[$tokenName] = $null }
                $response = Invoke-FactoryNativeProcess -Command ([string]$Configuration.claudePath) -Arguments $arguments -WorkingDirectory ([string]$Orchestrator.repoPath) -Environment $environment -TimeoutSeconds ([int]$Configuration.direct.timeoutSeconds)
                if ([int]$response.exitCode -ne 0) { throw "ROCK process failed with exit $($response.exitCode)." }
                $output = [string]$response.stdout
            }
            # Retain raw output as diagnostic evidence, never execute it as a command.
            Write-FactoryJsonAtomic -Path $outputPath -Value @{ output = [string]$output; capturedAt = Get-FactoryUtcTimestamp }
            $result = ConvertFrom-FactoryRockResult -Output ([string]$output) -EventId ([string]$event.id)
            # Validate every target before performing any side effect.
            foreach ($action in @($result.actions)) {
                if ($action.type -notin @('escalate', 'report', 'refresh') -and -not (Test-FactoryRockBinding $Orchestrator ([string]$action.taskId) ([string]$action.repository))) { throw 'ROCK result contains an unowned task.' }
            }
            $event.result = $result
            Write-FactoryRockJson -Path $EventPath -Value $event
        }
        # Result is durable before actions. Replays use the same action IDs.
        if ([int]$event.applyAttempts -ge 3 -and [string]$event.error -notlike 'Deferred:*') { throw 'Application attempt limit reached after interrupted operations.' }
        $event.applyAttempts = [int]$event.applyAttempts + 1
        Write-FactoryRockJson -Path $EventPath -Value $event
        foreach ($action in @($event.result.actions)) {
            if ([string]$action.id -cin @($event.receipts)) { continue }
            if ([bool](Read-FactoryRockMemory $Configuration $rockId).paused -or [bool](Read-FactoryRockCoordinatorMemory $Configuration).paused) { throw 'Deferred: ROCK coordinator or goal is paused.' }
            if ($event.sourcesUpdatedAt -and [string](Get-FactoryNestedValue (Read-FactoryRockMemory $Configuration $rockId) 'sourcesUpdatedAt') -cne [string]$event.sourcesUpdatedAt) { throw 'Source snapshots changed after planning; inspect the retained result before replanning.' }
            Invoke-FactoryRockAction $Configuration $Orchestrator $event $action
            $event.receipts = @($event.receipts) + @([string]$action.id)
            Write-FactoryRockJson -Path $EventPath -Value $event
        }
        $null = Update-FactoryRockMemory $Configuration $rockId {
            param($record)
            if ([string]$event.id -cnotin @($record.appliedCycles)) {
                $record.summary = [string]$event.result.summary
                foreach ($text in @($event.result.decisions)) { $record.decisions = @($record.decisions) + @([pscustomobject]@{ actor = "rock:$rockId"; text = [string]$text; eventId = [string]$event.id; createdAt = Get-FactoryUtcTimestamp }) }
                $record.appliedCycles = @($record.appliedCycles) + @([string]$event.id)
            }
        }
        $null = Update-FactoryRockCoordinatorMemory $Configuration {
            param($record)
            if ([string]$event.id -cnotin @($record.appliedEvents)) {
                $record.decisions = @($record.decisions) + @([pscustomobject]@{ rockId = $rockId; eventId = [string]$event.id; summary = [string]$event.result.summary; decisions = @($event.result.decisions); actor = "coordinator:$($record.coordinatorId)"; at = Get-FactoryUtcTimestamp })
                $record.summary = (@($record.decisions | Select-Object -Last 10 | ForEach-Object { "$($_.rockId): $($_.summary)" }) -join "`n")
                $record.appliedEvents = @($record.appliedEvents) + @([string]$event.id)
            }
        }
        # The internal checkpoint can contain technical history and is not a
        # human digest. Only explicit report/escalate actions enter the outbox.
        $event.status = 'completed'; $event.error = $null; $event.retryAt = $null
        Write-FactoryRockJson -Path $EventPath -Value $event
    } catch {
        $event.error = $_.Exception.Message
        $event.retryAt = [DateTimeOffset]::UtcNow.AddSeconds(60).ToString('o')
        # Applying a valid saved result never calls the model again. Pause/session races
        # are deferred without exhausting model attempts.
        if (($null -eq $event.result -and [int]$event.attempts -ge 3) -or ($null -ne $event.result -and [int]$event.applyAttempts -ge 3 -and $event.error -notlike 'Deferred:*')) {
            $event.status = 'failed'
            $null = Update-FactoryRockMemory $Configuration $rockId {
                param($record)
                $id = "$($event.id)/runner-failed"
                if (-not @($record.questions | Where-Object { $_.id -ceq $id }).Count) { $record.questions = @($record.questions) + @([pscustomobject]@{ id = $id; text = "ROCK cycle failed after $($event.attempts) attempts: $($event.error). Inspect $EventPath."; status = 'open'; createdAt = Get-FactoryUtcTimestamp; answer = $null }) }
            }
        }
        Write-FactoryRockJson -Path $EventPath -Value $event
        Write-Warning "ROCK $rockId event $($event.id): $($event.error)"
    }
}
