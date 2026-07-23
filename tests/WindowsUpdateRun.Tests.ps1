# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Common.psm1') -Force
    Import-Module (Join-Path $src 'WindowsPrep.psm1') -Force
    Import-Module (Join-Path $src 'WindowsUpdateRun.psm1') -Force
}

AfterAll { Disable-Rehearsal }

Describe 'WU run: pending-reboot detection' {
    It 'returns the expected shape (read-only registry checks)' {
        $s = Get-PendingRebootStatus
        $s.PSObject.Properties['Pending'] | Should -Not -BeNullOrEmpty
        $s.Pending | Should -BeOfType [bool]
        ($s.Reasons -is [System.Array]) | Should -BeTrue   # array, possibly empty
    }
}

Describe 'WU run: Invoke-WindowsUpdateStage' {
    BeforeAll {
        # Never touch WU/COM or mutate anything from tests.
        Mock -ModuleName WindowsUpdateRun Restore-WindowsUpdate { throw 'must not release hold in tests' }
        Mock -ModuleName WindowsUpdateRun Install-ScannedUpdates { throw 'must not install in tests' }
        Mock -ModuleName WindowsUpdateRun Register-ResumeAfterReboot { throw 'must not register RunOnce in tests' }
        Mock -ModuleName WindowsUpdateRun Restart-ForWindowsUpdate { throw 'must not reboot in tests' }
    }

    It 'skips when the state marker says the stage completed' {
        Mock -ModuleName WindowsUpdateRun Get-FirstBootState {
            [pscustomobject]@{ windowsUpdateRun = [pscustomobject]@{ completed = $true; cycles = 2; when = '2026-07-23' } }
        }
        $r = Invoke-WindowsUpdateStage
        $r.Status | Should -Be 'Skipped'
        $r.RebootRequested | Should -BeFalse
    }

    Context 'rehearsal' {
        BeforeAll { Enable-Rehearsal }
        AfterAll { Disable-Rehearsal }

        It 'reports the live offer count and mutates nothing' {
            Mock -ModuleName WindowsUpdateRun Get-FirstBootState {
                [pscustomobject]@{ windowsUpdatePrior = [pscustomobject]@{ NoAutoUpdate = $null } }
            }
            Mock -ModuleName WindowsUpdateRun Get-PendingRebootStatus {
                [pscustomobject]@{ Pending = $false; Reasons = @() }
            }
            Mock -ModuleName WindowsUpdateRun Get-WindowsUpdateScan {
                [pscustomobject]@{ Ok = $true; Count = 3; DriverCount = 1; Titles = @('KB1', 'KB2', 'Driver X'); Updates = $null; Error = $null }
            }
            $r = Invoke-WindowsUpdateStage
            $r.Status | Should -Be 'Rehearsed'
            $r.Detail | Should -Match '3 update'
            $r.RebootRequested | Should -BeFalse
            Should -Invoke -ModuleName WindowsUpdateRun Restore-WindowsUpdate -Times 0 -Exactly
            Should -Invoke -ModuleName WindowsUpdateRun Install-ScannedUpdates -Times 0 -Exactly
            Should -Invoke -ModuleName WindowsUpdateRun Register-ResumeAfterReboot -Times 0 -Exactly
        }

        It 'degrades gracefully when the WUA scan is unavailable' {
            Mock -ModuleName WindowsUpdateRun Get-FirstBootState { [pscustomobject]@{} }
            Mock -ModuleName WindowsUpdateRun Get-PendingRebootStatus {
                [pscustomobject]@{ Pending = $false; Reasons = @() }
            }
            Mock -ModuleName WindowsUpdateRun Get-WindowsUpdateScan {
                [pscustomobject]@{ Ok = $false; Count = $null; DriverCount = $null; Titles = @(); Updates = $null; Error = 'service unavailable' }
            }
            $r = Invoke-WindowsUpdateStage
            $r.Status | Should -Be 'Rehearsed'
            $r.Detail | Should -Match 'scan unavailable'
        }

        It 'Register-ResumeAfterReboot only logs under rehearsal' {
            { Register-ResumeAfterReboot } | Should -Not -Throw
        }
    }
}
