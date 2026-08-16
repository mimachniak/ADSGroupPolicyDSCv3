# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Get', 'Set', 'Test', 'Export')]
    [string]$Operation
)

$ErrorActionPreference = 'Stop'

#region Trace helpers
function Write-DscTrace {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Message
    )
    $levelKey = $Level.ToLower()
    $host.ui.WriteErrorLine((@{ $levelKey = $Message } | ConvertTo-Json -Compress))
}
#endregion

#region Parse stdin
$jsonInput = [Console]::In.ReadToEnd().Trim()
if ([string]::IsNullOrWhiteSpace($jsonInput)) {
    if ($Operation -eq 'Export') {
        $jsonInput = '{}'
    } else {
        Write-DscTrace -Level Error -Message 'No JSON input received on stdin.'
        exit 1
    }
}

try {
    $config = $jsonInput | ConvertFrom-Json
} catch {
    Write-DscTrace -Level Error -Message "Failed to parse JSON input: $_"
    exit 1
}

# 'gpoName'/'context'/'key' identify a single instance; export enumerates every preference item instead.
if ($Operation -ne 'Export') {
    foreach ($req in @('gpoName', 'context', 'key')) {
        if ([string]::IsNullOrEmpty($config.$req)) {
            Write-DscTrace -Level Error -Message "Required property '$req' is missing or empty."
            exit 1
        }
    }

    if ($config.context -notin @('User', 'Computer')) {
        Write-DscTrace -Level Error -Message "Property 'context' must be 'User' or 'Computer'."
        exit 1
    }
}
#endregion

#region Validate GroupPolicy module
if (-not (Get-Module -ListAvailable -Name GroupPolicy -ErrorAction SilentlyContinue)) {
    Write-DscTrace -Level Error -Message 'The GroupPolicy PowerShell module is not available. Install RSAT-Group-Policy-Management-Tools or the GroupPolicy Windows feature.'
    exit 2
}
Import-Module GroupPolicy -ErrorAction Stop
#endregion

#region Extract properties
$gpoName   = $config.gpoName
$context   = $config.context    # User | Computer
$key       = $config.key
$valueName = $config.valueName  # may be $null (key-only preference item)
$action    = $config.action     # Create | Replace | Update | Delete | $null
$valueType = $config.type       # String | ExpandString | Binary | DWord | MultiString | QWord | $null
$value     = $config.value      # may be $null
$order     = $config.order      # int | $null
$disabled  = if ($null -ne $config.disabled) { [bool]$config.disabled } else { $false }
$domain    = $config.domain
$server    = $config.server
$shouldExist = if ($config.ensure -eq 'Absent')  { $false }
               elseif ($config.ensure -eq 'Present') { $true }
               elseif ($null -ne $config._exist)      { [bool]$config._exist }
               else                                   { $true }

$commonParams = @{}
if (-not [string]::IsNullOrEmpty($domain)) { $commonParams['Domain'] = $domain }
if (-not [string]::IsNullOrEmpty($server)) { $commonParams['Server'] = $server }
#endregion

#region Helpers
function ConvertTo-ByteArray($rawValue) {
    # Accepts either a Base64 string (compact export/input form) or a legacy array of byte values.
    if ($null -eq $rawValue) { return [byte[]]@() }
    if ($rawValue -is [string]) { return [Convert]::FromBase64String($rawValue) }
    return [byte[]]@($rawValue)
}

function ConvertTo-SerializableValue($rawValue, [string]$regType) {
    if ($null -eq $rawValue) { return $null }
    switch ($regType) {
        'Binary'      { return [Convert]::ToBase64String([byte[]]$rawValue) }
        'MultiString' { return @([string[]]$rawValue) }
        'DWord'       { return [int]$rawValue }
        'QWord'       { return [long]$rawValue }
        default       { return $rawValue }
    }
}

function Compare-RegistryValues($currentValue, $desiredValue, [string]$regType) {
    if ($null -eq $currentValue -and $null -eq $desiredValue) { return $true }
    if ($null -eq $currentValue -or $null -eq $desiredValue)  { return $false }
    switch ($regType) {
        'DWord'  { return ([long]$currentValue -eq [long]$desiredValue) }
        'QWord'  { return ([long]$currentValue -eq [long]$desiredValue) }
        'Binary' {
            $a = ConvertTo-ByteArray $currentValue
            $b = ConvertTo-ByteArray $desiredValue
            if ($a.Count -ne $b.Count) { return $false }
            for ($i = 0; $i -lt $a.Count; $i++) {
                if ($a[$i] -ne $b[$i]) { return $false }
            }
            return $true
        }
        'MultiString' {
            $a = @([string[]]$currentValue)
            $b = @($desiredValue)
            if ($a.Count -ne $b.Count) { return $false }
            for ($i = 0; $i -lt $a.Count; $i++) {
                if ($a[$i] -ne $b[$i]) { return $false }
            }
            return $true
        }
        default { return ("$currentValue" -eq "$desiredValue") }
    }
}

function Get-PrefItems {
    # Returns all matching preference items for this key/value in the given context.
    $getParams = @{
        Name    = $gpoName
        Context = $context
        Key     = $key
    }
    foreach ($kv in $commonParams.GetEnumerator()) { $getParams[$kv.Key] = $kv.Value }
    if (-not [string]::IsNullOrEmpty($valueName)) { $getParams['ValueName'] = $valueName }

    $items = @(Get-GPPrefRegistryValue @getParams -ErrorAction SilentlyContinue |
        Where-Object { $_.HasValue -or [string]::IsNullOrEmpty($valueName) })
    return $items
}

function Get-CurrentState {
    $items = Get-PrefItems
    # Return state based on first (lowest order) item found
    $first = $items | Sort-Object Order | Select-Object -First 1

    if ($null -eq $first) {
        return [ordered]@{
            gpoName   = $gpoName
            context   = $context
            key       = $key
            valueName = $valueName
            ensure    = 'Absent'
            _exist    = $false
        }
    }

    $regType = if ($first.HasValue) { $first.Type.ToString() } else { $null }
    $serial  = if ($first.HasValue) { ConvertTo-SerializableValue -rawValue $first.Value -regType $regType } else { $null }

    return [ordered]@{
        gpoName          = $gpoName
        context          = $context
        key              = $first.FullKeyPath
        valueName        = if ($first.HasValue) { $first.ValueName } else { $null }
        action           = $first.Action.ToString()
        type             = $regType
        value            = $serial
        order            = [int]$first.Order
        disabled         = $first.DisabledDirectly
        disabledDirectly = $first.DisabledDirectly
        domain           = if (-not [string]::IsNullOrEmpty($domain)) { $domain } else { $null }
        server           = if (-not [string]::IsNullOrEmpty($server)) { $server } else { $null }
        ensure           = 'Present'
        _exist           = $true
    }
}

function Test-InDesiredState($current) {
    if ($shouldExist -and $current.ensure -ne 'Present') { return $false }
    if (-not $shouldExist -and $current.ensure -eq 'Present') { return $false }

    if ($shouldExist -and $current.ensure -eq 'Present') {
        if (-not [string]::IsNullOrEmpty($action) -and $current.action -ne $action) { return $false }
        if (-not [string]::IsNullOrEmpty($valueType) -and $current.type -ne $valueType) { return $false }
        if ($null -ne $value) {
            $effectiveType = if (-not [string]::IsNullOrEmpty($valueType)) { $valueType } else { $current.type }
            if (-not (Compare-RegistryValues -currentValue $current.value -desiredValue $value -regType $effectiveType)) {
                return $false
            }
        }
        if ($null -ne $order -and $current.order -ne $order) { return $false }
        if ($current.disabled -ne $disabled) { return $false }
    }
    return $true
}

function Remove-AllPrefItems {
    $removeParams = @{
        Name      = $gpoName
        Context   = $context
        Key       = $key
    }
    foreach ($kv in $commonParams.GetEnumerator()) { $removeParams[$kv.Key] = $kv.Value }
    if (-not [string]::IsNullOrEmpty($valueName)) { $removeParams['ValueName'] = $valueName }

    Remove-GPPrefRegistryValue @removeParams -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

function Merge-Params([hashtable]$base, [hashtable]$extra) {
    $merged = @{}
    foreach ($kv in $base.GetEnumerator())  { $merged[$kv.Key] = $kv.Value }
    foreach ($kv in $extra.GetEnumerator()) { $merged[$kv.Key] = $kv.Value }
    return $merged
}

function Get-RegistryHiveRootKeys([string]$hiveName) {
    # Get-GPPrefRegistryValue requires a real subkey after the hive name; the bare hive name alone
    # is not a valid Key and always yields zero results. Seed the walk with the hive's actual
    # first-level subkey names (e.g. SOFTWARE, SYSTEM) so the walk has valid starting points.
    return @(Get-ChildItem -Path "Registry::$hiveName" -ErrorAction SilentlyContinue |
        ForEach-Object { "$hiveName\$($_.PSChildName)" })
}

function Get-AllPrefRegistryItems([string]$gpo, [string]$ctx) {
    # Walks each registry hive's preference tree per GPO/context. Get-GPPrefRegistryValue returns
    # first-level items plus first-level subkeys for any key; subkeys are queued so every item is found.
    $results = [System.Collections.Generic.List[object]]::new()
    $rootKeys = @('HKEY_CLASSES_ROOT', 'HKEY_CURRENT_USER', 'HKEY_LOCAL_MACHINE', 'HKEY_USERS', 'HKEY_CURRENT_CONFIG')
    foreach ($rootKey in $rootKeys) {
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($seed in (Get-RegistryHiveRootKeys -hiveName $rootKey)) { $queue.Enqueue($seed) }
        $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        while ($queue.Count -gt 0) {
            $currentKey = $queue.Dequeue()
            if (-not $visited.Add($currentKey)) { continue }
            $getParams = Merge-Params -base @{ Name = $gpo; Context = $ctx; Key = $currentKey } -extra $commonParams
            $items = @(Get-GPPrefRegistryValue @getParams -ErrorAction SilentlyContinue)
            foreach ($item in $items) {
                # A returned entry with an Action is a real preference item; entries without one are browsable subkeys only.
                if ($null -ne $item.Action) { $results.Add($item) }
                if (-not [string]::IsNullOrEmpty($item.FullKeyPath)) { $queue.Enqueue($item.FullKeyPath) }
            }
        }
    }
    return $results
}
#endregion

try {
    switch ($Operation) {

        'Get' {
            $state = Get-CurrentState
            $state | ConvertTo-Json -Compress
        }

        'Test' {
            $current = Get-CurrentState
            $current['_inDesiredState'] = Test-InDesiredState -current $current
            $current | ConvertTo-Json -Compress
        }

        'Export' {
            # Emit one JSON line per existing preference item so `dsc resource export` can build a configuration document.
            # A declared 'gpoName' scopes the export to that single GPO instead of every GPO.
            $gpos = if (-not [string]::IsNullOrEmpty($gpoName)) {
                @(Get-GPO -Name $gpoName @commonParams -ErrorAction Stop)
            } else {
                Get-GPO -All @commonParams -ErrorAction Stop
            }
            foreach ($gpo in $gpos) {
                foreach ($ctx in @('User', 'Computer')) {
                    foreach ($item in (Get-AllPrefRegistryItems -gpo $gpo.DisplayName -ctx $ctx)) {
                        $regType = if ($item.HasValue) { $item.Type.ToString() } else { $null }
                        $serial  = if ($item.HasValue) { ConvertTo-SerializableValue -rawValue $item.Value -regType $regType } else { $null }
                        $state = [ordered]@{
                            gpoName          = $gpo.DisplayName
                            context          = $ctx
                            key              = $item.FullKeyPath
                            valueName        = if ($item.HasValue) { $item.ValueName } else { $null }
                            action           = $item.Action.ToString()
                            type             = $regType
                            value            = $serial
                            order            = [int]$item.Order
                            disabled         = $item.DisabledDirectly
                            disabledDirectly = $item.DisabledDirectly
                            domain           = if (-not [string]::IsNullOrEmpty($domain)) { $domain } else { $null }
                            server           = if (-not [string]::IsNullOrEmpty($server)) { $server } else { $null }
                            ensure           = 'Present'
                            _exist           = $true
                        }
                        $state | ConvertTo-Json -Compress
                    }
                }
            }
        }

        'Set' {
            $current = Get-CurrentState

            if ($shouldExist) {
                if ([string]::IsNullOrEmpty($action)) {
                    Write-DscTrace -Level Error -Message "Property 'action' is required when ensure is 'Present'."
                    exit 1
                }
                if (-not [string]::IsNullOrEmpty($valueName)) {
                    if ([string]::IsNullOrEmpty($valueType)) {
                        Write-DscTrace -Level Error -Message "Property 'type' is required when 'valueName' is specified."
                        exit 1
                    }
                    if ($null -eq $value) {
                        Write-DscTrace -Level Error -Message "Property 'value' is required when 'valueName' is specified."
                        exit 1
                    }
                }

                # Remove existing items first — Set-GPPrefRegistryValue only creates, never updates
                Remove-AllPrefItems

                $setParams = Merge-Params -base @{
                    Name    = $gpoName
                    Context = $context
                    Key     = $key
                    Action  = $action
                } -extra $commonParams

                if (-not [string]::IsNullOrEmpty($valueName)) { $setParams['ValueName'] = $valueName }
                if (-not [string]::IsNullOrEmpty($valueType)) { $setParams['Type']      = $valueType }
                if ($null -ne $value) {
                    $setParams['Value'] = if ($valueType -eq 'Binary') { ConvertTo-ByteArray $value } else { $value }
                }
                if ($null -ne $order)                         { $setParams['Order']     = $order }
                if ($disabled)                                { $setParams['Disable']   = $true }

                Set-GPPrefRegistryValue @setParams -ErrorAction Stop | Out-Null
                $valueDesc = if ([string]::IsNullOrEmpty($valueName)) { "key '$key'" } else { "value '$valueName' at '$key'" }
                Write-DscTrace -Level Info -Message "Configured preference item ($action) for $valueDesc in GPO '$gpoName' [$context]."
            } else {
                if ($current.ensure -eq 'Present') {
                    Remove-AllPrefItems
                    $valueDesc = if ([string]::IsNullOrEmpty($valueName)) { "key '$key'" } else { "value '$valueName' at '$key'" }
                    Write-DscTrace -Level Info -Message "Removed preference item(s) for $valueDesc from GPO '$gpoName' [$context]."
                }
            }

            $finalState = Get-CurrentState
            $finalState['_inDesiredState'] = Test-InDesiredState -current $finalState
            $finalState | ConvertTo-Json -Compress
        }
    }
} catch {
    Write-DscTrace -Level Error -Message "$Operation failed for preference item in GPO '$gpoName': $_"
    exit 3
}
