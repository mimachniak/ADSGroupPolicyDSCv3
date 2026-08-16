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

# 'name' identifies a single instance; export enumerates every GPO instead.
if ($Operation -ne 'Export' -and [string]::IsNullOrEmpty($config.name)) {
    Write-DscTrace -Level Error -Message "Required property 'name' is missing or empty."
    exit 1
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
$name           = $config.name
$comment        = $config.comment          # may be $null
$domain         = $config.domain           # may be $null
$server         = $config.server           # may be $null
$starterGpoName = $config.starterGpoName   # may be $null
$gpoStatus      = $config.gpoStatus        # may be $null
# ensure takes precedence over _exist when both are provided
$shouldExist    = if ($config.ensure -eq 'Absent')  { $false }
                  elseif ($config.ensure -eq 'Present') { $true }
                  elseif ($null -ne $config._exist)      { [bool]$config._exist }
                  else                                   { $true }

# Parameters shared across all GroupPolicy cmdlets in this resource
$commonParams = @{}
if (-not [string]::IsNullOrEmpty($domain)) { $commonParams['Domain'] = $domain }
if (-not [string]::IsNullOrEmpty($server)) { $commonParams['Server'] = $server }
#endregion

#region Helpers
function Get-CurrentState {
    $gpo = Get-GPO -Name $name @commonParams -ErrorAction SilentlyContinue
    if ($null -eq $gpo) {
        return [ordered]@{
            name   = $name
            ensure = 'Absent'
            _exist = $false
        }
    }
    return [ordered]@{
        name      = $gpo.DisplayName
        ensure    = 'Present'
        comment   = $gpo.Description
        domain    = $gpo.DomainName
        server    = if (-not [string]::IsNullOrEmpty($server)) { $server } else { $null }
        gpoStatus = $gpo.GpoStatus.ToString()
        id        = $gpo.Id.ToString()
        owner     = $gpo.Owner
        _exist    = $true
    }
}

function Test-InDesiredState($current) {
    if ($shouldExist -and -not $current._exist) { return $false }
    if (-not $shouldExist -and $current._exist) { return $false }
    if ($shouldExist -and $current._exist) {
        if ($null -ne $comment -and $current.comment -ne $comment) { return $false }
        if (-not [string]::IsNullOrEmpty($gpoStatus) -and $current.gpoStatus -ne $gpoStatus) { return $false }
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

        'Export' {
            # Emit one JSON line per existing GPO so `dsc resource export` can build a configuration document.
            # A declared 'name' scopes the export to that single GPO instead of every GPO.
            $gpos = if (-not [string]::IsNullOrEmpty($name)) {
                @(Get-GPO -Name $name @commonParams -ErrorAction Stop)
            } else {
                Get-GPO -All @commonParams -ErrorAction Stop
            }
            foreach ($gpo in $gpos) {
                $state = [ordered]@{
                    name      = $gpo.DisplayName
                    ensure    = 'Present'
                    comment   = $gpo.Description
                    domain    = $gpo.DomainName
                    server    = if (-not [string]::IsNullOrEmpty($server)) { $server } else { $null }
                    gpoStatus = $gpo.GpoStatus.ToString()
                    id        = $gpo.Id.ToString()
                    owner     = $gpo.Owner
                    _exist    = $true
                }
                $state | ConvertTo-Json -Compress
            }
        }

        'Set' {
            $current = Get-CurrentState

            if ($shouldExist) {
                if (-not $current._exist) {
                    # Create the GPO
                    $newParams = Merge-Params -base @{ Name = $name } -extra $commonParams
                    if (-not [string]::IsNullOrEmpty($comment))        { $newParams['Comment']      = $comment }
                    if (-not [string]::IsNullOrEmpty($starterGpoName)) { $newParams['StarterGPOName'] = $starterGpoName }

                    $gpo = New-GPO @newParams -ErrorAction Stop
                    Write-DscTrace -Level Info -Message "Created GPO '$name' (ID: $($gpo.Id))."

                    if (-not [string]::IsNullOrEmpty($gpoStatus)) {
                        $gpo.GpoStatus = [Microsoft.GroupPolicy.GpoStatus]$gpoStatus
                        Write-DscTrace -Level Info -Message "Set GpoStatus to '$gpoStatus' on GPO '$name'."
                    }
                } else {
                    # Update existing GPO properties
                    if ($null -ne $comment -and $current.comment -ne $comment) {
                        Set-GPO -Name $name @commonParams -Comment $comment -ErrorAction Stop | Out-Null
                        Write-DscTrace -Level Info -Message "Updated comment on GPO '$name'."
                    }
                    if (-not [string]::IsNullOrEmpty($gpoStatus) -and $current.gpoStatus -ne $gpoStatus) {
                        $gpo = Get-GPO -Name $name @commonParams -ErrorAction Stop
                        $gpo.GpoStatus = [Microsoft.GroupPolicy.GpoStatus]$gpoStatus
                        Write-DscTrace -Level Info -Message "Set GpoStatus on GPO '$name' to '$gpoStatus'."
                    }
                }
            } else {
                # Remove the GPO
                Remove-GPO -Name $name @commonParams -Confirm:$false -ErrorAction Stop
                Write-DscTrace -Level Info -Message "Removed GPO '$name'."
            }

            $finalState = Get-CurrentState
            $finalState['_inDesiredState'] = Test-InDesiredState -current $finalState
            $finalState | ConvertTo-Json -Compress
        }
    }
} catch {
    Write-DscTrace -Level Error -Message "$Operation operation failed for GPO '$name': $_"
    exit 3
}
