$ErrorActionPreference = "Stop"
$inputJson = [Console]::In.ReadToEnd() | ConvertFrom-Json
$name = [string]$inputJson.name
$cwd = [string]$inputJson.cwd
if (-not $name) { $name = "worker" }
if (-not $cwd) { throw "WorktreeCreate input does not contain cwd." }

$contextJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $cwd -Initialize
$context = $contextJson | ConvertFrom-Json
$config = Get-Content $context.configPath -Raw | ConvertFrom-Json

$safeName = ($name -replace '[^A-Za-z0-9._-]', '-').Trim('-')
if (-not $safeName) { $safeName = "worker" }
$suffix = [Guid]::NewGuid().ToString("N").Substring(0, 6)
$branch = "factory-worker/$safeName-$suffix"
$target = Join-Path $context.worktreeRoot "worker-$safeName-$suffix"

$remote = [string]$config.remote
$development = [string]$config.developmentBranch
if (-not $remote) { $remote = "origin" }
if (-not $development) { $development = "develop" }

& git -C $context.repositoryRoot fetch $remote $development 1> $null
if ($LASTEXITCODE -ne 0) { throw "Failed to fetch $remote/$development." }

$baseRef = "$remote/$development"
& git -C $context.repositoryRoot rev-parse --verify $baseRef *> $null
if ($LASTEXITCODE -ne 0) { throw "Base branch not found: $baseRef" }

& git -C $context.repositoryRoot worktree add -b $branch $target $baseRef 1> $null
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed." }

foreach ($relative in @($config.copyIgnoredFiles)) {
    if (-not $relative) { continue }
    $source = Join-Path $context.repositoryRoot $relative
    if (-not (Test-Path $source)) { continue }
    & git -C $context.repositoryRoot check-ignore -q -- $relative
    if ($LASTEXITCODE -ne 0) { continue }
    $destination = Join-Path $target $relative
    $parent = Split-Path $destination -Parent
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item $source $destination -Recurse -Force
}

# The last non-empty stdout line is the path Claude Code uses.
Write-Output ([IO.Path]::GetFullPath($target))
