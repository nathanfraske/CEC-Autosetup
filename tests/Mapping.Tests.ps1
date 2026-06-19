# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Mapping.psm1') -Force
}

Describe 'Mapping: Get-NormalizedModelKey' {
    It 'lower-cases and collapses punctuation' {
        Get-NormalizedModelKey -Model 'ROG STRIX Z490-I GAMING' | Should -Be 'rog strix z490 i gaming'
    }
    It 'drops a trailing parenthetical board code' {
        Get-NormalizedModelKey -Model 'PRO B650-P WIFI (MS-7E26)' | Should -Be 'pro b650 p wifi'
    }
}

Describe 'Mapping: lookup' {
    BeforeAll { $script:map = Get-Mapping }

    It 'loads the shipped seed' {
        $script:map.Count | Should -BeGreaterThan 0
    }
    It 'finds Gigabyte B650 with its rev-slug (exact)' {
        $e = Find-MappingEntry -Mapping $script:map -Model 'B650 GAMING X AX V2'
        $e.vendor | Should -Be 'gigabyte'
        $e.slug   | Should -Be 'B650-GAMING-X-AX-V2-rev-10-11-12'
    }
    It 'fuzzy-matches a suffixed model to a seed entry' {
        $e = Find-MappingEntry -Mapping $script:map -Model 'ROG STRIX Z490-I GAMING WIFI'
        $e.vendor | Should -Be 'asus'
    }
    It 'returns $null for an unknown board' {
        Find-MappingEntry -Mapping $script:map -Model 'Totally Unknown Board 9000' | Should -BeNullOrEmpty
    }
}
