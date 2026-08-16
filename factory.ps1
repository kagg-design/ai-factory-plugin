[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "help", "status", "inspect", "doctor", "chat", "hold", "reject",
        "cleanup", "concurrency", "completion"
    )]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [ArgumentCompleter({
        param($CommandName, $ParameterName, $WordToComplete, $CommandAst, $FakeBoundParameters)

        $typedCommand = if ($FakeBoundParameters.ContainsKey("Command")) {
            [string]$FakeBoundParameters["Command"]
        } else {
            $elements = @($CommandAst.CommandElements)
            if ($elements.Count -ge 2) { [string]$elements[1].Extent.Text } else { "" }
        }
        $typedCommand = $typedCommand.Trim("'", '"').ToLowerInvariant()
        $prefix = [string]$WordToComplete

        $staticValues = @(switch ($typedCommand) {
            "help" {
                @(
                    "status", "inspect", "doctor", "chat", "hold", "reject",
                    "cleanup", "concurrency", "completion", "help"
                )
            }
            "status" {
                @(
                    "all", "queued", "starting", "planning", "awaiting-input",
                    "running", "syncing", "awaiting-review", "approved",
                    "integrating", "production", "held", "rejected", "blocked",
                    "failed", "done"
                )
            }
            "completion" { "status", "enable" }
        })

        if ($staticValues.Count -gt 0) {
            foreach ($value in @($staticValues | Where-Object { $_ -like "$prefix*" })) {
                [Management.Automation.CompletionResult]::new($value, $value, "ParameterValue", $value)
            }
            return
        }

        if ($typedCommand -notin @("inspect", "chat", "hold", "reject", "cleanup")) { return }

        try {
            $commandInfo = Get-Command $CommandName -ErrorAction Stop
            $scriptPath = if ([string]$commandInfo.Source) { [string]$commandInfo.Source } else { [string]$commandInfo.Path }
            $pluginRoot = Split-Path -Parent $scriptPath
            $currentWorktree = (& git -C (Get-Location).Path rev-parse --show-toplevel 2>$null | Out-String).Trim()
            if (-not $currentWorktree) { return }
            $mainWorktreeLine = @(& git -C $currentWorktree worktree list --porcelain 2>$null) |
                Where-Object { $_ -like "worktree *" } |
                Select-Object -First 1
            $repositoryRoot = if ($mainWorktreeLine) {
                [IO.Path]::GetFullPath($mainWorktreeLine.Substring(9))
            } else {
                [IO.Path]::GetFullPath($currentWorktree)
            }
            $runtimeHome = if ($env:CLAUDE_FACTORY_HOME) {
                [IO.Path]::GetFullPath($env:CLAUDE_FACTORY_HOME)
            } else {
                Join-Path $pluginRoot "runtime"
            }
            $normalized = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar).ToLowerInvariant()
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
                $hash = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant().Substring(0, 8)
            } finally {
                $algorithm.Dispose()
            }
            $safeRepositoryName = ((Split-Path $repositoryRoot -Leaf) -replace '[^A-Za-z0-9._-]', '-').Trim('-')
            if (-not $safeRepositoryName) { $safeRepositoryName = "repository" }
            $statePath = Join-Path (Join-Path (Join-Path $runtimeHome "projects") "$safeRepositoryName-$hash") "state.json"
            if (-not (Test-Path -LiteralPath $statePath)) { return }
            $state = [IO.File]::ReadAllText($statePath, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json
            foreach ($task in @($state.tasks | Where-Object { [string]$_.id -like "$prefix*" })) {
                $id = [string]$task.id
                $title = if ([string]$task.title) { [string]$task.title } else { "Untitled task" }
                [Management.Automation.CompletionResult]::new($id, "$id  $title", "ParameterValue", $title)
            }
        } catch {
            return
        }
    })]
    [string]$Target = "",

    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$Remaining = @(),

    [switch]$Yes,
    [switch]$Keep,

    [string]$Repository = (Get-Location).Path,
    [string]$ClaudeCommand = "claude",
    [switch]$NoReconcile
)

$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$cliScript = Join-Path $pluginRoot "scripts\factory-cli.ps1"

try {
    & $cliScript `
        -Command $Command `
        -Target $Target `
        -Remaining $Remaining `
        -Yes:$Yes `
        -Keep:$Keep `
        -Repository $Repository `
        -ClaudeCommand $ClaudeCommand `
        -NoReconcile:$NoReconcile
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("factory: $($_.Exception.Message)")
    exit 1
}
