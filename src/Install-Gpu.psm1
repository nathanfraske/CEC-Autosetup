# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Install-Gpu.psm1 - fully-unattended NVIDIA GPU driver install via NVIDIA's
# headless driver-lookup API:
#   lookupValueSearch (TypeID=3)  GPU name -> { psid=ParentID, pfid=Value }
#   DriverManualLookup            psid+pfid+osID -> latest driver .exe
#   silent install                <driver>.exe -s -noreboot
# AMD/Intel have no comparable clean headless API (bot-walled), so their drivers
# come from the vendor app (Adrenalin auto-installs; Intel app) in the apps phase.
# Contract + live vectors: docs/vendor-contracts.md (GPU drivers).

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Install-Engine.psm1')

function Get-NvProp {
    param($Obj, [string] $Name)
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.PSObject.Properties[$Name].Value }
    return $null
}

function Get-NvidiaNormalizedName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Name)
    $n = $Name.ToLowerInvariant()
    $n = $n -replace '^\s*nvidia\s+', ''     # drop leading vendor prefix
    $n = $n -replace '[^a-z0-9]+', ' '
    return $n.Trim()
}

function Get-NvidiaProducts {
    <#
        .SYNOPSIS
        Parses a lookupValueSearch (TypeID=3) XML body into product rows
        { Psid; Pfid; Name; Norm }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Xml)

    $out = New-Object System.Collections.Generic.List[object]
    try { $doc = [xml]$Xml } catch { return @() }
    $values = $doc.LookupValueSearch.LookupValues.LookupValue
    foreach ($lv in $values) {
        if (-not $lv) { continue }
        $out.Add([pscustomobject]@{
            Psid = [string]$lv.ParentID
            Pfid = [string]$lv.Value
            Name = [string]$lv.Name
            Norm = Get-NvidiaNormalizedName ([string]$lv.Name)
        }) | Out-Null
    }
    return $out.ToArray()
}

function Resolve-NvidiaProduct {
    <#
        .SYNOPSIS
        Exact normalized-name match of a Win32_VideoController name to a product
        ({ Psid; Pfid; Name }), or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $GpuName,
        [Parameter(Mandatory)] $Products
    )
    $target = Get-NvidiaNormalizedName $GpuName
    foreach ($p in $Products) {
        if ($p.Norm -eq $target) {
            return [pscustomobject]@{ Psid = $p.Psid; Pfid = $p.Pfid; Name = $p.Name }
        }
    }
    return $null
}

function ConvertFrom-NvidiaDriverLookup {
    <#
        .SYNOPSIS
        Parses a DriverManualLookup JSON body into { Version; Url; Name }, or
        $null when no driver was found.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $JsonText)

    try { $j = $JsonText | ConvertFrom-Json } catch { return $null }
    if ("$(Get-NvProp $j 'Success')" -ne '1') { return $null }
    $ids = Get-NvProp $j 'IDS'
    if (-not $ids) { return $null }
    $info = Get-NvProp $ids[0] 'downloadInfo'
    $url = [string](Get-NvProp $info 'DownloadURL')
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    return [pscustomobject]@{
        Version = [string](Get-NvProp $info 'Version')
        Url     = $url
        Name    = [uri]::UnescapeDataString([string](Get-NvProp $info 'Name'))
    }
}

function Get-NvidiaDriverInfo {
    <#
        .SYNOPSIS
        Resolves a GPU name to the latest driver { Version; Url; Name } via the
        live lookup, or $null if it cannot be resolved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $GpuName,
        [int] $OsId = 0
    )
    $s = Get-Settings
    if (-not $OsId) { $OsId = [int]$s.nvidia.osId }

    $xml = Invoke-Http -Url $s.nvidia.lookupUrl
    $product = Resolve-NvidiaProduct -GpuName $GpuName -Products (Get-NvidiaProducts -Xml $xml)
    if (-not $product) {
        Write-Log "NVIDIA: no catalog match for '$GpuName'; the NVIDIA App will handle the driver." -Level Warn
        return $null
    }

    $url = ('{0}?func=DriverManualLookup&psid={1}&pfid={2}&osID={3}&languageCode=1033&isWHQL=1&dch=1&numberOfResults=1' -f `
        $s.nvidia.driverLookupBase, $product.Psid, $product.Pfid, $OsId)
    $info = ConvertFrom-NvidiaDriverLookup -JsonText (Invoke-Http -Url $url)
    if (-not $info) {
        Write-Log "NVIDIA: lookup returned no driver for '$GpuName' (osID=$OsId)." -Level Warn
        return $null
    }
    Write-Log "NVIDIA: '$GpuName' -> $($info.Name) $($info.Version)" -Level Success
    return $info
}

function Get-GpuSilentArgs {
    <#
        .SYNOPSIS
        The verified silent-install switch per GPU vendor (config-driven):
        NVIDIA '-s -noreboot', AMD '-INSTALL', Intel '-s'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Vendor)
    $s = Get-Settings
    switch ($Vendor.ToLowerInvariant()) {
        'nvidia' { return [string]$s.nvidia.silentArgs }
        'amd'    { return [string]$s.amd.silentArgs }
        'intel'  { return [string]$s.intel.silentArgs }
        default  { return '' }
    }
}

function Install-GpuVendorDriver {
    <#
        .SYNOPSIS
        Fully-unattended AMD/Intel GPU driver install GIVEN an installer URL
        (pinned in config or served from the driver library). Download + silent
        run with the vendor switch. Returns a result; honors -WhatIf.
        (NVIDIA uses Install-NvidiaDriver, which also resolves the URL headlessly.)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Vendor,
        [Parameter(Mandatory)][string] $InstallerUrl,
        [string] $SilentArgs
    )
    if (-not $SilentArgs) { $SilentArgs = Get-GpuSilentArgs -Vendor $Vendor }
    $result = [pscustomobject]@{ Vendor = $Vendor; Gpu = "$Vendor GPU driver"; Version = ''; Method = "gpu-driver:$Vendor"; Status = $null; Detail = $null }

    if (Test-Rehearsal) {
        $probe = Invoke-HttpProbe -Url $InstallerUrl
        $file = [IO.Path]::GetFileName(($InstallerUrl -split '\?')[0])
        if ($probe.Ok) {
            $sizeTxt = if ($probe.SizeBytes) { '{0:N1} MB' -f ($probe.SizeBytes / 1MB) } else { 'size unknown' }
            Write-Log ("REHEARSE: {0} GPU driver reachable (HTTP {1}, {2}); would run: ""<work>\{3}"" {4}" -f `
                $Vendor, $probe.StatusCode, $sizeTxt, $file, $SilentArgs) -Level Info -Data @{
                vendor = $Vendor; url = $InstallerUrl; statusCode = $probe.StatusCode
                sizeBytes = $probe.SizeBytes; command = "`"<work>\$file`" $SilentArgs"
            }
            $result.Status = 'Rehearsed'; $result.Detail = "HTTP $($probe.StatusCode), $sizeTxt"
        } else {
            Write-Log ("REHEARSE: {0} GPU installer unreachable: {1} :: {2}" -f $Vendor, $InstallerUrl, $probe.Error) -Level Warn
            $result.Status = 'Blocked'; $result.Detail = "probe failed: $($probe.Error)"
        }
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess($Vendor, "download + silent-install GPU driver ($SilentArgs)")) {
        Write-Log "PLAN: $Vendor GPU driver <- $InstallerUrl (silent: $SilentArgs)" -Level Info
        $result.Status = 'WhatIf'; return $result
    }
    try {
        $name = [IO.Path]::GetFileName(($InstallerUrl -split '\?')[0])
        if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '\.exe$') { $name = "$Vendor-gpu-driver.exe" }
        $dest = Join-Path (Get-WorkDirectory) $name
        Write-Log "Downloading $Vendor GPU driver..." -Level Info
        Save-Download -Url $InstallerUrl -Destination $dest -Activity "Downloading $Vendor GPU driver" | Out-Null
        Write-Log "Installing $Vendor GPU driver silently ($SilentArgs)..." -Level Info
        $code = Invoke-ExeInstaller -Path $dest -Arguments $SilentArgs
        # 0 ok; 1/14 vendor "reboot required"; 3010 Windows reboot-required.
        $result.Status = if ($code -in 0, 1, 14, 3010) { 'Installed' } else { 'Failed' }
        $result.Detail = "exit $code"
    } catch {
        $result.Status = 'Failed'; $result.Detail = $_.Exception.Message
    }
    return $result
}

function Install-NvidiaDriver {
    <#
        .SYNOPSIS
        Fully-unattended NVIDIA driver install: resolve -> download -> silent
        (-s -noreboot). Returns a result object; honors -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $GpuName,
        [int] $OsId = 0
    )
    $result = [pscustomobject]@{ Vendor = 'nvidia'; Gpu = $GpuName; Version = $null; Method = 'nvidia-driver'; Status = $null; Detail = $null }

    $info = $null
    try { $info = Get-NvidiaDriverInfo -GpuName $GpuName -OsId $OsId }
    catch { Write-Log "NVIDIA driver lookup failed: $($_.Exception.Message)" -Level Warn }

    if (-not $info) { $result.Status = 'NotResolved'; $result.Detail = 'no headless match; NVIDIA App will fetch the driver'; return $result }
    $result.Version = $info.Version

    if (Test-Rehearsal) {
        $nvArgs = [string](Get-Settings).nvidia.silentArgs
        $probe = Invoke-HttpProbe -Url $info.Url
        $file = [IO.Path]::GetFileName(($info.Url -split '\?')[0])
        if ($probe.Ok) {
            $sizeTxt = if ($probe.SizeBytes) { '{0:N1} MB' -f ($probe.SizeBytes / 1MB) } else { 'size unknown' }
            Write-Log ("REHEARSE: NVIDIA {0} reachable (HTTP {1}, {2}); would run: ""<work>\{3}"" {4}" -f `
                $info.Version, $probe.StatusCode, $sizeTxt, $file, $nvArgs) -Level Info -Data @{
                gpu = $GpuName; version = [string]$info.Version; url = [string]$info.Url
                statusCode = $probe.StatusCode; sizeBytes = $probe.SizeBytes
                command = "`"<work>\$file`" $nvArgs"
            }
            $result.Status = 'Rehearsed'; $result.Detail = "HTTP $($probe.StatusCode), $sizeTxt"
        } else {
            Write-Log ("REHEARSE: NVIDIA installer unreachable: {0} :: {1}" -f $info.Url, $probe.Error) -Level Warn
            $result.Status = 'Blocked'; $result.Detail = "probe failed: $($probe.Error)"
        }
        return $result
    }

    if (-not $PSCmdlet.ShouldProcess($GpuName, "download + silent-install NVIDIA $($info.Version)")) {
        Write-Log "PLAN: install NVIDIA driver $($info.Version) for '$GpuName' <- $($info.Url)" -Level Info
        $result.Status = 'WhatIf'; return $result
    }

    $s = Get-Settings
    try {
        $dest = Join-Path (Get-WorkDirectory) ([IO.Path]::GetFileName(($info.Url -split '\?')[0]))
        Write-Log "Downloading NVIDIA driver $($info.Version) (large file)..." -Level Info
        Save-Download -Url $info.Url -Destination $dest -Activity "Downloading NVIDIA driver $($info.Version)" | Out-Null
        Write-Log "Installing NVIDIA driver silently ($($s.nvidia.silentArgs))..." -Level Info
        $code = Invoke-ExeInstaller -Path $dest -Arguments $s.nvidia.silentArgs
        $result.Status = if ($code -in 0, 1) { 'Installed' } else { 'Failed' }   # NVIDIA setup uses 0/1 for success/reboot
        $result.Detail = "exit $code"
    } catch {
        $result.Status = 'Failed'; $result.Detail = $_.Exception.Message
    }
    return $result
}

Export-ModuleMember -Function `
    Get-NvidiaNormalizedName, Get-NvidiaProducts, Resolve-NvidiaProduct, `
    ConvertFrom-NvidiaDriverLookup, Get-NvidiaDriverInfo, Install-NvidiaDriver, `
    Get-GpuSilentArgs, Install-GpuVendorDriver
