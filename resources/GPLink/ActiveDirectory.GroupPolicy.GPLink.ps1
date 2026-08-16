# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Get', 'Set', 'Test', 'Export')]
    [string]$Operation
)

$ErrorActionPreference = 'Stop'

#region Trace helpers — write structured JSON lines to stderr
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

# 'gpoName'/'target' identify a single instance; export enumerates every link instead.
if ($Operation -ne 'Export') {
    if ([string]::IsNullOrEmpty($config.gpoName)) {
        Write-DscTrace -Level Error -Message "Required property 'gpoName' is missing or empty."
        exit 1
    }
    if ([string]::IsNullOrEmpty($config.target)) {
        Write-DscTrace -Level Error -Message "Required property 'target' is missing or empty."
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

#region Extract and normalize input properties
$gpoName     = $config.gpoName
$target      = $config.target
$linkEnabled = $config.linkEnabled   # 'Yes' | 'No' | 'Unspecified' | $null
$enforced    = $config.enforced      # 'Yes' | 'No' | 'Unspecified' | $null
$order       = $config.order         # int | $null
$domain      = $config.domain        # may be $null
$server      = $config.server        # may be $null
# ensure takes precedence over _exist when both are provided
$shouldExist = if ($config.ensure -eq 'Absent')  { $false }
               elseif ($config.ensure -eq 'Present') { $true }
               elseif ($null -ne $config._exist)      { [bool]$config._exist }
               else                                   { $true }

# Parameters shared across all GroupPolicy cmdlets in this resource
$commonParams = @{}
if (-not [string]::IsNullOrEmpty($domain)) { $commonParams['Domain'] = $domain }
if (-not [string]::IsNullOrEmpty($server)) { $commonParams['Server'] = $server }
#endregion

#region Helpers
function ConvertTo-YesNo([bool]$value) {
    if ($value) { 'Yes' } else { 'No' }
}

function Get-CurrentState {
    try {
        $inheritance = Get-GPInheritance -Target $target @commonParams -ErrorAction Stop
        $link = $inheritance.GpoLinks | Where-Object { $_.DisplayName -eq $gpoName } | Select-Object -First 1
        if ($null -eq $link) {
            return [ordered]@{
                gpoName = $gpoName
                target  = $target
                ensure  = 'Absent'
                _exist  = $false
            }
        }
        return [ordered]@{
            gpoName     = $link.DisplayName
            gpoId       = $link.GpoId.ToString()
            target      = $target
            ensure      = 'Present'
            linkEnabled = ConvertTo-YesNo -value $link.Enabled
            enforced    = ConvertTo-YesNo -value $link.Enforced
            order       = [int]$link.Order
            domain      = if (-not [string]::IsNullOrEmpty($domain)) { $domain } else { $null }
            server      = if (-not [string]::IsNullOrEmpty($server)) { $server } else { $null }
            _exist      = $true
        }
    } catch {
        # Target container may not exist or domain may be unreachable
        Write-DscTrace -Level Warn -Message "Could not query GPO links at '$target': $_"
        return [ordered]@{
            gpoName = $gpoName
            target  = $target
            ensure  = 'Absent'
            _exist  = $false
        }
    }
}

function Test-InDesiredState($current) {
    if ($shouldExist -and -not $current._exist) { return $false }
    if (-not $shouldExist -and $current._exist) { return $false }
    if ($shouldExist -and $current._exist) {
        if (-not [string]::IsNullOrEmpty($linkEnabled) -and $linkEnabled -ne 'Unspecified' -and $current.linkEnabled -ne $linkEnabled) { return $false }
        if (-not [string]::IsNullOrEmpty($enforced)    -and $enforced -ne 'Unspecified'    -and $current.enforced -ne $enforced)       { return $false }
        if ($null -ne $order -and $current.order -ne $order)                                                                           { return $false }
    }
    return $true
}

function Merge-Params([hashtable]$base, [hashtable]$extra) {
    $merged = @{}
    foreach ($kv in $base.GetEnumerator())  { $merged[$kv.Key] = $kv.Value }
    foreach ($kv in $extra.GetEnumerator()) { $merged[$kv.Key] = $kv.Value }
    return $merged
}

function Get-AllLinkTargets {
    # Discovers every site, domain root, and OU distinguished name that can hold a GPO link.
    # Requires the ActiveDirectory module; sites live under the Configuration naming context.
    $adParams = @{}
    if (-not [string]::IsNullOrEmpty($server)) { $adParams['Server'] = $server }
    elseif (-not [string]::IsNullOrEmpty($domain)) { $adParams['Server'] = $domain }

    $targets = [System.Collections.Generic.List[string]]::new()

    try {
        $rootDse = Get-ADRootDSE @adParams -ErrorAction Stop
        $targets.Add($rootDse.defaultNamingContext)

        Get-ADOrganizationalUnit -Filter * @adParams -ErrorAction Stop | ForEach-Object {
            $targets.Add($_.DistinguishedName)
        }

        try {
            Get-ADObject -SearchBase "CN=Sites,$($rootDse.configurationNamingContext)" -LDAPFilter '(objectClass=site)' @adParams -ErrorAction Stop |
                ForEach-Object { $targets.Add($_.DistinguishedName) }
        } catch {
            Write-DscTrace -Level Warn -Message "Could not enumerate AD sites: $_"
        }
    } catch {
        Write-DscTrace -Level Warn -Message "Could not enumerate GPO link targets via ActiveDirectory module: $_"
    }

    return ($targets | Select-Object -Unique)
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
            # Emit one JSON line per existing GPO link so `dsc resource export` can build a configuration document.
            # A declared 'target' scopes the export to that single container; a declared 'gpoName' filters to links for that GPO.
            $targets = if (-not [string]::IsNullOrEmpty($target)) {
                @($target)
            } else {
                if (-not (Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue)) {
                    Write-DscTrace -Level Error -Message 'The ActiveDirectory PowerShell module is required to enumerate GPO link targets for export. Install RSAT-AD-PowerShell.'
                    exit 2
                }
                Import-Module ActiveDirectory -ErrorAction Stop
                Get-AllLinkTargets
            }

            foreach ($t in $targets) {
                try {
                    $inheritance = Get-GPInheritance -Target $t @commonParams -ErrorAction Stop
                } catch {
                    Write-DscTrace -Level Warn -Message "Could not query GPO links at '$t': $_"
                    continue
                }
                foreach ($link in $inheritance.GpoLinks) {
                    if (-not [string]::IsNullOrEmpty($gpoName) -and $link.DisplayName -ne $gpoName) { continue }
                    $state = [ordered]@{
                        gpoName     = $link.DisplayName
                        gpoId       = $link.GpoId.ToString()
                        target      = $t
                        ensure      = 'Present'
                        linkEnabled = ConvertTo-YesNo -value $link.Enabled
                        enforced    = ConvertTo-YesNo -value $link.Enforced
                        order       = [int]$link.Order
                        domain      = if (-not [string]::IsNullOrEmpty($domain)) { $domain } else { $null }
                        server      = if (-not [string]::IsNullOrEmpty($server)) { $server } else { $null }
                        _exist      = $true
                    }
                    $state | ConvertTo-Json -Compress
                }
            }
        }

        'Set' {
            $current = Get-CurrentState

            if ($shouldExist) {
                if (-not $current._exist) {
                    # Create the GPO link
                    $newParams = Merge-Params -base @{ Name = $gpoName; Target = $target } -extra $commonParams
                    if (-not [string]::IsNullOrEmpty($linkEnabled)) { $newParams['LinkEnabled'] = $linkEnabled }
                    if (-not [string]::IsNullOrEmpty($enforced))    { $newParams['Enforced']    = $enforced }
                    if ($null -ne $order)                           { $newParams['Order']        = $order }

                    New-GPLink @newParams -ErrorAction Stop | Out-Null
                    Write-DscTrace -Level Info -Message "Created link: GPO '$gpoName' → '$target'."
                } else {
                    # Update existing link properties that differ
                    $setParams = Merge-Params -base @{ Name = $gpoName; Target = $target } -extra $commonParams

                    $needsUpdate = $false
                    if (-not [string]::IsNullOrEmpty($linkEnabled) -and $linkEnabled -ne 'Unspecified' -and $current.linkEnabled -ne $linkEnabled) {
                        $setParams['LinkEnabled'] = $linkEnabled
                        $needsUpdate = $true
                    }
                    if (-not [string]::IsNullOrEmpty($enforced) -and $enforced -ne 'Unspecified' -and $current.enforced -ne $enforced) {
                        $setParams['Enforced'] = $enforced
                        $needsUpdate = $true
                    }
                    if ($null -ne $order -and $current.order -ne $order) {
                        $setParams['Order'] = $order
                        $needsUpdate = $true
                    }

                    if ($needsUpdate) {
                        Set-GPLink @setParams -ErrorAction Stop | Out-Null
                        Write-DscTrace -Level Info -Message "Updated link properties: GPO '$gpoName' → '$target'."
                    }
                }
            } else {
                # Remove the GPO link
                Remove-GPLink -Name $gpoName -Target $target @commonParams -Confirm:$false -ErrorAction Stop
                Write-DscTrace -Level Info -Message "Removed link: GPO '$gpoName' → '$target'."
            }

            $finalState = Get-CurrentState
            $finalState['_inDesiredState'] = Test-InDesiredState -current $finalState
            $finalState | ConvertTo-Json -Compress
        }
    }
} catch {
    Write-DscTrace -Level Error -Message "$Operation operation failed for GPO link '$gpoName' → '$target': $_"
    exit 3
}
