[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Repository)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'factory-common.ps1')
. (Join-Path $PSScriptRoot 'asana-common.ps1')
$context = & (Join-Path $PSScriptRoot 'project-context.ps1') -Repository $Repository | ConvertFrom-Json
$config = Read-FactoryJson -Path $context.configPath
$state = Read-FactoryJson -Path $context.statePath
if ([bool]$state.paused) { return }
$syncErrors = New-Object Collections.Generic.List[string]

function Set-AsanaSyncState {
    param([string]$TaskId, [string]$Field, $Value)
    $mutex = Enter-FactoryMutex -ProjectKey ([string]$context.projectKey)
    try {
        $latest = Read-FactoryJson -Path $context.statePath
        $item = Get-FactoryTask -State $latest -TaskId $TaskId
        Set-FactoryProperty -Target $item -Name $Field -Value $Value
        Write-FactoryJsonAtomic -Path $context.statePath -Value $latest
    } finally { Exit-FactoryMutex -Mutex $mutex }
}

function Format-FactoryAsanaTestSummary {
    param([object[]]$Checks)
    if (-not $Checks.Count) { return 'See factory review and integration checks.' }
    $number = 0
    return (@($Checks | ForEach-Object {
        $number++
        $name = [string](Get-FactoryNestedValue -Target $_ -Name 'name' -Default '')
        if (-not $name) { $name = "Check $number" }
        $status = [string](Get-FactoryNestedValue -Target $_ -Name 'status' -Default 'unknown')
        "${name}: $status"
    }) -join ', ')
}

foreach ($task in @($state.tasks | Where-Object {
    [bool](Get-FactoryNestedValue -Target $_ -Name 'asanaMode' -Default $false) -and (
        ($null -ne (Get-FactoryNestedValue -Target $_ -Name 'asanaQuestion') -and
            [string]$_.status -in @('blocked', 'held', 'awaiting-input')) -or
        ([string]$_.status -in @('done', 'failed') -and
            [string](Get-FactoryNestedValue -Target $_ -Name 'asanaSyncedState' -Default '') -ne [string]$_.status)
    )
})) {
    $gid = [string]$task.id
    if ($gid -notmatch '^\d+$') { continue }
    try {
        $question = Get-FactoryNestedValue -Target $task -Name 'asanaQuestion'
        if ($null -ne $question -and [string](Get-FactoryNestedValue $question 'channel') -eq 'rock') { continue }
        if ($question -and [string]$task.status -in @('blocked', 'held', 'awaiting-input')) {
            $lastCheck = [string](Get-FactoryNestedValue -Target $question -Name 'lastPolledAt' -Default '')
            if ($lastCheck -and
                ([DateTime]::UtcNow - (ConvertTo-FactoryUtcDateTime -Value $lastCheck)).TotalMinutes -lt [int]$config.questions.answerPollMinutes) {
                continue
            }
            Set-FactoryProperty -Target $question -Name 'lastPolledAt' -Value (Get-FactoryUtcTimestamp)
            Set-AsanaSyncState -TaskId $gid -Field 'asanaQuestion' -Value $question
        }
        $remote = Get-FactoryAsanaTask -Config $config -Gid $gid
        $factoryValue = Get-FactoryAsanaField -Task $remote -Gid ([string]$config.asana.fields.factory)
        if (-not $factoryValue) { continue }
        if ($question -and [string]$task.status -in @('blocked', 'held', 'awaiting-input')) {
            if ($factoryValue -eq [string]$config.asana.fields.taken) {
                $comments = @(Get-FactoryAsanaComments -Config $config -Gid $gid)
                $after = New-Object Collections.Generic.List[object]
                $foundQuestion = $false
                foreach ($comment in $comments) {
                    if ([string]$comment.gid -eq [string]$question.storyGid) { $foundQuestion = $true; continue }
                    if ($foundQuestion -or ((ConvertTo-FactoryUtcDateTime -Value $comment.created_at) -gt (ConvertTo-FactoryUtcDateTime -Value $question.askedAt) -and
                        [string]$comment.gid -ne [string]$question.storyGid)) {
                        $after.Add($comment)
                    }
                }
                if ($after.Count -eq 0) { continue }
                $lines = @($after.ToArray() | ForEach-Object {
                    $actor = Get-FactoryAsanaCommentActor -Text ([string]$_.text)
                    "[$($_.created_at)] $actor`: $($_.text)"
                })
                $answer = "Asana comments after QUESTION (factory). The leading comment tag identifies the speaker; the Asana account does not. If Igor's untagged answer or ANSWER (Igor via terminal) conflicts with an orchestrator's answer, follow Igor's. Read every comment below:`n" + ($lines -join "`n")
                $result = Invoke-FactoryNativeProcess -Command 'powershell' -Arguments @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'answer-task.ps1'),
                    '-Repository', [string]$context.repositoryRoot, '-TaskId', $gid, '-Text', $answer, '-Mode', 'auto', '-FromAsanaSync'
                ) -TimeoutSeconds 120
                if ([int]$result.exitCode -ne 0) { throw "Could not resume worker: $($result.output)" }
                Set-AsanaSyncState -TaskId $gid -Field 'asanaQuestion' -Value $null
                Set-AsanaSyncState -TaskId $gid -Field 'asanaState' -Value 'Taken'
                if ([string]$task.asanaState -ne 'Taken') {
                    Write-FactoryAsanaTransition -Context $context -Gid $gid -From 'Question' -To 'Taken' -WorkerId $gid
                }
                Write-Output "Resumed $gid from Asana answer."
            } elseif ($factoryValue -eq [string]$config.asana.fields.question -and
                -not [string]$question.fallbackStartedAt -and
                ([DateTime]::UtcNow - (ConvertTo-FactoryUtcDateTime -Value $question.askedAt)).TotalHours -ge [int]$config.questions.timeoutHours) {
                if (-not [Environment]::UserInteractive) { continue }
                Set-FactoryProperty -Target $question -Name 'fallbackStartedAt' -Value (Get-FactoryUtcTimestamp)
                Set-AsanaSyncState -TaskId $gid -Field 'asanaQuestion' -Value $question
                $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'asana-terminal-answer.ps1'),
                    '-Repository', [string]$context.repositoryRoot, '-TaskId', $gid) |
                    ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }
                $hostPath = (Get-Process -Id $PID).Path
                $null = Start-Process -FilePath $hostPath -WindowStyle Normal -ArgumentList ($args -join ' ') -PassThru
                Write-Output "Opened terminal fallback for $gid."
            }
            continue
        }

        if ([string]$task.status -eq 'done' -and [string]$task.asanaSyncedState -ne 'Done') {
            $developmentSha = [string](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name 'integration') -Name 'mergeCommit' -Default '')
            $productionSha = [string](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name 'production') -Name 'mergeCommit' -Default '')
            $spec = [string](Get-FactoryNestedValue -Target $task -Name 'asanaSpecPath' -Default '')
            $checks = @(Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name 'workerResult') -Name 'tests' -Default @())
            $testText = Format-FactoryAsanaTestSummary -Checks $checks
            $securityText = [string](Get-FactoryNestedValue -Target (Get-FactoryNestedValue -Target $task -Name 'security') -Name 'summary' -Default 'not configured for this repo')
            $message = "DONE (factory):`nHEAD: $($task.commit)`nMerged: $($config.developmentBranch) $developmentSha, $($config.productionBranch) $productionSha`nSpec: $spec`nTests: $testText`nSecurity: $securityText`nNotes: Verify the published change."
            $comments = @(Get-FactoryAsanaComments -Config $config -Gid $gid)
            if (-not [string](Get-FactoryNestedValue $task 'rockId') -and -not @($comments | Where-Object { [string]$_.text -eq $message }).Count) {
                $null = Add-FactoryAsanaComment -Config $config -Gid $gid -Text $message
            }
            Set-FactoryAsanaDone -Config $config -Gid $gid
            Move-FactoryAsanaTask -Config $config -Gid $gid -Section ([string]$config.asana.sections.done)
            Write-FactoryAsanaTransition -Context $context -Gid $gid -From 'Taken' -To 'Done' -WorkerId $gid
            Set-AsanaSyncState -TaskId $gid -Field 'asanaSyncedState' -Value 'Done'
            Set-AsanaSyncState -TaskId $gid -Field 'asanaState' -Value 'Done'
            if (-not [string](Get-FactoryNestedValue $task 'rockId')) { try { Start-FactoryRockCycle -Config $config -Reason 'Done' -Gid $gid } catch { Write-Warning $_.Exception.Message } }
            Write-Output "Completed Asana task $gid."
        } elseif ([string]$task.status -eq 'failed' -and [string]$task.asanaSyncedState -ne 'Failed') {
            $reason = [string](Get-FactoryNestedValue -Target $task -Name 'error' -Default 'Worker could not finish.')
            $worktree = [string](Get-FactoryNestedValue -Target $task -Name 'worktree' -Default '')
            $branch = [string](Get-FactoryNestedValue -Target $task -Name 'branch' -Default '')
            $message = "FAILED (factory): $reason`nTried: worker implementation and checks.`nNext: inspect the retained worktree and re-groom or retry.`nWorktree: $worktree`nBranch: $branch"
            $comments = @(Get-FactoryAsanaComments -Config $config -Gid $gid)
            if (-not [string](Get-FactoryNestedValue $task 'rockId') -and -not @($comments | Where-Object { [string]$_.text -eq $message }).Count) {
                $null = Add-FactoryAsanaComment -Config $config -Gid $gid -Text $message
            }
            Set-FactoryAsanaField -Config $config -Gid $gid -Field ([string]$config.asana.fields.factory) -Value ([string]$config.asana.fields.failed)
            Write-FactoryAsanaTransition -Context $context -Gid $gid -From 'Taken' -To 'Failed' -WorkerId $gid
            Set-AsanaSyncState -TaskId $gid -Field 'asanaSyncedState' -Value 'Failed'
            Set-AsanaSyncState -TaskId $gid -Field 'asanaState' -Value 'Failed'
            if (-not [string](Get-FactoryNestedValue $task 'rockId')) { try { Start-FactoryRockCycle -Config $config -Reason 'Failed' -Gid $gid } catch { Write-Warning $_.Exception.Message } }
            Write-Output "Reported failure for Asana task $gid."
        }
    } catch { $syncErrors.Add("Asana sync for $gid failed: $($_.Exception.Message)") }
}
if ($syncErrors.Count) { throw ($syncErrors.ToArray() -join [Environment]::NewLine) }
