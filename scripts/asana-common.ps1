# Shared Asana transport for the optional board integration. Never serialize the PAT.
function Get-FactoryAsanaToken {
    param($Config)
    $name = [string]$Config.asana.tokenEnv
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Invalid Asana token environment variable name.' }
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not $value) { throw "Asana token environment variable '$name' is empty." }
    return $value
}

function Invoke-FactoryAsana {
    param($Config, [string]$Method = 'GET', [Parameter(Mandatory = $true)][string]$Path, $Data = $null)
    $token = Get-FactoryAsanaToken -Config $Config
    $uri = 'https://app.asana.com/api/1.0' + $Path
    $parameters = @{ Uri = $uri; Method = $Method; Headers = @{ Authorization = "Bearer $token" }; ErrorAction = 'Stop' }
    if ($null -ne $Data) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = @{ data = $Data } | ConvertTo-Json -Depth 30 -Compress
    }
    try { return Invoke-RestMethod @parameters } catch {
        # Web exceptions sometimes embed request details. Only expose status and route.
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'network' }
        throw "Asana $Method $($Path.Split('?')[0]) failed ($status)."
    }
}

function Get-FactoryAsanaPages {
    param($Config, [string]$Path)
    $rows = New-Object Collections.Generic.List[object]
    $nextPath = $Path
    while ($nextPath) {
        $page = Invoke-FactoryAsana -Config $Config -Path $nextPath
        foreach ($row in @($page.data)) { if ($null -ne $row) { $rows.Add($row) } }
        $nextPath = ''
        $nextPage = $page.PSObject.Properties['next_page']
        $uriProperty = if ($null -ne $nextPage -and $null -ne $nextPage.Value) {
            $nextPage.Value.PSObject.Properties['uri']
        } else { $null }
        if ($null -ne $uriProperty -and [string]$uriProperty.Value) {
            $nextUri = [Uri][string]$uriProperty.Value
            if ($nextUri.Host -ne 'app.asana.com' -or $nextUri.AbsolutePath -notlike '/api/1.0/*') { throw 'Asana returned an unexpected pagination URL.' }
            $nextPath = $nextUri.PathAndQuery.Substring('/api/1.0'.Length)
        }
    }
    return $rows.ToArray()
}

function Get-FactoryAsanaField {
    param($Task, [string]$Gid)
    $customFields = $Task.PSObject.Properties['custom_fields']
    if ($null -eq $customFields) { return '' }
    foreach ($field in @($customFields.Value)) {
        if ($null -eq $field) { continue }
        if ([string]$field.gid -eq $Gid) {
            $enumValue = $field.PSObject.Properties['enum_value']
            if ($null -ne $enumValue -and $null -ne $enumValue.Value) { return [string]$enumValue.Value.gid }
            $textValue = $field.PSObject.Properties['text_value']
            if ($null -ne $textValue) { return [string]$textValue.Value }
            return ''
        }
    }
    return ''
}

function Get-FactoryAsanaTask {
    param($Config, [string]$Gid)
    $fields = 'name,completed,custom_fields.gid,custom_fields.name,custom_fields.enum_value.gid,custom_fields.enum_value.name,custom_fields.text_value,modified_at,notes,permalink_url,created_at'
    return (Invoke-FactoryAsana -Config $Config -Path "/tasks/$Gid`?opt_fields=$fields").data
}

function Add-FactoryAsanaComment {
    param($Config, [string]$Gid, [string]$Text)
    return (Invoke-FactoryAsana -Config $Config -Method POST -Path "/tasks/$Gid/stories" -Data @{ text = $Text }).data
}

function Set-FactoryAsanaField {
    param($Config, [string]$Gid, [string]$Field, [string]$Value, [bool]$Completed = $false)
    $fields = @{ $Field = $Value }
    $body = @{ custom_fields = $fields }
    if ($Completed) { $body.completed = $true }
    $null = Invoke-FactoryAsana -Config $Config -Method PUT -Path "/tasks/$Gid" -Data $body
}

function Set-FactoryAsanaDone {
    param($Config, [string]$Gid)
    $fields = @{
        ([string]$Config.asana.fields.factory) = [string]$Config.asana.fields.done
        ([string]$Config.asana.fields.resolution) = [string]$Config.asana.fields.resolutionFixed
    }
    $null = Invoke-FactoryAsana -Config $Config -Method PUT -Path "/tasks/$Gid" -Data @{
        custom_fields = $fields
        completed = $true
    }
}

function Get-FactoryAsanaComments {
    param($Config, [string]$Gid)
    $fields = 'gid,created_at,created_by.gid,resource_subtype,text'
    return @(Get-FactoryAsanaPages -Config $Config -Path "/tasks/$Gid/stories?opt_fields=$fields" |
        Where-Object { [string]$_.resource_subtype -eq 'comment_added' } |
        Sort-Object created_at, gid)
}

function Get-FactoryAsanaCommentActor {
    param([string]$Text)
    if ($Text -match '^\s*(?:\[access-orchestrator\]|ANSWER \(access-orchestrator\):)') { return 'access-orchestrator' }
    if ($Text -match '^\s*(?:\[billing-orchestrator\]|ANSWER \(billing-orchestrator\):)') { return 'billing-orchestrator' }
    if ($Text -match '^\s*ANSWER \(Igor via terminal\):') { return 'Igor' }
    if ($Text -match '^\s*(?:TAKEN|QUESTION|DONE|FAILED) \(factory\):') { return 'factory' }
    return 'Igor'
}

function Get-FactoryAsanaTaskRepo {
    param([string]$Notes)
    if ($Notes -match '\A(?:\uFEFF)?[ \t]*Repo:[ \t]*([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)[ \t]*(?:\r?\n|\z)') {
        return $Matches[1].ToLowerInvariant()
    }
    return ''
}

function Get-FactoryRepositorySlug {
    param([string]$Repository, [string]$Remote = 'origin')
    $remoteUrl = (& git -C $Repository remote get-url $Remote 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $remoteUrl) { throw "Could not read Git remote '$Remote' for Asana repo routing." }
    if ([string]$remoteUrl -notmatch '[/:]([^/:]+/[^/:]+?)(?:\.git)?/?$') { throw "Could not identify owner/repo from Git remote '$Remote'." }
    return $Matches[1].ToLowerInvariant()
}

function Move-FactoryAsanaTask {
    param($Config, [string]$Gid, [string]$Section)
    $null = Invoke-FactoryAsana -Config $Config -Method POST -Path "/sections/$Section/addTask" -Data @{ task = $Gid }
}

function Write-FactoryAsanaTransition {
    param($Context, [string]$Gid, [string]$From, [string]$To, [string]$WorkerId)
    $path = Join-Path ([string]$Context.projectData) 'asana-transitions.log'
    $row = [ordered]@{ timestamp = [DateTime]::UtcNow.ToString('o'); taskGid = $Gid; from = $From; to = $To; workerId = $WorkerId }
    [IO.File]::AppendAllText($path, (($row | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}

function Start-FactoryRockCycle {
    param($Config, [string]$Reason, [string]$Gid)
    $path = [string]$Config.launcher.path
    if (-not $path) { return }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Rock launcher not found: $path" }
    $hostPath = (Get-Process -Id $PID).Path
    $items = @('-NoProfile', '-File', $path, '-Reason', $Reason, '-Task', $Gid)
    $arguments = $items | ForEach-Object { ConvertTo-FactoryWindowsArgument -Value ([string]$_) }
    $null = Start-Process -FilePath $hostPath -WindowStyle Hidden -ArgumentList ($arguments -join ' ') -PassThru
}
