param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\quality-gates.ps1')
. (Join-Path $PluginRoot 'scripts\metrics-common.ps1')
function Assert-Quality { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('factory-quality-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $root 'awesomehr'
$savedHome = $env:CLAUDE_FACTORY_HOME; $savedToken = $env:FACTORY_ASANA_TOKEN
$savedRegistry = $env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE
$null = New-Item -ItemType Directory -Path $repository -Force
$env:CLAUDE_FACTORY_HOME = Join-Path $root 'state'
$env:FACTORY_ASANA_TOKEN = 'synthetic-quality-secret-do-not-print'
try {
    & git -C $repository init -q
    & git -C $repository remote add origin https://example.test/owner/awesomehr.git
    $context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
    $config = Read-FactoryJson $context.configPath
    $config.repo = 'awesomehr'; $config.nativeScheduler.enabled = $false
    Write-FactoryJsonAtomic $context.configPath $config
    Assert-Quality ((Resolve-FactoryTaskRepo $config 'No header') -eq 'awesomehr') 'Default board repo is incorrect.'
    $config.repo = 'cloud-infrastructure-auditors'
    $refused = ''
    try { Assert-FactoryTaskRepo $config $repository 'No header' } catch { $refused = $_.Exception.Message }
    Assert-Quality ($refused -match "awesomehr.*cloud-infrastructure-auditors") 'Auditors accepted an unlabelled task.'
    Assert-FactoryTaskRepo $config $repository 'No header' -Force
    $config.repo = 'awesomehr'
    $refused = ''
    try { Assert-FactoryTaskRepo $config $repository "Repo: org/cloud-infrastructure-auditors`nDo work" } catch { $refused = $_.Exception.Message }
    Assert-Quality ($refused -match 'cloud-infrastructure-auditors') 'AwesomeHR accepted an auditors task.'
    Assert-Quality ((Get-FactoryAsanaCommentActor '[factory-metrics] stats') -ne 'Igor') 'Metrics comment impersonated Igor.'
    Assert-Quality ((Get-FactoryAsanaCommentActor 'MERGE GATE (factory): confirmed') -eq 'factory') 'Merge gate comment impersonated Igor.'
    & {
        $script:pageCall = 0
        function Get-FactoryAsanaPages {
            param($Config, [string]$Path)
            $script:pageCall++
            $ids = if ($script:pageCall -eq 1) { 1..100 } else { 100..101 }
            foreach ($id in $ids) { [pscustomobject]@{ gid = [string]$id; created_at = ([DateTime]'2026-10-18Z').AddSeconds($id).ToString('o') } }
        }
        $pages = @(Get-FactoryAsanaSearchTasks $config '/search?fixture=true' '/fallback')
        Assert-Quality ($pages.Count -eq 101 -and $script:pageCall -eq 2) 'Date-cursor search pagination lost or duplicated tasks.'
    }
    & {
        $script:pageCall = 0
        function Get-FactoryAsanaPages {
            param($Config, [string]$Path)
            $script:pageCall++
            $ids = if ($Path -eq '/fallback') { 1..105 } else { 1..100 }
            foreach ($id in $ids) { [pscustomobject]@{ gid = [string]$id; created_at = '2026-10-18T00:00:00Z' } }
        }
        $pages = @(Get-FactoryAsanaSearchTasks $config '/search?fixture=true' '/fallback')
        Assert-Quality ($pages.Count -eq 105 -and $script:pageCall -eq 3) 'Timestamp ties truncated the search.'
    }

    $envFile = Join-Path $repository '.env'
    [IO.File]::WriteAllText($envFile, "APP_KEY=keep`nDB_PASSWORD=db-keep`nASANA_ACCESS_TOKEN=erase`nACCESS_URL=erase`nBILLING_KEY='erase`nmore'`nGITHUB_APP_ID=erase`nGCS_KEY_FILE=erase`nSERVICE_TOKEN=erase`nSERVICE_SECRET=erase`nSERVICE_API_KEY=erase`nOTHER=keep`n")
    Protect-FactoryEnvironmentFile $config $envFile
    $clean = [IO.File]::ReadAllText($envFile)
    Assert-Quality ($clean -notmatch 'erase|more' -and $clean -match 'APP_KEY=keep' -and $clean -match 'DB_PASSWORD=db-keep' -and $clean -match 'OTHER=keep') 'Environment sanitizing lost DB/APP_KEY or retained a secret.'
    $security = Invoke-FactorySecurityCheck $config $repository $repository
    Assert-Quality ($security.summary -eq 'command not present yet') 'Missing composer security was not skipped.'
    [IO.File]::WriteAllText((Join-Path $repository 'composer.json'), '{"scripts":{"security":"fixture"}}')
    $config.repos.awesomehr.securityCommand = "Write-Output 'raw credential: never-relay'; Write-Output 'Summary: clean'; exit 0"
    $security = Invoke-FactorySecurityCheck $config $repository $repository
    Assert-Quality ($security.status -eq 'passed' -and $security.summary -eq 'Summary: clean') 'Security summary leaked raw output or lost success.'
    $config.repos.awesomehr.securityCommand = "Write-Output 'raw finding'; Write-Output 'Security: vulnerable dependency'; exit 1"
    $security = Invoke-FactorySecurityCheck $config $repository $repository
    Assert-Quality ($security.status -eq 'failed' -and $security.summary -eq 'Security: vulnerable dependency') 'Vulnerable security command passed.'
    $config.repos.awesomehr.securityCommand = 'Write-Output ("Summary: " + $env:FACTORY_ASANA_TOKEN); exit 0'
    $security = Invoke-FactorySecurityCheck $config $repository $repository
    Assert-Quality ($security.summary -eq 'Summary: [REDACTED]') 'A known credential leaked through a scanner summary.'
    $config.repo = 'cloud-infrastructure-auditors'
    Assert-Quality ((Invoke-FactorySecurityCheck $config $repository $repository).summary -eq 'not configured for this repo') 'Unconfigured security was not skipped.'
    $config.repo = 'awesomehr'

    $global:QualityremoteValue = [string]$config.asana.fields.ready; $global:QualityreadBackTaken = $true
    $global:Qualityposts = New-Object Collections.Generic.List[string]; $global:Qualitycomments = @(); $global:QualityfixtureTasks = @(); $global:QualityfixtureStories = @{}
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $Body, $ContentType, $ErrorAction)
        $route = ([Uri]$Uri).AbsolutePath.Substring('/api/1.0'.Length)
        if ($route -like '/custom_fields/*') { return [pscustomobject]@{ data = [pscustomobject]@{ enum_options = @([pscustomobject]@{ gid = 'bug-option'; name = 'Bug' }) } } }
        if ($route -like '/workspaces/*/tasks/search') { return [pscustomobject]@{ data = $global:QualityfixtureTasks; next_page = $null } }
        if ($route -eq '/tasks/123' -and $Method -eq 'PUT') {
            if ($global:QualityreadBackTaken) { $global:QualityremoteValue = [string]$config.asana.fields.taken }
            return [pscustomobject]@{ data = @{} }
        }
        if ($route -eq '/tasks/123') { return [pscustomobject]@{ data = [pscustomobject]@{ notes = 'Merge gate: ask Igor before merging'; custom_fields = @([pscustomobject]@{ gid = [string]$config.asana.fields.factory; enum_value = [pscustomobject]@{ gid = $global:QualityremoteValue } }) } } }
        if ($Method -eq 'GET' -and $route -match '^/tasks/(\d+)$') {
            $requestedGid = $Matches[1]
            return [pscustomobject]@{ data = @($global:QualityfixtureTasks | Where-Object { $_.gid -eq $requestedGid })[0] }
        }
        if ($route -match '^/tasks/(\d+)/stories$') {
            $storyTask = $Matches[1]
            if ($Method -eq 'POST') { $message = ($Body | ConvertFrom-Json).data.text; $global:Qualityposts.Add($message); return [pscustomobject]@{ data = [pscustomobject]@{ gid = 'posted' } } }
            $list = if ($storyTask -eq '123') { @($global:Qualitycomments) } else { @($global:QualityfixtureStories[$storyTask]) }
            return [pscustomobject]@{ data = $list; next_page = $null }
        }
        throw "Unexpected fixture request $Method $route. No network allowed."
    }
    $global:QualityreadBackTaken = $false
    $claimError = ''
    try { Confirm-FactoryAsanaClaim $config '123' } catch { $claimError = $_.Exception.Message }
    Assert-Quality ($claimError -match 'read-back is not Taken') 'Lost claim was accepted.'
    $global:QualityreadBackTaken = $true
    Confirm-FactoryAsanaClaim $config '123'

    $task = [pscustomobject]@{ id = '123'; url = $null; source = $null; commit = ('a' * 40); brief = 'Merge gate: ask Igor before merging'; asanaMode = $true; status = 'approved'; attempts = 1; branch = 'old'; worktree = 'retained'; workerResult = [pscustomobject]@{ commit = 'old' }; backgroundSession = $null }
    $lock = Enter-FactoryMutex $context.projectKey
    try { $state = Read-FactoryJson $context.statePath; $state.tasks = @($task); Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $lock }
    Set-FactoryProperty -Target $task -Name 'mergeGate' -Value $true
    Assert-Quality (-not (Test-FactoryMergeGate $context $config $task)) 'Merge gate did not wait.'
    Assert-Quality ($global:Qualityposts[-1] -match 'ready to merge a{40}') 'Merge gate did not announce the SHA.'
    $gateEvents = @(Get-FactoryOperatorActionEvents -State ([pscustomobject]@{ tasks = @($task) }) -Config $config)
    Assert-Quality ($gateEvents[0].kind -eq 'merge-gate' -and -not $gateEvents[0].aiActionable) 'Merge gate was not exposed as a human decision.'
    $global:Qualitycomments = @([pscustomobject]@{ gid = 'agent'; resource_subtype = 'comment_added'; created_at = [DateTime]::UtcNow.AddMinutes(1).ToString('o'); text = '[access-orchestrator] /merge' })
    Assert-Quality (-not (Test-FactoryMergeGate $context $config $task)) 'Tagged agent bypassed merge gate.'
    $global:Qualitycomments += [pscustomobject]@{ gid = 'human'; resource_subtype = 'comment_added'; created_at = [DateTime]::UtcNow.AddMinutes(1).ToString('o'); text = '/merge' }
    Assert-Quality (Test-FactoryMergeGate $context $config $task) 'Human /merge was ignored.'
    Assert-Quality ($global:Qualityposts[-1] -match 'Igor confirmed \(comment\).*Merging a{40}') 'Confirmation was not recorded.'
    $task.commit = 'b' * 40
    $lock = Enter-FactoryMutex $context.projectKey
    try { $state = Read-FactoryJson $context.statePath; $state.tasks[0].commit = $task.commit; Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $lock }
    Assert-Quality (-not (Test-FactoryMergeGate $context $config $task)) 'Old confirmation approved a new SHA.'
    Assert-Quality (Test-FactoryMergeGate $context $config $task -TerminalYes) 'Terminal yes was ignored.'
    Assert-Quality ($global:Qualityposts[-1] -match 'Igor confirmed \(terminal\)') 'Terminal confirmation was not posted.'
    Reset-FactoryAsanaRun $context ([pscustomobject]@{ gid = '123'; name = 'Fresh'; notes = "New description`nStart-from: abcdef0123" })
    $fresh = (Read-FactoryJson $context.statePath).tasks[0]
    Assert-Quality ($fresh.status -eq 'queued' -and $null -eq $fresh.commit -and $null -eq $fresh.worktree -and $null -eq $fresh.workerResult -and $fresh.brief -match 'New description' -and $fresh.previousRuns.Count -eq 1) 'Re-Ready reused a stale result or lost retained run.'
    $activity = Get-FactoryWorkerActivity ([pscustomobject]@{ launchStartedAt = [DateTime]::UtcNow.AddHours(-3).ToString('o'); backgroundSession = [pscustomobject]@{ lastSeenAt = Get-FactoryUtcTimestamp } })
    Assert-Quality (([DateTime]::UtcNow - $activity).TotalHours -gt 2) 'Poll heartbeat concealed a stalled worker.'

    # A real reconciliation pass uses a disposable FakeClaude registry. No
    # existing process/session is selected or stopped by this fixture.
    $fakeClaude = Join-Path $root 'claude-fixture.exe'
    $builder = Join-Path $root 'build.ps1'
    [IO.File]::WriteAllText($builder, 'param($Source,$Destination) Add-Type -Path $Source -OutputAssembly $Destination -OutputType ConsoleApplication')
    $built = Invoke-FactoryNativeProcess -Command powershell -Arguments @('-NoProfile', '-File', $builder, (Join-Path $PluginRoot 'tests\FakeClaude.cs'), $fakeClaude)
    Assert-Quality ($built.exitCode -eq 0) 'Could not build the isolated stalled-worker fixture.'
    $registry = Join-Path $root 'sessions.tsv'
    $env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE = $registry
    $uuid = '11111111-2222-4333-8444-555555555555'
    [IO.File]::WriteAllText($registry, "launch`tstalled-bg`t$repository`tfactory-stall`tworking`t$uuid`n")
    $old = [DateTime]::UtcNow.AddHours(-3).ToString('o')
    $stalled = [pscustomobject]@{ id = 'stall'; url = $null; source = $null; title = 'Silent worker'; status = 'running'; worktree = $repository; branch = 'fixture'; commit = $null; launchStartedAt = $old; createdAt = $old; updatedAt = $old
        backgroundSession = [pscustomobject]@{ runtime = 'claude'; id = 'stalled-bg'; sessionId = $uuid; name = 'factory-stall'; state = 'working'; startedAt = $old; transcriptPath = '' } }
    $lock = Enter-FactoryMutex $context.projectKey
    try { $state = Read-FactoryJson $context.statePath; $state.tasks += @($stalled); Write-FactoryJsonAtomic $context.statePath $state } finally { Exit-FactoryMutex $lock }
    $null = & (Join-Path $PluginRoot 'scripts\reconcile-worker-sessions.ps1') -Repository $repository -ClaudeCommand $fakeClaude
    $stalled = Get-FactoryTask (Read-FactoryJson $context.statePath) 'stall'
    Assert-Quality ($stalled.status -eq 'failed' -and $stalled.error -match '^stalled, no activity since ' -and $stalled.backgroundSession.state -eq 'stopped' -and (Test-Path $repository)) 'Stalled worker did not fail/stop while retaining its checkout.'

    function New-MetricTask {
        param([string]$Id, [string]$Notes = '', [string]$Factory = $config.asana.fields.done, [bool]$Bug = $false, [string]$Created = '2026-10-18T12:00:00Z', [string]$Reporter = '')
        $custom = @([pscustomobject]@{ gid = [string]$config.asana.fields.factory; enum_value = [pscustomobject]@{ gid = $Factory } })
        if ($Bug) { $custom += [pscustomobject]@{ gid = [string]$config.asana.fields.type; enum_value = [pscustomobject]@{ gid = 'bug-option' } } }
        if ($Reporter) { $custom += [pscustomobject]@{ gid = [string]$config.asana.fields.reporter; text_value = $Reporter } }
        return [pscustomobject]@{ gid = $Id; name = "Fixture $Id"; notes = $Notes; custom_fields = $custom; completed_at = '2026-10-18T10:00:00Z'; created_at = $Created; completed = ($Factory -eq $config.asana.fields.done) }
    }
    $config.asana.enabled = $true; $config.repo = 'cloud-infrastructure-auditors'
    Write-FactoryJsonAtomic $context.configPath $config
    $global:QualityfixtureTasks = @(New-MetricTask '456' -Notes 'No Repo header' -Factory $config.asana.fields.ready)
    $postCount = $global:Qualityposts.Count
    $null = & (Join-Path $PluginRoot 'scripts\asana-poller.ps1') -Repository $repository -Force
    Assert-Quality ($global:Qualityposts.Count -eq $postCount -and -not @((Read-FactoryJson $context.statePath).tasks | Where-Object id -eq '456').Count -and -not @(Get-ChildItem $context.worktreeRoot -Directory).Count) 'Auditors poller claimed an unlabelled task or created a checkout.'
    $message = ''
    try { $null = & (Join-Path $PluginRoot 'scripts\add-asana-task.ps1') -Repository $repository -Url 'https://app.asana.com/0/0/456' } catch { $message = $_.Exception.Message }
    Assert-Quality ($message -match "awesomehr.*cloud-infrastructure-auditors") 'Manual add accepted a foreign task without --force.'
    $null = & (Join-Path $PluginRoot 'scripts\add-asana-task.ps1') -Repository $repository -Url 'https://app.asana.com/0/0/456' -Force
    Assert-Quality ((Get-FactoryTask (Read-FactoryJson $context.statePath) '456').repoForce) 'Manual --force did not record the explicit routing override.'
    foreach ($nonReady in @($config.asana.fields.done, $config.asana.fields.failed, $config.asana.fields.taken)) {
        $global:QualityfixtureTasks = @(New-MetricTask '456' -Notes 'No Repo header' -Factory $nonReady)
        $message = ''
        try { $null = & (Join-Path $PluginRoot 'scripts\start-worker-session.ps1') -Repository $repository -TaskId '456' -ClaudeCommand $fakeClaude } catch { $message = $_.Exception.Message }
        Assert-Quality ($message -match 'Only Factory = Ready' -and -not @(Get-ChildItem $context.worktreeRoot -Directory).Count) 'A non-Ready manual worker created a checkout or escaped the claim boundary.'
    }
    $config.repo = 'awesomehr'; Write-FactoryJsonAtomic $context.configPath $config
    $seeds = Get-FactoryMetricsSeeds
    $fixture = @(); $ordinal = 0
    foreach ($id in $seeds.Keys) {
        $ordinal++; $notes = if ($ordinal -eq 1) { "Repo: org/cloud-infrastructure-auditors`nOrigin" } else { 'Origin' }
        $fixture += New-MetricTask $seeds[$id][0] $notes
        $fixture += New-MetricTask $id -Factory $config.asana.fields.taken -Bug $true
    }
    1..24 | ForEach-Object { $fixture += New-MetricTask ([string](9000 + $_)) }
    $report = @(Get-FactoryMetrics $config $fixture @{} 'bug-option' ([DateTime]'2026-10-12Z') ([DateTime]'2026-10-19T10:05:00Z'))
    $total = @($report | Where-Object { $_.repo -eq '_all' })[0]
    Assert-Quality ($total.all.done -eq 29 -and $total.all.escaped -eq 5 -and $total.all.byFound.verification -eq 4 -and $total.all.byFound.external -eq 1) 'Historical seeded metrics acceptance failed.'
    Assert-Quality ($report.Count -eq 3 -and $total.all.missingCycle -eq 29) 'Per-project totals or transitional cycle exclusions failed.'
    $originA = [string]$fixture[0].gid; $originB = [string]$fixture[2].gid
    $fixture[1].notes = "Escaped-from: $originB`nFound-in: ci`nRegression: yes"
    $fixture += New-MetricTask '8001' -Factory $config.asana.fields.failed -Bug $true -Reporter 'access-orchestrator'
    $fixture += New-MetricTask '8002' -Notes 'Escaped-from: bad data' -Factory $config.asana.fields.taken -Bug $true
    $fixture += New-MetricTask '8003' -Notes "Escaped-from: $originA, $originB`nFound-in: prod" -Factory $config.asana.fields.taken -Bug $true
    $fixture += New-MetricTask '8004' -Notes "Escaped-from: 999999`nFound-in: stage" -Factory $config.asana.fields.taken -Bug $true
    $timings = @{}; $timings[$originA] = @(
        [pscustomobject]@{ gid = '1'; created_at = '2026-10-18T08:00:00Z'; text = 'TAKEN (factory): start'; resource_subtype = 'comment_added' }
        [pscustomobject]@{ gid = '2'; created_at = '2026-10-18T10:00:00Z'; text = 'DONE (factory): complete'; resource_subtype = 'comment_added' }
        [pscustomobject]@{ gid = '3'; created_at = '2026-10-18T09:00:00Z'; text = 'QUESTION (factory): ask'; resource_subtype = 'comment_added' }
        [pscustomobject]@{ gid = '4'; created_at = '2026-10-18T09:30:00Z'; text = 'FAILED (factory): attempt'; resource_subtype = 'comment_added' }
    )
    $report = @(Get-FactoryMetrics $config $fixture $timings 'bug-option' ([DateTime]'2026-10-12Z') ([DateTime]'2026-10-19T10:05:00Z'))
    $total = @($report | Where-Object { $_.repo -eq '_all' })[0]
    Assert-Quality ($total.all.escaped -eq 7 -and $total.all.byFound.ci -eq 1 -and $total.all.regressions -eq 1 -and $total.unparsed.Count -eq 2) 'Line override, fallback, multi-origin or malformed-line metrics failed.'
    Assert-Quality ($total.all.questions -eq 1 -and $total.all.failedComments -eq 1 -and $total.all.failedNow -eq 1 -and $total.all.medianCycleHours -eq 2) 'Comment timing metrics failed.'
    $sum = ($report | Where-Object { $_.repo -ne '_all' } | ForEach-Object { $_.all.escaped } | Measure-Object -Sum).Sum
    Assert-Quality ($sum -eq 8 -and $total.all.escaped -eq 7) 'Cross-project defects were counted incorrectly.'
    Assert-Quality ((Get-FactoryMetricPercentile @(1, 2, 3, 4) 0.5) -eq 2.5 -and (Get-FactoryMetricPercentile @(1, 2, 3, 4) 0.9) -eq 3.7) 'Metric percentiles are incorrect.'
    $global:QualityfixtureTasks = $fixture; $global:QualityfixtureStories = $timings
    $legacyConfig = Read-FactoryJson $context.configPath
    $legacyConfig.asana.fields.PSObject.Properties.Remove('type')
    $legacyConfig.asana.fields.PSObject.Properties.Remove('reporter')
    Write-FactoryJsonAtomic $context.configPath $legacyConfig
    $beforeFiles = @(Get-ChildItem $context.projectData -File -Recurse | ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join '|'
    $postCount = $global:Qualityposts.Count
    $output = & (Join-Path $PluginRoot 'factory-metrics.ps1') -Repository $repository -Since '2026-10-12Z' -Until '2026-10-19T10:05:00Z' -Post -DryRun
    $afterFiles = @(Get-ChildItem $context.projectData -File -Recurse | ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join '|'
    Assert-Quality ($beforeFiles -eq $afterFiles -and $global:Qualityposts.Count -eq $postCount -and ($output -join '') -like '[[]factory-metrics[]]*') 'DryRun wrote or posted.'
    $null = & (Join-Path $PluginRoot 'factory-metrics.ps1') -Repository $repository -Since '2026-10-12Z' -Until '2026-10-19T10:05:00Z' -Post
    Assert-Quality ($global:Qualityposts.Count -eq $postCount + 1 -and $global:Qualityposts[-1] -match '^\[factory-metrics\]') 'Metrics did not post exactly once.'
    foreach ($repo in @('awesomehr', 'cloud-infrastructure-auditors', '_all')) {
        $folder = Join-Path $context.projectData "metrics\$repo"
        Assert-Quality ((Test-Path "$folder\latest.md") -and (Test-Path "$folder\escaped-defects.csv") -and @(Import-Csv "$folder\weekly.csv").Count -eq 1) "Metrics files missing for $repo."
    }
    $config.metricsTaskGid = ''; Write-FactoryJsonAtomic $context.configPath $config
    $null = & (Join-Path $PluginRoot 'factory-metrics.ps1') -Repository $repository -Since '2026-10-12Z' -Until '2026-10-19T10:05:00Z' -Post
    Assert-Quality ($global:Qualityposts.Count -eq $postCount + 1) 'Empty metricsTaskGid still posted.'
} finally {
    $env:CLAUDE_FACTORY_HOME = $savedHome; $env:FACTORY_ASANA_TOKEN = $savedToken
    $env:CLAUDE_FACTORY_TEST_SESSION_REGISTRY_FILE = $savedRegistry
    Get-Variable -Name 'Quality*' -Scope Global -ErrorAction SilentlyContinue | Remove-Variable -Scope Global -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'factory-quality-*') { throw 'Unsafe quality fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output 'Quality gate and metrics regressions passed (offline, no live Asana writes).'
