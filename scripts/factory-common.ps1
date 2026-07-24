Set-StrictMode -Version 2.0

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
        Get-Content -LiteralPath $temporaryPath -Raw | ConvertFrom-Json | Out-Null
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
    $mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeAsanaFactory-$safeKey")
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
