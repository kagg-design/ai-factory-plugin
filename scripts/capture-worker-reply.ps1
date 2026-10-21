$ErrorActionPreference = "Stop"
try {
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) { exit 0 }
    $inputJson = $raw | ConvertFrom-Json
    . (Join-Path $PSScriptRoot "factory-common.ps1")
    $eventName = [string](Get-FactoryNestedValue -Target $inputJson -Name "hook_event_name")
    if ($eventName -notin @("UserPromptSubmit", "UserPromptExpansion")) { exit 0 }
    $commandName = [string](Get-FactoryNestedValue -Target $inputJson -Name "command_name")
    if ($eventName -eq "UserPromptExpansion" -and
        ([string](Get-FactoryNestedValue -Target $inputJson -Name "expansion_type") -ne "slash_command" -or
            $commandName -notin @("factory", "factory:factory") -or
            [string](Get-FactoryNestedValue -Target $inputJson -Name "command_args") -notmatch '^\s*continue(?:\s|$)')) { exit 0 }
    $cwd = [string]$inputJson.cwd
    $sessionId = [string]$inputJson.session_id
    $prompt = [string]$inputJson.prompt
    if (-not $cwd -or -not $sessionId -or -not $prompt -or $prompt.TrimStart() -match '^FACTORY_PROMPT_FILE=') { exit 0 }
    $branch = (& git -C $cwd branch --show-current 2>$null | Out-String).Trim()
    if ($branch -notlike "factory-worker/*") { exit 0 }
    . (Join-Path $PSScriptRoot "worker-event.ps1")
    $context = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "project-context.ps1") -Repository $cwd) | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $context.statePath)) { exit 0 }
    $state = Read-FactoryJson -Path $context.statePath
    $matches = @($state.tasks | Where-Object {
        ([string]$_.branch -eq $branch -or [string](Get-FactoryNestedValue -Target $_.backgroundSession -Name "sessionId") -eq $sessionId) -and
        (Test-FactorySamePath -Left ([string]$_.worktree) -Right $cwd)
    })
    if ($matches.Count -eq 1) {
        $event = Publish-FactoryWorkerReply -Context $context -Task $matches[0] -SessionId $sessionId -Prompt $prompt `
            -Source $eventName -InputSource ([string](Get-FactoryNestedValue -Target $inputJson -Name "source")) `
            -CommandName $commandName -MessageId ([string](Get-FactoryNestedValue -Target $inputJson -Name "prompt_id"))
        if ($event.kind -eq "reply" -and $eventName -eq "UserPromptExpansion") {
            @{ hookSpecificOutput = @{ hookEventName = "UserPromptExpansion"; additionalContext =
                "Factory recorded this explicit worker continuation command for the current task and attempt. Continue this same worker session with the answer in command_args. Re-read the existing Factory task contract. This is not answer-task.ps1 or a new worker launch; review, GO and publication permissions are unchanged." } } | ConvertTo-Json -Depth 4 -Compress
        } elseif ($event.kind -eq "input" -and [string]$matches[0].status -in @("awaiting-input", "blocked")) {
            @{ systemMessage = "Factory: /factory continue <answer>"; hookSpecificOutput = @{
                hookEventName = $eventName; additionalContext =
                "Factory cannot verify this input as an operator decision. It is informational and does not resume a waiting task. Stay read-only until an authorized continuation. If the operator wants to continue this same Claude worker, ask them in conversationLanguage to type /factory continue followed by their answer. Do not invoke that command yourself, forge a reply event, or suggest rework for this attribution issue." }
            } | ConvertTo-Json -Depth 4 -Compress
        }
    }
} catch {
    # Observational capture must never prevent an operator's message.
}
exit 0
