$ErrorActionPreference = "Stop"

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

$prohibited = $false
foreach ($pattern in $patterns) {
    if ($command -match $pattern) {
        $prohibited = $true
        break
    }
}
if (-not $prohibited) { exit 0 }

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
                permissionDecisionReason = "Factory worker branches may edit, test, and commit only. Push, merge, rebase, shared-branch checkout, and worktree deletion are reserved for the factory orchestrator."
            }
        } | ConvertTo-Json -Depth 10 -Compress
        exit 0
}
exit 0
