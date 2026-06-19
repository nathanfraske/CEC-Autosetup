# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'providers/Asus.psm1') -Force
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'ASUS: slug + series helpers' {
    It 'builds a model slug' {
        Get-AsusModelSlug -Model 'ROG STRIX Z490-I GAMING' | Should -Be 'rog-strix-z490-i-gaming'
    }
    It 'produces series candidates from 3,2,1 leading tokens' {
        $c = Get-AsusSeriesCandidates -ModelSlug 'rog-strix-z490-i-gaming'
        $c[0] | Should -Be 'rog-strix-z490'
        $c    | Should -Contain 'rog-strix'
        $c    | Should -Contain 'rog'
    }
}

Describe 'ASUS: PDInfo parsing (fixture)' {
    It 'extracts ProductID 14684' {
        $json = Get-Content (Join-Path $script:fixtures 'asus_pdinfo.json') -Raw
        Get-AsusProductIdFromPdInfo -JsonText $json | Should -Be 14684
    }
    It 'returns $null for a body without a ProductID' {
        Get-AsusProductIdFromPdInfo -JsonText '{"Result":{"ProductID":null}}' | Should -BeNullOrEmpty
    }
}

Describe 'ASUS: GetPDDrivers parsing (fixture)' {
    BeforeAll {
        $json = Get-Content (Join-Path $script:fixtures 'asus_getpddrivers.json') -Raw
        $script:drivers = ConvertFrom-AsusDriverJson -JsonText $json
    }
    It 'returns 25 driver files' {
        @($script:drivers).Count | Should -Be 25
    }
    It 'builds absolute dlcdnets.asus.com URLs' {
        foreach ($d in $script:drivers) { $d.Url | Should -BeLike 'https://dlcdnets.asus.com/*' }
    }
    It 'includes a Chipset category and tags SHA256' {
        ($script:drivers.Category | Select-Object -Unique) | Should -Contain 'Chipset'
        ($script:drivers[0].HashAlg) | Should -Be 'SHA256'
    }
    It 'returns $null when Status is not SUCCESS' {
        ConvertFrom-AsusDriverJson -JsonText '{"Status":"FAIL","Result":{}}' | Should -BeNullOrEmpty
    }
}

Describe 'ASUS: fallback URL' {
    It 'builds a helpdesk_download URL with the encoded model' {
        $u = Get-AsusFallbackUrl -Identity $null -Model 'ROG STRIX Z490-I GAMING'
        $u | Should -Be 'https://www.asus.com/supportonly/ROG%20STRIX%20Z490-I%20GAMING/helpdesk_download/'
    }
}

Describe 'ASUS: provider object' {
    It 'advertises headless support' {
        (Get-AsusProvider).SupportsHeadless | Should -BeTrue
    }
}
