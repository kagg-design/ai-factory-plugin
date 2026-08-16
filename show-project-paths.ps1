param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [string]$RuntimeHome = ""
)
$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:CLAUDE_FACTORY_HOME = if ($RuntimeHome) { [IO.Path]::GetFullPath($RuntimeHome) } else { Join-Path $pluginRoot "runtime" }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository -Initialize
