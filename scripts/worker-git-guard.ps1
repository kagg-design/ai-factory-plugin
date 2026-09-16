$ErrorActionPreference = "Stop"

$utf8NoBom = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Stop-FactoryGuardClosed {
    param([string]$Reason)
    [Console]::Error.WriteLine("Factory Git guard blocked the tool because its safety check failed: $Reason")
    exit 2
}

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { Stop-FactoryGuardClosed -Reason "empty hook payload" }
try { $payload = $raw | ConvertFrom-Json } catch { Stop-FactoryGuardClosed -Reason $_.Exception.Message }

$command = [string]$payload.tool_input.command
$cwd = [string]$payload.cwd
if (-not $command -or -not $cwd) { Stop-FactoryGuardClosed -Reason "hook payload has no command or cwd" }

# A shared Claude background host can supply an older session's environment.
# Resolve ownership from Git/state, never from the inherited prompt pointer.
try {
    . (Join-Path $PSScriptRoot "factory-common.ps1")
    $branchProbe = Invoke-FactoryNativeProcess -Command git -Arguments @('-C', $cwd, 'branch', '--show-current')
    $branch = ([string]$branchProbe.stdout).Trim()
    if ($branchProbe.exitCode -eq 0 -and $branch -like "factory-worker/*") {
        $context = (& (Join-Path $PSScriptRoot "project-context.ps1") -Repository $cwd) | ConvertFrom-Json
        if (Test-Path -LiteralPath $context.statePath -PathType Leaf) {
            $state = Read-FactoryJson $context.statePath
            $matches = @($state.tasks | Where-Object {
                [string](Get-FactoryNestedValue $_ 'branch' '') -eq $branch -and
                (Test-FactorySamePath ([string](Get-FactoryNestedValue $_ 'worktree' '')) $context.currentWorktree)
            })
            if ($matches.Count -eq 1) {
                $config = Read-FactoryJson $context.configPath
                $settings = Get-FactoryTestDatabaseSettings -Config $config -RepositoryRoot $context.repositoryRoot
                $metadataPath = Join-Path $context.sessionsPath ((ConvertTo-FactoryTaskArtifactName $matches[0].id) + ".json")
                $expectedPrompt = if (Test-Path -LiteralPath $metadataPath) { [string](Read-FactoryJson $metadataPath).promptPath } else { "" }
                Assert-FactoryWorkerEnvironment -Task $matches[0] -DatabaseSettings $settings -PromptPath $expectedPrompt
            } elseif ($env:CLAUDE_FACTORY_TASK_ID -or $env:CLAUDE_FACTORY_PROMPT_PATH) {
                throw "Factory worker environment cannot be matched to exactly one task in this worktree."
            }
        } elseif ($env:CLAUDE_FACTORY_TASK_ID -or $env:CLAUDE_FACTORY_PROMPT_PATH) {
            throw "Factory worker environment points at a runtime without this project's state."
        }
    }
} catch { Stop-FactoryGuardClosed -Reason $_.Exception.Message }

$rules = @(
    [pscustomobject]@{ name = "git push"; pattern = '(?i)(^|[;&|]\s*)git\s+push(?![-\w])' },
    [pscustomobject]@{ name = "git merge"; pattern = '(?i)(^|[;&|]\s*)git\s+merge(?![-\w])' },
    [pscustomobject]@{ name = "git rebase"; pattern = '(?i)(^|[;&|]\s*)git\s+rebase(?![-\w])' },
    [pscustomobject]@{ name = "git worktree remove/prune"; pattern = '(?i)(^|[;&|]\s*)git\s+worktree\s+(remove|prune)(?![-\w])' },
    [pscustomobject]@{ name = "git branch delete"; pattern = '(?i)(^|[;&|]\s*)git\s+branch\s+(-d|-D|--delete)(?![-\w])' },
    [pscustomobject]@{ name = "git checkout/switch shared branch"; pattern = '(?i)(^|[;&|]\s*)git\s+(switch|checkout)(?![-\w])[^\r\n]*(master|main|develop|development)\b' },
    [pscustomobject]@{ name = "gh pr merge"; pattern = '(?i)(^|[;&|]\s*)gh\s+pr\s+merge(?![-\w])' }
)

$offendingCommand = ""
foreach ($rule in $rules) {
    if ($command -match [string]$rule.pattern) {
        $offendingCommand = [string]$rule.name
        break
    }
}
if (-not $offendingCommand) { exit 0 }

try {
    $branchOutput = @(& git -C $cwd branch --show-current 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { Stop-FactoryGuardClosed -Reason ($branchOutput -join [Environment]::NewLine) }
    $branch = ($branchOutput -join "").Trim()
} catch {
    Stop-FactoryGuardClosed -Reason $_.Exception.Message
}

if ($branch -like "factory-worker/*") {
        [ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName = "PreToolUse"
                permissionDecision = "deny"
                permissionDecisionReason = "Factory Git guard blocked '$offendingCommand' on worker branch '$branch'. Push, merge, rebase, shared-branch checkout, and worktree deletion are reserved for the factory orchestrator. Read-only history commands plus cherry-pick and revert inside the worker branch are allowed."
            }
        } | ConvertTo-Json -Depth 10 -Compress
        exit 0
}
exit 0
