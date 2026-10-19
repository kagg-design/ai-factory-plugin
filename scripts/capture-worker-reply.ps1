$ErrorActionPreference = "Stop"
try {
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $inputJson = $raw | ConvertFrom-Json
    if ([string]$inputJson.hook_event_name -ne "UserPromptSubmit") { exit 0 }
    $cwd = [string]$inputJson.cwd
    $sessionId = [string]$inputJson.session_id
    $prompt = [string]$inputJson.prompt
    if (-not $cwd -or -not $sessionId -or -not $prompt -or $prompt.TrimStart() -match '^FACTORY_PROMPT_FILE=') { exit 0 }
    $branch = (& git -C $cwd branch --show-current 2>$null | Out-String).Trim()
    if ($branch -notlike "factory-worker/*") { exit 0 }
    . (Join-Path $PSScriptRoot "factory-common.ps1")
    . (Join-Path $PSScriptRoot "worker-event.ps1")
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $cwd) | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $context.statePath)) { exit 0 }
    $state = Read-FactoryJson -Path $context.statePath
    $matches = @($state.tasks | Where-Object {
        ([string]$_.branch -eq $branch -or [string](Get-FactoryNestedValue -Target $_.backgroundSession -Name "sessionId") -eq $sessionId) -and
        (Test-FactorySamePath -Left ([string]$_.worktree) -Right $cwd)
    })
    if ($matches.Count -eq 1) {
        $null = Publish-FactoryWorkerReply -Context $context -Task $matches[0] -SessionId $sessionId -Prompt $prompt
    }
} catch {
    # Observational capture must never prevent an operator's message.
}
exit 0
