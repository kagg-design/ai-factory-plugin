[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PluginRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\asana-common.ps1')
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\attention-state.ps1')

function Assert-AsanaIntegration {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$syncSource = Get-Content -LiteralPath (Join-Path $PluginRoot 'scripts\asana-sync.ps1') -Raw
$syncTokens = $null
$syncParseErrors = $null
$syncAst = [Management.Automation.Language.Parser]::ParseInput($syncSource, [ref]$syncTokens, [ref]$syncParseErrors)
Assert-AsanaIntegration (@($syncParseErrors).Count -eq 0) 'Asana sync does not parse.'
$summaryFunction = @($syncAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Format-FactoryAsanaTestSummary' }, $true))[0]
Assert-AsanaIntegration ($null -ne $summaryFunction) 'Asana sync test summary formatter is missing.'
. ([scriptblock]::Create($summaryFunction.Extent.Text))
& {
    Set-StrictMode -Version 2.0
    $checks = @(
        [pscustomobject]@{ command = 'php artisan test --parallel'; status = 'passed' }
        [pscustomobject]@{ name = 'Pint'; status = 'passed' }
        [pscustomobject]@{ command = 'private command' }
    )
    $summary = Format-FactoryAsanaTestSummary -Checks $checks
    Assert-AsanaIntegration ($summary -eq 'Check 1: passed, Pint: passed, Check 3: unknown') 'Asana sync could not summarize checks without a name or status, or exposed a raw command.'
    Assert-AsanaIntegration ((Format-FactoryAsanaTestSummary -Checks @()) -eq 'See factory review and integration checks.') 'Asana sync lost the empty-check fallback.'
}

$config = Get-Content -LiteralPath (Join-Path $PluginRoot 'config.default.json') -Raw | ConvertFrom-Json
$script:calls = New-Object Collections.Generic.List[object]
function Invoke-FactoryAsana {
    param($Config, [string]$Method = 'GET', [string]$Path, $Data = $null)
    $script:calls.Add([pscustomobject]@{ method = $Method; path = $Path; data = $Data })
    if ($Path -eq '/test-pagination') {
        return [pscustomobject]@{
            data = @([pscustomobject]@{ gid = 'first' })
            next_page = [pscustomobject]@{ uri = 'https://app.asana.com/api/1.0/test-pagination?offset=second' }
        }
    }
    if ($Path -eq '/test-pagination?offset=second') {
        return [pscustomobject]@{ data = @([pscustomobject]@{ gid = 'second' }) }
    }
    if ($Path -eq '/test-null-page') {
        return [pscustomobject]@{ data = @([pscustomobject]@{ gid = 'only' }); next_page = $null }
    }
    return [pscustomobject]@{ data = [pscustomobject]@{ gid = '123'; created_at = '2026-10-17T00:00:00Z' } }
}

Set-FactoryAsanaDone -Config $config -Gid '123'
Assert-AsanaIntegration ($script:calls.Count -eq 1) 'Done must update task fields and completion in one request.'
$call = $script:calls[0]
Assert-AsanaIntegration ($call.method -eq 'PUT' -and $call.path -eq '/tasks/123') 'Done used the wrong Asana endpoint.'
Assert-AsanaIntegration ($call.data.completed -eq $true) 'Done did not complete the Asana task.'
Assert-AsanaIntegration ($call.data.custom_fields[[string]$config.asana.fields.factory] -eq [string]$config.asana.fields.done) 'Done did not set Factory = Done.'
Assert-AsanaIntegration ($call.data.custom_fields[[string]$config.asana.fields.resolution] -eq [string]$config.asana.fields.resolutionFixed) 'Done did not set Resolution = Fixed.'
Assert-AsanaIntegration ((Get-FactoryAsanaTaskRepo -Notes ("Repo: awesomemotive/motivehr" + [Environment]::NewLine + "Build this")) -eq 'awesomemotive/motivehr') 'Repo routing header was not read.'
Assert-AsanaIntegration (-not (Get-FactoryAsanaTaskRepo -Notes ("Build this" + [Environment]::NewLine + "Repo: other/repo"))) 'A later Repo line was treated as a routing header.'
Assert-AsanaIntegration ((Get-FactoryAsanaCommentActor -Text 'ANSWER (billing-orchestrator): B') -eq 'billing-orchestrator') 'Billing answer tag was ignored.'
Assert-AsanaIntegration ((Get-FactoryAsanaCommentActor -Text 'Igor says A') -eq 'Igor') 'Untagged Igor comment was misclassified.'
Assert-AsanaIntegration ((Get-FactoryAsanaCommentActor -Text 'ANSWER (Igor via terminal): A') -eq 'Igor') 'Igor terminal answer was misclassified.'

$pendingQuestion = [pscustomobject]@{
    storyGid = 'question-story-1'
    askedAt = '2026-10-17T10:00:00Z'
    text = "QUESTION (factory):`n1. Which option?`n   Options: A or B"
}
$questionState = [pscustomobject]@{
    tasks = @([pscustomobject]@{
        id = '123'; title = 'Asana worker'; status = 'blocked'; asanaMode = $true
        asanaQuestion = $pendingQuestion; updatedAt = '2026-10-17T10:01:00Z'
        error = 'Worker stopped for an answer.'
    })
    scheduler = [pscustomobject]@{ status = 'stopped' }
    paused = $false
}
$questionEvents = @(Get-FactoryOperatorActionEvents -State $questionState -Config $config)
Assert-AsanaIntegration ($questionEvents.Count -eq 1 -and $questionEvents[0].kind -eq 'asana-question') 'An Asana question appeared as a generic blocked failure.'
Assert-AsanaIntegration ($questionEvents[0].reason -eq $pendingQuestion.text -and $questionEvents[0].command -like 'factory answer 123*') 'The terminal attention event omitted the question or answer command.'
$questionKey = Get-FactoryAttentionEventKey -Event $questionEvents[0]
$questionState.tasks[0].updatedAt = '2026-10-17T10:05:00Z'
$nextEvents = @(Get-FactoryOperatorActionEvents -State $questionState -Config $config)
Assert-AsanaIntegration ((Get-FactoryAttentionEventKey -Event $nextEvents[0]) -eq $questionKey) 'A routine state update repeated the same Asana question.'
$questionState.tasks[0].asanaQuestion = $null
$closedEvents = @(Get-FactoryOperatorActionEvents -State $questionState -Config $config)
Assert-AsanaIntegration ($closedEvents[0].kind -eq 'blocked') 'A resolved Asana question remained an active terminal question.'

& {
    Set-StrictMode -Version 2.0
    $fieldWithoutValue = [pscustomobject]@{ gid = [string]$config.asana.fields.factory; name = 'Factory' }
    $taskWithoutValue = [pscustomobject]@{ custom_fields = @($fieldWithoutValue) }
    Assert-AsanaIntegration ((Get-FactoryAsanaField -Task $taskWithoutValue -Gid ([string]$config.asana.fields.factory)) -eq '') 'An unset Asana field failed under strict mode.'
}

& {
    Set-StrictMode -Version 2.0
    $onePage = @(Get-FactoryAsanaPages -Config $config -Path '/test-one-page')
    Assert-AsanaIntegration ($onePage.Count -eq 1 -and $onePage[0].gid -eq '123') 'A final Asana page without next_page failed.'
    $nullPage = @(Get-FactoryAsanaPages -Config $config -Path '/test-null-page')
    Assert-AsanaIntegration ($nullPage.Count -eq 1 -and $nullPage[0].gid -eq 'only') 'A null Asana next_page failed.'
    $twoPages = @(Get-FactoryAsanaPages -Config $config -Path '/test-pagination')
    Assert-AsanaIntegration (($twoPages.gid -join ',') -eq 'first,second') 'Asana pagination skipped a page.'
}

$source = Get-Content -LiteralPath (Join-Path $PluginRoot 'scripts\asana-poller.ps1') -Raw
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
Assert-AsanaIntegration (@($parseErrors).Count -eq 0) 'Asana poller does not parse.'
foreach ($name in @('Get-AsanaPriorityRank', 'Get-ReadyTasks')) {
    $functionAst = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))[0]
    Assert-AsanaIntegration ($null -ne $functionAst) "Missing poller function $name."
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
& {
    Set-StrictMode -Version 2.0
    $priorityWithoutValue = [pscustomobject]@{ custom_fields = @([pscustomobject]@{ name = 'Priority' }) }
    Assert-AsanaIntegration ((Get-AsanaPriorityRank -Task $priorityWithoutValue) -eq 3) 'An unset Priority field failed under strict mode.'
}

function New-ReadyFixture {
    param([string]$Gid, [string]$Priority, [string]$CreatedAt, [bool]$Completed = $false)
    $customFields = @([pscustomobject]@{
        gid = [string]$config.asana.fields.factory
        name = 'Factory'
        enum_value = [pscustomobject]@{ gid = [string]$config.asana.fields.ready; name = 'Ready' }
    })
    if ($Priority) {
        $customFields += [pscustomobject]@{
            gid = 'priority-field'; name = 'Priority'
            enum_value = [pscustomobject]@{ gid = 'priority-option'; name = $Priority }
        }
    }
    return [pscustomobject]@{ gid = $Gid; created_at = $CreatedAt; completed = $Completed; custom_fields = $customFields }
}

$script:readyFixtures = @(
    (New-ReadyFixture -Gid '1' -Priority 'Low' -CreatedAt '2026-10-15T00:00:00Z'),
    (New-ReadyFixture -Gid '2' -Priority 'High' -CreatedAt '2026-10-16T00:00:00Z'),
    (New-ReadyFixture -Gid '3' -Priority '' -CreatedAt '2026-10-14T00:00:00Z'),
    (New-ReadyFixture -Gid '4' -Priority 'Medium' -CreatedAt '2026-10-13T00:00:00Z'),
    (New-ReadyFixture -Gid '5' -Priority 'High' -CreatedAt '2026-10-12T00:00:00Z'),
    (New-ReadyFixture -Gid '6' -Priority 'High' -CreatedAt '2026-10-11T00:00:00Z' -Completed $true)
)
$script:searchFailure = $false
$script:seenPaths = New-Object Collections.Generic.List[string]
function Get-FactoryAsanaPages {
    param($Config, [string]$Path)
    $script:seenPaths.Add($Path)
    if ($script:searchFailure -and $Path -like '/workspaces/*') { throw 'Search unavailable.' }
    return $script:readyFixtures
}

$ordered = @(Get-ReadyTasks -Config $config | ForEach-Object { [string]$_.gid })
Assert-AsanaIntegration (($ordered -join ',') -eq '5,2,4,1,3') 'Ready tasks were not sorted by priority then creation time.'
Assert-AsanaIntegration ($script:seenPaths[0] -like '/workspaces/*/tasks/search*') 'Poller did not use Asana search.'
$script:searchFailure = $true
$script:seenPaths.Clear()
$ordered = @(Get-ReadyTasks -Config $config | ForEach-Object { [string]$_.gid })
Assert-AsanaIntegration (($ordered -join ',') -eq '5,2,4,1,3') 'Fallback task query changed Ready ordering.'
Assert-AsanaIntegration ($script:seenPaths[1] -like '/projects/*/tasks*') 'Poller did not fall back to project tasks.'

$rockSource = Get-Content -LiteralPath (Join-Path $PluginRoot 'rock-cycle.ps1') -Raw
$rockAst = [Management.Automation.Language.Parser]::ParseInput($rockSource, [ref]$tokens, [ref]$parseErrors)
Assert-AsanaIntegration (@($parseErrors).Count -eq 0) 'Rock launcher does not parse.'
foreach ($name in @('ConvertTo-RockTimestamp', 'Get-RockLockStatus', 'Test-RockAfter', 'Get-RockInstancePaths', 'Get-RockPauseControl', 'Test-RockEpicUrl', 'Select-RockOrchestrators', 'Write-RockStateAtomic')) {
    $functionAst = @($rockAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))[0]
    Assert-AsanaIntegration ($null -ne $functionAst) "Missing rock launcher function $name."
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$stateTestDir = Join-Path ([IO.Path]::GetTempPath()) ("rock-state-test-$([Guid]::NewGuid().ToString('N'))")
$stateTestPath = Join-Path $stateTestDir 'state.json'
try {
    Write-RockStateAtomic -Path $stateTestPath -Value ([ordered]@{ lastRunEnd = '2026-10-17T10:00:00Z'; lastDailyRun = '2026-10-17' })
    $firstState = [IO.File]::ReadAllText($stateTestPath) | ConvertFrom-Json
    Assert-AsanaIntegration ((ConvertTo-RockTimestamp -Value $firstState.lastRunEnd) -eq (ConvertTo-RockTimestamp -Value '2026-10-17T10:00:00Z')) 'Rock state could not be written without a factory mutex.'
    Write-RockStateAtomic -Path $stateTestPath -Value ([ordered]@{ lastRunEnd = '2026-10-17T11:00:00Z'; lastDailyRun = '2026-10-17' })
    $secondState = [IO.File]::ReadAllText($stateTestPath) | ConvertFrom-Json
    Assert-AsanaIntegration ((ConvertTo-RockTimestamp -Value $secondState.lastRunEnd) -eq (ConvertTo-RockTimestamp -Value '2026-10-17T11:00:00Z')) 'Rock state replacement failed.'
} finally {
    foreach ($path in @($stateTestPath, "$stateTestPath.previous.bak")) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    if ([IO.Directory]::Exists($stateTestDir)) { [IO.Directory]::Delete($stateTestDir) }
}
$lockFile = Join-Path ([IO.Path]::GetTempPath()) ("rock-lock-test-$([Guid]::NewGuid().ToString('N')).json")
try {
    Assert-AsanaIntegration ((Get-RockLockStatus -Path $lockFile -StaleMinutes 60) -eq 'absent') 'An absent rock lock was treated as busy.'
    [IO.File]::WriteAllText($lockFile, (@{ pid = $PID; startedAt = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json))
    Assert-AsanaIntegration ((Get-RockLockStatus -Path $lockFile -StaleMinutes 60) -eq 'busy') 'A live rock lock was ignored.'
    [IO.File]::WriteAllText($lockFile, (@{ pid = 2147483647; startedAt = [DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json))
    Assert-AsanaIntegration ((Get-RockLockStatus -Path $lockFile -StaleMinutes 60) -eq 'stale') 'A dead rock lock was not reclaimed.'
} finally { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
$boundary = [DateTimeOffset]::Parse('2026-10-17T10:00:00Z')
Assert-AsanaIntegration (Test-RockAfter -Value '2026-10-17T10:00:01Z' -Boundary $boundary) 'A new Asana change was missed.'
Assert-AsanaIntegration (-not (Test-RockAfter -Value '2026-10-17T10:00:00Z' -Boundary $boundary)) 'The last run boundary retriggered a cycle.'
$firstPaths = Get-RockInstancePaths -StateRoot ([IO.Path]::GetTempPath()) -Name 'access' -EpicGid '1219601019224697'
$secondPaths = Get-RockInstancePaths -StateRoot ([IO.Path]::GetTempPath()) -Name 'billing' -EpicGid '1219601069124635'
Assert-AsanaIntegration ($firstPaths.stateDir -ne $secondPaths.stateDir) 'Different epics share rock state.'
Assert-AsanaIntegration ($firstPaths.mutexName -ne $secondPaths.mutexName) 'Different epics share a rock mutex.'
Assert-AsanaIntegration ($firstPaths.stateDir -like '*\access') 'Rock state directory does not use the orchestrator name.'
$rockConfig = Get-Content -LiteralPath (Join-Path $PluginRoot 'rock-cycle.json') -Raw | ConvertFrom-Json
Assert-AsanaIntegration ('mcp__claude_ai_Asana__get_task' -in @($rockConfig.allowedTools)) 'Claude.ai Asana read tool is missing from the allowlist.'
Assert-AsanaIntegration ('mcp__claude_ai_Asana__add_comment' -in @($rockConfig.allowedTools)) 'Claude.ai Asana comment tool is missing from the allowlist.'
$rockOrchestrators = @($rockConfig.orchestrators)
Assert-AsanaIntegration ($rockOrchestrators.Count -eq 2) 'Rock config must list both orchestrators.'
foreach ($orchestrator in $rockOrchestrators) {
    Assert-AsanaIntegration (Test-RockEpicUrl -Url $orchestrator.epicUrl -EpicGid $orchestrator.epicGid) "Bad epic URL for $($orchestrator.name)."
}
$sharedDependents = @(
    [pscustomobject]@{ gid = '1219601019224697' },
    [pscustomobject]@{ gid = '1219601069124635' }
)
$selected = Select-RockOrchestrators -Orchestrators $rockOrchestrators -TaskGid '1219600878763453' -Dependents $sharedDependents
Assert-AsanaIntegration ((@($selected.items).name -join ',') -eq 'access,billing' -and -not $selected.fallback) 'Shared task did not wake both orchestrators.'
$selected = Select-RockOrchestrators -Orchestrators $rockOrchestrators -TaskGid 'access-only' -Dependents @([pscustomobject]@{ gid = '1219601019224697' })
Assert-AsanaIntegration ((@($selected.items).name -join ',') -eq 'access') 'Access-only task woke billing.'
$selected = Select-RockOrchestrators -Orchestrators $rockOrchestrators -TaskGid 'unknown' -Dependents @()
Assert-AsanaIntegration (@($selected.items).Count -eq 2 -and $selected.fallback) 'Unknown task did not fall back to change checks for both.'
$selected = Select-RockOrchestrators -Orchestrators $rockOrchestrators -EpicName 'billing'
Assert-AsanaIntegration ((@($selected.items).name -join ',') -eq 'billing') 'Explicit -Epic selected the wrong orchestrator.'
$stories = @(
    [pscustomobject]@{ gid = '1'; created_at = '2026-10-17T09:00:00Z'; created_by = [pscustomobject]@{ gid = '1201416335822270' }; text = '/pause' },
    [pscustomobject]@{ gid = '2'; created_at = '2026-10-17T10:00:00Z'; created_by = [pscustomobject]@{ gid = '1201416335822270' }; text = '[billing-orchestrator] /resume' }
)
Assert-AsanaIntegration ((Get-RockPauseControl -Stories $stories -IgorGid '1201416335822270') -eq 'paused') 'Tagged orchestrator control changed pause state.'
$stories += [pscustomobject]@{ gid = '3'; created_at = '2026-10-17T11:00:00Z'; created_by = [pscustomobject]@{ gid = '1201416335822270' }; text = '/resume' }
Assert-AsanaIntegration ((Get-RockPauseControl -Stories $stories -IgorGid '1201416335822270') -eq 'resumed') 'Untagged Igor resume was ignored.'

$config.launcher.path = Join-Path $PluginRoot 'rock-cycle.ps1'
$script:launchArgs = New-Object Collections.Generic.List[string]
function ConvertTo-FactoryWindowsArgument { param([string]$Value) return '"' + $Value + '"' }
function Start-Process {
    param([string]$FilePath, [string]$WindowStyle, [string]$ArgumentList, [switch]$PassThru)
    $script:launchArgs.Add($ArgumentList)
    return [pscustomobject]@{ Id = 1 }
}
Start-FactoryRockCycle -Config $config -Reason 'Done' -Gid '123'
Assert-AsanaIntegration ($script:launchArgs.Count -eq 1) 'Factory wake-up started multiple rock launchers.'
Assert-AsanaIntegration ($script:launchArgs[0] -like '*-Task*123*' -and $script:launchArgs[0] -notlike '*-EpicGid*') 'Factory wake-up did not delegate task selection to rock-cycle.'

foreach ($scriptName in @('rock-cycle.ps1', 'install-rock-cycle-task.ps1')) {
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Process -Id $PID).Path
    $scriptPath = Join-Path $PluginRoot $scriptName
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $scriptPath, (Join-Path $PluginRoot 'missing-rock-config.json')
    $startInfo.WorkingDirectory = [IO.Path]::GetTempPath()
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    Assert-AsanaIntegration ($process.ExitCode -ne 0 -and $output -match 'Rock config not found') "$scriptName failed before checking its config path."
}

$answerTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("factory-asana-answer-$([Guid]::NewGuid().ToString('N'))")
$answerRepo = Join-Path $answerTestRoot 'repo'
$answerWorktree = Join-Path $answerTestRoot 'worker'
$previousFactoryHome = $env:CLAUDE_FACTORY_HOME
$previousTestToken = [Environment]::GetEnvironmentVariable('FACTORY_ASANA_TEST_TOKEN')
try {
    New-Item -ItemType Directory -Path $answerRepo -Force | Out-Null
    New-Item -ItemType Directory -Path $answerWorktree -Force | Out-Null
    & git -C $answerRepo init -q
    if ($LASTEXITCODE -ne 0) { throw 'Could not create isolated Asana answer test repository.' }
    $env:CLAUDE_FACTORY_HOME = Join-Path $answerTestRoot 'runtime'
    [Environment]::SetEnvironmentVariable('FACTORY_ASANA_TEST_TOKEN', 'unit-test-token')
    $answerContext = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $answerRepo -Initialize | ConvertFrom-Json
    $answerConfig = Read-FactoryJson -Path $answerContext.configPath
    $answerConfig.asana.tokenEnv = 'FACTORY_ASANA_TEST_TOKEN'
    Write-FactoryJsonAtomic -Path $answerContext.configPath -Value $answerConfig
    $answerMutex = Enter-FactoryMutex -ProjectKey ([string]$answerContext.projectKey)
    try {
        $answerState = Read-FactoryJson -Path $answerContext.statePath
        Set-FactoryProperty -Target $answerState -Name 'tasks' -Value @([pscustomobject]@{
            id = '123'; title = 'Asana question'; status = 'blocked'; asanaMode = $true
            worktree = $answerWorktree; brief = 'Finish the Asana task.'; attempts = 1
            commit = $null; workerResult = [pscustomobject]@{ status = 'blocked' }
            asanaState = 'Question'; asanaQuestion = [pscustomobject]@{
                storyGid = 'question-story-1'; askedAt = '2026-10-17T10:00:00Z'
                text = 'QUESTION (factory): A or B?'; lastPolledAt = '2026-10-17T10:05:00Z'
            }
        })
        Write-FactoryJsonAtomic -Path $answerContext.statePath -Value $answerState
    } finally { Exit-FactoryMutex -Mutex $answerMutex }

    $global:FactoryAsanaAnswerTest = [pscustomobject]@{
        factoryValue = [string]$answerConfig.asana.fields.question
        comments = New-Object Collections.Generic.List[object]
        posts = 0
    }
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $ErrorAction, $ContentType, $Body)
        $requestPath = ([uri]$Uri).AbsolutePath
        if ($requestPath -eq '/api/1.0/tasks/123' -and $Method -eq 'GET') {
            return [pscustomobject]@{ data = [pscustomobject]@{
                name = 'Asana question'; permalink_url = 'https://app.asana.com/0/project/123'
                custom_fields = @([pscustomobject]@{
                    gid = [string]$answerConfig.asana.fields.factory
                    enum_value = [pscustomobject]@{ gid = [string]$global:FactoryAsanaAnswerTest.factoryValue }
                })
            } }
        }
        if ($requestPath -eq '/api/1.0/tasks/123/stories' -and $Method -eq 'GET') {
            return [pscustomobject]@{ data = @($global:FactoryAsanaAnswerTest.comments.ToArray()) }
        }
        if ($requestPath -eq '/api/1.0/tasks/123/stories' -and $Method -eq 'POST') {
            $payload = $Body | ConvertFrom-Json
            $global:FactoryAsanaAnswerTest.posts++
            $comment = [pscustomobject]@{
                gid = "answer-$($global:FactoryAsanaAnswerTest.posts)"; text = [string]$payload.data.text
                created_at = '2026-10-17T10:06:00Z'; resource_subtype = 'comment_added'
            }
            $global:FactoryAsanaAnswerTest.comments.Add($comment)
            return [pscustomobject]@{ data = $comment }
        }
        if ($requestPath -eq '/api/1.0/tasks/123' -and $Method -eq 'PUT') {
            $payload = $Body | ConvertFrom-Json
            $field = [string]$answerConfig.asana.fields.factory
            $global:FactoryAsanaAnswerTest.factoryValue = [string]$payload.data.custom_fields.$field
            return [pscustomobject]@{ data = [pscustomobject]@{} }
        }
        throw "Unexpected isolated Asana request: $Method $requestPath"
    }
    $firstAnswer = @(& (Join-Path $PluginRoot 'factory.ps1') answer '123' --text 'A' -Repository $answerRepo -NoReconcile)
    Assert-AsanaIntegration ($global:FactoryAsanaAnswerTest.posts -eq 1 -and $global:FactoryAsanaAnswerTest.factoryValue -eq [string]$answerConfig.asana.fields.taken) 'Terminal answer did not post once and return Asana to Taken.'
    $answerState = Read-FactoryJson -Path $answerContext.statePath
    Assert-AsanaIntegration ($answerState.tasks[0].asanaState -eq 'Taken' -and $null -eq $answerState.tasks[0].asanaQuestion.lastPolledAt) 'Terminal answer did not request an immediate Asana sync.'
    $secondAnswer = @(& (Join-Path $PluginRoot 'factory.ps1') answer '123' --text 'A' -Repository $answerRepo -NoReconcile)
    Assert-AsanaIntegration ($global:FactoryAsanaAnswerTest.posts -eq 1 -and ($secondAnswer -join ' ') -match 'already posted') 'Repeating a terminal answer posted a duplicate comment.'
    $answerTaskScript = Join-Path $PluginRoot 'scripts\answer-task.ps1'
    $directAnswerError = ''
    try { $null = & $answerTaskScript -Repository $answerRepo -TaskId '123' -Text 'A' -Mode auto }
    catch { $directAnswerError = $_.Exception.Message }
    Assert-AsanaIntegration ($directAnswerError -match 'Use factory answer') 'Direct answer bypassed the pending Asana question.'
    $syncOutput = @(& (Join-Path $PluginRoot 'scripts\asana-sync.ps1') -Repository $answerRepo)
    $resumedState = Read-FactoryJson -Path $answerContext.statePath
    Assert-AsanaIntegration ($resumedState.tasks[0].status -eq 'queued' -and $null -eq $resumedState.tasks[0].asanaQuestion -and
        (Test-Path -LiteralPath (Join-Path $answerWorktree 'FACTORY-DECISIONS.md'))) 'Asana sync could not resume a worker with a blocked FACTORY_RESULT.'
} finally {
    $env:CLAUDE_FACTORY_HOME = $previousFactoryHome
    [Environment]::SetEnvironmentVariable('FACTORY_ASANA_TEST_TOKEN', $previousTestToken)
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Variable -Name FactoryAsanaAnswerTest -Scope Global -ErrorAction SilentlyContinue
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedAnswerRoot = [IO.Path]::GetFullPath($answerTestRoot)
    if ($resolvedAnswerRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedAnswerRoot)) {
        Remove-Item -LiteralPath $resolvedAnswerRoot -Recurse -Force
    }
}

Write-Host 'Asana integration tests passed (fields, routing, rock selection, terminal questions and worker resume).' -ForegroundColor Green
