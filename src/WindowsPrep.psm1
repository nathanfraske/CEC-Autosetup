# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# WindowsPrep.psm1 - stage-1 "make Windows behave during provisioning":
#   1. Temporarily hold Windows Update (services + policies) BEFORE it can
#      auto-grab anything, so nothing half-bakes while BIOS is updated.
#      This is a SHORT hold, not a blanket disable: shop practice is to
#      restore WU right after the BIOS stage, let it run FULLY (inbox drivers
#      and all), and only then lay the vendor drivers over Windows' defaults.
#   2. Disable UAC for the unattended provisioning window (effective on the
#      stage's reboot). The preferred permanent home for this is
#      autounattend.xml (see docs/autounattend.md); this runtime path covers
#      images that don't carry the setting yet.
# Every change captures the PRIOR value into cross-boot state (state.json) so
# Restore-WindowsUpdate / Restore-Uac can put things back faithfully in the
# post-BIOS stage. All actions honor -WhatIf and rehearsal mode.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

# Hold mechanics per docs/windows-update-strategy.md (researched 2026-07-23):
# the SUPPORTED hold is the policy pair below. Services are stopped once to
# cancel in-flight work but NEVER disabled (WaaSMedic re-enables disabled
# update services on its own schedule - unpredictable expiry is exactly the
# nondeterminism this stage exists to remove). No SearchOrderConfig either -
# that is the blunter device-installation knob and is not needed for the hold.
$script:WuPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:WuAuKey     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:UacKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$script:WuServices  = @('wuauserv', 'UsoSvc')

function Get-RegistryValueOrNull {
    # Prior-value capture helper: the value data, or $null when absent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Name
    )
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch { return $null }
}

function Set-RegistryDword {
    # Mockable wrapper: ensures the key exists and writes a DWord value.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $Value
    )
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "set DWord $Value")) {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord
    }
}

function Disable-WindowsUpdateTemporarily {
    <#
        .SYNOPSIS
        Holds Windows Update with the SUPPORTED policy pair - NoAutoUpdate=1
        (no automatic scan/download/install) and
        ExcludeWUDriversInQualityUpdate=1 (no driver-class offers) - and stops
        wuauserv/UsoSvc once to cancel in-flight work (never disables them).
        Prior values land in state.json under 'windowsUpdatePrior' for
        Restore-WindowsUpdate. See docs/windows-update-strategy.md.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $result = [pscustomobject]@{ Step = 'windows-update-guard'; Status = $null; Detail = $null }

    if (Test-Rehearsal) {
        $svcNow = @($script:WuServices | ForEach-Object {
            $s = Get-Service -Name $_ -ErrorAction SilentlyContinue
            if ($s) { "$($_)=$($s.Status)/$($s.StartType)" } else { "$($_)=absent" }
        }) -join ', '
        Write-Log ("REHEARSE: would set {0}\AU NoAutoUpdate=1 and {0} ExcludeWUDriversInQualityUpdate=1 (supported policy pair), and stop (not disable) [{1}] to cancel in-flight work (currently: {2}); priors -> state.json" -f `
            $script:WuPolicyKey, ($script:WuServices -join ', '), $svcNow) -Level Info -Data @{
            keys = @("$script:WuAuKey\NoAutoUpdate=1",
                     "$script:WuPolicyKey\ExcludeWUDriversInQualityUpdate=1")
            services = $svcNow
        }
        $result.Status = 'Rehearsed'; $result.Detail = 'WU hold emulated'
        return $result
    }

    try {
        # Capture priors first so a partial failure still leaves a restore map.
        # Capture ONCE: on a re-run after the hold is already applied, the live
        # values are our own - overwriting the map would break the restore.
        if (-not (Get-FirstBootState).PSObject.Properties['windowsUpdatePrior']) {
            $prior = @{
                NoAutoUpdate                    = Get-RegistryValueOrNull -Path $script:WuAuKey     -Name 'NoAutoUpdate'
                ExcludeWUDriversInQualityUpdate = Get-RegistryValueOrNull -Path $script:WuPolicyKey -Name 'ExcludeWUDriversInQualityUpdate'
            }
            Set-FirstBootStateValue -Name 'windowsUpdatePrior' -Value $prior | Out-Null
        }

        Set-RegistryDword -Path $script:WuAuKey     -Name 'NoAutoUpdate' -Value 1
        Set-RegistryDword -Path $script:WuPolicyKey -Name 'ExcludeWUDriversInQualityUpdate' -Value 1

        foreach ($svc in $script:WuServices) {
            if ($PSCmdlet.ShouldProcess($svc, 'stop service (cancel in-flight work; not disabled)')) {
                try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch { }
            }
        }

        Write-Log 'Windows Update held: auto-updates off + driver offers off (policy pair); services stopped once, not disabled. Priors captured for restore.' -Level Success
        $result.Status = 'Applied'; $result.Detail = 'priors in state.json (windowsUpdatePrior)'
    } catch {
        Write-Log "Windows Update hold failed: $($_.Exception.Message)" -Level Error
        $result.Status = 'Failed'; $result.Detail = $_.Exception.Message
    }
    return $result
}

function Restore-WindowsUpdate {
    <#
        .SYNOPSIS
        Reverts Disable-WindowsUpdateTemporarily using the priors captured in
        state.json: absent-before values are removed, others restored; service
        start types restored. Intended for the post-BIOS stage, where shop
        practice lets Windows Update run fully BEFORE the vendor drivers go on.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $result = [pscustomobject]@{ Step = 'windows-update-restore'; Status = $null; Detail = $null }
    $state = Get-FirstBootState
    if (-not $state.PSObject.Properties['windowsUpdatePrior']) {
        Write-Log 'No windowsUpdatePrior in state; nothing to restore.' -Level Warn
        $result.Status = 'Skipped'; $result.Detail = 'no captured priors'
        return $result
    }
    $prior = $state.windowsUpdatePrior

    if (Test-Rehearsal) {
        Write-Log 'REHEARSE: would restore Windows Update policies/services from state.json priors.' -Level Info
        $result.Status = 'Rehearsed'
        return $result
    }

    try {
        # Values absent before the hold are DELETED (not set to 0) so the
        # machine ships policy-clean - per docs/windows-update-strategy.md.
        $map = @(
            @{ Path = $script:WuAuKey;     Name = 'NoAutoUpdate' },
            @{ Path = $script:WuPolicyKey; Name = 'ExcludeWUDriversInQualityUpdate' }
        )
        foreach ($m in $map) {
            $was = $null
            if ($prior.PSObject.Properties[$m.Name]) { $was = $prior.$($m.Name) }
            if ($PSCmdlet.ShouldProcess("$($m.Path)\$($m.Name)", $(if ($null -eq $was) { 'remove (was absent)' } else { "restore $was" }))) {
                if ($null -eq $was) {
                    Remove-ItemProperty -Path $m.Path -Name $m.Name -ErrorAction SilentlyContinue
                } else {
                    Set-RegistryDword -Path $m.Path -Name $m.Name -Value ([int]$was)
                }
            }
        }
        foreach ($svc in $script:WuServices) {
            if ($PSCmdlet.ShouldProcess($svc, 'start service (hold released)')) {
                try { Start-Service -Name $svc -ErrorAction SilentlyContinue } catch { }
            }
        }
        Write-Log 'Windows Update restored from captured priors (policy-clean when values were absent before).' -Level Success
        $result.Status = 'Restored'
    } catch {
        Write-Log "Windows Update restore failed: $($_.Exception.Message)" -Level Error
        $result.Status = 'Failed'; $result.Detail = $_.Exception.Message
    }
    return $result
}

function Disable-Uac {
    <#
        .SYNOPSIS
        Disables UAC (EnableLUA=0) for the unattended provisioning window; takes
        effect on the reboot this stage already performs. Prior value captured to
        state.json ('uacPrior') for Restore-Uac. Prefer setting this in
        autounattend.xml for imaged machines (docs/autounattend.md).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $result = [pscustomobject]@{ Step = 'uac-disable'; Status = $null; Detail = $null }
    $current = Get-RegistryValueOrNull -Path $script:UacKey -Name 'EnableLUA'

    if (Test-Rehearsal) {
        Write-Log ("REHEARSE: would set {0}\EnableLUA=0 (currently: {1}); effective after the stage's reboot; prior -> state.json. Preferred permanent home: autounattend.xml." -f `
            $script:UacKey, $(if ($null -ne $current) { $current } else { 'absent' })) -Level Info -Data @{
            key = "$script:UacKey\EnableLUA"; current = $current
        }
        $result.Status = 'Rehearsed'
        return $result
    }

    try {
        # Capture once (see Disable-WindowsUpdateTemporarily).
        if (-not (Get-FirstBootState).PSObject.Properties['uacPrior']) {
            Set-FirstBootStateValue -Name 'uacPrior' -Value @{ EnableLUA = $current } | Out-Null
        }
        Set-RegistryDword -Path $script:UacKey -Name 'EnableLUA' -Value 0
        Write-Log 'UAC disabled (EnableLUA=0; effective after reboot). Prior captured for restore. Consider moving this into autounattend.xml.' -Level Success
        $result.Status = 'Applied'; $result.Detail = 'effective after reboot'
    } catch {
        Write-Log "UAC disable failed: $($_.Exception.Message)" -Level Error
        $result.Status = 'Failed'; $result.Detail = $_.Exception.Message
    }
    return $result
}

function Restore-Uac {
    <#
        .SYNOPSIS
        Restores EnableLUA from the prior captured by Disable-Uac (removes the
        value if it was absent before). Effective after reboot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $result = [pscustomobject]@{ Step = 'uac-restore'; Status = $null; Detail = $null }
    $state = Get-FirstBootState
    if (-not $state.PSObject.Properties['uacPrior']) {
        Write-Log 'No uacPrior in state; nothing to restore.' -Level Warn
        $result.Status = 'Skipped'
        return $result
    }

    if (Test-Rehearsal) {
        Write-Log 'REHEARSE: would restore EnableLUA from state.json prior.' -Level Info
        $result.Status = 'Rehearsed'
        return $result
    }

    try {
        $was = $state.uacPrior.EnableLUA
        if ($PSCmdlet.ShouldProcess("$script:UacKey\EnableLUA", $(if ($null -eq $was) { 'remove (was absent)' } else { "restore $was" }))) {
            if ($null -eq $was) {
                Remove-ItemProperty -Path $script:UacKey -Name 'EnableLUA' -ErrorAction SilentlyContinue
            } else {
                Set-RegistryDword -Path $script:UacKey -Name 'EnableLUA' -Value ([int]$was)
            }
        }
        Write-Log 'UAC restored from captured prior (effective after reboot).' -Level Success
        $result.Status = 'Restored'
    } catch {
        Write-Log "UAC restore failed: $($_.Exception.Message)" -Level Error
        $result.Status = 'Failed'; $result.Detail = $_.Exception.Message
    }
    return $result
}

function Invoke-WindowsPrep {
    <#
        .SYNOPSIS
        Runs the stage-1 Windows prep: WU guard + UAC disable. Returns the
        per-step results.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $results = @()
    $results += Disable-WindowsUpdateTemporarily
    $results += Disable-Uac
    return $results
}

Export-ModuleMember -Function `
    Get-RegistryValueOrNull, Set-RegistryDword, `
    Disable-WindowsUpdateTemporarily, Restore-WindowsUpdate, `
    Disable-Uac, Restore-Uac, Invoke-WindowsPrep
