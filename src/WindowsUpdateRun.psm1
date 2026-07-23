# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# WindowsUpdateRun.psm1 - stage 2: let Windows Update run its FULL course
# (post-BIOS), so all of its updates and generic drivers land BEFORE the shop's
# vendor drivers replace them (docs/windows-update-strategy.md). Uses the
# in-box, documented WUA COM API (Microsoft.Update.Session) - never UsoClient,
# no PSWindowsUpdate dependency on targets.
#
# "Fully done" is the dual condition: a fresh scan returns ZERO applicable
# non-hidden updates AND no reboot is pending. The stage loops
# scan -> install -> reboot (resuming via RunOnce) until both hold, with a
# max-cycle guard, then writes the state marker so re-runs skip straight to
# the driver pipeline.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'WindowsPrep.psm1')

function Get-PendingRebootStatus {
    <#
        .SYNOPSIS
        Windows' pending-reboot indicators: CBS RebootPending, WU RebootRequired,
        and PendingFileRenameOperations. Returns { Pending; Reasons }.
    #>
    [CmdletBinding()]
    param()

    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'CBS RebootPending'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'WU RebootRequired'
    }
    try {
        $pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name 'PendingFileRenameOperations' -ErrorAction Stop).PendingFileRenameOperations
        if ($pfro) { $reasons += 'PendingFileRenameOperations' }
    } catch { }

    return [pscustomobject]@{ Pending = ($reasons.Count -gt 0); Reasons = $reasons }
}

function Get-WindowsUpdateScan {
    <#
        .SYNOPSIS
        One deliberate WUA scan (works even under the NoAutoUpdate hold) for
        applicable, non-hidden updates. Returns
        { Ok; Count; DriverCount; Titles; Updates (raw COM); Error }.
    #>
    [CmdletBinding()]
    param()

    try {
        $session = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
        $titles = @()
        $driverCount = 0
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u = $result.Updates.Item($i)
            $titles += [string]$u.Title
            if ([int]$u.Type -eq 2) { $driverCount++ }   # UpdateType: 1=Software, 2=Driver
        }
        return [pscustomobject]@{
            Ok = $true; Count = [int]$result.Updates.Count; DriverCount = $driverCount
            Titles = $titles; Updates = $result.Updates; Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Ok = $false; Count = $null; DriverCount = $null
            Titles = @(); Updates = $null; Error = $_.Exception.Message
        }
    }
}

function Install-ScannedUpdates {
    <#
        .SYNOPSIS
        Accepts EULAs, downloads and installs a WUA update collection. Returns
        { Installed; Failed; RebootRequired; ResultCode }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Updates)

    $result = [pscustomobject]@{ Installed = 0; Failed = 0; RebootRequired = $false; ResultCode = $null }
    if (-not $PSCmdlet.ShouldProcess('Windows Update', "download + install $($Updates.Count) update(s)")) {
        return $result
    }

    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $toInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    for ($i = 0; $i -lt $Updates.Count; $i++) {
        $u = $Updates.Item($i)
        if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
        $toInstall.Add($u) | Out-Null
    }

    Write-Log "Downloading $($toInstall.Count) Windows update(s)..." -Level Info
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $toInstall
    $downloader.Download() | Out-Null

    Write-Log "Installing $($toInstall.Count) Windows update(s)..." -Level Info
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $toInstall
    $installResult = $installer.Install()

    $result.ResultCode = [int]$installResult.ResultCode        # 2=Succeeded, 3=SucceededWithErrors
    $result.RebootRequired = [bool]$installResult.RebootRequired
    for ($i = 0; $i -lt $toInstall.Count; $i++) {
        if ([int]$installResult.GetUpdateResult($i).ResultCode -in 2, 3) { $result.Installed++ } else { $result.Failed++ }
    }
    Write-Log ("Windows updates installed: {0} ok, {1} failed, reboot required: {2}" -f `
        $result.Installed, $result.Failed, $result.RebootRequired) -Level $(if ($result.Failed -eq 0) { 'Success' } else { 'Warn' })
    return $result
}

function Register-ResumeAfterReboot {
    <#
        .SYNOPSIS
        Writes a RunOnce entry so the next boot re-launches bootstrap -Install
        and the pipeline resumes unattended after a WU-driven restart.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $bootstrap = Join-Path (Get-FirstBootRoot) 'bootstrap.ps1'
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Install' -f $bootstrap
    if (Test-Rehearsal) {
        Write-Log ("REHEARSE: would register RunOnce resume: {0}" -f $cmd) -Level Info -Data @{ runOnce = $cmd }
        return
    }
    if ($PSCmdlet.ShouldProcess('HKLM RunOnce', "resume via: $cmd")) {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name 'CEC-Autosetup-Resume' -Value $cmd
        Write-Log 'RunOnce resume registered (next boot re-runs the pipeline).' -Level Info
    }
}

function Restart-ForWindowsUpdate {
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $DelaySeconds = 10)
    if (Test-Rehearsal) {
        Write-Log ("REHEARSE: would run: shutdown.exe /r /t {0} (Windows Update reboot, pipeline resumes via RunOnce)" -f $DelaySeconds) -Level Info
        return $true
    }
    if ($PSCmdlet.ShouldProcess('this machine', "restart for Windows Update in $DelaySeconds s")) {
        & shutdown.exe /r /t $DelaySeconds /c 'firstboot: restarting to continue Windows Update'
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

function Invoke-WindowsUpdateStage {
    <#
        .SYNOPSIS
        Stage 2: release the stage-1 hold and drive Windows Update to true
        completion (zero applicable updates AND no pending reboot), rebooting
        + resuming as needed. Marks state when dry so re-runs fall through to
        the driver pipeline. Returns { Status; Detail; RebootRequested }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $MaxCycles = 8)

    $result = [pscustomobject]@{ Status = $null; Detail = $null; RebootRequested = $false }
    $state = Get-FirstBootState

    if ($state.PSObject.Properties['windowsUpdateRun'] -and $state.windowsUpdateRun.completed) {
        Write-Log "Windows Update stage already completed on $($state.windowsUpdateRun.when); skipping." -Level Info
        $result.Status = 'Skipped'; $result.Detail = 'state marker present'
        return $result
    }

    $pending = Get-PendingRebootStatus

    if (Test-Rehearsal) {
        $holdActive = [bool]$state.PSObject.Properties['windowsUpdatePrior']
        Write-Log 'REHEARSE: scanning Windows Update (deliberate WUA scan; can take a minute)...' -Level Info
        $scan = Get-WindowsUpdateScan
        if ($scan.Ok) {
            Write-Log ("REHEARSE: WU currently offers {0} applicable update(s) ({1} driver-class); pending reboot: {2}{3}" -f `
                $scan.Count, $scan.DriverCount, $pending.Pending, $(if ($pending.Pending) { " ($($pending.Reasons -join ', '))" } else { '' })) -Level Info -Data @{
                count = $scan.Count; driverCount = $scan.DriverCount
                pendingReboot = $pending.Pending; holdActive = $holdActive
            }
            foreach ($t in $scan.Titles) { Write-Log ("  offer: {0}" -f $t) -Level Trace }
            Write-Log ("REHEARSE: would release the WU hold, then loop install->reboot (RunOnce resume) until 0 updates AND no pending reboot (max {0} cycles), then mark state and continue to drivers." -f $MaxCycles) -Level Info
            $result.Detail = "$($scan.Count) update(s) pending, hold active: $holdActive"
        } else {
            Write-Log ("REHEARSE: WUA scan unavailable ({0}); a real run would release the hold first and retry." -f $scan.Error) -Level Warn
            $result.Detail = "scan unavailable: $($scan.Error)"
        }
        $result.Status = 'Rehearsed'
        return $result
    }

    # Real run: release the hold once (idempotent; Skipped when no priors).
    if ($state.PSObject.Properties['windowsUpdatePrior']) {
        Restore-WindowsUpdate | Out-Null
    }

    if ($pending.Pending) {
        Write-Log ("Reboot already pending ({0}); restarting before scanning." -f ($pending.Reasons -join ', ')) -Level Info
        Register-ResumeAfterReboot
        $result.RebootRequested = Restart-ForWindowsUpdate
        $result.Status = 'RebootRequired'; $result.Detail = 'pre-existing pending reboot'
        return $result
    }

    $cycles = 0
    if ($state.PSObject.Properties['windowsUpdateRun'] -and $state.windowsUpdateRun.PSObject.Properties['cycles']) {
        $cycles = [int]$state.windowsUpdateRun.cycles
    }

    while ($true) {
        Write-Log 'Scanning Windows Update (WUA)...' -Level Info
        $scan = Get-WindowsUpdateScan
        if (-not $scan.Ok) {
            Write-Log "Windows Update scan failed: $($scan.Error)" -Level Error
            $result.Status = 'Blocked'; $result.Detail = "scan failed: $($scan.Error)"
            return $result
        }

        $pending = Get-PendingRebootStatus
        if ($scan.Count -eq 0 -and -not $pending.Pending) {
            Set-FirstBootStateValue -Name 'windowsUpdateRun' -Value @{
                completed = $true; cycles = $cycles; when = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            } | Out-Null
            Write-Log "Windows Update is fully done (0 applicable updates, no pending reboot) after $cycles install cycle(s)." -Level Success
            $result.Status = 'Completed'; $result.Detail = "$cycles cycle(s)"
            return $result
        }

        if ($cycles -ge $MaxCycles) {
            Write-Log "Windows Update still not clean after $MaxCycles cycles ($($scan.Count) update(s) remain); flagging for manual review." -Level Error
            $result.Status = 'Blocked'; $result.Detail = "max cycles reached; $($scan.Count) update(s) remain"
            return $result
        }

        if ($scan.Count -gt 0) {
            $cycles++
            Set-FirstBootStateValue -Name 'windowsUpdateRun' -Value @{ completed = $false; cycles = $cycles } | Out-Null
            Write-Log ("WU cycle {0}/{1}: {2} update(s) ({3} driver-class)." -f $cycles, $MaxCycles, $scan.Count, $scan.DriverCount) -Level Info
            $install = Install-ScannedUpdates -Updates $scan.Updates
            if ($install.RebootRequired) {
                Register-ResumeAfterReboot
                $result.RebootRequested = Restart-ForWindowsUpdate
                $result.Status = 'RebootRequired'; $result.Detail = "cycle $cycles installed $($install.Installed); rebooting"
                return $result
            }
            # No reboot needed: loop straight into the next scan.
            continue
        }

        # Zero updates but a reboot is pending: clear it and resume.
        Register-ResumeAfterReboot
        $result.RebootRequested = Restart-ForWindowsUpdate
        $result.Status = 'RebootRequired'; $result.Detail = "pending reboot ($($pending.Reasons -join ', '))"
        return $result
    }
}

Export-ModuleMember -Function `
    Get-PendingRebootStatus, Get-WindowsUpdateScan, Install-ScannedUpdates, `
    Register-ResumeAfterReboot, Restart-ForWindowsUpdate, Invoke-WindowsUpdateStage
