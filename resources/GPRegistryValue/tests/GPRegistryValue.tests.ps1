# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#Requires -Module Pester

$resourceType = 'ActiveDirectory.GroupPolicy/GPRegistryValue'

Describe 'ActiveDirectory.GroupPolicy/GPRegistryValue resource' -Tag 'Integration' {
    BeforeAll {
        $gpModuleAvailable = Get-Module -ListAvailable -Name GroupPolicy -ErrorAction SilentlyContinue
        if (-not $gpModuleAvailable) {
            Set-ItResult -Skipped -Because 'GroupPolicy module is not available on this system.'
            return
        }
        try {
            Import-Module GroupPolicy -ErrorAction Stop
            $null = Get-GPO -All -ErrorAction Stop
        } catch {
            Set-ItResult -Skipped -Because "Domain is not accessible: $_"
            return
        }

        $testGpoName = "DSCv3-RegTest-$(New-Guid)"
        $null = New-GPO -Name $testGpoName -ErrorAction Stop

        $testKey       = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
        $testValueName = 'ScreenSaveTimeOut'
    }

    AfterAll {
        if ($testGpoName) {
            Remove-GPRegistryValue -Name $testGpoName -Key $testKey -ValueName $testValueName `
                -Confirm:$false -ErrorAction SilentlyContinue
            Remove-GPO -Name $testGpoName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Get operation' {
        It 'Returns NotConfigured when the value is not set in the GPO' {
            $json = @{ gpoName = $testGpoName; key = $testKey; valueName = $testValueName } |
                ConvertTo-Json -Compress

            $out = $json | dsc resource get -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).actualState
            $result.policyState | Should -Be 'NotConfigured'
            $result.ensure      | Should -Be 'Absent'
        }

        It 'Returns Set with correct value after the setting is configured' {
            Set-GPRegistryValue -Name $testGpoName -Key $testKey `
                -ValueName $testValueName -Value 900 -Type DWord | Out-Null

            $json = @{ gpoName = $testGpoName; key = $testKey; valueName = $testValueName } |
                ConvertTo-Json -Compress

            $out = $json | dsc resource get -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).actualState
            $result.policyState | Should -Be 'Set'
            $result.ensure      | Should -Be 'Present'
            $result.type        | Should -Be 'DWord'
            $result.value       | Should -Be 900

            Remove-GPRegistryValue -Name $testGpoName -Key $testKey `
                -ValueName $testValueName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Test operation — ensure Present' {
        It 'Returns _inDesiredState=false when value is not configured' {
            $json = @{
                gpoName   = $testGpoName; key = $testKey; valueName = $testValueName
                type = 'DWord'; value = 900; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $false
        }

        It 'Returns _inDesiredState=true when value matches' {
            Set-GPRegistryValue -Name $testGpoName -Key $testKey `
                -ValueName $testValueName -Value 900 -Type DWord | Out-Null

            $json = @{
                gpoName = $testGpoName; key = $testKey; valueName = $testValueName
                type = 'DWord'; value = 900; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $true

            Remove-GPRegistryValue -Name $testGpoName -Key $testKey `
                -ValueName $testValueName -Confirm:$false -ErrorAction SilentlyContinue
        }

        It 'Returns _inDesiredState=false when value differs' {
            Set-GPRegistryValue -Name $testGpoName -Key $testKey `
                -ValueName $testValueName -Value 300 -Type DWord | Out-Null

            $json = @{
                gpoName = $testGpoName; key = $testKey; valueName = $testValueName
                type = 'DWord'; value = 900; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $false

            Remove-GPRegistryValue -Name $testGpoName -Key $testKey `
                -ValueName $testValueName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Test operation — ensure Absent' {
        It 'Returns _inDesiredState=true when value is not configured and ensure=Absent' {
            $json = @{
                gpoName = $testGpoName; key = $testKey; valueName = $testValueName
                ensure = 'Absent'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $true
        }

        It 'Returns _inDesiredState=false when value exists and ensure=Absent' {
            Set-GPRegistryValue -Name $testGpoName -Key $testKey `
                -ValueName $testValueName -Value 900 -Type DWord | Out-Null

            $json = @{
                gpoName = $testGpoName; key = $testKey; valueName = $testValueName
                ensure = 'Absent'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $false

            Remove-GPRegistryValue -Name $testGpoName -Key $testKey `
                -ValueName $testValueName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Set operation — DWord' {
        It 'Configures a DWord registry value in the GPO' {
            $json = @{
                gpoName = $testGpoName; key = $testKey; valueName = $testValueName
                type = 'DWord'; value = 60; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).afterState
            $result.ensure          | Should -Be 'Present'
            $result.value           | Should -Be 60
            $result.type            | Should -Be 'DWord'
            $result._inDesiredState | Should -Be $true
        }

        It 'Updates the DWord value when it differs' {
            $json = @{
                gpoName = $testGpoName; key = $testKey; valueName = $testValueName
                type = 'DWord'; value = 120; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).afterState
            $result.value           | Should -Be 120
            $result._inDesiredState | Should -Be $true
        }

        It 'Removes the policy setting when ensure=Absent' {
            $json = @{
                gpoName = $testGpoName; key = $testKey; valueName = $testValueName
                ensure = 'Absent'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).afterState
            $result.ensure          | Should -Be 'Absent'
            $result.policyState     | Should -Be 'NotConfigured'
            $result._inDesiredState | Should -Be $true
        }
    }

    Context 'Set operation — String' {
        It 'Configures a String registry value in the GPO' {
            $json = @{
                gpoName   = $testGpoName
                key       = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
                valueName = 'SCRNSAVE.EXE'
                type      = 'String'
                value     = 'scrnsave.scr'
                ensure    = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).afterState
            $result.type            | Should -Be 'String'
            $result.value           | Should -Be 'scrnsave.scr'
            $result._inDesiredState | Should -Be $true

            Remove-GPRegistryValue -Name $testGpoName `
                -Key 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop' `
                -ValueName 'SCRNSAVE.EXE' -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}
