param([Parameter(Mandatory=$true)][string]$Repository)
$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:CLAUDE_FACTORY_HOME = Join-Path $pluginRoot "runtime"
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository -Initialize) | ConvertFrom-Json
if (Get-Command code -ErrorAction SilentlyContinue) {
    & code $context.configPath
} else {
    & notepad.exe $context.configPath
}
