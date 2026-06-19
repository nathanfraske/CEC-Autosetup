# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'providers/Msi.psm1') -Force
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'MSI: slug' {
    It 'hyphenates the model, preserving case' {
        Get-MsiSlug -Model 'MAG B650 TOMAHAWK WIFI' | Should -Be 'MAG-B650-TOMAHAWK-WIFI'
    }
}

Describe 'MSI: OS selection' {
    It 'parses the os list from the fixture' {
        $os = Get-MsiOsList -JsonText (Get-Content (Join-Path $script:fixtures 'msi_os.json') -Raw)
        $os | Should -Contain 'Win11 64'
    }
    It 'prefers Win11 64' {
        Select-MsiOs -OsList @('Win10 64', 'Win11 64') -Preferred @('Win11 64', 'Win10 64') | Should -Be 'Win11 64'
    }
    It 'falls back to the first when no preferred match' {
        Select-MsiOs -OsList @('Win8 64') -Preferred @('Win11 64', 'Win10 64') | Should -Be 'Win8 64'
    }
}

Describe 'MSI: panel parsing (fixture)' {
    BeforeAll {
        $json = Get-Content (Join-Path $script:fixtures 'msi_panel.json') -Raw
        $script:drivers = ConvertFrom-MsiPanel -JsonText $json
        $script:chipset = $script:drivers | Where-Object { $_.Name -eq 'AMD Chipset Driver' } | Select-Object -First 1
    }
    It 'returns at least one driver' {
        @($script:drivers).Count | Should -BeGreaterThan 0
    }
    It 'skips the type_title/os metadata keys (no empty categories)' {
        ($script:drivers.Category) | Should -Not -Contain 'type_title'
        ($script:drivers.Category) | Should -Not -Contain 'os'
    }
    It 'parses the AMD Chipset Driver with version and category' {
        $script:chipset | Should -Not -BeNullOrEmpty
        $script:chipset.Version  | Should -Be '7.12.04.858'
        $script:chipset.Category | Should -Be 'System & Chipset Drivers'
    }
    It 'extracts a clean 64-hex SHA-256 (strips the SHA-256: prefix and <br>)' {
        $script:chipset.HashAlg | Should -Be 'SHA256'
        $script:chipset.Hash    | Should -Be 'e38e4840ad5a0bade0e04f52c54cf174104092b3d924098288a625f894895946'
    }
    It 'uses the download.msi.com CDN url' {
        $script:chipset.Url | Should -BeLike 'https://download.msi.com/*'
    }
}

Describe 'MSI: fallback + provider' {
    It 'builds the support URL' {
        Get-MsiFallbackUrl -Identity $null -Model 'MAG B650 TOMAHAWK WIFI' |
            Should -Be 'https://www.msi.com/Motherboard/MAG-B650-TOMAHAWK-WIFI/support'
    }
    It 'advertises headless support' {
        (Get-MsiProvider).SupportsHeadless | Should -BeTrue
    }
}
