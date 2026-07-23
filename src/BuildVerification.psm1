# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# BuildVerification.psm1 - stage 4: the build's pass/fail gate, run after the
# vendor drivers are on (docs/windows-update-strategy.md, verification pass):
#   1. Final WU scan: expect ZERO driver-class offers. Any driver re-offer
#      means WU thinks its package outranks ours (the CHID/broad-targeting
#      GPU-downgrade hole, acknowledged by Microsoft, fix enforces ~Q1 2027) -
#      hide THAT update per-update (never blanket-block) and record the SKU.
#   2. Device Manager audit: zero problem devices (ConfigManagerErrorCode 0).
#   3. No pending reboot.
# Verdict: Pass / Degraded (hidden re-offers or non-driver residue) /
# Fail (problem devices or pending reboot). State marker on Pass/Degraded.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'WindowsUpdateRun.psm1')

function Get-ProblemDevices {
    <#
        .SYNOPSIS
        Devices with a Device Manager problem code (splats). Pass -Devices to
        inject for tests; otherwise queries Win32_PnPEntity. Returns
        { Name; ErrorCode; DeviceID } per problem device.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()] $Devices)

    if ($null -eq $Devices) {
        try {
            $Devices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop
        } catch {
            Write-Log "Problem-device query failed: $($_.Exception.Message)" -Level Warn
            return @()
        }
    }

    return @($Devices | Where-Object {
        $_.PSObject.Properties['ConfigManagerErrorCode'] -and
        $null -ne $_.ConfigManagerErrorCode -and
        [int]$_.ConfigManagerErrorCode -ne 0
    } | ForEach-Object {
        [pscustomobject]@{
            Name      = [string]$_.Name
            ErrorCode = [int]$_.ConfigManagerErrorCode
            DeviceID  = [string]$_.DeviceID
        }
    })
}

function Hide-DriverOffers {
    <#
        .SYNOPSIS
        Hides driver-class updates from a WUA scan result so WU cannot swap a
        vendor driver back out (per-update hiding, the researched policy - the
        machine ships with WU driver offers otherwise ENABLED). Returns the
        titles hidden. Honors rehearsal (logs would-hide, touches nothing).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Updates)

    $hidden = @()
    for ($i = 0; $i -lt $Updates.Count; $i++) {
        $u = $Updates.Item($i)
        if ([int]$u.Type -ne 2) { continue }   # UpdateType 2 = Driver
        $title = [string]$u.Title
        if (Test-Rehearsal) {
            Write-Log ("REHEARSE: would hide re-offered driver update: {0}" -f $title) -Level Info -Data @{ title = $title }
            $hidden += $title
            continue
        }
        if ($PSCmdlet.ShouldProcess($title, 'hide Windows Update driver offer')) {
            try {
                $u.IsHidden = $true
                Write-Log ("Hid re-offered driver update: {0} (record this SKU/driver pairing for the deviation log)" -f $title) -Level Warn -Data @{ title = $title }
                $hidden += $title
            } catch {
                Write-Log ("Could not hide '{0}': {1}" -f $title, $_.Exception.Message) -Level Warn
            }
        }
    }
    return $hidden
}

function Invoke-BuildVerification {
    <#
        .SYNOPSIS
        Runs the stage-4 gate and returns { Status; Detail; ProblemDevices;
        HiddenOffers }. Status: Pass | Degraded | Fail | Skipped | Blocked.
        Marks state on Pass/Degraded so completed builds skip re-verification
        (delete state.json to redo).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $result = [pscustomobject]@{ Status = $null; Detail = $null; ProblemDevices = @(); HiddenOffers = @() }
    $state = Get-FirstBootState
    if ($state.PSObject.Properties['buildVerification'] -and $state.buildVerification.completed) {
        Write-Log "Build verification already passed on $($state.buildVerification.when); skipping." -Level Info
        $result.Status = 'Skipped'; $result.Detail = 'state marker present'
        return $result
    }

    $notes = @()

    # 1) WU re-offer check (deliberate scan works under any policy state).
    Write-Log 'Verification: scanning Windows Update for driver re-offers...' -Level Info
    $scan = Get-WindowsUpdateScan
    if (-not $scan.Ok) {
        Write-Log "Verification: WUA scan unavailable ($($scan.Error))." -Level Warn
        $notes += "WU scan unavailable: $($scan.Error)"
    } else {
        if ($scan.DriverCount -gt 0) {
            Write-Log ("Verification: {0} driver-class offer(s) present - WU believes it outranks an installed driver (CHID/broad-targeting case). Hiding per-update." -f $scan.DriverCount) -Level Warn
            $result.HiddenOffers = @(Hide-DriverOffers -Updates $scan.Updates)
            $notes += "$(@($result.HiddenOffers).Count) driver offer(s) hidden"
        } else {
            Write-Log 'Verification: zero driver-class offers - vendor drivers hold rank.' -Level Success
        }
        $nonDriver = [int]$scan.Count - [int]$scan.DriverCount
        if ($nonDriver -gt 0) {
            Write-Log ("Verification: {0} non-driver update(s) still offered (residue; stage 2 handles installs - flag only here)." -f $nonDriver) -Level Warn
            $notes += "$nonDriver non-driver residue"
        }
    }

    # 2) Device Manager splat audit.
    Write-Log 'Verification: auditing Device Manager for problem devices...' -Level Info
    $problems = @(Get-ProblemDevices)
    $result.ProblemDevices = $problems
    foreach ($p in $problems) {
        Write-Log ("  PROBLEM device (code {0}): {1} [{2}]" -f $p.ErrorCode, $p.Name, $p.DeviceID) -Level Error
    }
    if ($problems.Count -eq 0) {
        Write-Log 'Verification: zero problem devices.' -Level Success
    }

    # 3) Pending reboot.
    $pending = Get-PendingRebootStatus
    if ($pending.Pending) {
        Write-Log ("Verification: reboot pending ({0})." -f ($pending.Reasons -join ', ')) -Level Warn
        $notes += "pending reboot: $($pending.Reasons -join ', ')"
    }

    # Verdict.
    if ($problems.Count -gt 0 -or $pending.Pending) {
        $result.Status = 'Fail'
        $result.Detail = ("{0} problem device(s){1}{2}" -f $problems.Count, `
            $(if ($pending.Pending) { '; reboot pending' } else { '' }), `
            $(if ($notes) { '; ' + ($notes -join '; ') } else { '' }))
        Write-Log "BUILD VERIFICATION: FAIL - $($result.Detail)" -Level Error
        return $result
    }

    $result.Status = if (@($result.HiddenOffers).Count -gt 0 -or $notes) { 'Degraded' } else { 'Pass' }
    $result.Detail = if ($notes) { $notes -join '; ' } else { 'clean' }

    if (-not (Test-Rehearsal)) {
        Set-FirstBootStateValue -Name 'buildVerification' -Value @{
            completed = $true; status = [string]$result.Status
            hiddenOffers = @($result.HiddenOffers)
            when = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        } | Out-Null
    }
    Write-Log ("BUILD VERIFICATION: {0} ({1})" -f $result.Status.ToUpperInvariant(), $result.Detail) -Level Success
    return $result
}

Export-ModuleMember -Function Get-ProblemDevices, Hide-DriverOffers, Invoke-BuildVerification
