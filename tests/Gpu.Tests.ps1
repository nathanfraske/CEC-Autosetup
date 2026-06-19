# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Detect-Gpu.psm1') -Force
    Import-Module (Join-Path $src 'apps/AppCatalog.psm1') -Force
}

Describe 'Detect-Gpu: vendor classification' {
    It 'classifies <vid> as <expected>' -TestCases @(
        @{ vid = 'PCI\VEN_10DE&DEV_2684&SUBSYS_1';  expected = 'nvidia' }
        @{ vid = 'PCI\VEN_1002&DEV_744C&SUBSYS_1';  expected = 'amd' }
        @{ vid = 'PCI\VEN_8086&DEV_56A0&SUBSYS_1';  expected = 'intel' }
        @{ vid = 'PCI\VEN_1234&DEV_0000';            expected = $null }
    ) {
        param($vid, $expected)
        Resolve-GpuVendor -PnpDeviceId $vid | Should -Be $expected
    }

    It 'falls back to the adapter name when VEN is absent' {
        Resolve-GpuVendor -PnpDeviceId '' -Name 'NVIDIA GeForce RTX 4070' | Should -Be 'nvidia'
        Resolve-GpuVendor -PnpDeviceId '' -Name 'AMD Radeon RX 7800 XT'   | Should -Be 'amd'
    }
}

Describe 'Detect-Gpu: Get-GpuVendors (injected controllers)' {
    It 'returns distinct recognised vendors (iGPU + dGPU)' {
        $ctrls = @(
            [pscustomobject]@{ Name = 'Intel UHD Graphics 770';  PNPDeviceID = 'PCI\VEN_8086&DEV_4680'; AdapterCompatibility = 'Intel Corporation' }
            [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4090'; PNPDeviceID = 'PCI\VEN_10DE&DEV_2684'; AdapterCompatibility = 'NVIDIA' }
        )
        $v = Get-GpuVendors -Controllers $ctrls
        $v | Should -Contain 'nvidia'
        $v | Should -Contain 'intel'
        @($v).Count | Should -Be 2
    }
}

Describe 'Apps: GPU-vendor matching' {
    It 'matches the <vendor> app on a detected GPU' -TestCases @(
        @{ vendor = 'nvidia'; app = 'NVIDIA App' }
        @{ vendor = 'amd';    app = 'AMD Software: Adrenalin Edition' }
        @{ vendor = 'intel';  app = 'Intel Arc / Graphics Software' }
    ) {
        param($vendor, $app)
        $hits = Find-MatchingApps -Devices @() -GpuVendors @($vendor)
        ($hits.Name) | Should -Contain $app
    }

    It 'matches no GPU app when no GPU vendor is present' {
        $hits = Find-MatchingApps -Devices @() -GpuVendors @()
        ($hits.Name) | Should -Not -Contain 'NVIDIA App'
    }
}
