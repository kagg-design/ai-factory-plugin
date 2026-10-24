[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PluginRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PluginRoot 'scripts/factory-incidents.ps1')
function Assert-Incident {param([bool]$Value,[string]$Message) if(-not $Value){throw $Message}}
function Assert-IncidentThrows {param([scriptblock]$Code,[string]$Pattern) $message='';try{& $Code|Out-Null}catch{$message=$_.Exception.Message};Assert-Incident ($message -match $Pattern) "Expected $Pattern; got $message"}
function Invoke-IncidentCli {param([string[]]$Arguments) Invoke-FactoryNativeProcess powershell (@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PluginRoot 'factory.ps1'))+$Arguments) -TimeoutSeconds 60}
function New-IncidentFixtureRepo {param([string]$Path)
    $null=New-Item -ItemType Directory -Path $Path -Force
    & git -C $Path init --quiet
    if($LASTEXITCODE){throw 'Cannot initialize incident fixture.'}
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('factory-incident-tests-'+[Guid]::NewGuid().ToString('N'))
$oldHome=$env:CLAUDE_FACTORY_HOME
try{
    $env:CLAUDE_FACTORY_HOME=Join-Path $fixture 'runtime'
    $source=Join-Path $fixture 'factory-source'
    New-IncidentFixtureRepo $source
    $null=New-Item -ItemType Directory -Path (Join-Path $source 'scripts'),(Join-Path $source 'tests'),(Join-Path $source 'docs/tasks') -Force
    Write-FactoryJsonAtomic (Join-Path $source 'MANIFEST.json') @{name='claude-factory-plugin'}
    [IO.File]::WriteAllText((Join-Path $source 'factory.ps1'),'# Factory source fixture')
    [IO.File]::WriteAllText((Join-Path $source 'scripts/broken.ps1'),"function Get-IncidentFixtureValue { 'broken' }")
    $validation=@'
param([string]$PluginRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PluginRoot 'scripts/broken.ps1')
if((Get-IncidentFixtureValue) -cne 'fixed'){throw 'The defect still reproduces.'}
Write-Output 'Independent native regression passed.'
'@
    [IO.File]::WriteAllText((Join-Path $source 'tests/incident-fixture.tests.ps1'),$validation)
    & git -C $source add .
    & git -C $source -c user.name=IncidentTest -c user.email=test@example.invalid -c commit.gpgsign=false commit --quiet -m fixture
    if($LASTEXITCODE){throw 'Cannot commit incident fixture.'}
    $contexts=@()
    foreach($name in @('one','two')){
        $repo=Join-Path $fixture $name;New-IncidentFixtureRepo $repo
        $contexts+=& (Join-Path $PluginRoot 'scripts/project-context.ps1') -Repository $repo -Initialize|ConvertFrom-Json
    }
    $one=$contexts[0];$two=$contexts[1]
    $report=[pscustomobject]@{version=1;component='attention';errorCode='duplicate-completion-edges';summary='Repeated native edges';observed='The same native fingerprint is delivered repeatedly. Bearer abcdef-SECRET password=hunter2';expected='One edge per fingerprint.';reproduction='Run a stable scan twice and compare revisions.';evidenceReferences=@('task:123')}
    Assert-Incident (-not (Add-FactoryIncident $one $report).accepted) 'Disabled incident routing launched a repair.'
    $policyPath=Join-Path $fixture 'policy.json'
    Write-FactoryJsonAtomic $policyPath @{version=1;enabled=$true;autoDispatch=$false;sourceRepository=$source;codexCommand='must-never-run';maxAttempts=1;timeoutSeconds=60;validationScripts=@('tests/incident-fixture.tests.ps1')}
    $configured=Invoke-IncidentCli @('incident','configure','-File',$policyPath,'-Repository',$one.repositoryRoot)
    Assert-Incident ($configured.exitCode -eq 0) $configured.output
    $evidence=Join-Path $fixture 'evidence.json';Write-FactoryJsonAtomic $evidence $report
    $accepted=Invoke-IncidentCli @('incident','report','-File',$evidence,'-Repository',$one.repositoryRoot)
    Assert-Incident ($accepted.exitCode -eq 0) $accepted.output
    $first=$accepted.stdout|ConvertFrom-Json
    $duplicate=Add-FactoryIncident $two $report
    Assert-Incident ($first.accepted -and -not $first.duplicate -and $duplicate.duplicate -and $duplicate.id -ceq $first.id) 'Cross-factory reports did not deduplicate.'
    $items=@(Get-FactoryIncidents $one.runtimeHome)
    Assert-Incident ($items.Count -eq 1 -and $items[0].occurrences -eq 2 -and @($items[0].projects).Count -eq 2) 'Incident multiplicity or ownership is wrong.'
    Assert-Incident ($items[0].report.observed -notmatch 'abcdef-SECRET|hunter2') 'Credential values escaped report redaction.'
    Assert-Incident ((Get-Content $items[0].reportPath -Raw) -match 'Reproduction') 'Native defect specification was not saved in Factory docs/tasks.'
    $script:repairCalls=0
    $repair={param($request)
        $script:repairCalls++
        Assert-Incident ((Invoke-FactoryIncidentRepair $one.runtimeHome).busy) 'A second repair bypassed the running reservation.'
        $during=Add-FactoryIncident $one $report
        Assert-Incident $during.duplicate 'A repeated failure created another running job.'
        [IO.File]::WriteAllText((Join-Path $request.worktree 'scripts/broken.ps1'),"function Get-IncidentFixtureValue { 'fixed' }")
        Write-FactoryJsonAtomic $request.resultFile @{version=1;status='candidate';summary='Fixed the fixture defect.';tests=@('Model claims are ignored by native validation.')}
    }
    $result=Invoke-FactoryIncidentRepair $one.runtimeHome $first.id -RepairInvoker $repair
    Assert-Incident ($result.status -eq 'ready-for-review' -and $script:repairCalls -eq 1) "Repair failed: $($result.error)"
    Assert-Incident ($result.result.validation.Count -eq 1 -and $result.result.validation[0].exitCode -eq 0 -and -not $result.result.installed) 'No independent native validation receipt.'
    Assert-Incident ((Get-Content (Join-Path $source 'scripts/broken.ps1') -Raw) -match "'broken'") 'Repair installed itself into the source checkout.'
    $patch=Get-Content $result.result.patchPath -Raw
    Assert-Incident ($patch -match "'fixed'" -and $patch -notmatch '\.factory-incident-(input|result|schema)') 'Candidate diff contains metadata or no repair.'
    Assert-Incident ((Get-FileHash $result.result.patchPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $result.result.patchHash) 'Patch receipt hash is wrong.'
    $events=@(Get-FactoryIncidentAttentionEvents $one)
    Assert-Incident ($events.Count -eq 1 -and $events[0].aiActionable) 'Repair result did not reach the originating factory attention.'
    Assert-Incident ((Invoke-FactoryIncidentRepair $one.runtimeHome -RepairInvoker $repair).empty -and $script:repairCalls -eq 1) 'No-change queue launched another Codex repair.'
    $repeat=Add-FactoryIncident $one $report
    Assert-Incident ($repeat.duplicate -and $repeat.status -eq 'ready-for-review') 'A completed handoff was automatically repeated.'
    foreach($ctx in $contexts){$state=Read-FactoryJson $ctx.statePath;Assert-Incident (-not $state.active -and -not $state.paused -and @($state.tasks).Count -eq 0) 'Repair changed application Factory activity, pause or tasks.'}

    $report.errorCode='native-regression-fails';$new=Add-FactoryIncident $one $report
    $bad=Invoke-FactoryIncidentRepair $one.runtimeHome $new.id -RepairInvoker {param($request)
        [IO.File]::WriteAllText((Join-Path $request.worktree 'scripts/unrelated.ps1'),'# Does not fix the reproduced defect')
        Write-FactoryJsonAtomic $request.resultFile @{version=1;status='candidate';summary='Unsupported claim of success.';tests=@('all green')}
    }
    Assert-Incident ($bad.status -eq 'failed' -and $bad.error -match 'validation failed' -and (Test-Path $bad.worktree)) 'Model claim bypassed failing native regression or erased evidence.'
    $retry=Invoke-IncidentCli @('incident','retry',$new.id,'-Repository',$one.repositoryRoot)
    Assert-Incident ($retry.exitCode -ne 0) 'An exhausted attempt budget could be retried.'

    $report.errorCode='protected-controller-change';$new=Add-FactoryIncident $one $report
    $blocked=Invoke-FactoryIncidentRepair $one.runtimeHome $new.id -RepairInvoker {param($request)
        [IO.File]::WriteAllText((Join-Path $request.worktree 'scripts/factory-incidents.ps1'),'# Unauthorized self-controller change')
        Write-FactoryJsonAtomic $request.resultFile @{version=1;status='candidate';summary='Controller alteration.';tests=@()}
    }
    Assert-Incident ($blocked.status -eq 'failed' -and $blocked.error -match 'protected') 'A repair changed its own control path.'

    $report.errorCode='not-a-plugin-defect';$new=Add-FactoryIncident $one $report
    $diagnosed=Invoke-FactoryIncidentRepair $one.runtimeHome $new.id -RepairInvoker {param($request) Write-FactoryJsonAtomic $request.resultFile @{version=1;status='not-a-factory-defect';summary='Application defect; no Factory change.';tests=@()}}
    Assert-Incident ($diagnosed.status -eq 'not-a-factory-defect' -and -not $diagnosed.result.patchPath) 'Expected application failure became a Factory patch.'
    Assert-Incident (-not (Test-FactoryIncidentCandidatePath '../runtime/state.json') -and -not (Test-FactoryIncidentCandidatePath 'runtime/README.md')) 'Unsafe repair path was accepted.'
    $report.errorCode='interrupted-runner';$new=Add-FactoryIncident $one $report
    $paths=Get-FactoryIncidentPaths $one.runtimeHome
    $mutex=Enter-FactoryMutex $paths.mutex
    try{$lost=Read-FactoryJson (Join-Path $paths.queue "$($new.id).json");$lost.status='running';$lost.attempts=1;$lost.attemptId='lost-attempt';$lost.runner=@{pid=0};Write-FactoryJsonAtomic (Join-Path $paths.queue "$($new.id).json") $lost}finally{Exit-FactoryMutex $mutex}
    Assert-Incident (Invoke-FactoryIncidentRepair $one.runtimeHome -RepairInvoker {throw 'An interrupted repair was repeated.'}).blocked 'A dead parent allowed an uncertain repair child to be duplicated.'
    Assert-Incident (@(Get-FactoryIncidents $one.runtimeHome|Where-Object id -eq $new.id)[0].status -eq 'interrupted') 'Interrupted repair evidence was discarded.'
    Write-Output 'Factory incident handoff tests passed (shared dedupe, one repair, native validation, protected paths, no install, receipts, no-change and bounded failures).'
}finally{
    $env:CLAUDE_FACTORY_HOME=$oldHome
    $absolute=[IO.Path]::GetFullPath($fixture);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\factory-incident-tests-'
    if($absolute.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $absolute)){Remove-Item -LiteralPath $absolute -Recurse -Force}
}
