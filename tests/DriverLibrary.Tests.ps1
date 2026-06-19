# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'DriverLibrary.psm1') -Force
}

Describe 'DriverLibrary: vendor CDN key mapping' {
    It 'maps <url> -> <key>' -TestCases @(
        @{ url = 'https://dlcdnets.asus.com/pub/ASUS/mb/x.zip';          key = 'asus' }
        @{ url = 'https://download.msi.com/dvr_exe/mb/x.zip';            key = 'msi' }
        @{ url = 'https://download-2.msi.com/dvr_exe/mb/x.zip';          key = 'msi' }
        @{ url = 'https://download.gigabyte.com/FileList/Driver/x.zip';  key = 'gigabyte' }
        @{ url = 'https://download.asrock.com/Drivers/All/Audio/x.zip';  key = 'asrock' }
        @{ url = 'https://us.download.nvidia.com/Windows/610.62/x.exe';  key = 'nvidia' }
        @{ url = 'https://example.com/x.zip';                            key = $null }
    ) {
        param($url, $key)
        Get-VendorCdnKey -Url $url | Should -Be $key
    }
}

Describe 'DriverLibrary: mirror relative path + url' {
    It 'mirrors the ASUS CDN path and strips the query' {
        Get-MirrorRelativePath -Url 'https://dlcdnets.asus.com/pub/ASUS/mb/03CHIPSET/DRV_x.zip' |
            Should -Be 'asus/pub/ASUS/mb/03CHIPSET/DRV_x.zip'
    }
    It 'strips the Gigabyte ?v= query' {
        Get-MirrorRelativePath -Url 'https://download.gigabyte.com/FileList/Driver/mb_driver_597_chipset_8.03.25.247.zip?v=abc' |
            Should -Be 'gigabyte/FileList/Driver/mb_driver_597_chipset_8.03.25.247.zip'
    }
    It 'returns $null for a non-CDN host' {
        Get-MirrorRelativePath -Url 'https://example.com/x.zip' | Should -BeNullOrEmpty
    }
    It 'builds an escaped mirror url under the base' {
        Get-MirrorUrl -RelativePath 'asrock/Drivers/All/Audio/Realtek_Audio(v1).zip' -MirrorBase 'http://10.0.0.5:8080/' |
            Should -Be 'http://10.0.0.5:8080/asrock/Drivers/All/Audio/Realtek_Audio%28v1%29.zip'
    }
}

Describe 'DriverLibrary: index lookup + entry conversion' {
    BeforeAll {
        $script:index = [pscustomobject]@{
            boards = [pscustomobject]@{
                'ROG STRIX Z490-I GAMING' = [pscustomobject]@{
                    vendor = 'asus'; model = 'ROG STRIX Z490-I GAMING'
                    entries = @(
                        [pscustomobject]@{ category = 'Chipset'; name = 'Intel Chipset'; version = '10.1'; relPath = 'asus/pub/ASUS/mb/03CHIPSET/DRV_x.zip'; hash = ''; hashAlg = 'SHA256'; size = 123 }
                    )
                }
            }
        }
    }
    It 'finds entries by normalized identifier (case/punctuation-insensitive)' {
        $e = Find-LibraryEntries -Index $script:index -Model 'rog strix z490-i gaming'
        @($e).Count | Should -Be 1
        $e[0].relPath | Should -Be 'asus/pub/ASUS/mb/03CHIPSET/DRV_x.zip'
    }
    It 'returns empty for a board not in the index' {
        @(Find-LibraryEntries -Index $script:index -Model 'Some Other Board').Count | Should -Be 0
    }
    It 'converts a library entry to a mirror-pointed driver entry' {
        $e = (Find-LibraryEntries -Index $script:index -Model 'ROG STRIX Z490-I GAMING')[0]
        $d = ConvertTo-MirrorDriverEntry -LibEntry $e -MirrorBase 'http://10.0.0.5:8080'
        $d.Provider | Should -Be 'mirror'
        $d.Category | Should -Be 'Chipset'
        $d.Url | Should -Be 'http://10.0.0.5:8080/asus/pub/ASUS/mb/03CHIPSET/DRV_x.zip'
    }
}

Describe 'DriverLibrary: current+last-gen board selection' {
    BeforeAll {
        $script:map = @{
            'rog strix x870e e gaming' = [pscustomobject]@{ vendor = 'asus';     model = 'ROG STRIX X870E-E GAMING'; slug = $null }
            'b650 gaming x ax v2'      = [pscustomobject]@{ vendor = 'gigabyte'; model = 'B650 GAMING X AX V2'; slug = 'B650-GAMING-X-AX-V2-rev-10-11-12' }
            'prime z390 a'             = [pscustomobject]@{ vendor = 'asus';     model = 'PRIME Z390-A'; slug = $null }
            'x870e taichi'             = [pscustomobject]@{ vendor = 'asrock';   model = 'X870E Taichi'; slug = $null }
        }
    }
    It 'keeps current/last-gen headless boards, drops old gens and ASRock' {
        $b = Select-LibraryBoards -Mapping $script:map -Tokens @('X870E', 'B650', 'Z890')
        ($b.model) | Should -Contain 'ROG STRIX X870E-E GAMING'   # X870E (boundary before '-')
        ($b.model) | Should -Contain 'B650 GAMING X AX V2'
        ($b.model) | Should -Not -Contain 'PRIME Z390-A'          # Z390 not in token set
        ($b.model) | Should -Not -Contain 'X870E Taichi'          # ASRock not headless-pullable
    }
    It 'loads chipset tokens from the shipped config (current + lastGen)' {
        $t = Get-LibraryChipsetTokens
        $t | Should -Contain 'X870E'
        $t | Should -Contain 'Z790'
    }
}
