# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Common.psm1') -Force
    Import-Module (Join-Path $src 'WindowsUpdateRun.psm1') -Force
    Import-Module (Join-Path $src 'BuildVerification.psm1') -Force
}

AfterAll { Disable-Rehearsal }

Describe 'Verification: problem-device audit' {
    It 'flags only devices with a non-zero ConfigManagerErrorCode' {
        $devices = @(
            [pscustomobject]@{ Name = 'Fine Device';   ConfigManagerErrorCode = 0;  DeviceID = 'PCI\OK' }
            [pscustomobject]@{ Name = 'Broken Device'; ConfigManagerErrorCode = 28; DeviceID = 'PCI\BAD' }
            [pscustomobject]@{ Name = 'No Code';       ConfigManagerErrorCode = $null; DeviceID = 'PCI\NULL' }
        )
        $problems = @(Get-ProblemDevices -Devices $devices)
        $problems.Count | Should -Be 1
        $problems[0].Name | Should -Be 'Broken Device'
        $problems[0].ErrorCode | Should -Be 28
    }
    It 'returns empty for a clean device list' {
        @(Get-ProblemDevices -Devices @([pscustomobject]@{ Name = 'x'; ConfigManagerErrorCode = 0; DeviceID = 'y' })).Count | Should -Be 0
    }
}

Describe 'Verification: Invoke-BuildVerification' {
    BeforeAll {
        Mock -ModuleName BuildVerification Set-FirstBootStateValue { }
    }

    It 'skips when the state marker is present' {
        Mock -ModuleName BuildVerification Get-FirstBootState {
            [pscustomobject]@{ buildVerification = [pscustomobject]@{ completed = $true; when = '2026-07-23' } }
        }
        (Invoke-BuildVerification).Status | Should -Be 'Skipped'
    }

    It 'passes clean: no offers, no splats, no pending reboot' {
        Mock -ModuleName BuildVerification Get-FirstBootState { [pscustomobject]@{} }
        Mock -ModuleName BuildVerification Get-WindowsUpdateScan {
            [pscustomobject]@{ Ok = $true; Count = 0; DriverCount = 0; Titles = @(); Updates = $null; Error = $null }
        }
        Mock -ModuleName BuildVerification Get-ProblemDevices { @() }
        Mock -ModuleName BuildVerification Get-PendingRebootStatus { [pscustomobject]@{ Pending = $false; Reasons = @() } }
        $r = Invoke-BuildVerification
        $r.Status | Should -Be 'Pass'
        Should -Invoke -ModuleName BuildVerification Set-FirstBootStateValue -Times 1 -Exactly
    }

    It 'fails on problem devices' {
        Mock -ModuleName BuildVerification Get-FirstBootState { [pscustomobject]@{} }
        Mock -ModuleName BuildVerification Get-WindowsUpdateScan {
            [pscustomobject]@{ Ok = $true; Count = 0; DriverCount = 0; Titles = @(); Updates = $null; Error = $null }
        }
        Mock -ModuleName BuildVerification Get-ProblemDevices {
            @([pscustomobject]@{ Name = 'Unknown device'; ErrorCode = 28; DeviceID = 'USB\X' })
        }
        Mock -ModuleName BuildVerification Get-PendingRebootStatus { [pscustomobject]@{ Pending = $false; Reasons = @() } }
        $r = Invoke-BuildVerification
        $r.Status | Should -Be 'Fail'
        $r.Detail | Should -Match '1 problem device'
        @($r.ProblemDevices).Count | Should -Be 1
    }

    Context 'rehearsal: driver re-offer handling' {
        BeforeAll { Enable-Rehearsal }
        AfterAll { Disable-Rehearsal }

        It 'reports would-hide for driver offers without touching WU or state' {
            Mock -ModuleName BuildVerification Get-FirstBootState { [pscustomobject]@{} }
            # Fake COM-ish collection: Count + Item(i) with Type/Title.
            $fakeUpdates = New-Object psobject
            $fakeUpdates | Add-Member -MemberType NoteProperty -Name Count -Value 2
            $fakeUpdates | Add-Member -MemberType ScriptMethod -Name Item -Value {
                param($i)
                @(
                    [pscustomobject]@{ Type = 2; Title = 'Some OEM Graphics Driver 30.0' }
                    [pscustomobject]@{ Type = 1; Title = 'Some Software Update' }
                )[$i]
            }
            Mock -ModuleName BuildVerification Get-WindowsUpdateScan {
                [pscustomobject]@{ Ok = $true; Count = 2; DriverCount = 1; Titles = @('a', 'b'); Updates = $fakeUpdates; Error = $null }
            }
            Mock -ModuleName BuildVerification Get-ProblemDevices { @() }
            Mock -ModuleName BuildVerification Get-PendingRebootStatus { [pscustomobject]@{ Pending = $false; Reasons = @() } }
            $r = Invoke-BuildVerification
            $r.Status | Should -Be 'Degraded'
            @($r.HiddenOffers).Count | Should -Be 1
            $r.HiddenOffers[0] | Should -Match 'Graphics Driver'
            Should -Invoke -ModuleName BuildVerification Set-FirstBootStateValue -Times 0 -Exactly
        }
    }
}
