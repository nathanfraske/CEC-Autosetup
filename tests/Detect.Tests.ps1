# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Detect-Hardware.psm1') -Force
}

Describe 'Detect-Hardware: vendor mapping' {
    It 'maps <manufacturer> to <expected>' -TestCases @(
        @{ manufacturer = 'ASUSTeK COMPUTER INC.';            expected = 'asus' }
        @{ manufacturer = 'Gigabyte Technology Co., Ltd.';    expected = 'gigabyte' }
        @{ manufacturer = 'GIGA-BYTE TECHNOLOGY CO., LTD.';   expected = 'gigabyte' }
        @{ manufacturer = 'ASRock';                           expected = 'asrock' }
        @{ manufacturer = 'ASRock Incorporation';             expected = 'asrock' }
        @{ manufacturer = 'Micro-Star International Co., Ltd.'; expected = 'msi' }
        @{ manufacturer = 'MSI';                              expected = 'msi' }
        @{ manufacturer = 'Biostar Group';                    expected = $null }
    ) {
        param($manufacturer, $expected)
        Resolve-Vendor -Manufacturer $manufacturer | Should -Be $expected
    }
}

Describe 'Detect-Hardware: Get-MotherboardInfo (injected board)' {
    It 'returns vendor/model from an injected Win32_BaseBoard object' {
        $board = [pscustomobject]@{
            Manufacturer = 'ASUSTeK COMPUTER INC.'
            Product      = 'ROG STRIX Z490-I GAMING'
            Version      = 'Rev 1.xx'
        }
        $info = Get-MotherboardInfo -BaseBoard $board
        $info.Vendor | Should -Be 'asus'
        $info.Model  | Should -Be 'ROG STRIX Z490-I GAMING'
    }

    It 'reports $null vendor for an unknown manufacturer' {
        $board = [pscustomobject]@{ Manufacturer = 'Acme Boards'; Product = 'X'; Version = '' }
        (Get-MotherboardInfo -BaseBoard $board).Vendor | Should -BeNullOrEmpty
    }
}
