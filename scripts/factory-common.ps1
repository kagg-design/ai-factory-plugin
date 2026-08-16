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

function Read-FactoryJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json
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

    $temporaryPath = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth 100
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, $utf8)

    try {
        Read-FactoryJson -Path $temporaryPath | Out-Null
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
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
