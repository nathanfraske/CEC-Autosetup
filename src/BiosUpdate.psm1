# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# BiosUpdate.psm1 - stage-1 BIOS acquisition + hand-off. Finds the latest
# NON-BETA BIOS for the detected board (driver library stub first, then the
# vendor's own list when the provider surfaces a BIOS/Firmware category),
# downloads + extracts it, stages the firmware file where the UEFI flash tool
# can see it (USB root when running from a stick, else %ProgramData%), then
# reboots straight into UEFI setup (shutdown /r /fw) for the human to flash.
#
# THE TOOL NEVER FLASHES. Staging + reboot only; the flash itself is the
# technician's action inside UEFI (EZ Flash / Q-Flash / M-Flash / Instant
# Flash). A cross-boot state marker prevents a reboot loop after the flash.
#
# Offline path: try LAN drivers staged under lan-drivers/ (pnputil), else log
# the manual step. See docs/bios-stage.md.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Install-Engine.psm1')
Import-Module (Join-Path $PSScriptRoot 'Install-Chrome.psm1')

function Test-BetaBios {
    <#
        .SYNOPSIS
        $true when a BIOS entry looks like a beta release (name or version
        mentions beta). Pure; used to enforce "latest NON-BETA".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Entry)
    $text = '{0} {1}' -f [string]$Entry.Name, [string]$Entry.Version
    return ($text -match '(?i)beta')
}

function Select-LatestBios {
    <#
        .SYNOPSIS
        Picks the latest non-beta BIOS from a list of entries. Sorts by the
        numeric core of Version when every entry parses (vendor BIOS versions
        are typically plain integers like 2004 < 2103); otherwise trusts the
        vendor's newest-first ordering. Returns $null when nothing qualifies.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][array] $Entries)

    $candidates = @($Entries | Where-Object { -not (Test-BetaBios -Entry $_) })
    if ($candidates.Count -eq 0) { return $null }

    $parsed = @($candidates | ForEach-Object {
        $core = ([string]$_.Version) -replace '[^\d.]', ''
        $num = $null
        if ($core -match '^\d+$') { $num = [int64]$core }
        elseif ($core) { try { $num = [int64](([version]$core).Major * 1000000 + ([version]$core).Minor) } catch { } }
        [pscustomobject]@{ Entry = $_; Num = $num }
    })
    if (@($parsed | Where-Object { $null -eq $_.Num }).Count -eq 0) {
        return ($parsed | Sort-Object Num -Descending | Select-Object -First 1).Entry
    }
    return $candidates[0]   # unparseable version(s): vendor lists are newest-first
}

function Find-FirmwareFile {
    <#
        .SYNOPSIS
        Locates the firmware image inside an extracted BIOS package: .cap/.rom/
        .bin/.bio/.fd, or Gigabyte's bare "<MODEL>.F<nn>" convention. Prefers the
        largest match. Returns a FileInfo or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Root)

    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $all = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)
    $fw = @($all | Where-Object {
        $ext = $_.Extension
        ($ext -match '(?i)^\.(cap|rom|bin|bio|fd)$') -or ($ext -match '(?i)^\.f\d+[a-z]?$')
    })
    if ($fw.Count -eq 0) { return $null }
    return ($fw | Sort-Object Length -Descending | Select-Object -First 1)
}

function Get-LibraryBios {
    <#
        .SYNOPSIS
        STUB: the driver-library (LAN server) BIOS source is not set up yet.
        When it is, this resolves "do we have this board's BIOS and is it the
        latest" against the mirror and returns an entry; today it logs and
        returns $null so the vendor path runs.
    #>
    [CmdletBinding()]
    param(
        [string] $Model,
        [string] $MirrorBase
    )
    Write-Log ("BIOS library source: not configured yet (stub) - skipping mirror lookup for '{0}'." -f $Model) -Level Debug
    return $null
}

function Get-BiosStagingRoot {
    <#
        .SYNOPSIS
        Where to put the firmware file so the UEFI flash tool can find it: the
        root of the removable drive the tool runs from (BIOS\ folder), else
        %ProgramData%\<app>\bios (operator copies to FAT32 media if needed).
    #>
    [CmdletBinding()]
    param()
    try {
        $qualifier = [IO.Path]::GetPathRoot((Get-FirstBootRoot))
        if ($qualifier -and $qualifier -match '^[A-Za-z]:\\$') {
            $drive = New-Object IO.DriveInfo ($qualifier)
            if ($drive.DriveType -eq [IO.DriveType]::Removable) {
                return (Join-Path $qualifier 'BIOS')
            }
        }
    } catch { }
    return (Join-Path (Get-ProgramDataRoot) 'bios')
}

function Save-BiosPackage {
    <#
        .SYNOPSIS
        Downloads the BIOS entry, extracts it when zipped, finds the firmware
        file and copies it to the staging root. Returns
        { FirmwarePath; StagedPath; SizeBytes } or throws.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Entry)

    $work = Join-Path (Get-WorkDirectory) 'bios'
    if (-not (Test-Path -LiteralPath $work)) { New-Item -ItemType Directory -Path $work -Force -WhatIf:$false | Out-Null }

    $fileName = [IO.Path]::GetFileName(($Entry.Url -split '\?')[0])
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = 'bios_package.bin' }
    $dest = Join-Path $work $fileName

    Write-Log "Downloading BIOS $($Entry.Name) ($($Entry.Version))..." -Level Info
    Save-Download -Url $Entry.Url -Destination $dest -Activity "Downloading BIOS $($Entry.Version)" | Out-Null

    $hash = ''
    $hashAlg = 'SHA256'
    if ($Entry.PSObject.Properties['Hash'])    { $hash = [string]$Entry.Hash }
    if ($Entry.PSObject.Properties['HashAlg'] -and $Entry.HashAlg) { $hashAlg = [string]$Entry.HashAlg }
    if (-not (Test-FileHash -Path $dest -ExpectedHash $hash -Algorithm $hashAlg)) {
        throw "BIOS package failed $hashAlg verification."
    }

    $fwSource = $dest
    if ([IO.Path]::GetExtension($fileName) -ieq '.zip') {
        $extractDir = Expand-DriverArchive -Path $dest -WhatIf:$false
        $fw = Find-FirmwareFile -Root $extractDir
        if (-not $fw) { throw "No firmware file (.cap/.rom/.bin/.bio/.fd/.Fnn) found inside $fileName." }
        $fwSource = $fw.FullName
    }

    $stagingRoot = Get-BiosStagingRoot
    if (-not (Test-Path -LiteralPath $stagingRoot)) { New-Item -ItemType Directory -Path $stagingRoot -Force -WhatIf:$false | Out-Null }
    $staged = Join-Path $stagingRoot ([IO.Path]::GetFileName($fwSource))
    if ($PSCmdlet.ShouldProcess($staged, "stage firmware file")) {
        Copy-Item -LiteralPath $fwSource -Destination $staged -Force
    }

    return [pscustomobject]@{
        FirmwarePath = $fwSource
        StagedPath   = $staged
        SizeBytes    = (Get-Item -LiteralPath $fwSource).Length
    }
}

function Install-LanDriverFromRepo {
    <#
        .SYNOPSIS
        Offline fallback: install any LAN driver INFs staged under lan-drivers/
        on the stick via pnputil. Returns a result; when the folder is empty this
        becomes the documented manual step. (-WhatIf gating happens inside
        Invoke-Pnputil.)
    #>
    [CmdletBinding()]
    param()

    $result = [pscustomobject]@{ Step = 'lan-driver'; Status = $null; Detail = $null }
    $dir = Join-Path (Get-FirstBootRoot) 'lan-drivers'
    $infs = @()
    if (Test-Path -LiteralPath $dir) {
        $infs = @(Get-ChildItem -LiteralPath $dir -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
    }

    if ($infs.Count -eq 0) {
        Write-Log "MANUAL STEP: no internet and no staged LAN drivers. Load the board's LAN driver by hand (or stage INF packs under lan-drivers\ on the stick - see lan-drivers\README.md), then re-run." -Level Warn
        $result.Status = 'NeedsManual'; $result.Detail = "no INFs under $dir"
        return $result
    }

    $pattern = Join-Path $dir '*.inf'
    if (Test-Rehearsal) {
        Write-Log ("REHEARSE: {0} staged LAN INF(s); would run: pnputil.exe /add-driver ""{1}"" /subdirs /install" -f $infs.Count, $pattern) -Level Info -Data @{
            infCount = $infs.Count; command = "pnputil.exe /add-driver `"$pattern`" /subdirs /install"
        }
        $result.Status = 'Rehearsed'; $result.Detail = "$($infs.Count) INF(s)"
        return $result
    }

    Write-Log "Offline: installing $($infs.Count) staged LAN driver INF(s) via pnputil..." -Level Info
    $code = Invoke-Pnputil -InfPattern $pattern
    $result.Status = if ($code -in 0, 3010) { 'Installed' } else { 'Failed' }
    $result.Detail = "pnputil exit $code"
    return $result
}

function Restart-ToFirmware {
    <#
        .SYNOPSIS
        Reboots directly into UEFI setup (shutdown /r /fw) so the technician can
        flash the staged BIOS. Requires an elevated UEFI system; logs the manual
        route (reboot + DEL/F2) if scheduling fails.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $DelaySeconds = 10)

    if (Test-Rehearsal) {
        Write-Log ("REHEARSE: would run: shutdown.exe /r /fw /t {0} (reboot straight into UEFI setup)" -f $DelaySeconds) -Level Info -Data @{
            command = "shutdown.exe /r /fw /t $DelaySeconds"
        }
        return $true
    }

    if ($PSCmdlet.ShouldProcess('this machine', "reboot to UEFI setup in $DelaySeconds s (shutdown /r /fw)")) {
        & shutdown.exe /r /fw /t $DelaySeconds /c "firstboot: rebooting to UEFI setup for the BIOS update"
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Rebooting to UEFI setup in $DelaySeconds seconds..." -Level Success
            return $true
        }
        Write-Log "shutdown /r /fw failed (exit $LASTEXITCODE; legacy BIOS or not elevated?). Reboot manually and enter setup (DEL/F2) to flash." -Level Warn
        return $false
    }
    return $false
}

function Invoke-BiosStage {
    <#
        .SYNOPSIS
        The stage-1 BIOS flow: skip when already done (state marker), check
        connectivity (LAN-driver fallback when offline), resolve the latest
        non-beta BIOS (library stub -> vendor list), stage it, mark state, and
        reboot to UEFI. Auto-reboot happens ONLY when a file was staged; the
        fallback path leaves the machine up and hands the operator the steps.
        Returns { Status; Detail; RebootRequested }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Board,
        $Provider,
        $Identity,
        [AllowEmptyCollection()][array] $RawDrivers = @(),
        [string] $MirrorBase
    )

    $result = [pscustomobject]@{ Status = $null; Detail = $null; RebootRequested = $false }

    $state = Get-FirstBootState
    if ($state.PSObject.Properties['biosStage'] -and $state.biosStage.completed) {
        Write-Log ("BIOS stage already completed on {0} (version {1}); skipping (delete {2} to redo)." -f `
            $state.biosStage.when, $state.biosStage.version, (Get-FirstBootStatePath)) -Level Info
        $result.Status = 'Skipped'; $result.Detail = 'state marker present'
        return $result
    }

    # Connectivity: probe the board vendor's support host.
    $vendorHost = $null
    if ($Provider) {
        try { $vendorHost = ([uri](& $Provider.GetFallbackUrl $Identity $Board.Model)).Host } catch { }
    }
    $online = if ($vendorHost) { Test-HostReachable -TargetHost $vendorHost } else { $false }
    if (-not $online) {
        Write-Log "No route to the vendor ($(if ($vendorHost) { $vendorHost } else { 'unknown host' })); trying the offline LAN-driver fallback." -Level Warn
        $lan = Install-LanDriverFromRepo
        if ($lan.Status -eq 'Installed') {
            Start-Sleep -Seconds 5   # give the fresh NIC a moment to come up
            $online = if ($vendorHost) { Test-HostReachable -TargetHost $vendorHost } else { $false }
        }
        if (-not $online) {
            Write-Log "MANUAL STEP: still offline. Get networking up (LAN driver / USB NIC / tether), then re-run. BIOS staging + UEFI reboot will resume from here." -Level Warn
            $result.Status = 'Blocked'; $result.Detail = "offline (lan fallback: $($lan.Status))"
            return $result
        }
    }

    # 1) Driver library / LAN server (stub until the server side exists).
    $entry = Get-LibraryBios -Model $Board.Model -MirrorBase $MirrorBase

    # 2) Vendor list: BIOS/Firmware category entries, newest non-beta.
    if (-not $entry) {
        $biosEntries = @($RawDrivers | Where-Object { [string]$_.Category -match '(?i)bios|firmware' })
        Write-Log ("Vendor list carries {0} BIOS/firmware entr(ies) for '{1}'." -f $biosEntries.Count, $Board.Model) -Level Info
        $entry = Select-LatestBios -Entries $biosEntries
    }

    if (-not $entry) {
        # No headless BIOS source for this vendor yet: operator fallback.
        $page = $null
        if ($Provider) { try { $page = & $Provider.GetFallbackUrl $Identity $Board.Model } catch { } }
        Write-Log ("MANUAL STEP: no headless BIOS source for {0} yet. Download the latest NON-BETA BIOS from the support page{1}, put it on FAT32 media, then run: shutdown /r /fw" -f `
            $Board.Vendor, $(if ($page) { ": $page" } else { '' })) -Level Warn
        if ($page) { Open-Url -Url $page }
        $result.Status = 'Fallback'; $result.Detail = 'no headless BIOS entries; support page handed to operator'
        return $result
    }

    Write-Log ("BIOS selected: {0} {1} (non-beta latest)" -f $entry.Name, $entry.Version) -Level Success

    if (Test-Rehearsal) {
        $probe = Invoke-HttpProbe -Url $entry.Url
        $sizeTxt = if ($probe.Ok -and $probe.SizeBytes) { '{0:N1} MB' -f ($probe.SizeBytes / 1MB) } else { 'size unknown' }
        $staging = Get-BiosStagingRoot
        if ($probe.Ok) {
            Write-Log ("REHEARSE: BIOS reachable (HTTP {0}, {1}); would download, extract, stage the firmware file to {2}, mark state, then reboot to UEFI (shutdown /r /fw). The flash itself stays manual." -f `
                $probe.StatusCode, $sizeTxt, $staging) -Level Info -Data @{
                url = [string]$entry.Url; sizeBytes = $probe.SizeBytes; stagingRoot = $staging
            }
            $result.Status = 'Rehearsed'; $result.Detail = "would stage to $staging"
        } else {
            Write-Log ("REHEARSE: BIOS URL unreachable: {0} :: {1}" -f $entry.Url, $probe.Error) -Level Warn
            $result.Status = 'Blocked'; $result.Detail = "probe failed: $($probe.Error)"
        }
        return $result
    }

    try {
        $staged = Save-BiosPackage -Entry $entry
        Set-FirstBootStateValue -Name 'biosStage' -Value @{
            completed = $true
            version   = [string]$entry.Version
            stagedTo  = [string]$staged.StagedPath
            when      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        } | Out-Null
        Write-Log ("BIOS {0} staged at: {1}" -f $entry.Version, $staged.StagedPath) -Level Success
        Write-Log 'OPERATOR: after the reboot, flash from UEFI (EZ Flash / Q-Flash / M-Flash / Instant Flash) using the staged file, then boot back into Windows and re-run - the pipeline continues from the drivers stage.' -Level Info
        $result.RebootRequested = Restart-ToFirmware
        $result.Status = 'Staged'; $result.Detail = "$($entry.Version) -> $($staged.StagedPath)"
    } catch {
        Write-Log "BIOS staging failed: $($_.Exception.Message)" -Level Error
        $result.Status = 'Failed'; $result.Detail = $_.Exception.Message
    }
    return $result
}

Export-ModuleMember -Function `
    Test-BetaBios, Select-LatestBios, Find-FirmwareFile, Get-LibraryBios, `
    Get-BiosStagingRoot, Save-BiosPackage, Install-LanDriverFromRepo, `
    Restart-ToFirmware, Invoke-BiosStage
