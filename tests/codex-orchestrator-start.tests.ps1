param([string]$PluginRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
. (Join-Path $PluginRoot 'scripts\factory-common.ps1')
. (Join-Path $PluginRoot 'scripts\codex-orchestrator.ps1')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('factory-codex-start-' + [Guid]::NewGuid().ToString('N'))
$context = [pscustomobject]@{
    repositoryRoot = Join-Path $fixtureRoot 'repository with spaces'
    runtimeHome = Join-Path $fixtureRoot 'runtime'
    worktreeRoot = Join-Path $fixtureRoot 'worktrees'
    projectData = Join-Path $fixtureRoot 'runtime\project'
}
$fakeCodex = Join-Path $fixtureRoot 'fake-codex.exe'
$logPath = Join-Path $fixtureRoot 'requests.tsv'
$originalLocation = Get-Location
$environment = @{
    CLAUDE_FACTORY_TEST_CODEX_LOG = $logPath
    CLAUDE_FACTORY_TEST_CODEX_THREAD_ID = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'
    CLAUDE_FACTORY_TEST_CODEX_APP_SERVER_FAIL_METHOD = $null
}
$previous = @{}
# Skill installation has its own integration coverage; avoid user skill links.
function Install-FactoryCodexSkillLink { param($PluginRoot) [pscustomobject]@{ created = $false } }

try {
    foreach ($path in @($context.repositoryRoot, $context.runtimeHome, $context.worktreeRoot, $context.projectData)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    # Compile a .NET Framework executable usable by both PowerShell editions.
    $compile = "Add-Type -Path '" + (Join-Path $PluginRoot 'tests\FakeCodex.cs').Replace("'", "''") +
        "' -OutputAssembly '" + $fakeCodex.Replace("'", "''") + "' -OutputType ConsoleApplication"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compile))
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -EncodedCommand $encoded
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile fake Codex.' }
    foreach ($entry in $environment.GetEnumerator()) {
        $previous[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }

    foreach ($mode in @('new', 'resume')) {
        $launchExitCode = -1
        Start-FactoryCodexOrchestrator -CodexCommand $fakeCodex -PluginRoot $PluginRoot -Context $context `
            -Model 'test-model' -Resume:($mode -eq 'resume') -ExitCodeVariableName 'launchExitCode'
        if ($launchExitCode -ne 0) { throw "Codex $mode attach rejected the launch arguments (exit $launchExitCode)." }
    }

    $lines = @(Get-Content -LiteralPath $logPath)
    $requests = @($lines | Where-Object { $_.StartsWith("app-server-request`t") } | ForEach-Object {
        $_.Substring("app-server-request`t".Length) | ConvertFrom-Json
    })
    $starts = @($requests | Where-Object { $_.method -eq 'thread/start' })
    if ($starts.Count -ne 1) { throw 'Resume created a replacement conversation.' }
    $parameters = $starts[0].params
    if ($parameters.sandbox -ne 'workspace-write' -or $parameters.approvalsReviewer -ne 'auto_review') {
        throw 'Server-side thread permission policy changed.'
    }
    $expectedRoots = @($context.repositoryRoot, $context.runtimeHome, $context.worktreeRoot)
    if (@(Compare-Object $expectedRoots @($parameters.runtimeWorkspaceRoots)).Count -ne 0) {
        throw 'Server-side thread lost a required workspace root.'
    }
    if (@($requests | Where-Object { $_.method -eq 'thread/read' }).Count -ne 1) {
        throw 'Resume did not validate the saved conversation.'
    }
    $attaches = @($lines | Where-Object { $_ -match '^--remote\t.*\tresume\t' })
    if ($attaches.Count -ne 2) { throw 'Expected one terminal attach for each startup.' }
    foreach ($attach in $attaches) {
        $argv = $attach.Split("`t")
        if ($argv[-1] -ne $environment.CLAUDE_FACTORY_TEST_CODEX_THREAD_ID) { throw 'Attached to the wrong conversation.' }
        if ($argv[[Array]::IndexOf($argv, '-C') + 1] -ne $context.repositoryRoot) { throw 'Repository path was lost.' }
        if ($argv[[Array]::IndexOf($argv, '--model') + 1] -ne 'test-model') { throw 'Model selection was lost.' }
    }
    Write-Host 'Codex orchestrator startup regressions passed.' -ForegroundColor Green
} finally {
    Set-Location $originalLocation
    try {
        if (Test-Path -LiteralPath $fakeCodex) {
            $null = Stop-FactoryCodexSharedServer -CodexCommand $fakeCodex -RuntimeHome $context.runtimeHome
        }
    } finally {
        foreach ($entry in $previous.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }
    $fullFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path -Parent $fullFixture) -ne $tempRoot -or (Split-Path -Leaf $fullFixture) -notlike 'factory-codex-start-*') {
        throw "Unsafe startup fixture cleanup: $fullFixture"
    }
    Remove-Item -LiteralPath $fullFixture -Recurse -Force
}
