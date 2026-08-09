# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#Requires -Module Pester

$resourceType = 'ActiveDirectory.GroupPolicy/GPO'

Describe 'ActiveDirectory.GroupPolicy/GPO resource' -Tag 'Integration' {
    BeforeAll {
        # Skip all tests when the GroupPolicy module or domain connectivity is not present
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

        $testGpoName = "DSCv3-Test-GPO-$(New-Guid)"
    }

    AfterAll {
        # Clean up test GPO if it was created
        if ($testGpoName -and (Get-GPO -Name $testGpoName -ErrorAction SilentlyContinue)) {
            Remove-GPO -Name $testGpoName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Get operation' {
        It 'Returns _exist=false for a GPO that does not exist' {
            $json = @{ name = 'NonExistentGPO-DoesNotExist-12345' } | ConvertTo-Json -Compress

            $out = $json | dsc resource get -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.actualState
            $result._exist | Should -Be $false
        }

        It 'Returns _exist=true for an existing GPO' {
            # Create a temporary GPO for this test
            $tempName = "DSCv3-Temp-$(New-Guid)"
            $null = New-GPO -Name $tempName -Comment 'Temp for DSCv3 get test'

            try {
                $json = @{ name = $tempName } | ConvertTo-Json -Compress

                $out = $json | dsc resource get -r $resourceType -f - 2>$TestDrive/error.log
                $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

                $output = $out | ConvertFrom-Json
                $result = $output.actualState
                $result._exist   | Should -Be $true
                $result.name     | Should -Be $tempName
                $result.id       | Should -Not -BeNullOrEmpty
                $result.owner    | Should -Not -BeNullOrEmpty
            } finally {
                Remove-GPO -Name $tempName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Test operation — GPO should exist' {
        It 'Returns _inDesiredState=false when GPO is absent but should exist' {
            $json = @{ name = 'NonExistentGPO-DoesNotExist-12345'; _exist = $true } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.actualState
            $result._inDesiredState | Should -Be $false
        }

        It 'Returns _inDesiredState=true when GPO exists and properties match' {
            $tempName = "DSCv3-Temp-$(New-Guid)"
            $null = New-GPO -Name $tempName -Comment 'test comment'

            try {
                $json = @{ name = $tempName; comment = 'test comment'; _exist = $true } | ConvertTo-Json -Compress

                $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
                $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

                $output = $out | ConvertFrom-Json
                $result = $output.actualState
                $result._inDesiredState | Should -Be $true
            } finally {
                Remove-GPO -Name $tempName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }

        It 'Returns _inDesiredState=false when comment differs' {
            $tempName = "DSCv3-Temp-$(New-Guid)"
            $null = New-GPO -Name $tempName -Comment 'original comment'

            try {
                $json = @{ name = $tempName; comment = 'different comment'; _exist = $true } | ConvertTo-Json -Compress

                $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
                $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

                $output = $out | ConvertFrom-Json
                $result = $output.actualState
                $result._inDesiredState | Should -Be $false
            } finally {
                Remove-GPO -Name $tempName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Test operation — GPO should be absent' {
        It 'Returns _inDesiredState=true when GPO is absent and _exist=false' {
            $json = @{ name = 'NonExistentGPO-DoesNotExist-12345'; _exist = $false } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.actualState
            $result._inDesiredState | Should -Be $true
        }

        It 'Returns _inDesiredState=false when GPO exists but _exist=false' {
            $tempName = "DSCv3-Temp-$(New-Guid)"
            $null = New-GPO -Name $tempName

            try {
                $json = @{ name = $tempName; _exist = $false } | ConvertTo-Json -Compress

                $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
                $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

                $output = $out | ConvertFrom-Json
                $result = $output.actualState
                $result._inDesiredState | Should -Be $false
            } finally {
                Remove-GPO -Name $tempName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Set operation — create GPO' {
        It 'Creates a GPO when it does not exist' {
            $json = @{
                name    = $testGpoName
                comment = 'Created by DSCv3 test'
                _exist  = $true
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.afterState
            $result._exist           | Should -Be $true
            $result.name             | Should -Be $testGpoName
            $result.id               | Should -Not -BeNullOrEmpty
            $result._inDesiredState  | Should -Be $true

            # Verify in Active Directory
            $gpo = Get-GPO -Name $testGpoName -ErrorAction SilentlyContinue
            $gpo | Should -Not -BeNullOrEmpty
        }

        It 'Updates GPO comment when it differs' {
            $json = @{
                name    = $testGpoName
                comment = 'Updated by DSCv3 test'
                _exist  = $true
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.afterState
            $result.comment         | Should -Be 'Updated by DSCv3 test'
            $result._inDesiredState | Should -Be $true
        }

        It 'Is idempotent — returns success when GPO is already in desired state' {
            $json = @{
                name    = $testGpoName
                comment = 'Updated by DSCv3 test'
                _exist  = $true
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $output.afterState._inDesiredState | Should -Be $true
        }

        It 'Removes a GPO when _exist=false' {
            $json = @{
                name   = $testGpoName
                _exist = $false
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $null = Get-GPO -Name $testGpoName -ErrorAction SilentlyContinue
            (Get-GPO -Name $testGpoName -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
    }

    Context 'What-if mode' {
        It 'Reports intended creation without creating the GPO' {
            $whatIfName = "DSCv3-WhatIf-$(New-Guid)"
            $json = @{
                name    = $whatIfName
                _exist  = $true
                _whatIf = $true
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            # The GPO must not have been created
            (Get-GPO -Name $whatIfName -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
    }
}
