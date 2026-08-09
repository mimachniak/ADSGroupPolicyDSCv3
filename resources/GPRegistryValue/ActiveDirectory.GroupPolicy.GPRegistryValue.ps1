# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Get', 'Set', 'Test')]
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
    Write-DscTrace -Level Error -Message 'No JSON input received on stdin.'
    exit 1
}

try {
    $config = $jsonInput | ConvertFrom-Json
} catch {
    Write-DscTrace -Level Error -Message "Failed to parse JSON input: $_"
    exit 1
}

foreach ($req in @('gpoName', 'key', 'valueName')) {
    if ([string]::IsNullOrEmpty($config.$req)) {
        Write-DscTrace -Level Error -Message "Required property '$req' is missing or empty."
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
function ConvertTo-SerializableValue($rawValue, [string]$regType) {
    if ($null -eq $rawValue) { return $null }
    switch ($regType) {
        'Binary'      { return @([byte[]]$rawValue) }
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
            $a = [byte[]]$currentValue
            $b = @($desiredValue)
            if ($a.Count -ne $b.Count) { return $false }
            for ($i = 0; $i -lt $a.Count; $i++) {
                if ($a[$i] -ne [byte]$b[$i]) { return $false }
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

                $setParams = Merge-Params -base @{
                    Name      = $gpoName
                    Key       = $key
                    ValueName = $valueName
                    Value     = $value
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
