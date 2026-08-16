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

# 'gpoName'/'key'/'valueName' identify a single instance; export enumerates every value instead.
if ($Operation -ne 'Export') {
    foreach ($req in @('gpoName', 'key', 'valueName')) {
        if ([string]::IsNullOrEmpty($config.$req)) {
            Write-DscTrace -Level Error -Message "Required property '$req' is missing or empty."
            exit 1
        }
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
$key       = $config.key
$valueName = $config.valueName
$valueType = $config.type       # String | ExpandString | Binary | DWord | MultiString | QWord | $null
$value     = $config.value      # the desired value data, may be $null
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

function Get-CurrentState {
    try {
        $setting = Get-GPRegistryValue -Name $gpoName -Key $key -ValueName $valueName @commonParams -ErrorAction Stop
        $regType = $setting.Type.ToString()
        $serialized = ConvertTo-SerializableValue -rawValue $setting.Value -regType $regType
        $isPresent = ($setting.PolicyState.ToString() -eq 'Set')
        return [ordered]@{
            gpoName     = $gpoName
            key         = $setting.FullKeyPath
            valueName   = $setting.ValueName
            type        = $regType
            value       = $serialized
            policyState = $setting.PolicyState.ToString()
            domain      = if (-not [string]::IsNullOrEmpty($domain)) { $domain } else { $null }
            server      = if (-not [string]::IsNullOrEmpty($server)) { $server } else { $null }
            ensure      = if ($isPresent) { 'Present' } else { 'Absent' }
            _exist      = $isPresent
        }
    } catch {
        # Not configured in this GPO
        return [ordered]@{
            gpoName     = $gpoName
            key         = $key
            valueName   = $valueName
            policyState = 'NotConfigured'
            ensure      = 'Absent'
            _exist      = $false
        }
    }
}

function Test-InDesiredState($current) {
    # Existence check
    if ($shouldExist -and $current.ensure -ne 'Present') { return $false }
    if (-not $shouldExist -and $current.ensure -eq 'Present') { return $false }

    # Property checks (only when both exist and desired properties are specified)
    if ($shouldExist -and $current.ensure -eq 'Present') {
        if (-not [string]::IsNullOrEmpty($valueType) -and $current.type -ne $valueType) { return $false }
        if ($null -ne $value) {
            $effectiveType = if (-not [string]::IsNullOrEmpty($valueType)) { $valueType } else { $current.type }
            if (-not (Compare-RegistryValues -currentValue $current.value -desiredValue $value -regType $effectiveType)) {
                return $false
            }
        }
    }
    return $true
}

function Merge-Params([hashtable]$base, [hashtable]$extra) {
    $merged = @{}
    foreach ($kv in $base.GetEnumerator())  { $merged[$kv.Key] = $kv.Value }
    foreach ($kv in $extra.GetEnumerator()) { $merged[$kv.Key] = $kv.Value }
    return $merged
}

function Get-RegistryHiveRootKeys([string]$hiveName) {
    # Get-GPRegistryValue requires a real subkey after the hive name; the bare hive name alone is
    # not a valid Key and always yields zero results. Seed the walk with the hive's actual
    # first-level subkey names (e.g. SOFTWARE, SYSTEM) so the walk has valid starting points.
    return @(Get-ChildItem -Path "Registry::$hiveName" -ErrorAction SilentlyContinue |
        ForEach-Object { "$hiveName\$($_.PSChildName)" })
}

function Get-AllRegistryPolicyValues([string]$gpo) {
    # Walks the registry.pol tree per GPO. Get-GPRegistryValue returns first-level values plus
    # first-level subkeys for any key; subkeys are queued so every leaf value gets discovered.
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($rootKey in @('HKEY_LOCAL_MACHINE', 'HKEY_CURRENT_USER')) {
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($seed in (Get-RegistryHiveRootKeys -hiveName $rootKey)) { $queue.Enqueue($seed) }
        $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        while ($queue.Count -gt 0) {
            $currentKey = $queue.Dequeue()
            if (-not $visited.Add($currentKey)) { continue }
            $getParams = Merge-Params -base @{ Name = $gpo; Key = $currentKey } -extra $commonParams
            $items = @(Get-GPRegistryValue @getParams -ErrorAction SilentlyContinue)
            foreach ($item in $items) {
                if ($item.HasValue) { $results.Add($item) }
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
            # Emit one JSON line per configured registry policy value so `dsc resource export` can build a configuration document.
            # A declared 'gpoName' scopes the export to that single GPO instead of every GPO.
            $gpos = if (-not [string]::IsNullOrEmpty($gpoName)) {
                @(Get-GPO -Name $gpoName @commonParams -ErrorAction Stop)
            } else {
                Get-GPO -All @commonParams -ErrorAction Stop
            }
            foreach ($gpo in $gpos) {
                foreach ($item in (Get-AllRegistryPolicyValues -gpo $gpo.DisplayName)) {
                    $regType = $item.Type.ToString()
                    $serialized = ConvertTo-SerializableValue -rawValue $item.Value -regType $regType
                    $isPresent = ($item.PolicyState.ToString() -eq 'Set')
                    $state = [ordered]@{
                        gpoName     = $gpo.DisplayName
                        key         = $item.FullKeyPath
                        valueName   = $item.ValueName
                        type        = $regType
                        value       = $serialized
                        policyState = $item.PolicyState.ToString()
                        domain      = if (-not [string]::IsNullOrEmpty($domain)) { $domain } else { $null }
                        server      = if (-not [string]::IsNullOrEmpty($server)) { $server } else { $null }
                        ensure      = if ($isPresent) { 'Present' } else { 'Absent' }
                        _exist      = $isPresent
                    }
                    $state | ConvertTo-Json -Compress
                }
            }
        }

        'Set' {
            $current = Get-CurrentState

            if ($shouldExist) {
                if ([string]::IsNullOrEmpty($valueType)) {
                    Write-DscTrace -Level Error -Message "Property 'type' is required when ensure is 'Present'."
                    exit 1
                }
                if ($null -eq $value) {
                    Write-DscTrace -Level Error -Message "Property 'value' is required when ensure is 'Present'."
                    exit 1
                }

                $setValue = if ($valueType -eq 'Binary') { ConvertTo-ByteArray $value } else { $value }
                $setParams = Merge-Params -base @{
                    Name      = $gpoName
                    Key       = $key
                    ValueName = $valueName
                    Value     = $setValue
                    Type      = $valueType
                } -extra $commonParams

                Set-GPRegistryValue @setParams -ErrorAction Stop | Out-Null
                Write-DscTrace -Level Info -Message "Configured registry value '$valueName' ($valueType) in GPO '$gpoName' at '$key'."
            } else {
                if ($current.ensure -eq 'Present') {
                    $removeParams = Merge-Params -base @{
                        Name      = $gpoName
                        Key       = $key
                        ValueName = $valueName
                    } -extra $commonParams

                    Remove-GPRegistryValue @removeParams -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-DscTrace -Level Info -Message "Removed registry policy setting '$valueName' from GPO '$gpoName' at '$key'."
                }
            }

            $finalState = Get-CurrentState
            $finalState['_inDesiredState'] = Test-InDesiredState -current $finalState
            $finalState | ConvertTo-Json -Compress
        }
    }
} catch {
    Write-DscTrace -Level Error -Message "$Operation failed for '$valueName' in GPO '$gpoName': $_"
    exit 3
}
