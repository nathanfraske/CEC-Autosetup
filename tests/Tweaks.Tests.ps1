# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Tweaks.psm1') -Force
    Import-Module (Join-Path $src 'apps/AppCatalog.psm1') -Force
}

Describe 'Tweaks: default-browser associations XML' {
    It 'maps http/https to ChromeHTML' {
        $xml = New-AppAssociationsXml -ProgId 'ChromeHTML'
        $xml | Should -Match '<DefaultAssociations>'
        $xml | Should -Match 'Identifier="http"\s+ProgId="ChromeHTML"'
        $xml | Should -Match 'Identifier="https"\s+ProgId="ChromeHTML"'
    }
}

Describe 'Tweaks: taskbar layout XML' {
    It 'pins the given app link path' {
        $xml = New-TaskbarLayoutXml -LinkPaths @('%ProgramFiles%\Google\Chrome\Application\chrome.exe')
        $xml | Should -Match 'CustomTaskbarLayoutCollection'
        $xml | Should -Match 'DesktopApplicationLinkPath="%ProgramFiles%\\Google\\Chrome\\Application\\chrome.exe"'
    }
}

Describe 'Tweaks: tier wallpaper resolution' {
    BeforeAll {
        $script:tiers = [pscustomobject]@{ tier1 = 'tier1.jpg'; flagship = 'flagship.png' }
    }
    It 'resolves a known tier to a path under the wallpaper dir' {
        $p = Get-TierWallpaper -Tier 'flagship' -Tiers $script:tiers -Root '/opt/cec' -WallpaperDir 'wallpapers'
        $p | Should -BeLike '*wallpapers*flagship.png'
    }
    It 'passes an absolute mapping through unchanged' {
        $abs = [pscustomobject]@{ flagship = '/branding/flagship.png' }
        Get-TierWallpaper -Tier 'flagship' -Tiers $abs -Root '/opt/cec' | Should -Be '/branding/flagship.png'
    }
    It 'returns $null for an unknown tier' {
        Get-TierWallpaper -Tier 'nope' -Tiers $script:tiers -Root '/opt/cec' | Should -BeNullOrEmpty
    }
    It 'returns $null for an empty tier' {
        Get-TierWallpaper -Tier '' -Tiers $script:tiers -Root '/opt/cec' | Should -BeNullOrEmpty
    }
}

Describe 'Tweaks: Steam baseline (always match)' {
    It 'matches Steam with no hardware present' {
        $hits = Find-MatchingApps -Devices @() -GpuVendors @()
        ($hits.Name) | Should -Contain 'Steam'
        ($hits | Where-Object { $_.Name -eq 'Steam' }).Reason | Should -Match 'baseline'
    }
}
