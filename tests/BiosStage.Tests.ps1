# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Common.psm1') -Force
    Import-Module (Join-Path $src 'Install-Chrome.psm1') -Force
    Import-Module (Join-Path $src 'Install-Engine.psm1') -Force
    Import-Module (Join-Path $src 'WindowsPrep.psm1') -Force
    Import-Module (Join-Path $src 'BiosUpdate.psm1') -Force
}

AfterAll { Disable-Rehearsal }

Describe 'BIOS: beta filter + latest pick' {
    It 'flags beta by name or version' {
        Test-BetaBios -Entry ([pscustomobject]@{ Name = 'BIOS 9902 Beta Version'; Version = '9902' }) | Should -BeTrue
        Test-BetaBios -Entry ([pscustomobject]@{ Name = 'BIOS'; Version = '2103-beta' }) | Should -BeTrue
        Test-BetaBios -Entry ([pscustomobject]@{ Name = 'BIOS 2103'; Version = '2103' }) | Should -BeFalse
    }

    It 'picks the highest numeric version among non-beta entries' {
        $entries = @(
            [pscustomobject]@{ Name = 'BIOS 9902 Beta Version'; Version = '9902' }
            [pscustomobject]@{ Name = 'BIOS 2004'; Version = '2004' }
            [pscustomobject]@{ Name = 'BIOS 2103'; Version = '2103' }
        )
        (Select-LatestBios -Entries $entries).Version | Should -Be '2103'
    }

    It 'falls back to vendor (newest-first) order when versions do not parse' {
        $entries = @(
            [pscustomobject]@{ Name = 'BIOS F12a'; Version = 'F12a' }
            [pscustomobject]@{ Name = 'BIOS F11';  Version = 'F11' }
        )
        (Select-LatestBios -Entries $entries).Version | Should -Be 'F12a'
    }

    It 'returns $null when everything is beta or the list is empty' {
        Select-LatestBios -Entries @([pscustomobject]@{ Name = 'Beta only'; Version = '1 beta' }) | Should -BeNullOrEmpty
        Select-LatestBios -Entries @() | Should -BeNullOrEmpty
    }

    It 'falls back to vendor order when version formats are mixed (audit #12 regression)' {
        $entries = @(
            [pscustomobject]@{ Name = 'BIOS 2103'; Version = '2103' }
            [pscustomobject]@{ Name = 'BIOS 1.10'; Version = '1.10' }
        )
        # Mixed integer + dotted formats are incomparable: trust newest-first.
        (Select-LatestBios -Entries $entries).Version | Should -Be '2103'
        $reversed = @($entries[1], $entries[0])
        (Select-LatestBios -Entries $reversed).Version | Should -Be '1.10'
    }
}

Describe 'BIOS: firmware file discovery' {
    BeforeAll {
        $script:root = Join-Path ([IO.Path]::GetTempPath()) ("fb_fw_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:root 'nested') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $script:root 'nested\BOARD.CAP'), (New-Object byte[] 4096))
        [IO.File]::WriteAllBytes((Join-Path $script:root 'B650GX.F12'), (New-Object byte[] 8192))
        [IO.File]::WriteAllText((Join-Path $script:root 'readme.txt'), 'not firmware')
        [IO.File]::WriteAllText((Join-Path $script:root 'Renamer.exe'), 'MZ tool')
    }
    AfterAll { Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'finds firmware files by extension, preferring the largest' {
        (Find-FirmwareFile -Root $script:root).Name | Should -Be 'B650GX.F12'
    }
    It 'returns $null when the tree has no firmware file' {
        $empty = Join-Path ([IO.Path]::GetTempPath()) ("fb_fw_e_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        try { Find-FirmwareFile -Root $empty | Should -BeNullOrEmpty }
        finally { Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'BIOS: staging root' {
    It 'stages under ProgramData when not running from removable media' {
        # The test checkout sits on a fixed disk.
        (Get-BiosStagingRoot) | Should -Match '\\bios$'
    }
}

Describe 'BIOS: Invoke-BiosStage rehearsal flow' {
    BeforeAll {
        Enable-Rehearsal
        $script:board = [pscustomobject]@{ Vendor = 'asus'; Model = 'TEST BOARD'; Manufacturer = 'Test Inc.'; Version = '' }
        $script:provider = [pscustomobject]@{
            GetFallbackUrl = { param($Identity, $Model) 'https://vendor.example/supportonly/TEST/helpdesk_download/' }
        }
    }
    AfterAll { Disable-Rehearsal }

    It 'skips when the state marker says the stage already completed' {
        Mock -ModuleName BiosUpdate Get-FirstBootState {
            [pscustomobject]@{ biosStage = [pscustomobject]@{ completed = $true; when = '2026-07-23'; version = '2103' } }
        }
        $r = Invoke-BiosStage -Board $script:board -Provider $script:provider -Identity $null -RawDrivers @()
        $r.Status | Should -Be 'Skipped'
        $r.RebootRequested | Should -BeFalse
    }

    It 'rehearses the happy path: picks latest non-beta, probes, plans staging + UEFI reboot' {
        Mock -ModuleName BiosUpdate Get-FirstBootState { [pscustomobject]@{} }
        Mock -ModuleName BiosUpdate Test-HostReachable { $true }
        Mock -ModuleName BiosUpdate Invoke-HttpProbe {
            [pscustomobject]@{ Url = $Url; Ok = $true; StatusCode = 200; SizeBytes = 20MB; FinalUrl = $Url; Via = 'HEAD'; Error = $null }
        }
        Mock -ModuleName BiosUpdate Save-BiosPackage { throw 'must not download in rehearsal' }
        $raw = @(
            [pscustomobject]@{ Category = 'BIOS'; Name = 'BIOS 9902 Beta Version'; Version = '9902'; Url = 'https://vendor.example/b9902.zip' }
            [pscustomobject]@{ Category = 'BIOS'; Name = 'BIOS 2103'; Version = '2103'; Url = 'https://vendor.example/b2103.zip' }
            [pscustomobject]@{ Category = 'Chipset'; Name = 'Chipset'; Version = '1'; Url = 'https://vendor.example/c.zip' }
        )
        $r = Invoke-BiosStage -Board $script:board -Provider $script:provider -Identity $null -RawDrivers $raw
        $r.Status | Should -Be 'Rehearsed'
        $r.RebootRequested | Should -BeFalse
        Should -Invoke -ModuleName BiosUpdate Save-BiosPackage -Times 0 -Exactly
    }

    It 'falls back to the support page when the vendor list has no BIOS entries' {
        Mock -ModuleName BiosUpdate Get-FirstBootState { [pscustomobject]@{} }
        Mock -ModuleName BiosUpdate Test-HostReachable { $true }
        $raw = @([pscustomobject]@{ Category = 'Chipset'; Name = 'Chipset'; Version = '1'; Url = 'https://vendor.example/c.zip' })
        $r = Invoke-BiosStage -Board $script:board -Provider $script:provider -Identity $null -RawDrivers $raw
        $r.Status | Should -Be 'Fallback'
        $r.RebootRequested | Should -BeFalse
    }

    It 'reports Blocked when offline and no LAN drivers are staged' {
        Mock -ModuleName BiosUpdate Get-FirstBootState { [pscustomobject]@{} }
        Mock -ModuleName BiosUpdate Test-HostReachable { $false }
        $r = Invoke-BiosStage -Board $script:board -Provider $script:provider -Identity $null -RawDrivers @()
        $r.Status | Should -Be 'Blocked'
        $r.Detail | Should -Match 'offline'
    }

    It 'probes the mirror host when the mirror supplied the drivers (audit #4 regression)' {
        Mock -ModuleName BiosUpdate Get-FirstBootState { [pscustomobject]@{} }
        Mock -ModuleName BiosUpdate Test-HostReachable { param($TargetHost) $TargetHost -eq '10.0.0.10' }
        # No provider object (mirror-fed run), mirror reachable, no BIOS entries
        # -> must land on Fallback, NOT the false-offline Blocked path.
        $r = Invoke-BiosStage -Board $script:board -Provider $null -Identity $null -RawDrivers @() -MirrorBase 'http://10.0.0.10:8080'
        $r.Status | Should -Be 'Fallback'
    }

    It 'does not mark complete when the UEFI reboot fails (audit #7 regression)' {
        # Real-path behavior: rehearsal must be OFF for this one.
        Disable-Rehearsal
        try {
            Mock -ModuleName BiosUpdate Get-FirstBootState { [pscustomobject]@{} }
            Mock -ModuleName BiosUpdate Test-HostReachable { $true }
            Mock -ModuleName BiosUpdate Save-BiosPackage {
                [pscustomobject]@{ FirmwarePath = 'C:\x\B.CAP'; StagedPath = 'C:\stage\B.CAP'; SizeBytes = 1024 }
            }
            Mock -ModuleName BiosUpdate Restart-ToFirmware { $false }
            $script:written = $null
            Mock -ModuleName BiosUpdate Set-FirstBootStateValue { param($Name, $Value) $script:written = $Value }
            $raw = @([pscustomobject]@{ Category = 'BIOS'; Name = 'BIOS 2103'; Version = '2103'; Url = 'https://vendor.example/b2103.zip' })
            $r = Invoke-BiosStage -Board $script:board -Provider $script:provider -Identity $null -RawDrivers $raw
            $r.Status | Should -Be 'StagedManualReboot'
            $r.RebootRequested | Should -BeFalse
            $script:written.completed | Should -BeFalse
            $script:written.stagedButNotRebooted | Should -BeTrue
        } finally { Enable-Rehearsal }
    }

    It 'Restart-ToFirmware only logs under rehearsal' {
        Restart-ToFirmware | Should -BeTrue
    }
}

Describe 'WindowsPrep: rehearsal emulates, mutates nothing' {
    BeforeAll {
        Enable-Rehearsal
        Mock -ModuleName WindowsPrep Set-RegistryDword { throw 'must not write registry in rehearsal' }
        Mock -ModuleName WindowsPrep Set-FirstBootStateValue { throw 'must not write state in rehearsal' }
    }
    AfterAll { Disable-Rehearsal }

    It 'WU guard rehearses without touching registry/services/state' {
        $r = Disable-WindowsUpdateTemporarily
        $r.Status | Should -Be 'Rehearsed'
        Should -Invoke -ModuleName WindowsPrep Set-RegistryDword -Times 0 -Exactly
        Should -Invoke -ModuleName WindowsPrep Set-FirstBootStateValue -Times 0 -Exactly
    }

    It 'UAC disable rehearses without touching registry/state' {
        $r = Disable-Uac
        $r.Status | Should -Be 'Rehearsed'
        Should -Invoke -ModuleName WindowsPrep Set-RegistryDword -Times 0 -Exactly
    }

    It 'Invoke-WindowsPrep returns both step results' {
        $rs = @(Invoke-WindowsPrep)
        $rs.Count | Should -Be 2
        @($rs | Where-Object { $_.Status -eq 'Rehearsed' }).Count | Should -Be 2
    }

    It 'restores report Skipped when no priors were captured' {
        Mock -ModuleName WindowsPrep Get-FirstBootState { [pscustomobject]@{} }
        (Restore-WindowsUpdate).Status | Should -Be 'Skipped'
        (Restore-Uac).Status | Should -Be 'Skipped'
    }
}
