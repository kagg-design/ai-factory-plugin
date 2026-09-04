param(
    [Parameter(Mandatory=$true)][string]$Repository,
    [string]$RuntimeHome = ""
)
$ErrorActionPreference = "Stop"
$pluginRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($RuntimeHome) { $env:CLAUDE_FACTORY_HOME = [IO.Path]::GetFullPath($RuntimeHome) }
$context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pluginRoot "scripts\project-context.ps1") -Repository $Repository -Initialize) | ConvertFrom-Json
if (Get-Command code -ErrorAction SilentlyContinue) {
    & code $context.configPath
} else {
    & notepad.exe $context.configPath
}
