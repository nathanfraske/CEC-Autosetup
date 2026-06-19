# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Detect-Gpu.psm1 - enumerate display adapters (Win32_VideoController) and
# classify each by vendor (nvidia / amd / intel) from the PCI VEN_ id. The GPU
# phase then installs the matching vendor app (NVIDIA App / AMD Adrenalin /
# Intel Arc), which pulls the actual driver. The CIM call is isolated so the
# classification is unit-testable by injecting controller objects.

Set-StrictMode -Version Latest

function Get-VideoControllerList {
    <#
        .SYNOPSIS
        Raw Win32_VideoController list. Wrapped so detection can be mocked.
    #>
    [CmdletBinding()]
    param()
    return Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
        Select-Object Name, PNPDeviceID, AdapterCompatibility
}

function Resolve-GpuVendor {
    <#
        .SYNOPSIS
        Classifies a display adapter as 'nvidia' | 'amd' | 'intel' | $null.
        Prefers the PCI VEN_ id (10DE/1002/8086); falls back to the name /
        AdapterCompatibility string for odd cases.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string] $PnpDeviceId,
        [AllowEmptyString()][string] $Name,
        [AllowEmptyString()][string] $AdapterCompatibility
    )

    $ven = $null
    $m = [regex]::Match([string]$PnpDeviceId, 'VEN_(?<v>[0-9A-Fa-f]{4})')
    if ($m.Success) { $ven = $m.Groups['v'].Value.ToUpperInvariant() }
    switch ($ven) {
        '10DE' { return 'nvidia' }
        '1002' { return 'amd' }
        '8086' { return 'intel' }
    }

    $text = ("{0} {1}" -f $Name, $AdapterCompatibility)
    switch -Regex ($text) {
        '(?i)nvidia'                          { return 'nvidia' }
        '(?i)advanced micro devices|\bAMD\b|radeon' { return 'amd' }
        '(?i)intel'                           { return 'intel' }
        default                               { return $null }
    }
}

function Get-Gpus {
    <#
        .SYNOPSIS
        Normalised adapters { Name; Vendor; PnpDeviceId }. Pass -Controllers to
        inject raw objects (testing / dry runs).
    #>
    [CmdletBinding()]
    param([psobject[]] $Controllers)

    if (-not $Controllers) { $Controllers = Get-VideoControllerList }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Controllers) {
        $out.Add([pscustomobject]@{
            Name        = [string]$c.Name
            Vendor      = Resolve-GpuVendor -PnpDeviceId ([string]$c.PNPDeviceID) -Name ([string]$c.Name) -AdapterCompatibility ([string]$c.AdapterCompatibility)
            PnpDeviceId = [string]$c.PNPDeviceID
        }) | Out-Null
    }
    return $out.ToArray()
}

function Get-GpuVendors {
    <#
        .SYNOPSIS
        The distinct, recognised GPU vendors present (e.g. @('nvidia','intel')).
    #>
    [CmdletBinding()]
    param([psobject[]] $Controllers)
    return @(Get-Gpus -Controllers $Controllers | Where-Object { $_.Vendor } |
        Select-Object -ExpandProperty Vendor -Unique)
}

Export-ModuleMember -Function Get-VideoControllerList, Resolve-GpuVendor, Get-Gpus, Get-GpuVendors
