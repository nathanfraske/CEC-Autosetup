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

    if (-not $PSCmdlet.ShouldProcess($GpuName, "download + silent-install NVIDIA $($info.Version)")) {
        Write-Log "PLAN: install NVIDIA driver $($info.Version) for '$GpuName' <- $($info.Url)" -Level Info
        $result.Status = 'WhatIf'; return $result
    }

    $s = Get-Settings
    try {
        $dest = Join-Path (Get-WorkDirectory) ([IO.Path]::GetFileName(($info.Url -split '\?')[0]))
        Write-Log "Downloading NVIDIA driver $($info.Version) (large file)..." -Level Info
        Save-Download -Url $info.Url -Destination $dest | Out-Null
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
    ConvertFrom-NvidiaDriverLookup, Get-NvidiaDriverInfo, Install-NvidiaDriver
