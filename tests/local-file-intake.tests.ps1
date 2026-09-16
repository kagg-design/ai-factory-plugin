param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')

function Assert-LocalIntake {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-local-file-' + [Guid]::NewGuid().ToString('N'))
$repository = Join-Path $fixtureRoot 'repository'
$inputDirectory = Join-Path $fixtureRoot 'specifications'
$savedRuntime = $env:CLAUDE_FACTORY_HOME
$env:CLAUDE_FACTORY_HOME = Join-Path $fixtureRoot 'runtime'

function Invoke-LocalNew {
    param([string[]]$Tokens = @(), [string]$Directory = $inputDirectory, [string]$ShellCommand = 'powershell')
    return Invoke-FactoryNativeProcess -Command $ShellCommand -WorkingDirectory $Directory -Arguments (@(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PluginRoot 'factory.ps1'),
        'new', '-Repository', $repository
    ) + $Tokens)
}

function Get-AddedLocalTask {
    param($Result)
    Assert-LocalIntake ($Result.exitCode -eq 0) "Local intake failed: $($Result.output)"
    $id = [regex]::Match($Result.stdout, 'local:[0-9]{8}-[0-9]{6}-[0-9a-f]{8}').Value
    Assert-LocalIntake ([bool]$id) "Intake did not print a task ID: $($Result.output)"
    $matches = @((Read-FactoryJson $context.statePath).tasks | Where-Object { $_.id -eq $id })
    Assert-LocalIntake ($matches.Count -eq 1) 'Intake did not create exactly one matching task.'
    return $matches[0]
}

try {
    New-Item -ItemType Directory -Path $repository, $inputDirectory -Force | Out-Null
    & git init --quiet $repository
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the local intake fixture.' }
    $context = & (Join-Path $PluginRoot 'scripts\project-context.ps1') -Repository $repository -Initialize | ConvertFrom-Json
    $config = Read-FactoryJson $context.configPath
    $config.nativeScheduler.enabled = $false
    $config.nativeScheduler.startWithOrchestrator = $false
    Write-FactoryJsonAtomic $context.configPath $config

    $specPath = Join-Path $inputDirectory 'TASK-REPORTS-UI-011.md'
    # Avoid source-file encoding assumptions in Windows PowerShell 5.1 tests.
    $unicode = -join ([char[]]@(0x0417, 0x0430, 0x0434, 0x0430, 0x0447, 0x0430))
    $spec = "`r`n# A heading that must not become the title`r`n  $unicode `"quoted`" ``code`` `$variable  `r`n`r`n"
    [IO.File]::WriteAllText($specPath, $spec, $script:FactoryUtf8NoBom)
    $sourceBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($specPath))

    $result = Invoke-LocalNew -Tokens @($specPath)
    $task = Get-AddedLocalTask $result
    Assert-LocalIntake ($task.title -ceq 'TASK-REPORTS-UI-011') 'The default title did not come from the filename stem.'
    Assert-LocalIntake ($task.brief -ceq $spec) 'File contents or whitespace were changed.'
    Assert-LocalIntake ($task.startMode -eq 'interactive' -and $task.status -eq 'queued') 'File intake changed the default planning mode.'
    Assert-LocalIntake ($task.source.adapter -eq 'local' -and -not $task.agentId) 'File intake did not use the native local task path.'
    Assert-LocalIntake ($result.stdout -notmatch 'The worker will ask what') 'A file task was reported as an empty worker.'
    $shortCode = ($task.id -split '-')[-1]
    Assert-LocalIntake ((Get-FactoryWorkerSessionName -TaskId $task.id -Title $task.title) -ceq "factory-local-$shortCode-task-reports-ui-011") 'File intake did not produce the expected readable worker name.'

    $customTitle = "$unicode reports UI"
    $task = Get-AddedLocalTask (Invoke-LocalNew -Tokens @($specPath, $customTitle))
    Assert-LocalIntake ($task.title -ceq $customTitle -and $task.brief -ceq $spec) 'The optional title changed the file brief or was lost.'

    $relativeFile = "spec [011] $unicode.v2.md"
    [IO.File]::WriteAllText((Join-Path $inputDirectory $relativeFile), $spec, $script:FactoryUtf8NoBom)
    $task = Get-AddedLocalTask (Invoke-LocalNew -Tokens @(".\$relativeFile"))
    Assert-LocalIntake ($task.title -ceq "spec [011] $unicode.v2" -and $task.brief -ceq $spec) 'Relative/literal paths, Unicode or multi-dot filename stems failed.'
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        $task = Get-AddedLocalTask (Invoke-LocalNew -ShellCommand 'pwsh' -Tokens @(".\$relativeFile", $customTitle))
        Assert-LocalIntake ($task.title -ceq $customTitle -and $task.brief -ceq $spec) 'PowerShell 7 changed the file path, title or contents.'
    }

    $longStem = 'TASK-REPORTS-UI-011-' + ('long-description-' * 5).TrimEnd('-')
    $longNamePath = Join-Path $inputDirectory "$longStem.md"
    [IO.File]::WriteAllText($longNamePath, $spec, $script:FactoryUtf8NoBom)
    $task = Get-AddedLocalTask (Invoke-LocalNew -Tokens @($longNamePath))
    $workerName = Get-FactoryWorkerSessionName -TaskId $task.id -Title $task.title
    Assert-LocalIntake ($task.title -ceq $longStem -and $workerName -match '^factory-local-[0-9a-f]{8}-.{1,28}$') 'A long filename escaped the compact worker-name cap.'

    $task = Get-AddedLocalTask (Invoke-LocalNew -Tokens @('--auto', $specPath, 'Immediate work'))
    Assert-LocalIntake ($task.startMode -eq 'auto' -and $task.title -eq 'Immediate work' -and $task.brief -ceq $spec) 'File-first --auto intake failed.'
    $task = Get-AddedLocalTask (Invoke-LocalNew -Tokens @($specPath, '-Auto'))
    Assert-LocalIntake ($task.startMode -eq 'auto' -and $task.title -eq 'TASK-REPORTS-UI-011') 'PowerShell -Auto file intake failed.'

    # Native intake must pass the path, not the file text, through process argv.
    # Quotes expand to more than the Windows 32767-character command-line limit.
    $longPath = Join-Path $inputDirectory 'large.txt'
    $longSpec = ('"' * 18000) + "`r`n"
    [IO.File]::WriteAllText($longPath, $longSpec, $script:FactoryUtf8NoBom)
    $task = Get-AddedLocalTask (Invoke-LocalNew -Tokens @($longPath))
    Assert-LocalIntake ($task.brief -ceq $longSpec) 'Large file content was truncated or passed through the command line.'
    Assert-LocalIntake ([Convert]::ToBase64String([IO.File]::ReadAllBytes($specPath)) -ceq $sourceBytes) 'Intake modified or consumed the source file.'

    $task = Get-AddedLocalTask (Invoke-LocalNew -Tokens @('Update README.md'))
    Assert-LocalIntake ($task.title -eq 'Update README.md' -and $task.brief -eq 'Update README.md') 'Inline task text was mistaken for a path.'
    $task = Get-AddedLocalTask (Invoke-LocalNew -Tokens @('--auto', 'Fix the profile export'))
    Assert-LocalIntake ($task.startMode -eq 'auto' -and $task.title -eq 'Fix the profile export') 'Inline automatic task compatibility broke.'
    $task = Get-AddedLocalTask (Invoke-LocalNew)
    Assert-LocalIntake ($task.title -eq 'Untitled local task' -and $task.startMode -eq 'interactive') 'Intentionally blank workers no longer work.'

    $emptyPath = Join-Path $inputDirectory 'empty.md'
    [IO.File]::WriteAllText($emptyPath, " `r`n`t", $script:FactoryUtf8NoBom)
    $oversizePath = Join-Path $inputDirectory 'too-large.md'
    [IO.File]::WriteAllText($oversizePath, ('x' * 20001), $script:FactoryUtf8NoBom)
    $invalidUtf8Path = Join-Path $inputDirectory 'invalid-utf8.md'
    [IO.File]::WriteAllBytes($invalidUtf8Path, [byte[]]@(0xFF, 0x80))
    $before = [IO.File]::ReadAllText($context.statePath)
    $invalidCases = @(
        @{ tokens = @((Join-Path $inputDirectory 'missing.md')); message = 'does not exist' },
        @{ tokens = @('missing.md'); message = 'does not exist' },
        @{ tokens = @($inputDirectory); message = 'not a file' },
        @{ tokens = @($emptyPath); message = 'empty' },
        @{ tokens = @($oversizePath); message = '20000' },
        @{ tokens = @($invalidUtf8Path); message = 'Unable to translate|Unable to decode' },
        @{ tokens = @('old title', $specPath); message = 'file goes first' },
        @{ tokens = @($specPath, 'unquoted', 'title'); message = 'Quote the title' },
        @{ tokens = @('--auto'); message = 'requires text or a file' }
    )
    foreach ($case in $invalidCases) {
        $result = Invoke-LocalNew -Tokens $case.tokens
        Assert-LocalIntake ($result.exitCode -ne 0 -and $result.output -match $case.message) "Invalid input did not fail clearly: $($case.tokens -join ' | ') => $($result.output)"
        Assert-LocalIntake ([IO.File]::ReadAllText($context.statePath) -ceq $before) 'Invalid file intake changed the task ledger.'
    }

    Write-Host 'Local file intake tests passed (file-first title, verbatim UTF-8, relative paths, auto, large specs, invalid input and text/blank compatibility).'
} finally {
    $env:CLAUDE_FACTORY_HOME = $savedRuntime
    # Only isolated fixture state is created; no scheduler or real worker runs.
    # Retain it in the OS temporary directory for failure inspection.
}
