param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GitArguments = @()
)

$ErrorActionPreference = "Stop"
$realGit = [string]$env:CLAUDE_FACTORY_REAL_GIT
$worktree = [string]$env:CLAUDE_FACTORY_WORKTREE
if (-not $realGit -or -not (Test-Path -LiteralPath $realGit -PathType Leaf)) {
    [Console]::Error.WriteLine("Factory Git proxy has no verified real Git executable.")
    exit 2
}
if (-not $worktree -or -not (Test-Path -LiteralPath $worktree -PathType Container)) {
    [Console]::Error.WriteLine("Factory Git proxy has no verified worker worktree.")
    exit 2
}

$verb = ""
$verbIndex = -1
for ($index = 0; $index -lt $GitArguments.Count; $index++) {
    $value = [string]$GitArguments[$index]
    if ($value -eq "-C" -or $value -eq "--git-dir" -or $value -eq "--work-tree") {
        $index++
        continue
    }
    if ($value.StartsWith("-c")) {
        if ($value -eq "-c") { $index++ }
        continue
    }
    if ($value.StartsWith("-")) { continue }
    $verb = $value.ToLowerInvariant()
    $verbIndex = $index
    break
}

$blocked = $verb -in @("push", "merge", "cherry-pick", "rebase")
if ($verb -eq "worktree" -and $verbIndex + 1 -lt $GitArguments.Count) {
    $blocked = ([string]$GitArguments[$verbIndex + 1]).ToLowerInvariant() -in @("remove", "prune")
}
if ($verb -eq "branch") {
    $blocked = @($GitArguments | Where-Object { [string]$_ -in @("-d", "-D", "--delete") }).Count -gt 0
}
if ($verb -in @("switch", "checkout")) {
    $blocked = @($GitArguments | Where-Object { [string]$_ -match '^(?i:develop|development|master|main)$' }).Count -gt 0
}
if ($blocked) {
    [Console]::Error.WriteLine("Factory Git proxy blocked '$verb'; publication and shared-branch operations belong to the factory pipeline.")
    exit 2
}

& $realGit @GitArguments
exit $LASTEXITCODE
