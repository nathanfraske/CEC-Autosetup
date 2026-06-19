# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors
#
# FirstBoot.ps1 - the orchestrator. Detect the board, pick the provider, resolve
# the model, fetch + install drivers headlessly when possible, fall back to Chrome
# for holdout vendors, then run the apps layer for detected peripherals.
#
# Flags:
#   -WhatIf            dry run; plans everything, installs nothing
#   -IncludeBios       list BIOS entries (never flashes - listing only)
#   -Categories <[]>   explicit category allow-list (default: skip utilities)
#   -Osid <int>        ASUS osid override (default: probe candidates)
#   -SkipApps          skip the peripheral-software (apps) phase
#   -Model / -Vendor   override hardware detection (testing / odd boards)

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]   $IncludeBios,
    [string[]] $Categories,
    [int]      $Osid = 0,
    [switch]   $SkipApps,
    [string]   $Model,
    [string]   $Vendor
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Import-Module (Join-Path $here 'Common.psm1') -Force
Import-Module (Join-Path $here 'Detect-Hardware.psm1') -Force
Import-Module (Join-Path $here 'Detect-Peripherals.psm1') -Force
Import-Module (Join-Path $here 'Install-Engine.psm1') -Force
Import-Module (Join-Path $here 'Install-Chrome.psm1') -Force
Import-Module (Join-Path $here 'providers/Provider.psm1') -Force
Import-Module (Join-Path $here 'apps/AppCatalog.psm1') -Force

function Select-Drivers {
    param($Drivers, [string[]] $AllowCategories, [string[]] $DenyDefault, [switch] $IncludeBiosEntries)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in $Drivers) {
        $cat = [string]$d.Category
        $isBios = $cat -match '(?i)bios|firmware'
        if ($isBios -and -not $IncludeBiosEntries) { continue }
        if ($isBios) { $out.Add($d) | Out-Null; continue }  # listed; install loop will not flash

        if ($AllowCategories -and $AllowCategories.Count -gt 0) {
            $matched = $false
            foreach ($c in $AllowCategories) { if ($cat -match [regex]::Escape($c)) { $matched = $true; break } }
            if (-not $matched) { continue }
        }
        else {
            $denied = $false
            foreach ($dn in $DenyDefault) { if ($cat -match [regex]::Escape($dn)) { $denied = $true; break } }
            if ($denied) { continue }
        }
        $out.Add($d) | Out-Null
    }
    return $out.ToArray()
}

# --- start ----------------------------------------------------------------
$logPath = Initialize-Log
$settings = Get-Settings
$dryRun = [bool]$WhatIfPreference

Write-Log "==================== $((Get-AppName)) first-boot run ====================" -Level Info
Write-Log "Log file: $logPath" -Level Info
if ($dryRun) { Write-Log "Mode: DRY RUN (-WhatIf) - nothing will be installed." -Level Warn }

# --- admin ---------------------------------------------------------------
if (Test-Admin) {
    Write-Log "Running elevated." -Level Info
} elseif ($dryRun) {
    Write-Log "Not elevated; continuing because this is a dry run." -Level Warn
} else {
    Assert-Admin
}

# --- detect board --------------------------------------------------------
if ($Model -and $Vendor) {
    $board = [pscustomobject]@{ Vendor = $Vendor.ToLowerInvariant(); Model = $Model; Manufacturer = '(override)'; Version = '' }
    Write-Log "Board (override): vendor=$($board.Vendor), model='$($board.Model)'" -Level Info
} else {
    $board = Get-MotherboardInfo
    Write-Log "Board: manufacturer='$($board.Manufacturer)', model='$($board.Model)', vendor=$($board.Vendor)" -Level Info
}

$driverResults = New-Object System.Collections.Generic.List[object]
$fallbackOpened = $false

if (-not $board.Vendor) {
    Write-Log "Unrecognised motherboard manufacturer; no driver provider. Skipping driver phase." -Level Warn
} else {
    $provider = Get-Provider -Vendor $board.Vendor
    if (-not $provider) {
        Write-Log "No provider registered for vendor '$($board.Vendor)'." -Level Warn
    } else {
        Write-Log "Provider: $($provider.Name) (headless=$($provider.SupportsHeadless))" -Level Info

        $identity = $null
        try { $identity = & $provider.ResolveProduct $board.Model } catch { Write-Log "Resolve failed: $($_.Exception.Message)" -Level Warn }

        $drivers = $null
        $headlessFailed = $false
        if ($provider.SupportsHeadless -and $identity) {
            try {
                $drivers = & $provider.GetDriverList $identity $Osid
            } catch {
                Write-Log "Headless driver list failed: $($_.Exception.Message)" -Level Warn
                $headlessFailed = $true
            }
        }

        if ($drivers) {
            $kept = Select-Drivers -Drivers $drivers -AllowCategories $Categories `
                -DenyDefault $settings.categories.denyDefault -IncludeBiosEntries:$IncludeBios
            Write-Log "Selected $(@($kept).Count) of $(@($drivers).Count) driver file(s) to process." -Level Info

            foreach ($entry in $kept) {
                if ([string]$entry.Category -match '(?i)bios|firmware') {
                    Write-Log "BIOS listed (NOT flashed): $($entry.Name) $($entry.Version)" -Level Warn
                    $driverResults.Add([pscustomobject]@{ Name = $entry.Name; Category = $entry.Category; Version = $entry.Version; Method = 'bios'; Status = 'ListedOnly'; Detail = $entry.Url }) | Out-Null
                    continue
                }
                $r = Install-DriverPackage -Entry $entry
                $driverResults.Add($r) | Out-Null
            }
        }

        # Fallback to Chrome when headless is unsupported, failed, or unresolved.
        if (-not $provider.SupportsHeadless -or $headlessFailed -or -not $identity) {
            $fallbackUrl = & $provider.GetFallbackUrl $identity $board.Model
            Write-Log "Falling back to browser for $($provider.Name): $fallbackUrl" -Level Warn
            Open-Url -Url $fallbackUrl
            $fallbackOpened = $true
            Write-Log "OPERATOR CHECKLIST - download + install from the page above:" -Level Info
            foreach ($c in 'Chipset', 'LAN / Ethernet', 'Wi-Fi / Wireless', 'Bluetooth', 'Audio', 'Graphics (VGA)', 'Storage (SATA/RAID)') {
                Write-Log "    [ ] $c driver" -Level Info
            }
        }
    }
}

# --- apps phase ----------------------------------------------------------
$appResults = New-Object System.Collections.Generic.List[object]
$appsEnabled = $true
try { $appsEnabled = [bool]$settings.apps.enabled } catch { }
if ($SkipApps -or -not $appsEnabled) {
    Write-Log "Apps phase skipped." -Level Info
} else {
    Write-Log "Apps phase: scanning peripherals..." -Level Info
    try {
        $devices = Get-Peripherals
        $appMatches = Find-MatchingApps -Devices $devices
        if (@($appMatches).Count -eq 0) {
            Write-Log "No catalog apps matched the detected peripherals." -Level Info
        }
        foreach ($m in $appMatches) {
            Write-Log "App match: $($m.Name) ($($m.Reason))" -Level Info
            $r = Install-App -App $m.App
            $appResults.Add($r) | Out-Null
        }
    } catch {
        Write-Log "Apps phase error: $($_.Exception.Message)" -Level Warn
    }
}

# --- summary -------------------------------------------------------------
Write-Log "-------------------- summary --------------------" -Level Info
Write-Log "Board: $($board.Manufacturer) / $($board.Model) ($($board.Vendor))" -Level Info
foreach ($r in $driverResults) {
    Write-Log ("  driver [{0,-11}] {1} {2} ({3})" -f $r.Status, $r.Category, $r.Name, $r.Method) -Level Info
}
foreach ($r in $appResults) {
    Write-Log ("  app    [{0,-11}] {1} ({2})" -f $r.Status, $r.Name, $r.Method) -Level Info
}
if ($fallbackOpened) { Write-Log "A vendor page was opened for manual completion." -Level Warn }
Write-Log "Done. Full transcript: $logPath" -Level Success

exit 0
