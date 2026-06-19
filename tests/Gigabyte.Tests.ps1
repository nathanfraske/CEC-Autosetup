# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'providers/Gigabyte.psm1') -Force
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'Gigabyte: slug' {
    It 'upper-cases and hyphenates the model' {
        Get-GigabyteSlug -Model 'B650 GAMING X AX V2' | Should -Be 'B650-GAMING-X-AX-V2'
    }
}

Describe 'Gigabyte: Akamai challenge guard' {
    It 'flags an undersized body as a challenge' {
        Test-GigabyteChallenge -Content ('x' * 430) | Should -BeTrue
    }
    It 'flags an empty body' {
        Test-GigabyteChallenge -Content '' | Should -BeTrue
    }
    It 'passes a full-size page' {
        Test-GigabyteChallenge -Content ('x' * 60000) | Should -BeFalse
    }
    It 'Get-GigabyteDriverList throws on a challenge response' {
        Mock -ModuleName Gigabyte Invoke-Http { 'tiny challenge body' }
        $id = [pscustomobject]@{ Vendor = 'gigabyte'; Model = 'X'; Slug = 'X'; SupportUrl = 'https://www.gigabyte.com/Motherboard/X/support' }
        { Get-GigabyteDriverList -Identity $id } | Should -Throw
    }
}

Describe 'Gigabyte: support page parsing (fixture)' {
    BeforeAll {
        $html = Get-Content (Join-Path $script:fixtures 'gigabyte_support.html') -Raw
        $script:drivers = ConvertFrom-GigabyteSupport -Html $html
        $script:byId = @{}
        foreach ($d in $script:drivers) { if ($d.DriverId) { $script:byId[$d.DriverId] = $d } }
    }
    It 'dedups by driverId keeping document order (newest first)' {
        # driver 597 appears as 8.03.25.247 (newest, first) and 7.12.04.858 (older).
        $script:byId['597'].Version | Should -Be '8.03.25.247'
    }
    It 'drops older duplicates of the same driverId' {
        ($script:drivers | Where-Object { $_.Version -eq '7.12.04.858' }) | Should -BeNullOrEmpty
    }
    It 'keeps the chipset 597 component with its MD5 from ?v=' {
        $script:byId['597'].Url     | Should -BeLike 'https://download.gigabyte.com/FileList/Driver/mb_driver_597_chipset_8.03.25.247.zip?v=*'
        $script:byId['597'].HashAlg | Should -Be 'MD5'
        $script:byId['597'].Hash    | Should -Match '^[a-f0-9]{32}$'
    }
    It 'returns the expected number of unique components' {
        # 13 numeric mb_driver_<id> components + the mb_driver_preinstall LAN
        # package + one non-mb_driver PreInstall RAID file = 15.
        @($script:drivers).Count | Should -Be 15
    }
    It 'classifies the chipset component as Chipset' {
        $script:byId['597'].Category | Should -Be 'Chipset'
    }
}

Describe 'Gigabyte: provider object' {
    It 'advertises headless support' {
        (Get-GigabyteProvider).SupportsHeadless | Should -BeTrue
    }
}
