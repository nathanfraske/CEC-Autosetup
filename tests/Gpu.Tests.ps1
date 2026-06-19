# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Detect-Gpu.psm1') -Force
    Import-Module (Join-Path $src 'Install-Gpu.psm1') -Force
    Import-Module (Join-Path $src 'apps/AppCatalog.psm1') -Force
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
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

Describe 'NVIDIA driver: name normalization + product resolve (fixture)' {
    BeforeAll {
        $script:products = Get-NvidiaProducts -Xml (Get-Content (Join-Path $script:fixtures 'nvidia_products.xml') -Raw)
    }
    It 'normalizes away the NVIDIA prefix' {
        Get-NvidiaNormalizedName 'NVIDIA GeForce RTX 4090' | Should -Be 'geforce rtx 4090'
        Get-NvidiaNormalizedName 'GeForce RTX 4090 Laptop GPU' | Should -Be 'geforce rtx 4090 laptop gpu'
    }
    It 'parses the product list' {
        @($script:products).Count | Should -Be 5
    }
    It 'resolves the desktop RTX 4090 to psid 127 / pfid 995' {
        $p = Resolve-NvidiaProduct -GpuName 'NVIDIA GeForce RTX 4090' -Products $script:products
        $p.Psid | Should -Be '127'
        $p.Pfid | Should -Be '995'
    }
    It 'does not confuse the 4090 with the 4090 D variant' {
        (Resolve-NvidiaProduct -GpuName 'NVIDIA GeForce RTX 4090' -Products $script:products).Pfid | Should -Be '995'
    }
    It 'resolves the laptop GPU despite the prefix difference' {
        $p = Resolve-NvidiaProduct -GpuName 'NVIDIA GeForce RTX 4090 Laptop GPU' -Products $script:products
        $p.Pfid | Should -Be '1004'
    }
    It 'returns $null for an unknown card' {
        Resolve-NvidiaProduct -GpuName 'NVIDIA GeForce RTX 9999' -Products $script:products | Should -BeNullOrEmpty
    }
}

Describe 'GPU driver: AMD/Intel silent install' {
    It 'maps the verified silent switch per vendor' {
        Get-GpuSilentArgs -Vendor 'amd'    | Should -Be '-INSTALL'
        Get-GpuSilentArgs -Vendor 'intel'  | Should -Be '-s'
        Get-GpuSilentArgs -Vendor 'nvidia' | Should -Be '-s -noreboot'
    }
    It 'plans only under -WhatIf' {
        $r = Install-GpuVendorDriver -Vendor 'amd' -InstallerUrl 'http://x/adrenalin.exe' -WhatIf
        $r.Status | Should -Be 'WhatIf'
        $r.Method | Should -Be 'gpu-driver:amd'
    }
    It 'downloads + silent-installs when given an installer url' {
        Mock -ModuleName Install-Gpu Save-Download { }
        Mock -ModuleName Install-Gpu Invoke-ExeInstaller { 0 }
        $r = Install-GpuVendorDriver -Vendor 'intel' -InstallerUrl 'http://x/gfx_win.exe'
        $r.Status | Should -Be 'Installed'
        Should -Invoke -ModuleName Install-Gpu Invoke-ExeInstaller -Times 1 -ParameterFilter { $Arguments -eq '-s' }
    }
}

Describe 'NVIDIA driver: DriverManualLookup parsing (fixture)' {
    It 'extracts the version and CDN url' {
        $info = ConvertFrom-NvidiaDriverLookup -JsonText (Get-Content (Join-Path $script:fixtures 'nvidia_driver_lookup.json') -Raw)
        $info.Version | Should -Be '610.62'
        $info.Url     | Should -BeLike 'https://us.download.nvidia.com/*.exe'
    }
    It 'returns $null when Success is 0' {
        ConvertFrom-NvidiaDriverLookup -JsonText '{"Success":"0","IDS":[]}' | Should -BeNullOrEmpty
    }
}
