[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "help", "status", "inspect", "preview", "doctor", "chat", "add", "new", "go", "hold", "retry", "reject",
        "cleanup", "concurrency", "completion", "start", "rotate", "paths", "config",
        "scheduler", "tick", "pause", "resume", "stop", "wait", "purge"
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
                    "status", "inspect", "preview", "doctor", "chat", "add", "new", "go", "hold", "retry", "reject",
                    "cleanup", "concurrency", "completion", "start", "paths",
                    "rotate", "config", "scheduler", "tick", "pause", "resume", "stop", "wait",
                    "purge", "help"
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
            "config" { "path", "edit" }
            "scheduler" { "status", "start", "stop", "tick" }
            "rotate" { "status", "cancel" }
            "preview" { "status", "stop" }
        })

        if ($staticValues.Count -gt 0) {
            foreach ($value in @($staticValues | Where-Object { $_ -like "$prefix*" })) {
                [Management.Automation.CompletionResult]::new($value, $value, "ParameterValue", $value)
            }
            if ($typedCommand -ne "preview") { return }
        }

        if ($typedCommand -notin @("inspect", "preview", "chat", "go", "hold", "reject", "cleanup", "retry")) { return }

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
                if (
                    $typedCommand -eq "preview" -and
                    (-not [string]$task.worktree -or [string]$task.status -in @("approved", "integrating", "production", "done"))
                ) { continue }
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
    [switch]$Force,
    [switch]$New,
    [Alias("Resume")]
    [switch]$ResumeSession,
    [switch]$Continue,
    [string]$Model = "",
    [ValidateSet("claude", "codex")][string]$Agent = "",
    [string]$File = "",
    [switch]$Auto,
    [switch]$Direct,
    [switch]$NoOpen,

    [string]$Repository = (Get-Location).Path,
    [string]$ClaudeCommand = "claude",
    [string]$CodexCommand = "",
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
        -Force:$Force `
        -New:$New `
        -ResumeSession:$ResumeSession `
        -Continue:$Continue `
        -Model $Model `
        -Agent $Agent `
        -File $File `
        -Auto:$Auto `
        -Direct:$Direct `
        -NoOpen:$NoOpen `
        -Repository $Repository `
        -ClaudeCommand $ClaudeCommand `
        -CodexCommand $CodexCommand `
        -NoReconcile:$NoReconcile
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("factory: $($_.Exception.Message)")
    exit 1
}
