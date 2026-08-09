# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#Requires -Module Pester

$resourceType = 'ActiveDirectory.GroupPolicy/GPLink'

Describe 'ActiveDirectory.GroupPolicy/GPLink resource' -Tag 'Integration' {
    BeforeAll {
        # Skip all tests when the GroupPolicy module or domain connectivity is not present
        $gpModuleAvailable = Get-Module -ListAvailable -Name GroupPolicy -ErrorAction SilentlyContinue
        if (-not $gpModuleAvailable) {
            Set-ItResult -Skipped -Because 'GroupPolicy module is not available on this system.'
            return
        }

        try {
            Import-Module GroupPolicy -ErrorAction Stop
            Import-Module ActiveDirectory -ErrorAction Stop
            # Retrieve the domain DN to use as a link target
            $domainDN = (Get-ADDomain -ErrorAction Stop).DistinguishedName
        } catch {
            Set-ItResult -Skipped -Because "Domain or ActiveDirectory module is not accessible: $_"
            return
        }

        # Create a dedicated test OU and GPO for all link tests
        $testOuName  = "DSCv3-TestOU-$(New-Guid)"
        $testGpoName = "DSCv3-TestGPO-$(New-Guid)"

        $testOU = New-ADOrganizationalUnit -Name $testOuName -Path $domainDN -ProtectedFromAccidentalDeletion $false -PassThru -ErrorAction Stop
        $testTarget = $testOU.DistinguishedName

        $null = New-GPO -Name $testGpoName -ErrorAction Stop
    }

    AfterAll {
        # Remove link if still present
        if ($testGpoName -and $testTarget) {
            Remove-GPLink -Name $testGpoName -Target $testTarget -Confirm:$false -ErrorAction SilentlyContinue
        }
        # Remove test GPO
        if ($testGpoName) {
            Remove-GPO -Name $testGpoName -Confirm:$false -ErrorAction SilentlyContinue
        }
        # Remove test OU
        if ($testOU) {
            Remove-ADOrganizationalUnit -Identity $testOU.DistinguishedName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    Context 'Get operation' {
        It 'Returns _exist=false when the link does not exist' {
            $json = @{ gpoName = $testGpoName; target = $testTarget } | ConvertTo-Json -Compress

            $out = $json | dsc resource get -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.actualState
            $result._exist  | Should -Be $false
            $result.gpoName | Should -Be $testGpoName
        }

        It 'Returns _exist=true after a link is created' {
            New-GPLink -Name $testGpoName -Target $testTarget -LinkEnabled Yes -ErrorAction Stop | Out-Null

            try {
                $json = @{ gpoName = $testGpoName; target = $testTarget } | ConvertTo-Json -Compress

                $out = $json | dsc resource get -r $resourceType -f - 2>$TestDrive/error.log
                $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

                $output = $out | ConvertFrom-Json
                $result = $output.actualState
                $result._exist      | Should -Be $true
                $result.gpoName     | Should -Be $testGpoName
                $result.target      | Should -Be $testTarget
                $result.linkEnabled | Should -Be 'Yes'
                $result.enforced    | Should -Be 'No'
                $result.gpoId       | Should -Not -BeNullOrEmpty
            } finally {
                Remove-GPLink -Name $testGpoName -Target $testTarget -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Test operation — link should exist' {
        It 'Returns _inDesiredState=false when link is absent but should exist' {
            $json = @{ gpoName = $testGpoName; target = $testTarget; _exist = $true } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.actualState
            $result._inDesiredState | Should -Be $false
        }

        It 'Returns _inDesiredState=true when link exists and properties match' {
            New-GPLink -Name $testGpoName -Target $testTarget -LinkEnabled Yes -Enforced No -ErrorAction Stop | Out-Null

            try {
                $json = @{
                    gpoName     = $testGpoName
                    target      = $testTarget
                    linkEnabled = 'Yes'
                    enforced    = 'No'
                    _exist      = $true
                } | ConvertTo-Json -Compress

                $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
                $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

                $output = $out | ConvertFrom-Json
                $result = $output.actualState
                $result._inDesiredState | Should -Be $true
            } finally {
                Remove-GPLink -Name $testGpoName -Target $testTarget -Confirm:$false -ErrorAction SilentlyContinue
            }
        }

        It 'Returns _inDesiredState=false when enforced flag differs' {
            New-GPLink -Name $testGpoName -Target $testTarget -Enforced No -ErrorAction Stop | Out-Null

            try {
                $json = @{
                    gpoName  = $testGpoName
                    target   = $testTarget
                    enforced = 'Yes'
                    _exist   = $true
                } | ConvertTo-Json -Compress

                $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
                $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

                $output = $out | ConvertFrom-Json
                $result = $output.actualState
                $result._inDesiredState | Should -Be $false
            } finally {
                Remove-GPLink -Name $testGpoName -Target $testTarget -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Test operation — link should be absent' {
        It 'Returns _inDesiredState=true when link is absent and _exist=false' {
            $json = @{ gpoName = $testGpoName; target = $testTarget; _exist = $false } | ConvertTo-Json -Compress

            $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.actualState
            $result._inDesiredState | Should -Be $true
        }

        It 'Returns _inDesiredState=false when link exists but _exist=false' {
            New-GPLink -Name $testGpoName -Target $testTarget -ErrorAction Stop | Out-Null

            try {
                $json = @{ gpoName = $testGpoName; target = $testTarget; _exist = $false } | ConvertTo-Json -Compress

                $out = $json | dsc resource test -r $resourceType -f - 2>$TestDrive/error.log
                $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

                $output = $out | ConvertFrom-Json
                $result = $output.actualState
                $result._inDesiredState | Should -Be $false
            } finally {
                Remove-GPLink -Name $testGpoName -Target $testTarget -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Set operation — create link' {
        It 'Creates a GPO link when it does not exist' {
            $json = @{
                gpoName     = $testGpoName
                target      = $testTarget
                linkEnabled = 'Yes'
                enforced    = 'No'
                _exist      = $true
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.afterState
            $result._exist          | Should -Be $true
            $result.gpoName         | Should -Be $testGpoName
            $result.linkEnabled     | Should -Be 'Yes'
            $result.enforced        | Should -Be 'No'
            $result._inDesiredState | Should -Be $true
        }

        It 'Updates the enforced flag when it differs' {
            $json = @{
                gpoName  = $testGpoName
                target   = $testTarget
                enforced = 'Yes'
                _exist   = $true
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $result = $output.afterState
            $result.enforced        | Should -Be 'Yes'
            $result._inDesiredState | Should -Be $true
        }

        It 'Is idempotent — returns success when link is already in desired state' {
            $json = @{
                gpoName     = $testGpoName
                target      = $testTarget
                linkEnabled = 'Yes'
                enforced    = 'Yes'
                _exist      = $true
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            $output = $out | ConvertFrom-Json
            $output.afterState._inDesiredState | Should -Be $true
        }

        It 'Removes the link when _exist=false' {
            $json = @{
                gpoName = $testGpoName
                target  = $testTarget
                _exist  = $false
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            # Verify the link is gone
            $inheritance = Get-GPInheritance -Target $testTarget -ErrorAction SilentlyContinue
            $link = $inheritance.GpoLinks | Where-Object { $_.DisplayName -eq $testGpoName }
            $link | Should -BeNullOrEmpty
        }
    }

    Context 'What-if mode' {
        It 'Reports intended link creation without creating it' {
            $json = @{
                gpoName = $testGpoName
                target  = $testTarget
                _exist  = $true
                _whatIf = $true
            } | ConvertTo-Json -Compress

            $out = $json | dsc resource set -r $resourceType -f - 2>$TestDrive/error.log
            $LASTEXITCODE | Should -Be 0 -Because (Get-Content -Raw $TestDrive/error.log)

            # Link must not have been created
            $inheritance = Get-GPInheritance -Target $testTarget -ErrorAction SilentlyContinue
            $link = $inheritance.GpoLinks | Where-Object { $_.DisplayName -eq $testGpoName }
            $link | Should -BeNullOrEmpty
        }
    }
}
