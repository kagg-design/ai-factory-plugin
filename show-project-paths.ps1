param([Parameter(Mandatory=$true)][string]$Repository)
$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:CLAUDE_FACTORY_HOME = Join-Path $pluginRoot "runtime"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository -Initialize
