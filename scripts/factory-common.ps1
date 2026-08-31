Set-StrictMode -Version 2.0

$script:FactoryUtf8NoBom = New-Object Text.UTF8Encoding($false)
try {
    # Claude Code and Git emit UTF-8. Windows PowerShell 5.1 otherwise decodes
    # redirected native output through the active OEM code page.
    [Console]::InputEncoding = $script:FactoryUtf8NoBom
    [Console]::OutputEncoding = $script:FactoryUtf8NoBom
    $OutputEncoding = $script:FactoryUtf8NoBom
} catch {
    # Explicit ProcessStartInfo encodings below still protect captured output.
}

function ConvertTo-FactoryWindowsArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-FactoryNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = "",
        [hashtable]$Environment = @{}
    )

    $resolvedCommand = Get-Command $Command -ErrorAction Stop
    $executable = if ([string]$resolvedCommand.Source) {
        [string]$resolvedCommand.Source
    } else {
        [string]$resolvedCommand.Path
    }
    if (-not $executable) { throw "Could not resolve executable '$Command'." }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = (@($Arguments | ForEach-Object {
        ConvertTo-FactoryWindowsArgument -Value ([string]$_)
    }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($null -ne $startInfo.PSObject.Properties["StandardOutputEncoding"]) {
        $startInfo.StandardOutputEncoding = $script:FactoryUtf8NoBom
    }
    if ($null -ne $startInfo.PSObject.Properties["StandardErrorEncoding"]) {
        $startInfo.StandardErrorEncoding = $script:FactoryUtf8NoBom
    }
    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Failed to start '$executable'." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result.TrimEnd("`r", "`n")
        $stderr = $stderrTask.Result.TrimEnd("`r", "`n")
        $combined = @($stdout, $stderr) | Where-Object { $_ } | ForEach-Object { [string]$_ }
        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $stdout
            stderr = $stderr
            output = ($combined -join [Environment]::NewLine)
        }
    } finally {
        $process.Dispose()
    }
}

function Remove-FactoryAnsiSequences {
    param([AllowNull()][string]$Value)

    if (-not $Value) { return "" }
    $withoutOsc = [regex]::Replace($Value, '\x1B\][^\x07]*(?:\x07|\x1B\\)', "")
    $withoutCsi = [regex]::Replace($withoutOsc, '\x1B\[[0-?]*[ -/]*[@-~]', "")
    return [regex]::Replace($withoutCsi, '\x1B[@-_]', "")
}

function Get-FactoryBoundedTextTail {
    param(
        [AllowNull()][string]$Value,
        [int]$MaximumLength = 8192
    )

    if ($MaximumLength -lt 128) { throw "MaximumLength must be at least 128 characters." }
    $text = [string]$Value
    if ($text.Length -le $MaximumLength) { return $text }
    $marker = "[... earlier output omitted; full output is in outputPath ...]" + [Environment]::NewLine
    $tailLength = $MaximumLength - $marker.Length
    if ($tailLength -lt 1) { return $text.Substring($text.Length - $MaximumLength) }
    return $marker + $text.Substring($text.Length - $tailLength)
}

function Read-FactoryJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$RetryCount = 6,
        [int]$RetryDelayMilliseconds = 25
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $fullPath = [IO.Path]::GetFullPath($Path)
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            return [IO.File]::ReadAllText($fullPath, $utf8) | ConvertFrom-Json
        } catch {
            if ($attempt -ge $RetryCount) {
                throw "Could not read valid JSON from '$fullPath' after $RetryCount attempt(s): $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }
}

function Write-FactoryJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $fullPath = [IO.Path]::GetFullPath($Path)
    $temporaryPath = "$fullPath.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupPath = "$fullPath.$([Guid]::NewGuid().ToString('N')).bak"
    $json = $Value | ConvertTo-Json -Depth 100
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $utf8)

    try {
        Read-FactoryJson -Path $temporaryPath | Out-Null
        $replaced = $false
        for ($attempt = 1; $attempt -le 8 -and -not $replaced; $attempt++) {
            try {
                if ([IO.File]::Exists($fullPath)) {
                    [IO.File]::Replace($temporaryPath, $fullPath, $backupPath, $true)
                } else {
                    [IO.File]::Move($temporaryPath, $fullPath)
                }
                $replaced = $true
            } catch [IO.IOException] {
                if ($attempt -ge 8) { throw }
                Start-Sleep -Milliseconds (25 * $attempt)
            } catch [UnauthorizedAccessException] {
                if ($attempt -ge 8) { throw }
                Start-Sleep -Milliseconds (25 * $attempt)
            }
        }
        if (-not $replaced) { throw "Could not atomically replace '$fullPath'." }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
}

function Add-MissingFactoryProperties {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)]$Defaults
    )

    foreach ($defaultProperty in $Defaults.PSObject.Properties) {
        $existingProperty = $Target.PSObject.Properties[$defaultProperty.Name]
        if ($null -eq $existingProperty) {
            $copy = $defaultProperty.Value |
                ConvertTo-Json -Depth 100 |
                ConvertFrom-Json
            $Target | Add-Member -NotePropertyName $defaultProperty.Name -NotePropertyValue $copy
            continue
        }

        $existingValue = $existingProperty.Value
        $defaultValue = $defaultProperty.Value
        if (
            $null -ne $existingValue -and
            $null -ne $defaultValue -and
            $existingValue -is [PSCustomObject] -and
            $defaultValue -is [PSCustomObject]
        ) {
            Add-MissingFactoryProperties -Target $existingValue -Defaults $defaultValue
        }
    }
}

function Set-FactoryProperty {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($null -eq $Target.PSObject.Properties[$Name]) {
        $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $Target.$Name = $Value
    }
}

function Get-FactoryCodingConcurrency {
    param([Parameter(Mandatory = $true)]$Config)

    if ($null -ne $Config.PSObject.Properties["codingConcurrency"]) {
        return [int]$Config.codingConcurrency
    }
    if ($null -ne $Config.PSObject.Properties["concurrency"]) {
        return [int]$Config.concurrency
    }
    return 8
}

function Get-FactoryCodingConcurrencySource {
    param([Parameter(Mandatory = $true)]$Config)

    if ($null -ne $Config.PSObject.Properties["codingConcurrency"]) {
        if ($null -ne $Config.PSObject.Properties["concurrency"]) {
            return "codingConcurrency (deprecated concurrency is present but ignored)"
        }
        return "codingConcurrency"
    }
    if ($null -ne $Config.PSObject.Properties["concurrency"]) {
        return "deprecated concurrency alias"
    }
    return "default"
}

function Get-FactoryLaunchedWorkerCount {
    param([Parameter(Mandatory = $true)]$State)

    # awaiting-input retains a live coding slot. It represents a launched
    # worker/conversation, even while the operator is deciding what to answer.
    return @(
        $State.tasks | Where-Object {
            [string]$_.status -in @("starting", "planning", "awaiting-input", "running")
        }
    ).Count
}

function Enter-FactoryMutex {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectKey,
        [int]$TimeoutMilliseconds = 30000
    )

    $safeKey = $ProjectKey -replace '[^A-Za-z0-9_.-]', '-'
    $mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeFactory-$safeKey")
    try {
        if (-not $mutex.WaitOne($TimeoutMilliseconds)) {
            throw "Timed out waiting for the factory state lock for '$ProjectKey'."
        }
    } catch [System.Threading.AbandonedMutexException] {
        # Ownership is granted when the previous process abandoned the mutex.
    }
    return $mutex
}

function Exit-FactoryMutex {
    param($Mutex)

    if ($null -eq $Mutex) { return }
    try {
        $Mutex.ReleaseMutex()
    } catch {
        # The caller may be unwinding before it acquired ownership.
    } finally {
        $Mutex.Dispose()
    }
}

function Get-FactoryTask {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$TaskId
    )

    $matches = @($State.tasks | Where-Object { [string]$_.id -eq $TaskId })
    if ($matches.Count -ne 1) {
        throw "Expected exactly one factory task with ID '$TaskId'; found $($matches.Count)."
    }
    return $matches[0]
}

function Get-FactoryUtcTimestamp {
    return [DateTime]::UtcNow.ToString("o")
}

function Get-FactoryFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($Path))
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Resolve-FactoryAsanaTaskUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $trimmed = $Url.Trim()
    $uri = $null
    if (-not [Uri]::TryCreate($trimmed, [UriKind]::Absolute, [ref]$uri)) {
        throw "Invalid Asana task URL: $Url"
    }
    if ($uri.Scheme -notin @("http", "https") -or $uri.Host -ne "app.asana.com") {
        throw "Asana task URL must use app.asana.com."
    }
    if ($uri.UserInfo) { throw "Asana task URL must not contain credentials." }

    $path = $uri.AbsolutePath.TrimEnd('/')
    $taskId = ""
    if ($path -match '(?i)/task/(\d+)(?:/|$)') {
        $taskId = [string]$matches[1]
    } elseif ($path -match '^/0/\d+/(\d+)(?:/|$)') {
        $taskId = [string]$matches[1]
    }
    if (-not $taskId) {
        throw "Could not extract a numeric Asana task ID from '$Url'."
    }

    return [pscustomobject]@{
        source = "asana"
        taskId = $taskId
        canonicalUrl = "https://app.asana.com/0/0/$taskId"
        suppliedUrl = $trimmed
    }
}

function Get-FactoryInferredReviewCommands {
    param([string]$RepositoryRoot = "")

    if (-not $RepositoryRoot -or -not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
        return @()
    }
    $commands = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot "vendor\bin\pint") -PathType Leaf) {
        $commands.Add("vendor/bin/pint --test")
    }
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot "artisan") -PathType Leaf) {
        $commands.Add("php artisan test --parallel")
    }
    return @($commands.ToArray())
}

function Resolve-FactoryReviewCommands {
    param($InputValue = @(), $ConfigValue = @(), $SavedValue = @(), [string]$RepositoryRoot = "")

    $commands = @($InputValue | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($commands.Count -eq 0) {
        $commands = @($ConfigValue | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    if ($commands.Count -eq 0) {
        $commands = @($SavedValue | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    }
    if ($commands.Count -eq 0) {
        $commands = @(Get-FactoryInferredReviewCommands -RepositoryRoot $RepositoryRoot)
    }
    $commands = @($commands | ForEach-Object {
        $command = ([string]$_).Trim()
        if ($command -match '^(?i:php(?:\.exe)?\s+artisan\s+test)$') {
            "$command --parallel"
        } else {
            $command
        }
    })
    foreach ($command in $commands) {
        if ($command.Length -gt 4096 -or $command -match '[\r\n]') {
            throw "Review test commands must be single-line strings no longer than 4096 characters."
        }
    }
    return @($commands)
}

function Get-FactoryPublicationReadiness {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$State,
        [string]$RepositoryRoot = ""
    )

    $blockers = New-Object System.Collections.Generic.List[string]
    if (-not [bool](Get-FactoryNestedValue -Target $Config -Name "autoPushDevelopment" -Default $false)) {
        $blockers.Add("autoPushDevelopment=false")
    }
    if (-not [bool](Get-FactoryNestedValue -Target $Config -Name "autoPromoteToProduction" -Default $false)) {
        $blockers.Add("autoPromoteToProduction=false")
    }

    $developmentBranch = ([string](Get-FactoryNestedValue -Target $Config -Name "developmentBranch" -Default "")).Trim()
    $productionBranch = ([string](Get-FactoryNestedValue -Target $Config -Name "productionBranch" -Default "")).Trim()
    if (-not $developmentBranch) { $blockers.Add("developmentBranch is not configured") }
    if (-not $productionBranch) { $blockers.Add("productionBranch is not configured") }

    $productionMode = [string](Get-FactoryNestedValue -Target $Config -Name "productionMode" -Default "merge-develop")
    $allowsUnrelatedDevelopment = [bool](Get-FactoryNestedValue -Target $Config -Name "allowUnrelatedDevelopCommitsToProduction" -Default $false)
    if ($productionMode -notin @("merge-develop", "task-only")) {
        $blockers.Add("productionMode '$productionMode' is unsupported")
    } elseif (($productionMode -eq "merge-develop") -ne $allowsUnrelatedDevelopment) {
        $blockers.Add("productionMode '$productionMode' conflicts with allowUnrelatedDevelopCommitsToProduction=$allowsUnrelatedDevelopment")
    }

    $savedCommands = Get-FactoryNestedValue -Target $State -Name "resolvedCommands"
    $integrationCommands = @()
    $releaseCommands = @()
    try {
        $integrationCommands = @(Resolve-FactoryReviewCommands `
            -ConfigValue (Get-FactoryNestedValue -Target $Config -Name "integrationTestCommands" -Default @()) `
            -SavedValue (Get-FactoryNestedValue -Target $savedCommands -Name "integration" -Default @()) `
            -RepositoryRoot $RepositoryRoot)
        if ($integrationCommands.Count -eq 0) {
            $blockers.Add("no trusted integration test commands are configured or saved")
        }
        $releaseCommands = @(Resolve-FactoryReviewCommands `
            -ConfigValue (Get-FactoryNestedValue -Target $Config -Name "releaseTestCommands" -Default @()) `
            -SavedValue (Get-FactoryNestedValue -Target $savedCommands -Name "release" -Default @()) `
            -RepositoryRoot $RepositoryRoot)
        if ($releaseCommands.Count -eq 0 -and $integrationCommands.Count -gt 0) {
            $releaseCommands = @($integrationCommands)
        }
    } catch {
        $blockers.Add($_.Exception.Message)
    }

    return [pscustomobject]@{
        ready = ($blockers.Count -eq 0)
        blockers = @($blockers | ForEach-Object { $_ })
        integrationTestCommands = @($integrationCommands)
        releaseTestCommands = @($releaseCommands)
    }
}

function Test-FactoryTaskRequiresFreshReview {
    param([Parameter(Mandatory = $true)]$Task)

    foreach ($stageName in @("integration", "production")) {
        $stage = Get-FactoryNestedValue -Target $Task -Name $stageName
        if ([string](Get-FactoryNestedValue -Target $stage -Name "status" -Default "") -eq "failed") {
            return $true
        }
    }
    return $false
}

function Get-FactoryChangedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    return @(
        & git -C $Worktree diff-tree --no-commit-id --name-only -r $Commit 2>$null |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Format-FactoryPathDifference {
    param(
        [AllowEmptyCollection()][string[]]$Paths = @(),
        [int]$MaximumPaths = 5
    )

    $items = @($Paths)
    if ($items.Count -eq 0) { return "none" }
    $shown = @($items | Select-Object -First $MaximumPaths | ForEach-Object { "'$_'" })
    $tail = if ($items.Count -gt $MaximumPaths) { " (+$($items.Count - $MaximumPaths) more)" } else { "" }
    return ($shown -join ", ") + $tail
}

function Get-FactoryChangedFilesDiagnostic {
    param(
        [AllowEmptyCollection()][string[]]$DerivedFiles = @(),
        [AllowEmptyCollection()][string[]]$ReportedFiles = @()
    )

    $derived = @($DerivedFiles | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
    $reported = @($ReportedFiles | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
    $missing = @($derived | Where-Object { $reported -cnotcontains $_ })
    $extra = @($reported | Where-Object { $derived -cnotcontains $_ })
    $matches = $missing.Count -eq 0 -and $extra.Count -eq 0
    return [pscustomobject][ordered]@{
        matches = $matches
        reported = $reported
        derived = $derived
        missingFromReport = $missing
        extraInReport = $extra
        error = if ($matches) {
            $null
        } else {
            "Reported changedFiles differ from the validated commit. Missing from report: $(Format-FactoryPathDifference -Paths $missing). Extra in report: $(Format-FactoryPathDifference -Paths $extra)."
        }
    }
}

function Get-FactoryDirectApprovalReadiness {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Task,
        [string]$RepositoryRoot = ""
    )

    $publication = Get-FactoryPublicationReadiness -Config $Config -State $State -RepositoryRoot $RepositoryRoot
    $blockers = New-Object System.Collections.Generic.List[string]
    foreach ($blocker in @($publication.blockers)) { $blockers.Add([string]$blocker) }

    $taskId = [string](Get-FactoryNestedValue -Target $Task -Name "id" -Default "unknown")
    $status = [string](Get-FactoryNestedValue -Target $Task -Name "status" -Default "")
    if ($status -notin @("awaiting-review", "held")) {
        $blockers.Add("task '$taskId' is '$status', not awaiting review")
    }
    if (Test-FactoryTaskRequiresFreshReview -Task $Task) {
        $blockers.Add("the previous publication attempt failed; run a fresh review first")
    }

    $commit = ([string](Get-FactoryNestedValue -Target $Task -Name "commit" -Default "")).ToLowerInvariant()
    if ($commit -notmatch '^[0-9a-f]{40}$') {
        $blockers.Add("task '$taskId' has no validated 40-character worker commit")
    }
    $workerResult = Get-FactoryNestedValue -Target $Task -Name "workerResult"
    $workerCommit = ([string](Get-FactoryNestedValue -Target $workerResult -Name "commit" -Default "")).ToLowerInvariant()
    if ($commit -match '^[0-9a-f]{40}$' -and $workerCommit -ne $commit) {
        $blockers.Add("the validated worker result does not match commit '$commit'")
    }

    $workerTests = @(Get-FactoryNestedValue -Target $workerResult -Name "tests" -Default @())
    if (@($workerTests | Where-Object { [string]$_.status -eq "failed" }).Count -gt 0) {
        $blockers.Add("the worker result contains failed checks")
    } elseif (@($workerTests | Where-Object { [string]$_.status -eq "passed" }).Count -eq 0) {
        $blockers.Add("the worker result contains no passed checks")
    }

    $review = Get-FactoryNestedValue -Target $Task -Name "review"
    $reviewCommit = [string](Get-FactoryNestedValue -Target $review -Name "commit" -Default "")
    $reviewVerdict = [string](Get-FactoryNestedValue -Target $review -Name "verdict" -Default "")
    if ($reviewCommit -eq $commit -and $reviewVerdict -in @("changes-required", "blocked")) {
        $blockers.Add("the existing '$reviewVerdict' review must be resolved first")
    }

    $backgroundSession = Get-FactoryNestedValue -Target $Task -Name "backgroundSession"
    if ([string](Get-FactoryNestedValue -Target $backgroundSession -Name "state" -Default "") -eq "working") {
        $blockers.Add("the worker session is still working")
    }

    return [pscustomobject]@{
        ready = ($blockers.Count -eq 0)
        blockers = @($blockers | ForEach-Object { $_ })
        publication = $publication
    }
}

function Get-FactoryIntegrationPlanCanonicalValue {
    param([Parameter(Mandatory = $true)]$Plan)

    return [ordered]@{
        version = [int](Get-FactoryNestedValue -Target $Plan -Name "version" -Default 1)
        taskId = [string](Get-FactoryNestedValue -Target $Plan -Name "taskId" -Default "")
        taskCommit = [string](Get-FactoryNestedValue -Target $Plan -Name "taskCommit" -Default "")
        remote = [string](Get-FactoryNestedValue -Target $Plan -Name "remote" -Default "")
        developmentBranch = [string](Get-FactoryNestedValue -Target $Plan -Name "developmentBranch" -Default "")
        developmentBase = [string](Get-FactoryNestedValue -Target $Plan -Name "developmentBase" -Default "")
        productionBranch = [string](Get-FactoryNestedValue -Target $Plan -Name "productionBranch" -Default "")
        productionBase = [string](Get-FactoryNestedValue -Target $Plan -Name "productionBase" -Default "")
        productionMode = [string](Get-FactoryNestedValue -Target $Plan -Name "productionMode" -Default "")
        allowUnrelatedDevelopCommitsToProduction = [bool](Get-FactoryNestedValue -Target $Plan -Name "allowUnrelatedDevelopCommitsToProduction" -Default $false)
        integrationTestCommands = @((Get-FactoryNestedValue -Target $Plan -Name "integrationTestCommands" -Default @()) | ForEach-Object { [string]$_ })
        releaseTestCommands = @((Get-FactoryNestedValue -Target $Plan -Name "releaseTestCommands" -Default @()) | ForEach-Object { [string]$_ })
        autoPushDevelopment = [bool](Get-FactoryNestedValue -Target $Plan -Name "autoPushDevelopment" -Default $false)
        autoPromoteToProduction = [bool](Get-FactoryNestedValue -Target $Plan -Name "autoPromoteToProduction" -Default $false)
        createdAt = [string](Get-FactoryNestedValue -Target $Plan -Name "createdAt" -Default "")
    }
}

function Get-FactoryIntegrationPlanHash {
    param([Parameter(Mandatory = $true)]$Plan)

    $canonical = Get-FactoryIntegrationPlanCanonicalValue -Plan $Plan
    $json = $canonical | ConvertTo-Json -Depth 30 -Compress
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Assert-FactoryIntegrationPlan {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    if ([int](Get-FactoryNestedValue -Target $Plan -Name "version" -Default 0) -ne 1) {
        throw "Task '$TaskId' has an unsupported integration plan version. Run review again."
    }
    if ([string](Get-FactoryNestedValue -Target $Plan -Name "taskId" -Default "") -ne $TaskId) {
        throw "Task '$TaskId' has an integration plan for a different task. Run review again."
    }
    if ([string](Get-FactoryNestedValue -Target $Plan -Name "taskCommit" -Default "") -ne $Commit) {
        throw "Task '$TaskId' integration plan does not pin commit '$Commit'. Run review again."
    }
    $savedHash = [string](Get-FactoryNestedValue -Target $Plan -Name "planHash" -Default "")
    $computedHash = Get-FactoryIntegrationPlanHash -Plan $Plan
    if (-not $savedHash -or $savedHash -ne $computedHash) {
        throw "Task '$TaskId' integration plan hash is invalid. Run review again."
    }
    if (@(Get-FactoryNestedValue -Target $Plan -Name "integrationTestCommands" -Default @()).Count -eq 0) {
        throw "Task '$TaskId' integration plan has no integration checks. Run review again."
    }
    if (@(Get-FactoryNestedValue -Target $Plan -Name "releaseTestCommands" -Default @()).Count -eq 0) {
        throw "Task '$TaskId' integration plan has no release checks. Run review again."
    }
    return $computedHash
}

function ConvertTo-FactorySafeName {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$Fallback = "task"
    )

    $safe = ($Value.ToLowerInvariant() -replace '[^a-z0-9._-]', '-')
    $safe = ($safe -replace '-+', '-').Trim('-', '.')
    if (-not $safe) { return $Fallback }
    return $safe
}

function ConvertTo-FactoryTaskArtifactName {
    param([Parameter(Mandatory = $true)][string]$TaskId)

    $safe = ConvertTo-FactorySafeName -Value $TaskId
    if ($safe -ceq $TaskId.ToLowerInvariant() -and $safe.Length -le 80) { return $safe }

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($TaskId)
        $suffix = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant().Substring(0, 12)
    } finally {
        $algorithm.Dispose()
    }
    $maximumPrefixLength = 67
    $prefix = if ($safe.Length -gt $maximumPrefixLength) { $safe.Substring(0, $maximumPrefixLength).TrimEnd("-", ".") } else { $safe }
    if (-not $prefix) { $prefix = "task" }
    return "$prefix-$suffix"
}

function Get-FactoryWorkerSessionName {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Title
    )

    $localMatch = [regex]::Match($TaskId, '^local:(\d{8})-(\d{6})-([0-9a-f]{8})$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $localMatch.Success) {
        $safeTaskId = ConvertTo-FactoryTaskArtifactName -TaskId $TaskId
        $titleSlug = ConvertTo-FactorySafeName -Value $Title -Fallback "task"
        if ($titleSlug.Length -gt 28) { $titleSlug = $titleSlug.Substring(0, 28).TrimEnd("-") }
        $legacyName = "factory-$safeTaskId-$titleSlug"
        if ($legacyName.Length -gt 64) { $legacyName = $legacyName.Substring(0, 64).TrimEnd("-") }
        return $legacyName
    }

    # The random nonce is the task's stable short code. The timestamp and the
    # separate filesystem artifact hash add no useful Agent View identity and
    # leave less room for the operator-supplied title.
    $sessionIdentity = "local-$($localMatch.Groups[3].Value.ToLowerInvariant())"
    $titleSlug = ($Title.ToLowerInvariant() -replace '[^\p{L}\p{Nd}._-]', '-')
    $titleSlug = ($titleSlug -replace '-+', '-').Trim('-', '.')
    if (-not $titleSlug) { $titleSlug = "task" }
    $prefix = "factory-$sessionIdentity-"
    $maximumTitleLength = [Math]::Min(28, 64 - $prefix.Length)
    if ($maximumTitleLength -lt 1) { throw "Local factory session identity is too long: $TaskId" }
    if ($titleSlug.Length -gt $maximumTitleLength) {
        $titleSlug = $titleSlug.Substring(0, $maximumTitleLength).TrimEnd("-")
    }
    if (-not $titleSlug) { $titleSlug = "task" }
    return "$prefix$titleSlug"
}

function Get-FactoryNestedValue {
    param(
        $Target,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Target -or $null -eq $Target.PSObject.Properties[$Name]) {
        return $Default
    }
    $value = $Target.$Name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        return $Default
    }
    return $value
}

function Read-FactoryEnvironmentFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Test database connection environment file not found: $Path"
    }

    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines([IO.Path]::GetFullPath($Path))) {
        if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }
        $name = [string]$matches[1]
        $value = [string]$matches[2]
        if (
            $value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        } elseif ($value -match '^(.*?)\s+#.*$') {
            $value = [string]$matches[1]
        }
        $values[$name] = $value.Trim()
    }
    return $values
}

function Get-FactoryTestDatabaseSettings {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot
    )

    $section = Get-FactoryNestedValue -Target $Config -Name "testDatabaseIsolation"
    if ($null -eq $section -or -not [bool](Get-FactoryNestedValue -Target $section -Name "enabled" -Default $false)) {
        return $null
    }

    $provider = ([string](Get-FactoryNestedValue -Target $section -Name "provider" -Default "postgresql")).ToLowerInvariant()
    if ($provider -notin @("postgresql", "postgres")) {
        throw "Unsupported test database isolation provider '$provider'. Only PostgreSQL is currently supported."
    }

    $prefix = ([string](Get-FactoryNestedValue -Target $section -Name "databasePrefix" -Default "")).ToLowerInvariant()
    $prefix = ($prefix -replace '[^a-z0-9_]', '_') -replace '_+', '_'
    $prefix = $prefix.Trim('_')
    if (-not $prefix) { throw "testDatabaseIsolation.databasePrefix is required when isolation is enabled." }
    if ($prefix[0] -match '[0-9]') { $prefix = "factory_$prefix" }

    $repositoryFull = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
    $environmentFile = [string](Get-FactoryNestedValue -Target $section -Name "connectionEnvironmentFile" -Default ".env")
    $environmentPath = [IO.Path]::GetFullPath((Join-Path $repositoryFull $environmentFile))
    $repositoryPrefix = $repositoryFull + [IO.Path]::DirectorySeparatorChar
    if (
        -not $environmentPath.Equals($repositoryFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $environmentPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "Test database connection environment file must stay inside the repository: $environmentFile"
    }

    return [pscustomobject]@{
        enabled = $true
        provider = "postgresql"
        databasePrefix = $prefix
        connectionEnvironmentPath = $environmentPath
        databaseEnvironmentVariable = [string](Get-FactoryNestedValue -Target $section -Name "databaseEnvironmentVariable" -Default "DB_DATABASE")
        hostEnvironmentVariable = [string](Get-FactoryNestedValue -Target $section -Name "hostEnvironmentVariable" -Default "DB_HOST")
        portEnvironmentVariable = [string](Get-FactoryNestedValue -Target $section -Name "portEnvironmentVariable" -Default "DB_PORT")
        usernameEnvironmentVariable = [string](Get-FactoryNestedValue -Target $section -Name "usernameEnvironmentVariable" -Default "DB_USERNAME")
        passwordEnvironmentVariable = [string](Get-FactoryNestedValue -Target $section -Name "passwordEnvironmentVariable" -Default "DB_PASSWORD")
        maintenanceDatabase = [string](Get-FactoryNestedValue -Target $section -Name "maintenanceDatabase" -Default "postgres")
        clientCommand = [string](Get-FactoryNestedValue -Target $section -Name "clientCommand" -Default "psql")
    }
}

function Get-FactoryTestDatabaseName {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [ValidateSet("worker", "integrator", "release")][string]$Scope,
        [string]$TaskId = ""
    )

    $suffix = switch ($Scope) {
        "worker" {
            if (-not $TaskId) { throw "TaskId is required for worker test database isolation." }
            $safeTask = ($TaskId.ToLowerInvariant() -replace '[^a-z0-9]', '_') -replace '_+', '_'
            $safeTask = $safeTask.Trim('_')
            if (-not $safeTask) { throw "TaskId '$TaskId' cannot produce a safe PostgreSQL database name." }
            "worker_$safeTask"
            break
        }
        default { $Scope }
    }

    $candidate = "$([string]$Settings.databasePrefix)_$suffix"
    if ($candidate.Length -le 63) { return $candidate }

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($candidate)
        $hash = ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant().Substring(0, 10)
    } finally {
        $algorithm.Dispose()
    }
    return $candidate.Substring(0, 52).TrimEnd('_') + "_" + $hash
}

function Invoke-FactoryPostgresMaintenance {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$Sql
    )

    $values = Read-FactoryEnvironmentFile -Path ([string]$Settings.connectionEnvironmentPath)
    $hostName = [string]$values[[string]$Settings.hostEnvironmentVariable]
    if (-not $hostName) { $hostName = "127.0.0.1" }
    $port = [string]$values[[string]$Settings.portEnvironmentVariable]
    if (-not $port) { $port = "5432" }
    $username = [string]$values[[string]$Settings.usernameEnvironmentVariable]
    if (-not $username) {
        throw "Test database connection file has no $($Settings.usernameEnvironmentVariable)."
    }
    $password = [string]$values[[string]$Settings.passwordEnvironmentVariable]

    $processEnvironment = @{
        PGPASSWORD = $password
        PGCONNECT_TIMEOUT = "10"
        PGAPPNAME = "claude-factory"
    }
    $result = Invoke-FactoryNativeProcess `
        -Command ([string]$Settings.clientCommand) `
        -Arguments @(
            "-X", "-q", "-v", "ON_ERROR_STOP=1",
            "-h", $hostName,
            "-p", $port,
            "-U", $username,
            "-d", ([string]$Settings.maintenanceDatabase),
            "-tAc", $Sql
        ) `
        -Environment $processEnvironment
    if ([int]$result.exitCode -ne 0) {
        throw "PostgreSQL test database command failed: $($result.output)"
    }
    return $result
}

function Get-FactoryTestDatabaseProcessEnvironment {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$DatabaseName
    )

    $values = Read-FactoryEnvironmentFile -Path ([string]$Settings.connectionEnvironmentPath)
    $environment = @{}
    foreach ($property in @(
        "hostEnvironmentVariable",
        "portEnvironmentVariable",
        "usernameEnvironmentVariable",
        "passwordEnvironmentVariable"
    )) {
        $variableName = [string]$Settings.$property
        if ($variableName -and $values.ContainsKey($variableName)) {
            $environment[$variableName] = [string]$values[$variableName]
        }
    }
    $environment[[string]$Settings.databaseEnvironmentVariable] = $DatabaseName
    return $environment
}

function Initialize-FactoryTestDatabase {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [ValidateSet("worker", "integrator", "release")][string]$Scope,
        [string]$TaskId = ""
    )

    $settings = Get-FactoryTestDatabaseSettings -Config $Config -RepositoryRoot $RepositoryRoot
    if ($null -eq $settings) {
        return [pscustomobject]@{ enabled = $false; name = $null; environmentVariable = $null; created = $false }
    }

    $name = Get-FactoryTestDatabaseName -Settings $settings -Scope $Scope -TaskId $TaskId
    $exists = Invoke-FactoryPostgresMaintenance -Settings $settings -Sql "SELECT 1 FROM pg_database WHERE datname = '$name'"
    $created = $false
    if (-not ([string]$exists.stdout).Trim()) {
        try {
            $null = Invoke-FactoryPostgresMaintenance -Settings $settings -Sql "CREATE DATABASE $name"
            $created = $true
        } catch {
            # A concurrent idempotent initializer may win the create race.
            $recheck = Invoke-FactoryPostgresMaintenance -Settings $settings -Sql "SELECT 1 FROM pg_database WHERE datname = '$name'"
            if (-not ([string]$recheck.stdout).Trim()) { throw }
        }
    }

    return [pscustomobject]@{
        enabled = $true
        name = $name
        environmentVariable = [string]$settings.databaseEnvironmentVariable
        created = $created
    }
}

function Remove-FactoryTestDatabase {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [ValidateSet("worker", "integrator", "release")][string]$Scope,
        [string]$TaskId = "",
        [string]$DatabaseName = ""
    )

    $settings = Get-FactoryTestDatabaseSettings -Config $Config -RepositoryRoot $RepositoryRoot
    if ($null -eq $settings) {
        if ($DatabaseName) {
            throw "Task records isolated test database '$DatabaseName', but testDatabaseIsolation is disabled. Re-enable its configuration before cleanup."
        }
        return [pscustomobject]@{ enabled = $false; name = $null; removed = $false }
    }
    if (-not $DatabaseName) {
        return [pscustomobject]@{ enabled = $true; name = $null; removed = $false }
    }

    $expected = Get-FactoryTestDatabaseName -Settings $settings -Scope $Scope -TaskId $TaskId
    if ($DatabaseName -ne $expected) {
        throw "Refusing to drop unexpected test database '$DatabaseName'; expected '$expected'."
    }

    $exists = Invoke-FactoryPostgresMaintenance -Settings $settings -Sql "SELECT 1 FROM pg_database WHERE datname = '$DatabaseName'"
    if (-not ([string]$exists.stdout).Trim()) {
        return [pscustomobject]@{ enabled = $true; name = $DatabaseName; removed = $false }
    }

    $null = Invoke-FactoryPostgresMaintenance -Settings $settings -Sql "DROP DATABASE $DatabaseName WITH (FORCE)"
    return [pscustomobject]@{ enabled = $true; name = $DatabaseName; removed = $true }
}

function Test-FactorySamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    try {
        $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd('\', '/')
        $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd('\', '/')
        return $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-FactoryTerminalAgentRow {
    param([Parameter(Mandatory = $true)]$Row)

    $terminal = @("done", "stopped", "failed")
    $state = if ($null -ne $Row.PSObject.Properties["state"]) { [string]$Row.state } else { "" }
    $status = if ($null -ne $Row.PSObject.Properties["status"]) { [string]$Row.status } else { "" }
    return $state -in $terminal -or $status -in $terminal
}

function Get-FactoryClaudeAgentRows {
    param([Parameter(Mandatory = $true)][string]$ClaudeCommand)

    $result = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @("agents", "--json", "--all")
    if ($result.exitCode -ne 0) {
        throw "Failed to query Claude background sessions: $($result.output)"
    }
    if (-not $result.stdout) { return @() }
    return @(($result.stdout | ConvertFrom-Json) | ForEach-Object { $_ })
}

function Stop-FactoryClaudeSessionAndWait {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$BackgroundId,
        [int]$TimeoutMilliseconds = 5000
    )

    $stopResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @("stop", $BackgroundId)
    if ($stopResult.exitCode -ne 0) {
        throw "Failed to stop background session '$BackgroundId': $($stopResult.output)"
    }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $rows = @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)
        $row = @($rows | Where-Object {
            $null -ne $_.PSObject.Properties["id"] -and
            [string]$_.id -eq $BackgroundId
        } | Select-Object -First 1)
        if ($row.Count -eq 0) { return }
        $hasPid = (
            $null -ne $row[0].PSObject.Properties["pid"] -and
            [long]$row[0].pid -gt 0
        )
        if (-not $hasPid -and (Test-FactoryTerminalAgentRow -Row $row[0])) { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Background session '$BackgroundId' is still live after $TimeoutMilliseconds ms and may still hold its worktree."
}

function Remove-FactoryAgentSessionRow {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$BackgroundId
    )

    $removeResult = Invoke-FactoryNativeProcess -Command $ClaudeCommand -Arguments @("rm", $BackgroundId)
    if ($removeResult.exitCode -eq 0) {
        return [pscustomobject]@{ id = $BackgroundId; removed = $true; alreadyGone = $false; warning = $null }
    }

    try {
        $stillPresent = @(
            Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand |
                Where-Object {
                    $null -ne $_.PSObject.Properties["id"] -and
                    [string]$_.id -eq $BackgroundId
                }
        ).Count -gt 0
        if (-not $stillPresent) {
            return [pscustomobject]@{ id = $BackgroundId; removed = $true; alreadyGone = $true; warning = $null }
        }
    } catch {
        # Preserve the original rm failure below; the verification query is best effort.
    }

    $detail = if ($removeResult.output) { $removeResult.output } else { "exit code $($removeResult.exitCode)" }
    return [pscustomobject]@{
        id = $BackgroundId
        removed = $false
        alreadyGone = $false
        warning = "Agent View session '$BackgroundId' could not be removed: $detail"
    }
}

function Remove-FactoryTaskAgentSessions {
    <#
    Removes only background Agent View rows owned by one factory task. `claude
    rm` removes the Agent View index row but, as verified with Claude Code
    2.1.228, leaves the JSONL transcript under ~/.claude/projects intact.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeCommand,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$Worktree = "",
        [string]$KeepId = ""
    )

    $safeTaskId = ConvertTo-FactoryTaskArtifactName -TaskId $TaskId
    $sessionNamePrefix = "factory-$safeTaskId-"
    $candidates = @()
    foreach ($row in @(Get-FactoryClaudeAgentRows -ClaudeCommand $ClaudeCommand)) {
        $kind = if ($null -ne $row.PSObject.Properties["kind"]) { [string]$row.kind } else { "" }
        if ($kind -ne "background") { continue }
        if ($null -eq $row.PSObject.Properties["id"] -or -not [string]$row.id) { continue }

        $rowId = [string]$row.id
        if ($KeepId -and $rowId -eq $KeepId) { continue }
        $rowName = if ($null -ne $row.PSObject.Properties["name"]) { [string]$row.name } else { "" }
        if ($rowName -ceq "Claude Factory Orchestrator") { continue }
        $rowCwd = if ($null -ne $row.PSObject.Properties["cwd"]) { [string]$row.cwd } else { "" }
        $matchesWorktree = [bool]($Worktree -and $rowCwd -and (Test-FactorySamePath -Left $rowCwd -Right $Worktree))
        $matchesName = $rowName.StartsWith($sessionNamePrefix, [StringComparison]::OrdinalIgnoreCase)
        if ($matchesWorktree -or $matchesName) { $candidates += $row }
    }

    $stopped = @()
    $removed = @()
    $alreadyGone = @()
    $stopFailures = @()
    $removeFailures = @()

    # Stop every live process before removing any Agent View row. If a process
    # survives, callers can abort before touching the worktree.
    foreach ($row in @($candidates)) {
        $hasPid = $null -ne $row.PSObject.Properties["pid"] -and [long]$row.pid -gt 0
        if (-not $hasPid -and (Test-FactoryTerminalAgentRow -Row $row)) { continue }
        $rowId = [string]$row.id
        try {
            Stop-FactoryClaudeSessionAndWait -ClaudeCommand $ClaudeCommand -BackgroundId $rowId
            $stopped += $rowId
        } catch {
            $stopFailures += [pscustomobject]@{ id = $rowId; warning = $_.Exception.Message }
        }
    }

    if ($stopFailures.Count -eq 0) {
        foreach ($row in @($candidates)) {
            $rowId = [string]$row.id
            $result = Remove-FactoryAgentSessionRow -ClaudeCommand $ClaudeCommand -BackgroundId $rowId
            if ($result.removed) {
                $removed += $rowId
                if ($result.alreadyGone) { $alreadyGone += $rowId }
            } else {
                $removeFailures += [pscustomobject]@{ id = $rowId; warning = [string]$result.warning }
            }
        }
    }

    return [pscustomobject]@{
        matchedAgentSessions = @($candidates | ForEach-Object { [string]$_.id })
        stoppedAgentSessions = @($stopped)
        removedAgentSessions = @($removed)
        alreadyGoneAgentSessions = @($alreadyGone)
        stopFailures = @($stopFailures)
        removeFailures = @($removeFailures)
        warnings = @(@($stopFailures) + @($removeFailures) | ForEach-Object { [string]$_.warning })
    }
}
