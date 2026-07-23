# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# FirstBoot.ps1 - the orchestrator. Detect the board, pick the provider, resolve
# the model, fetch + install drivers headlessly when possible, fall back to Chrome
# for holdout vendors, then run the apps layer for detected peripherals.
#
# Flags:
#   -WhatIf            dry run; plans everything, installs nothing
#   -Rehearse          dev dry run; emulates the full stack true-to-life (probes
#                      URLs, renders artifacts, logs exact commands + a JSON
#                      report), installs nothing
#   -RehearseDownloads with -Rehearse: really download + extract + packer-detect
#                      (files only) for maximum fidelity
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
    [switch]   $SkipGpu,
    [switch]   $SkipTweaks,
    [string]   $Tier,
    [string[]] $InstallApps,
    [string]   $Mirror,
    [string]   $Model,
    [string]   $Vendor,
    [switch]   $Rehearse,
    [switch]   $RehearseDownloads,
    [switch]   $SkipWindowsPrep,
    [switch]   $SkipBiosUpdate,
    [switch]   $SkipWindowsUpdateRun,
    [switch]   $SkipVerify
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Import-Module (Join-Path $here 'Common.psm1') -Force
Import-Module (Join-Path $here 'Detect-Hardware.psm1') -Force
Import-Module (Join-Path $here 'Detect-Peripherals.psm1') -Force
Import-Module (Join-Path $here 'Detect-Gpu.psm1') -Force
Import-Module (Join-Path $here 'Install-Gpu.psm1') -Force
Import-Module (Join-Path $here 'Mapping.psm1') -Force
Import-Module (Join-Path $here 'DriverLibrary.psm1') -Force
Import-Module (Join-Path $here 'Install-Engine.psm1') -Force
Import-Module (Join-Path $here 'Install-Chrome.psm1') -Force
Import-Module (Join-Path $here 'Tweaks.psm1') -Force
Import-Module (Join-Path $here 'providers/Provider.psm1') -Force
Import-Module (Join-Path $here 'apps/AppCatalog.psm1') -Force
Import-Module (Join-Path $here 'WindowsPrep.psm1') -Force
Import-Module (Join-Path $here 'BiosUpdate.psm1') -Force
Import-Module (Join-Path $here 'WindowsUpdateRun.psm1') -Force
Import-Module (Join-Path $here 'DriverOrder.psm1') -Force
Import-Module (Join-Path $here 'BuildVerification.psm1') -Force

function Resolve-MsiBoardCode {
    # MSI boards may report an MS-xxxx code instead of the model name; map it via
    # config/msi-codes.json (verified data only). Returns the name, or $null.
    param([string] $Model)
    if ($Model -notmatch '^(?i)MS-[0-9A-Za-z]+$') { return $null }
    try {
        $p = Join-Path (Get-FirstBootRoot) 'config/msi-codes.json'
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $codes = (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json).codes
        $hit = $codes.PSObject.Properties[$Model.ToUpperInvariant()]
        if ($hit) { return [string]$hit.Value }
    } catch { }
    return $null
}

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
if ($Rehearse) { Enable-Rehearsal -Downloads:$RehearseDownloads }

# Phase ledger: one row per pipeline stage recording how far the run got.
$ledger = New-Object System.Collections.Generic.List[object]
function Add-LedgerEntry {
    param([string] $Phase, [string] $Outcome, [string] $Detail = '')
    $ledger.Add([pscustomobject]@{ Phase = $Phase; Outcome = $Outcome; Detail = $Detail }) | Out-Null
}

# Master progress: the operator always sees the current stage [n/total] and
# elapsed wall clock, above the per-download/per-driver bars.
$script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:StageTotal = 11
function Enter-Stage {
    param(
        [Parameter(Mandatory)][string] $Phase,
        [int] $Index = 0
    )
    Set-LogPhase $Phase
    if ($Index -gt 0) {
        Write-Progress -Id 100 -Activity "$(Get-AppName) pipeline" `
            -Status ("[{0}/{1}] {2}  (elapsed {3})" -f $Index, $script:StageTotal, $Phase, $script:RunStopwatch.Elapsed.ToString('hh\:mm\:ss')) `
            -PercentComplete ([int](($Index / $script:StageTotal) * 100))
    }
}

function Get-DoneKind {
    # Maps a step result Status to the done-ledger mark kind.
    param([string] $Status)
    switch -Regex ($Status) {
        '^(Failed|Blocked|HashFailed|Fail)$'                        { return 'fail' }
        '^(SkippedByRule|Skipped|WhatIf|NotResolved|NeedsManual)$'  { return 'skip' }
        default                                                     { return 'ok' }
    }
}

Write-Log "==================== $((Get-AppName)) first-boot run ====================" -Level Info
Write-Log "Log file: $logPath" -Level Info
Write-Log "JSONL log: $(Get-JsonLogFile)" -Level Info
if ($dryRun) { Write-Log "Mode: DRY RUN (-WhatIf) - nothing will be installed." -Level Warn }

$envSnap = $null
if (Test-Rehearsal) {
    Write-Log ("Mode: REHEARSAL - emulate the full stack, install nothing{0}." -f `
        $(if (Test-RehearsalDownloads) { ' (real downloads enabled for fidelity)' } else { '' })) -Level Warn
    Set-LogPhase 'env'
    $envSnap = Get-EnvironmentSnapshot
    Write-Log ("Environment: {0} build {1} | PS {2} ({3}) | elevated={4} | winget={5} | BITS={6} | {7} GB free | {8} GB RAM" -f `
        $envSnap.OsCaption, $envSnap.OsBuild, $envSnap.PsVersion, $envSnap.PsEdition, $envSnap.Elevated, `
        $(if ($envSnap.WingetPresent) { $envSnap.WingetVersion } else { 'ABSENT' }), `
        $envSnap.BitsService, $envSnap.SystemDriveFreeGB, $envSnap.MemoryGB) -Level Info -Data @{ snapshot = $envSnap }
    foreach ($h in $envSnap.VendorHosts) {
        Write-Log ("vendor host {0}: {1}" -f $h.Host, $(if ($h.Reachable) { 'reachable' } else { 'UNREACHABLE' })) -Level Trace
    }
    $unreachable = @($envSnap.VendorHosts | Where-Object { -not $_.Reachable })
    Add-LedgerEntry -Phase 'environment' -Outcome $(if ($unreachable.Count -eq 0) { 'ok' } else { 'degraded' }) `
        -Detail ("{0}/{1} vendor hosts reachable" -f (@($envSnap.VendorHosts).Count - $unreachable.Count), @($envSnap.VendorHosts).Count)
}

# --- admin ---------------------------------------------------------------
if (Test-Admin) {
    Write-Log "Running elevated." -Level Info
} elseif ($dryRun -or (Test-Rehearsal)) {
    Write-Log "Not elevated; continuing (dry run / rehearsal installs nothing)." -Level Warn
} else {
    Assert-Admin
}

# --- stage 1a: Windows prep (hold WU before it grabs anything; UAC off) ---
# Shop order: hold WU -> BIOS -> reboot to UEFI -> (post-flash) restore WU and
# let it run FULLY -> vendor drivers on top. The hold is temporary by design.
Enter-Stage 'windows-prep' 1
if ($SkipWindowsPrep) {
    Write-Log 'Windows prep skipped (-SkipWindowsPrep).' -Level Info
    Add-LedgerEntry -Phase 'windows-prep' -Outcome 'skipped' -Detail '-SkipWindowsPrep'
} elseif ((Get-FirstBootState).PSObject.Properties['windowsPrepDone']) {
    Write-Log 'Windows prep already applied on a previous run; skipping.' -Level Info
    Add-LedgerEntry -Phase 'windows-prep' -Outcome 'ok' -Detail 'already applied (state marker)'
} else {
    $prepResults = @(Invoke-WindowsPrep)
    foreach ($pr in $prepResults) {
        Write-Log ("  prep [{0,-11}] {1} {2}" -f $pr.Status, $pr.Step, $pr.Detail) -Level Info
    }
    $prepFailed = @($prepResults | Where-Object { $_.Status -eq 'Failed' })
    if (-not (Test-Rehearsal) -and -not $dryRun -and $prepFailed.Count -eq 0) {
        Set-FirstBootStateValue -Name 'windowsPrepDone' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Out-Null
    }
    Add-LedgerEntry -Phase 'windows-prep' -Outcome $(if ($prepFailed.Count -eq 0) { 'ok' } else { 'degraded' }) `
        -Detail ((@($prepResults | ForEach-Object { "$($_.Step)=$($_.Status)" }) -join ', '))
}

# --- detect board --------------------------------------------------------
Enter-Stage 'detect' 2
if ($Model -and $Vendor) {
    $board = [pscustomobject]@{ Vendor = $Vendor.ToLowerInvariant(); Model = $Model; Manufacturer = '(override)'; Version = '' }
    Write-Log "Board (override): vendor=$($board.Vendor), model='$($board.Model)'" -Level Info
} else {
    $board = Get-MotherboardInfo
    Write-Log "Board: manufacturer='$($board.Manufacturer)', model='$($board.Model)', vendor=$($board.Vendor)" -Level Info
}
Add-LedgerEntry -Phase 'detect' -Outcome $(if ($board.Vendor) { 'ok' } else { 'blocked' }) `
    -Detail ("{0} / {1} -> {2}" -f $board.Manufacturer, $board.Model, $(if ($board.Vendor) { $board.Vendor } else { 'no provider' }))

# --- naming reconciliation (mapping table + MS-xxxx codes) ----------------
Enter-Stage 'mapping' 3
$resolveModel = $board.Model
$resolveSlug  = $null
$mapEntry = $null
try {
    $mapEntry = Find-MappingEntry -Mapping (Get-Mapping) -Model $board.Model
} catch { Write-Log "Mapping lookup error: $($_.Exception.Message)" -Level Warn }

if ($mapEntry) {
    Write-Log "Mapping hit: '$($board.Model)' -> $($mapEntry.vendor)/$($mapEntry.model)" -Level Info
    if (-not $board.Vendor) { $board.Vendor = [string]$mapEntry.vendor }
    if ($mapEntry.model) { $resolveModel = [string]$mapEntry.model }
    if ($mapEntry.slug)  { $resolveSlug  = [string]$mapEntry.slug }
}
if ($board.Vendor -eq 'msi') {
    $msiName = Resolve-MsiBoardCode -Model $board.Model
    if ($msiName) {
        Write-Log "MSI board code '$($board.Model)' -> '$msiName'" -Level Info
        $resolveModel = $msiName
    }
}
Add-LedgerEntry -Phase 'mapping' -Outcome 'ok' `
    -Detail $(if ($mapEntry) { "hit: '$($board.Model)' -> $($mapEntry.vendor)/$($mapEntry.model)" } else { "no entry (resolving '$resolveModel' as-is)" })

$driverResults = New-Object System.Collections.Generic.List[object]
$fallbackOpened = $false
$drivers = $null
$driverSource = 'vendor'
$provider = $null
$identity = $null

# Mirror base: -Mirror overrides config/defaults.json mirror.baseUrl.
$mirrorBase = if ($Mirror) { $Mirror }
              elseif ($settings.mirror.enabled -and $settings.mirror.baseUrl) { [string]$settings.mirror.baseUrl }
              else { $null }

# 1) Local driver mirror first (LAN; works offline-from-internet).
Enter-Stage 'source' 4
$index = $null
if (-not $mirrorBase) {
    Add-LedgerEntry -Phase 'mirror' -Outcome 'skipped' -Detail 'no mirror configured'
}
if ($mirrorBase) {
    Write-Log "Checking local driver mirror: $mirrorBase" -Level Info
    try {
        $index = Get-LibraryIndex -MirrorBase $mirrorBase
        $libEntries = if ($index) { Find-LibraryEntries -Index $index -Model $board.Model } else { @() }
        if (@($libEntries).Count -gt 0) {
            $drivers = @($libEntries | ForEach-Object { ConvertTo-MirrorDriverEntry -LibEntry $_ -MirrorBase $mirrorBase })
            $driverSource = "mirror ($mirrorBase)"
            Write-Log "Driver source: local mirror - $(@($drivers).Count) entr(ies) for '$($board.Model)'." -Level Success
            Add-LedgerEntry -Phase 'mirror' -Outcome 'ok' -Detail "$(@($drivers).Count) entries from $mirrorBase"
        } else {
            Write-Log "Mirror has no entry for '$($board.Model)'; using vendor." -Level Info
            Add-LedgerEntry -Phase 'mirror' -Outcome 'skipped' -Detail "no entry for '$($board.Model)'"
        }
    } catch {
        Write-Log "Mirror lookup failed: $($_.Exception.Message); using vendor." -Level Warn
        Add-LedgerEntry -Phase 'mirror' -Outcome 'blocked' -Detail $_.Exception.Message
    }
}

# 2) Vendor path (only when the mirror did not supply the drivers).
if (-not $drivers) {
    if (-not $board.Vendor) {
        Write-Log "Unrecognised motherboard manufacturer; no driver provider." -Level Warn
        Add-LedgerEntry -Phase 'vendor-resolve' -Outcome 'blocked' -Detail 'unrecognised manufacturer'
    } else {
        $provider = Get-Provider -Vendor $board.Vendor
        if (-not $provider) {
            Write-Log "No provider registered for vendor '$($board.Vendor)'." -Level Warn
            Add-LedgerEntry -Phase 'vendor-resolve' -Outcome 'blocked' -Detail "no provider for '$($board.Vendor)'"
        } else {
            Write-Log "Provider: $($provider.Name) (headless=$($provider.SupportsHeadless)); resolving '$resolveModel'$(if($resolveSlug){" (slug $resolveSlug)"})" -Level Info
            try { $identity = & $provider.ResolveProduct $resolveModel $resolveSlug } catch { Write-Log "Resolve failed: $($_.Exception.Message)" -Level Warn }
            Add-LedgerEntry -Phase 'vendor-resolve' -Outcome $(if ($identity) { 'ok' } else { 'blocked' }) `
                -Detail $(if ($identity) { "$($provider.Name) resolved '$resolveModel'" } else { "$($provider.Name) could not resolve '$resolveModel'" })
            if ($provider.SupportsHeadless -and $identity) {
                try { $drivers = & $provider.GetDriverList $identity $Osid }
                catch { Write-Log "Headless driver list failed: $($_.Exception.Message)" -Level Warn }
                Add-LedgerEntry -Phase 'driver-list' -Outcome $(if ($drivers) { 'ok' } else { 'blocked' }) `
                    -Detail $(if ($drivers) { "$(@($drivers).Count) file(s) from $($provider.Name)" } else { 'headless list failed' })
            } elseif ($identity) {
                Add-LedgerEntry -Phase 'driver-list' -Outcome 'fallback' -Detail "$($provider.Name) is fallback-only (no headless list)"
            }
            if ($drivers -and -not $mapEntry -and -not (Test-Rehearsal)) {
                # Self-heal the mapping cache after a successful headless
                # resolve (real runs only - rehearsal mutates nothing).
                try {
                    $fb = & $provider.GetFallbackUrl $identity $resolveModel
                    Save-MappingEntry -Model $board.Model -Entry ([pscustomobject]@{
                        vendor = $provider.Name; model = $resolveModel
                        method = "$($provider.Name)-api"; slug = $resolveSlug
                        downloadPage = $fb; lastVerified = (Get-Date -Format 'yyyy-MM-dd')
                    })
                } catch { Write-Log "Mapping self-heal skipped: $($_.Exception.Message)" -Level Debug }
            }
        }
    }
}

# --- stage 1b: BIOS update hand-off (stage file + reboot to UEFI) ----------
# Runs before any driver installs. Real runs end at the reboot; after the tech
# flashes and boots back, the state marker skips this and the pipeline
# continues below. Rehearsal emulates and carries on.
Enter-Stage 'bios' 5
if ($SkipBiosUpdate) {
    Write-Log 'BIOS stage skipped (-SkipBiosUpdate).' -Level Info
    Add-LedgerEntry -Phase 'bios' -Outcome 'skipped' -Detail '-SkipBiosUpdate'
} else {
    $biosResult = Invoke-BiosStage -Board $board -Provider $provider -Identity $identity `
        -RawDrivers @($drivers) -MirrorBase $mirrorBase
    Add-LedgerEntry -Phase 'bios' -Outcome $(switch ($biosResult.Status) {
            'Staged'            { 'ok' }
            'Rehearsed'         { 'ok' }
            'Skipped'           { 'skipped' }
            'Fallback'          { 'fallback' }
            'StagedManualReboot' { 'fallback' }
            default             { 'blocked' }
        }) -Detail "$($biosResult.Status): $($biosResult.Detail)"
    if ($biosResult.RebootRequested) {
        Write-Log 'BIOS staged; this run ends here. After flashing in UEFI, boot back into Windows and re-run - the pipeline resumes from Windows Update + drivers.' -Level Success
        Write-Log "Done. Full transcript: $logPath" -Level Success
        exit 0
    }
    if ($biosResult.Status -eq 'StagedManualReboot') {
        # Do not install drivers on the old firmware; the operator flashes by
        # hand and re-runs.
        Write-Log 'Run stops here pending the manual BIOS flash (see MANUAL STEP above); re-run afterwards to continue.' -Level Warn
        Write-Log "Done. Full transcript: $logPath" -Level Success
        exit 0
    }
}

# --- stage 2: Windows Update runs its FULL course (post-BIOS) --------------
# WU gets all of its updates + generic drivers out of the way first; the
# vendor drivers below then replace its defaults. Real runs exit at WU-driven
# reboots and resume via the resume task; rehearsal scans + reports without touching.
Enter-Stage 'windows-update' 6
if ($SkipWindowsUpdateRun) {
    Write-Log 'Windows Update stage skipped (-SkipWindowsUpdateRun).' -Level Info
    Add-LedgerEntry -Phase 'windows-update' -Outcome 'skipped' -Detail '-SkipWindowsUpdateRun'
} else {
    # Contained: a WUA COM failure must degrade this stage, not kill the run
    # (the hold may already be released by this point).
    $wuResult = $null
    try { $wuResult = Invoke-WindowsUpdateStage }
    catch {
        Write-Log "Windows Update stage error: $($_.Exception.Message)" -Level Error
        $wuResult = [pscustomobject]@{ Status = 'Blocked'; Detail = $_.Exception.Message; RebootRequested = $false }
    }
    Add-LedgerEntry -Phase 'windows-update' -Outcome $(switch ($wuResult.Status) {
            'Completed'      { 'ok' }
            'Rehearsed'      { 'ok' }
            'Skipped'        { 'ok' }
            'RebootRequired' { 'ok' }
            default          { 'blocked' }
        }) -Detail "$($wuResult.Status): $($wuResult.Detail)"
    if ($wuResult.RebootRequested) {
        Write-Log 'Restarting to continue Windows Update; the pipeline resumes automatically (resume task).' -Level Success
        Write-Log "Done. Full transcript: $logPath" -Level Success
        exit 0
    }
}

# 3) Install whatever the source produced (mirror or vendor share this path).
if ($drivers) {
    Enter-Stage 'drivers' 7
    $kept = Select-Drivers -Drivers $drivers -AllowCategories $Categories `
        -DenyDefault $settings.categories.denyDefault -IncludeBiosEntries:$IncludeBios
    Write-Log "Selected $(@($kept).Count) of $(@($drivers).Count) driver file(s) from $driverSource." -Level Info

    # Stage 3: config-driven install order (docs/driver-install-order.md) with
    # conditional skips and forced-restart boundaries (resume-task resume).
    $platform = Get-PlatformKind
    $orderConditions = Get-DriverOrderConditions
    $plan = Get-DriverOrderPlan -Drivers @($kept) -Platform $platform -Conditions $orderConditions
    $planTxt = Format-DriverOrderPlan -Plan $plan
    Write-Log ("Install order ({0}): {1}" -f $platform, $planTxt) -Level Info -Data @{
        platform = $platform; conditions = $orderConditions
    }

    $doneGroups = @()
    $st = Get-FirstBootState
    if ($st.PSObject.Properties['driverOrder'] -and $st.driverOrder.PSObject.Properties['completedGroups']) {
        $doneGroups = @($st.driverOrder.completedGroups)
    }

    $idx = 0
    $tot = @($kept).Count
    $rebootAtBoundary = $false
    foreach ($group in $plan) {
        if ($group.Entries.Count -eq 0) { continue }

        if ($group.Skipped) {
            foreach ($entry in $group.Entries) {
                Write-Log ("SKIP by order rule [{0}]: {1} ({2})" -f $group.Key, $entry.Name, $group.SkipReason) -Level Info
                $driverResults.Add([pscustomobject]@{ Name = $entry.Name; Category = $entry.Category; Version = $entry.Version; Method = 'order-rule'; Status = 'SkippedByRule'; Detail = $group.SkipReason }) | Out-Null
            }
            continue
        }
        if ($doneGroups -contains $group.Key) {
            Write-Log ("Group '{0}' completed on a previous boot; skipping {1} entr(ies)." -f $group.Key, $group.Entries.Count) -Level Info
            continue
        }

        Write-Log ("--- install group '{0}' ({1}): {2} entr(ies){3} ---" -f $group.Key, $group.Title, $group.Entries.Count, $(if ($group.RestartAfter) { ' [RESTART after]' } else { '' })) -Level Info
        $installedInGroup = $false
        foreach ($entry in $group.Entries) {
            $idx++
            Write-Progress -Id 0 -Activity "$(Get-AppName): installing drivers" `
                -Status "[$idx/$tot] [$($group.Key)] $($entry.Category) - $($entry.Name)" `
                -PercentComplete ([int](($idx / [Math]::Max(1, $tot)) * 100))
            if ([string]$entry.Category -match '(?i)bios|firmware') {
                Write-Log "BIOS listed (NOT flashed): $($entry.Name) $($entry.Version)" -Level Warn
                $driverResults.Add([pscustomobject]@{ Name = $entry.Name; Category = $entry.Category; Version = $entry.Version; Method = 'bios'; Status = 'ListedOnly'; Detail = $entry.Url }) | Out-Null
                continue
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Install-DriverPackage -Entry $entry
            $sw.Stop()
            $driverResults.Add($r) | Out-Null
            Write-Log ("  {0} -> {1} in {2}s ({3})" -f $entry.Name, $r.Status, [Math]::Round($sw.Elapsed.TotalSeconds, 1), $r.Method) -Level Trace -Data @{
                name = [string]$entry.Name; status = [string]$r.Status
                method = [string]$r.Method; seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            }
            Write-StepDone -Label ("[{0}] {1} -> {2}" -f $group.Key, $entry.Name, $r.Status) `
                -Seconds $sw.Elapsed.TotalSeconds -Kind (Get-DoneKind $r.Status)
            if ($r.Status -eq 'Installed') { $installedInGroup = $true }
        }

        if (-not (Test-Rehearsal) -and -not $dryRun) {
            $doneGroups = @($doneGroups + $group.Key)
            Set-FirstBootStateValue -Name 'driverOrder' -Value @{ completedGroups = $doneGroups } | Out-Null
        }
        if ($group.RestartAfter -and $installedInGroup -and -not (Test-Rehearsal) -and -not $dryRun) {
            Register-ResumeAfterReboot
            if (Restart-ForDriverPhase) { $rebootAtBoundary = $true; break }
        }
        elseif ($group.RestartAfter -and (Test-Rehearsal)) {
            Write-Log ("REHEARSE: [RESTART] boundary after group '{0}' (real runs reboot + resume here)." -f $group.Key) -Level Info
        }
    }
    Write-Progress -Id 0 -Activity "$(Get-AppName): installing drivers" -Completed

    $byStatus = @($driverResults | Group-Object Status | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    Add-LedgerEntry -Phase 'drivers' -Outcome $(if (@($driverResults | Where-Object { $_.Status -in 'Failed', 'Blocked', 'HashFailed' }).Count -eq 0) { 'ok' } else { 'degraded' }) `
        -Detail ("{0} | order: {1}" -f $byStatus, $planTxt)

    if ($rebootAtBoundary) {
        Write-Log 'Restarting at a driver-order boundary; the pipeline resumes automatically (resume task).' -Level Success
        Write-Log "Done. Full transcript: $logPath" -Level Success
        exit 0
    }
}

# 4) Chrome fallback when neither mirror nor vendor produced drivers.
if (-not $drivers) {
    Enter-Stage 'fallback' 7
    $fallbackUrl = $null
    if ($mapEntry -and $mapEntry.downloadPage) { $fallbackUrl = [string]$mapEntry.downloadPage }
    elseif ($provider) { $fallbackUrl = & $provider.GetFallbackUrl $identity $resolveModel }
    if ($fallbackUrl) {
        Write-Log "Falling back to browser: $fallbackUrl" -Level Warn
        Open-Url -Url $fallbackUrl
        $fallbackOpened = $true
        Write-Log "OPERATOR CHECKLIST - download + install from the page above:" -Level Info
        foreach ($c in 'Chipset', 'LAN / Ethernet', 'Wi-Fi / Wireless', 'Bluetooth', 'Audio', 'Graphics (VGA)', 'Storage (SATA/RAID)') {
            Write-Log "    [ ] $c driver" -Level Info
        }
        Add-LedgerEntry -Phase 'fallback' -Outcome 'fallback' -Detail $fallbackUrl
    } else {
        Add-LedgerEntry -Phase 'fallback' -Outcome 'blocked' -Detail 'no fallback URL available'
    }
}

# --- GPU detection (shared by the GPU-driver and apps phases) ------------
Enter-Stage 'gpu' 8
$gpus = @()
$gpuVendors = @()
try {
    $gpus = @(Get-Gpus)
    $gpuVendors = @($gpus | Where-Object { $_.Vendor } | Select-Object -ExpandProperty Vendor -Unique)
    if ($gpus.Count -gt 0) {
        Write-Log ("GPU(s): {0}" -f (($gpus | ForEach-Object { "$($_.Name) [$(if($_.Vendor){$_.Vendor}else{'?'})]" }) -join '; ')) -Level Info
    }
} catch { Write-Log "GPU detection error: $($_.Exception.Message)" -Level Warn }

# --- GPU driver phase (NVIDIA fully unattended; AMD/Intel via their app) --
# Every detected GPU vendor is handled - no fragile iGPU-vs-dGPU guessing. NVIDIA
# gets the silent headless driver here AND the NVIDIA App in the apps phase;
# AMD/Intel drivers ship with their vendor app (installed in the apps phase).
$gpuResults = New-Object System.Collections.Generic.List[object]
if ($SkipGpu) {
    Write-Log "GPU driver phase skipped (-SkipGpu)." -Level Info
    Add-LedgerEntry -Phase 'gpu' -Outcome 'skipped' -Detail '-SkipGpu'
} else {
    # NVIDIA: fully headless (resolves its own installer + silent install).
    foreach ($g in ($gpus | Where-Object { $_.Vendor -eq 'nvidia' })) {
        $gsw = [System.Diagnostics.Stopwatch]::StartNew()
        $gr = Install-NvidiaDriver -GpuName $g.Name -OsId ([int]$settings.nvidia.osId)
        $gsw.Stop()
        $gpuResults.Add($gr) | Out-Null
        Write-StepDone -Label ("gpu: {0} -> {1}" -f $g.Name, $gr.Status) `
            -Seconds $gsw.Elapsed.TotalSeconds -Kind (Get-DoneKind $gr.Status)
    }
    # AMD / Intel: unattended IF an installer is provided (pinned config url, or
    # staged in the driver library). No clean headless discovery API, so otherwise
    # the vendor app (apps phase) carries the driver.
    foreach ($v in @($gpuVendors | Where-Object { $_ -in 'amd', 'intel' })) {
        $url = $null
        $pin = $null
        try { $pin = [string]$settings.$v.url } catch { }
        if ($pin) { $url = $pin }
        elseif ($mirrorBase) { try { $url = Get-LibraryGpuInstaller -Index $index -Vendor $v -MirrorBase $mirrorBase } catch { } }

        if ($url) {
            Write-Log "$v GPU driver: unattended install from $url" -Level Info
            $gsw = [System.Diagnostics.Stopwatch]::StartNew()
            $gr = Install-GpuVendorDriver -Vendor $v -InstallerUrl $url
            $gsw.Stop()
            $gpuResults.Add($gr) | Out-Null
            Write-StepDone -Label ("gpu: {0} -> {1}" -f $v, $gr.Status) `
                -Seconds $gsw.Elapsed.TotalSeconds -Kind (Get-DoneKind $gr.Status)
        } else {
            Write-Log "$v GPU driver: no pinned/mirrored installer; the vendor app (apps phase) will carry it. To make it unattended, pin '$v.url' in defaults.json or stage it in the driver library." -Level Info
        }
    }
    # NOTE: use the List's own .Count - @() around a generic List throws
    # 'Argument types do not match' on some Win11 PS 5.1 builds (seen on
    # 5.1.26100.8894); piping (@($list | ...)) is unaffected.
    $gpuTxt = if ($gpuResults.Count -gt 0) {
        (@($gpuResults | ForEach-Object { "$($_.Gpu): $($_.Status)" }) -join '; ')
    } else { "no headless GPU-driver work ($(@($gpus).Count) GPU(s): $($gpuVendors -join ', '))" }
    Add-LedgerEntry -Phase 'gpu' -Outcome $(if (@($gpuResults | Where-Object { $_.Status -in 'Failed', 'Blocked' }).Count -eq 0) { 'ok' } else { 'degraded' }) `
        -Detail $gpuTxt
}

# --- apps phase ----------------------------------------------------------
Enter-Stage 'apps' 9
$appResults = New-Object System.Collections.Generic.List[object]
$appsEnabled = $true
try { $appsEnabled = [bool]$settings.apps.enabled } catch { }
if ($SkipApps -or -not $appsEnabled) {
    Write-Log "Apps phase skipped." -Level Info
    Add-LedgerEntry -Phase 'apps' -Outcome 'skipped' -Detail $(if ($SkipApps) { '-SkipApps' } else { 'disabled in config' })
} else {
    Write-Log "Apps phase: matching GPU vendors + peripherals to the catalog..." -Level Info
    try {
        $devices = Get-Peripherals
        $appMatches = Find-MatchingApps -Devices $devices -GpuVendors $gpuVendors -Include $InstallApps
        if (@($appMatches).Count -eq 0) {
            Write-Log "No catalog apps matched the detected hardware." -Level Info
        }
        $aidx = 0
        $atot = @($appMatches).Count
        foreach ($m in $appMatches) {
            $aidx++
            Write-Progress -Id 0 -Activity "$(Get-AppName): installing apps" `
                -Status "[$aidx/$atot] $($m.Name)" -PercentComplete ([int](($aidx / [Math]::Max(1, $atot)) * 100))
            Write-Log "App match: $($m.Name) ($($m.Reason))" -Level Info
            $asw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Install-App -App $m.App
            $asw.Stop()
            $appResults.Add($r) | Out-Null
            Write-StepDone -Label ("app: {0} -> {1}" -f $m.Name, $r.Status) `
                -Seconds $asw.Elapsed.TotalSeconds -Kind (Get-DoneKind $r.Status)
        }
        Write-Progress -Id 0 -Activity "$(Get-AppName): installing apps" -Completed
        Add-LedgerEntry -Phase 'apps' -Outcome $(if (@($appResults | Where-Object { $_.Status -eq 'Failed' }).Count -eq 0) { 'ok' } else { 'degraded' }) `
            -Detail ("{0} match(es): {1}" -f @($appMatches).Count, ((@($appResults | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')))
    } catch {
        Write-Log "Apps phase error: $($_.Exception.Message)" -Level Warn
        Add-LedgerEntry -Phase 'apps' -Outcome 'blocked' -Detail $_.Exception.Message
    }
}

# --- tweaks / provisioning phase -----------------------------------------
Enter-Stage 'tweaks' 10
if ($SkipTweaks) {
    Write-Log "Tweaks phase skipped (-SkipTweaks)." -Level Info
    Add-LedgerEntry -Phase 'tweaks' -Outcome 'skipped' -Detail '-SkipTweaks'
} else {
    Write-Log "Tweaks phase: applying provisioning (default browser, taskbar, OneDrive/Copilot, wallpaper)..." -Level Info
    try {
        Invoke-Tweaks -Tier $Tier
        Add-LedgerEntry -Phase 'tweaks' -Outcome 'ok' -Detail $(if (Test-Rehearsal) { 'emulated (see REHEARSE lines)' } else { 'applied' })
    } catch {
        Write-Log "Tweaks phase error: $($_.Exception.Message)" -Level Warn
        Add-LedgerEntry -Phase 'tweaks' -Outcome 'blocked' -Detail $_.Exception.Message
    }
}

# --- stage 4: build verification (the pass/fail gate) ---------------------
Enter-Stage 'verify' 11
if ($SkipVerify) {
    Write-Log 'Build verification skipped (-SkipVerify).' -Level Info
    Add-LedgerEntry -Phase 'verify' -Outcome 'skipped' -Detail '-SkipVerify'
} else {
    $verify = Invoke-BuildVerification
    Add-LedgerEntry -Phase 'verify' -Outcome $(switch ($verify.Status) {
            'Pass'     { 'ok' }
            'Skipped'  { 'ok' }
            'Degraded' { 'degraded' }
            default    { 'blocked' }
        }) -Detail "$($verify.Status): $($verify.Detail)"
}

# --- summary -------------------------------------------------------------
Enter-Stage 'summary'
Write-Progress -Id 100 -Activity "$(Get-AppName) pipeline" -Completed
Write-Log "-------------------- summary --------------------" -Level Info
Write-Log ("Total elapsed this boot: {0}" -f $script:RunStopwatch.Elapsed.ToString('hh\:mm\:ss')) -Level Info -Data @{
    totalSeconds = [Math]::Round($script:RunStopwatch.Elapsed.TotalSeconds, 1)
}
Write-Log "Board: $($board.Manufacturer) / $($board.Model) ($($board.Vendor))" -Level Info
foreach ($r in $driverResults) {
    Write-Log ("  driver [{0,-11}] {1} {2} ({3})" -f $r.Status, $r.Category, $r.Name, $r.Method) -Level Info
}
foreach ($r in $gpuResults) {
    Write-Log ("  gpu    [{0,-11}] {1} {2} ({3})" -f $r.Status, $r.Gpu, $r.Version, $r.Method) -Level Info
}
foreach ($r in $appResults) {
    Write-Log ("  app    [{0,-11}] {1} ({2})" -f $r.Status, $r.Name, $r.Method) -Level Info
}
if ($fallbackOpened) { Write-Log "A vendor page was opened for manual completion." -Level Warn }

# --- rehearsal report ----------------------------------------------------
if (Test-Rehearsal) {
    Write-Log "-------------------- rehearsal report (how far could this machine get?) --------------------" -Level Info
    foreach ($e in $ledger) {
        $lvl = switch ($e.Outcome) {
            'blocked'  { 'Warn' }
            'degraded' { 'Warn' }
            default    { 'Info' }
        }
        Write-Log ("  {0,-15} {1,-9} {2}" -f $e.Phase, $e.Outcome, $e.Detail) -Level $lvl
    }

    $reportPath = Join-Path (Get-LogDirectory) ('rehearsal_{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $report = [pscustomobject]@{
        generatedAt   = (Get-Date).ToString('o')
        machine       = $envSnap
        board         = $board
        ledger        = $ledger.ToArray()
        driverResults = $driverResults.ToArray()
        gpuResults    = $gpuResults.ToArray()
        appResults    = $appResults.ToArray()
        textLog       = $logPath
        jsonLog       = (Get-JsonLogFile)
    }
    ConvertTo-Json -InputObject $report -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8 -WhatIf:$false
    Write-Log "Rehearsal report (portable JSON, collect these across machines): $reportPath" -Level Success
}

# Pipeline reached the end on this boot: retire the resume task (no-op when
# absent; rehearsal/dry runs never registered one).
if (-not (Test-Rehearsal) -and -not $dryRun) {
    try { Remove-ResumeAfterReboot } catch { }
}

Write-Log "Done. Full transcript: $logPath" -Level Success

exit 0
