$ErrorActionPreference = "SilentlyContinue"
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$command = [string]$payload.tool_input.command
$cwd = [string]$payload.cwd
if (-not $command -or -not $cwd) { exit 0 }

$branch = (& git -C $cwd branch --show-current 2>$null).Trim()
if ($branch -notlike "factory-worker/*") { exit 0 }

$patterns = @(
    '(?i)(^|[;&|]\s*)git\s+push\b',
    '(?i)(^|[;&|]\s*)git\s+merge\b',
    '(?i)(^|[;&|]\s*)git\s+cherry-pick\b',
    '(?i)(^|[;&|]\s*)git\s+rebase\b',
    '(?i)(^|[;&|]\s*)git\s+worktree\s+(remove|prune)\b',
    '(?i)(^|[;&|]\s*)git\s+branch\s+(-d|-D|--delete)\b',
    '(?i)(^|[;&|]\s*)git\s+(switch|checkout)\b[^\r\n]*(master|main|develop|development)\b',
    '(?i)(^|[;&|]\s*)gh\s+pr\s+merge\b'
)

foreach ($pattern in $patterns) {
    if ($command -match $pattern) {
        [ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName = "PreToolUse"
                permissionDecision = "deny"
                permissionDecisionReason = "Factory worker branches may edit, test, and commit only. Push, merge, rebase, shared-branch checkout, and worktree deletion are reserved for the factory orchestrator."
            }
        } | ConvertTo-Json -Depth 10 -Compress
        exit 0
    }
}
exit 0
