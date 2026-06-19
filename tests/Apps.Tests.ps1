# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Detect-Peripherals.psm1') -Force
    Import-Module (Join-Path $src 'apps/AppCatalog.psm1') -Force
}

Describe 'Detect-Peripherals: Get-VidPid' {
    It 'parses VID/PID from a USB device id' {
        Get-VidPid -DeviceId 'USB\VID_0416&PID_5302\6&ABC' | Should -Be '0416:5302'
    }
    It 'parses VID/PID from an HID device id (upper-cases hex)' {
        Get-VidPid -DeviceId 'HID\VID_1b1c&PID_1b2d&MI_00' | Should -Be '1B1C:1B2D'
    }
    It 'returns $null when there is no VID/PID' {
        Get-VidPid -DeviceId 'ACPI\PNP0C14' | Should -BeNullOrEmpty
    }
}

Describe 'Apps: catalog' {
    It 'loads at least the two seeded apps' {
        $cat = Get-AppCatalog
        @($cat).Count | Should -BeGreaterOrEqual 2
        ($cat.name) | Should -Contain 'SignalRGB'
        ($cat.name) | Should -Contain 'Thermalright Control Center'
    }
    It 'SignalRGB has the verified winget id' {
        $sig = Get-AppCatalog | Where-Object { $_.name -eq 'SignalRGB' }
        $sig.wingetId | Should -Be 'WhirlwindFX.SignalRgb'
    }
    It 'includes Hyte Nexus (browser-fallback)' {
        $hyte = Get-AppCatalog | Where-Object { $_.name -eq 'Hyte Nexus' }
        $hyte | Should -Not -BeNullOrEmpty
        $hyte.fallbackUrl | Should -Be 'https://hyte.com/nexus'
    }
}

Describe 'Apps: force-install (-Include)' {
    It 'force-includes a requested app with no hardware match' {
        $hits = Find-MatchingApps -Devices @() -GpuVendors @() -Include @('Hyte Nexus')
        $hit = $hits | Where-Object { $_.Name -eq 'Hyte Nexus' }
        $hit | Should -Not -BeNullOrEmpty
        $hit.Reason | Should -Match 'requested'
    }
    It 'does not duplicate an app that already matched' {
        $hits = Find-MatchingApps -Devices @() -GpuVendors @() -Include @('Steam')
        @($hits | Where-Object { $_.Name -eq 'Steam' }).Count | Should -Be 1
    }
    It 'ignores an unknown requested app' {
        $hits = Find-MatchingApps -Devices @() -GpuVendors @() -Include @('Totally Made Up App')
        ($hits.Name) | Should -Not -Contain 'Totally Made Up App'
    }
}

Describe 'Apps: matching' {
    It 'matches SignalRGB on an RGB peripheral name' {
        $devices = Get-Peripherals -Devices @(
            [pscustomobject]@{ Name = 'Corsair K70 RGB Keyboard'; DeviceID = 'USB\VID_1B1C&PID_1B2D'; PNPClass = 'HIDClass'; Manufacturer = 'Corsair' }
        )
        $hits = Find-MatchingApps -Devices $devices
        ($hits.Name) | Should -Contain 'SignalRGB'
    }

    It 'matches Thermalright Control Center on a known VID:PID' {
        $devices = Get-Peripherals -Devices @(
            [pscustomobject]@{ Name = 'USB Input Device'; DeviceID = 'HID\VID_0416&PID_5302\x'; PNPClass = 'HIDClass'; Manufacturer = '' }
        )
        $hits = Find-MatchingApps -Devices $devices
        ($hits.Name) | Should -Contain 'Thermalright Control Center'
    }

    It 'matches Thermalright Control Center on a device name' {
        $devices = Get-Peripherals -Devices @(
            [pscustomobject]@{ Name = 'Thermalright LCD Cooler'; DeviceID = 'USB\VID_FFFF&PID_FFFF'; PNPClass = 'USB'; Manufacturer = '' }
        )
        $hits = Find-MatchingApps -Devices $devices
        ($hits.Name) | Should -Contain 'Thermalright Control Center'
    }

    It 'triggers no hardware-specific app for an unrelated device (baseline apps still match)' {
        $devices = Get-Peripherals -Devices @(
            [pscustomobject]@{ Name = 'Standard NVMe Controller'; DeviceID = 'PCI\VEN_8086'; PNPClass = 'SCSIAdapter'; Manufacturer = 'Intel' }
        )
        $hits = Find-MatchingApps -Devices $devices -GpuVendors @()
        @($hits | Where-Object { $_.Reason -notmatch 'baseline' }).Count | Should -Be 0
    }
}
