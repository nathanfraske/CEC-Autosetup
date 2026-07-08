# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'providers/Asrock.psm1') -Force
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'ASRock: platform classification' {
    It 'classifies <model> as <platform>' -TestCases @(
        @{ model = 'X870E Taichi';        platform = 'AMD' }
        @{ model = 'B650E PG Riptide';    platform = 'AMD' }
        @{ model = 'Z790 PG Lightning';   platform = 'Intel' }
        @{ model = 'B760M Pro RS';        platform = 'Intel' }
    ) {
        param($model, $platform)
        Get-AsrockPlatform -Model $model | Should -Be $platform
    }
}

Describe 'ASRock: fallback-only provider' {
    It 'reports SupportsHeadless = $false (Incapsula JS challenge blocks headless)' {
        (Get-AsrockProvider).SupportsHeadless | Should -BeFalse
    }
    It 'builds the exact index.asp#Download URL for X870E Taichi' {
        Get-AsrockFallbackUrl -Identity $null -Model 'X870E Taichi' |
            Should -Be 'https://www.asrock.com/mb/AMD/X870E%20Taichi/index.asp#Download'
    }
    It 'builds the Download.html fragment URL' {
        Get-AsrockDownloadUrl -Platform 'AMD' -Model 'X870E Taichi' |
            Should -Be 'https://www.asrock.com/mb/AMD/X870E%20Taichi/Download.html'
    }
}

Describe 'ASRock: Incapsula challenge guard' {
    It 'flags the ~212-byte Incapsula stub' {
        Test-AsrockChallenge -Content '<html><head><script src="/_Incapsula_Resource?x"></script></head></html>' | Should -BeTrue
    }
    It 'passes a real fragment' {
        Test-AsrockChallenge -Content ('x' * 5000) | Should -BeFalse
    }
    It 'Get-DriverList throws on a challenge response (-> Chrome fallback)' {
        Mock -ModuleName Asrock Invoke-Http { '<html><script src="/_Incapsula_Resource?x"></script></html>' }
        $id = [pscustomobject]@{ Model = 'X870E Taichi'; Platform = 'AMD'; DownloadHtmlUrl = 'https://www.asrock.com/mb/AMD/X870E%20Taichi/Download.html' }
        { Get-AsrockDriverList -Identity $id } | Should -Throw
    }
}

Describe 'ASRock: Download.html parsing (fixture)' {
    BeforeAll {
        $html = Get-Content (Join-Path $script:fixtures 'asrock_drivers.html') -Raw
        $script:drivers = ConvertFrom-AsrockDownloadHtml -Html $html
        $script:byCat = @{}
        foreach ($d in $script:drivers) { $script:byCat[$d.Category] = $d }
    }
    It 'parses both driver rows (deduped by URL across Global/China)' {
        @($script:drivers).Count | Should -Be 2
    }
    It 'derives category, name, and version from the CDN url' {
        $script:byCat['Audio'].Name    | Should -Be 'Realtek_Audio'
        $script:byCat['Audio'].Version | Should -Be '2422_UAD_WHQL'
        $script:byCat['Audio'].Url     | Should -BeLike 'https://download.asrock.com/Drivers/All/Audio/*'
        $script:byCat['Chipset'].Version | Should -Be '7.12.0.139'
    }
    It 'Get-DriverList parses entries when a real fragment is supplied' {
        Mock -ModuleName Asrock Invoke-Http {
            '<table><a href="https://download.asrock.com/Drivers/All/LAN/Realtek_LAN(v1.2.3).zip">Global</a></table>' + ('x' * 2000)
        }
        $id = [pscustomobject]@{ Model = 'X870E Taichi'; Platform = 'AMD'; DownloadHtmlUrl = 'https://www.asrock.com/x/Download.html' }
        @(Get-AsrockDriverList -Identity $id).Count | Should -Be 1
    }
}
