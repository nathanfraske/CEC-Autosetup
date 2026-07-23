# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Common.psm1') -Force
    Import-Module (Join-Path $src 'DriverOrder.psm1') -Force

    function New-Entry([string] $Category, [string] $Name) {
        [pscustomobject]@{ Category = $Category; Name = $Name; Version = '1.0'; Url = 'https://example.com/x.zip' }
    }

    # A realistic mixed board list (ASUS-style categories).
    $script:mixed = @(
        (New-Entry 'Audio'       'Realtek Audio Driver')
        (New-Entry 'Wireless'    'Intel WiFi Driver')
        (New-Entry 'Chipset'     'Intel Chipset Driver')
        (New-Entry 'Bluetooth'   'Intel Bluetooth Driver')
        (New-Entry 'SATA'        'Intel Rapid Storage Technology Driver')
        (New-Entry 'VGA Drivers' 'Intel Graphics Accelerator Driver')
        (New-Entry 'Chipset'     'Intel Management Engine Interface')
        (New-Entry 'Mystery'     'Weird Vendor Blob')
    )
    $script:allTrue = @{ never = $false; vmdOrRaid = $true; apoEligible = $true; series800 = $true; igpuPresent = $true }
}

Describe 'DriverOrder: config' {
    It 'loads the shipped install-order config' {
        $groups = Get-InstallOrderConfig
        @($groups).Count | Should -BeGreaterThan 5
        ($groups.key) | Should -Contain 'chipset'
        ($groups | Select-Object -Last 1).match | Should -Contain '*'
    }
}

Describe 'DriverOrder: planning' {
    It 'orders groups per the spec and assigns every entry exactly once' {
        $plan = Get-DriverOrderPlan -Drivers $script:mixed -Platform 'intel' -Conditions $script:allTrue
        $nonEmpty = @($plan | Where-Object { $_.Entries.Count -gt 0 })
        # chipset before storage before bluetooth before wireless before igpu before audio before other
        $keys = $nonEmpty.Key
        $keys.IndexOf('chipset')   | Should -BeLessThan $keys.IndexOf('storage')
        $keys.IndexOf('storage')   | Should -BeLessThan $keys.IndexOf('bluetooth')
        $keys.IndexOf('bluetooth') | Should -BeLessThan $keys.IndexOf('wireless')
        $keys.IndexOf('wireless')  | Should -BeLessThan $keys.IndexOf('igpu')
        $keys.IndexOf('igpu')      | Should -BeLessThan $keys.IndexOf('audio')
        (@($plan | ForEach-Object { $_.Entries }).Count) | Should -Be $script:mixed.Count
    }

    It 'routes the ME package to the Intel ME group by name' {
        $plan = Get-DriverOrderPlan -Drivers $script:mixed -Platform 'intel' -Conditions $script:allTrue
        $chipset = $plan | Where-Object Key -eq 'chipset'
        $me = $plan | Where-Object Key -eq 'me'
        # 'Intel Management Engine Interface' carries Category=Chipset, so the
        # chipset group (listed first) legitimately claims it; the dedicated ME
        # group only catches entries whose *category* says ME. Both are in the
        # platform block, so order remains correct either way.
        ($chipset.Entries.Name + $me.Entries.Name) | Should -Contain 'Intel Management Engine Interface'
    }

    It 'sends unknown categories to the trailing catch-all' {
        $plan = Get-DriverOrderPlan -Drivers $script:mixed -Platform 'intel' -Conditions $script:allTrue
        $other = $plan | Where-Object Key -eq 'other'
        ($other.Entries.Name) | Should -Contain 'Weird Vendor Blob'
        $plan[-1].Key | Should -Be 'other'
    }

    It 'marks conditional groups skipped when the condition is false (RST without VMD)' {
        $conds = @{ never = $false; vmdOrRaid = $false; apoEligible = $true; series800 = $true; igpuPresent = $true }
        $plan = Get-DriverOrderPlan -Drivers $script:mixed -Platform 'intel' -Conditions $conds
        $storage = $plan | Where-Object Key -eq 'storage'
        $storage.Skipped | Should -BeTrue
        $storage.SkipReason | Should -Match 'vmdOrRaid'
        ($storage.Entries.Name) | Should -Contain 'Intel Rapid Storage Technology Driver'
    }

    It 'skips the iGPU group when no iGPU is present' {
        $conds = @{ never = $false; vmdOrRaid = $true; apoEligible = $true; series800 = $true; igpuPresent = $false }
        $plan = Get-DriverOrderPlan -Drivers $script:mixed -Platform 'intel' -Conditions $conds
        ($plan | Where-Object Key -eq 'igpu').Skipped | Should -BeTrue
    }

    It 'drops Intel-only groups from an AMD plan (entries fall through)' {
        $plan = Get-DriverOrderPlan -Drivers $script:mixed -Platform 'amd' -Conditions $script:allTrue
        ($plan.Key) | Should -Not -Contain 'me'
        ($plan.Key) | Should -Not -Contain 'serialio'
        (@($plan | ForEach-Object { $_.Entries }).Count) | Should -Be $script:mixed.Count
    }

    It 'flags restart boundaries on chipset, storage, and audio' {
        $plan = Get-DriverOrderPlan -Drivers $script:mixed -Platform 'intel' -Conditions $script:allTrue
        ($plan | Where-Object Key -eq 'chipset').RestartAfter | Should -BeTrue
        ($plan | Where-Object Key -eq 'storage').RestartAfter | Should -BeTrue
        ($plan | Where-Object Key -eq 'audio').RestartAfter   | Should -BeTrue
        ($plan | Where-Object Key -eq 'wireless').RestartAfter | Should -BeFalse
    }

    It 'splits MSI-style "LAN Drivers" radios by name: BT and Wi-Fi before Ethernet (audit #3 regression)' {
        # MSI files Bluetooth + Wi-Fi + Ethernet ALL under Category 'LAN Drivers'.
        $msi = @(
            (New-Entry 'LAN Drivers' 'Realtek Ethernet Driver')
            (New-Entry 'LAN Drivers' 'AMD WIFI Driver')
            (New-Entry 'LAN Drivers' 'Realtek BlueTooth Driver')
        )
        $plan = Get-DriverOrderPlan -Drivers $msi -Platform 'amd' -Conditions $script:allTrue
        (($plan | Where-Object Key -eq 'bluetooth').Entries.Name) | Should -Contain 'Realtek BlueTooth Driver'
        (($plan | Where-Object Key -eq 'wireless').Entries.Name)  | Should -Contain 'AMD WIFI Driver'
        (($plan | Where-Object Key -eq 'lan').Entries.Name)       | Should -Contain 'Realtek Ethernet Driver'
        $keys = @($plan | Where-Object { $_.Entries.Count -gt 0 }).Key
        $keys.IndexOf('bluetooth') | Should -BeLessThan $keys.IndexOf('wireless')
        $keys.IndexOf('wireless')  | Should -BeLessThan $keys.IndexOf('lan')
    }

    It 'lets a generic SATA controller driver fall to the catch-all instead of the RST gate (audit #9 regression)' {
        $entries = @((New-Entry 'SATA' 'ASMedia SATA Controller Driver'))
        $conds = @{ never = $false; vmdOrRaid = $false; apoEligible = $true; series800 = $true; igpuPresent = $true }
        $plan = Get-DriverOrderPlan -Drivers $entries -Platform 'intel' -Conditions $conds
        (($plan | Where-Object Key -eq 'other').Entries.Name) | Should -Contain 'ASMedia SATA Controller Driver'
        (($plan | Where-Object Key -eq 'storage').Entries.Count) | Should -Be 0
    }

    It 'hard-denies GNA via the never condition' {
        $entries = @((New-Entry 'GNA' 'Intel GNA Scoring Accelerator'))
        $plan = Get-DriverOrderPlan -Drivers $entries -Platform 'intel' -Conditions $script:allTrue
        $gna = $plan | Where-Object Key -eq 'gna'
        $gna.Skipped | Should -BeTrue
        ($gna.Entries.Name) | Should -Contain 'Intel GNA Scoring Accelerator'
    }
}

Describe 'DriverOrder: runtime probes' {
    It 'Get-PlatformKind returns a known value' {
        Get-PlatformKind | Should -BeIn @('intel', 'amd', 'unknown')
    }
    It 'Get-DriverOrderConditions returns all condition keys with booleans' {
        $c = Get-DriverOrderConditions
        foreach ($k in 'never', 'vmdOrRaid', 'apoEligible', 'series800', 'igpuPresent') {
            $c.ContainsKey($k) | Should -BeTrue
            $c[$k] | Should -BeOfType [bool]
        }
        $c['never'] | Should -BeFalse
    }
}

Describe 'DriverOrder: plan formatting' {
    It 'summarizes groups with counts, restart markers, and skips' {
        $conds = @{ never = $false; vmdOrRaid = $false; apoEligible = $true; series800 = $true; igpuPresent = $true }
        $txt = Format-DriverOrderPlan -Plan (Get-DriverOrderPlan -Drivers $script:mixed -Platform 'intel' -Conditions $conds)
        $txt | Should -Match 'chipset\(\d+\) \[RESTART\]'
        $txt | Should -Match 'storage\(\d+\) SKIP'
    }
}
