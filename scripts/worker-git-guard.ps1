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
