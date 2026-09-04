param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [string]$RuntimeHome = ""
)
$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($RuntimeHome) { $env:CLAUDE_FACTORY_HOME = [IO.Path]::GetFullPath($RuntimeHome) }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository -Initialize
