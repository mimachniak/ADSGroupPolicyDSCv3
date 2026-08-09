# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#Requires -Module Pester

$resourceType = 'ActiveDirectory.GroupPolicy/GPPrefRegistryValue'

Describe 'ActiveDirectory.GroupPolicy/GPPrefRegistryValue resource' -Tag 'Integration' {
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

        $testGpoName = "DSCv3-PrefTest-$(New-Guid)"
        $null = New-GPO -Name $testGpoName -ErrorAction Stop

        $testKey       = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel'
        $testValueName = 'ScreenSaveIsSecure'
    }

    AfterAll {
        if ($testGpoName) {
            Remove-GPPrefRegistryValue -Name $testGpoName -Context User `
                -Key $testKey -ValueName $testValueName `
                -Confirm:$false -ErrorAction SilentlyContinue
            Remove-GPO -Name $testGpoName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Get operation' {
        It 'Returns ensure=Absent when no preference item exists' {
            $json = @{
                gpoName   = $testGpoName
                context   = 'User'
                key       = $testKey
                valueName = $testValueName
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource get -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).actualState
            $result.ensure | Should -Be 'Absent'
        }

        It 'Returns ensure=Present with correct properties after item is created' {
            Set-GPPrefRegistryValue -Name $testGpoName -Context User `
                -Key $testKey -ValueName $testValueName `
                -Value '1' -Type String -Action Update | Out-Null

            $json = @{
                gpoName   = $testGpoName
                context   = 'User'
                key       = $testKey
                valueName = $testValueName
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource get -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).actualState
            $result.ensure    | Should -Be 'Present'
            $result.action    | Should -Be 'Update'
            $result.type      | Should -Be 'String'
            $result.value     | Should -Be '1'
            $result.valueName | Should -Be $testValueName

            Remove-GPPrefRegistryValue -Name $testGpoName -Context User `
                -Key $testKey -ValueName $testValueName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Test operation — ensure Present' {
        It 'Returns _inDesiredState=false when item does not exist' {
            $json = @{
                gpoName   = $testGpoName; context = 'User'
                key = $testKey; valueName = $testValueName
                action = 'Update'; type = 'String'; value = '1'; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $false
        }

        It 'Returns _inDesiredState=true when item matches' {
            Set-GPPrefRegistryValue -Name $testGpoName -Context User `
                -Key $testKey -ValueName $testValueName `
                -Value '1' -Type String -Action Update | Out-Null

            $json = @{
                gpoName   = $testGpoName; context = 'User'
                key = $testKey; valueName = $testValueName
                action = 'Update'; type = 'String'; value = '1'; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $true

            Remove-GPPrefRegistryValue -Name $testGpoName -Context User `
                -Key $testKey -ValueName $testValueName -Confirm:$false -ErrorAction SilentlyContinue
        }

        It 'Returns _inDesiredState=false when action differs' {
            Set-GPPrefRegistryValue -Name $testGpoName -Context User `
                -Key $testKey -ValueName $testValueName `
                -Value '1' -Type String -Action Create | Out-Null

            $json = @{
                gpoName   = $testGpoName; context = 'User'
                key = $testKey; valueName = $testValueName
                action = 'Update'; type = 'String'; value = '1'; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $false

            Remove-GPPrefRegistryValue -Name $testGpoName -Context User `
                -Key $testKey -ValueName $testValueName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Test operation — ensure Absent' {
        It 'Returns _inDesiredState=true when item is absent and ensure=Absent' {
            $json = @{
                gpoName = $testGpoName; context = 'User'
                key = $testKey; valueName = $testValueName
                ensure = 'Absent'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $true
        }

        It 'Returns _inDesiredState=false when item exists and ensure=Absent' {
            Set-GPPrefRegistryValue -Name $testGpoName -Context User `
                -Key $testKey -ValueName $testValueName `
                -Value '1' -Type String -Action Update | Out-Null

            $json = @{
                gpoName = $testGpoName; context = 'User'
                key = $testKey; valueName = $testValueName
                ensure = 'Absent'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            ($out | ConvertFrom-Json).actualState._inDesiredState | Should -Be $false

            Remove-GPPrefRegistryValue -Name $testGpoName -Context User `
                -Key $testKey -ValueName $testValueName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Set operation' {
        It 'Creates a preference item (action=Update, String value)' {
            $json = @{
                gpoName = $testGpoName; context = 'User'
                key = $testKey; valueName = $testValueName
                action = 'Update'; type = 'String'; value = '1'; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).afterState
            $result.ensure          | Should -Be 'Present'
            $result.action          | Should -Be 'Update'
            $result.type            | Should -Be 'String'
            $result.value           | Should -Be '1'
            $result._inDesiredState | Should -Be $true
        }

        It 'Replaces an existing item when action changes (idempotent remove-then-create)' {
            $json = @{
                gpoName = $testGpoName; context = 'User'
                key = $testKey; valueName = $testValueName
                action = 'Replace'; type = 'String'; value = '0'; ensure = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).afterState
            $result.action          | Should -Be 'Replace'
            $result.value           | Should -Be '0'
            $result._inDesiredState | Should -Be $true
        }

        It 'Removes the preference item when ensure=Absent' {
            $json = @{
                gpoName = $testGpoName; context = 'User'
                key = $testKey; valueName = $testValueName
                ensure = 'Absent'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).afterState
            $result.ensure          | Should -Be 'Absent'
            $result._inDesiredState | Should -Be $true
        }

        It 'Creates a DWord preference item (Computer context)' {
            $dwordKey  = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization'
            $dwordName = 'NoLockScreenCamera'

            $json = @{
                gpoName   = $testGpoName
                context   = 'Computer'
                key       = $dwordKey
                valueName = $dwordName
                action    = 'Update'
                type      = 'DWord'
                value     = 1
                ensure    = 'Present'
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $result = ($out | ConvertFrom-Json).afterState
            $result.type            | Should -Be 'DWord'
            $result.value           | Should -Be 1
            $result._inDesiredState | Should -Be $true

            Remove-GPPrefRegistryValue -Name $testGpoName -Context Computer `
                -Key $dwordKey -ValueName $dwordName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}
