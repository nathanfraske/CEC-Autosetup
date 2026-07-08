# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Detect-Peripherals.psm1 - enumerate PnP/USB devices so the apps layer can
# decide which peripheral software to install (e.g. SignalRGB for RGB gear,
# Thermalright Control Center for TR coolers). The CIM call is isolated so the
# parsing/normalisation is unit-testable by injecting device objects.

Set-StrictMode -Version Latest

function Get-PnpDeviceList {
    <#
        .SYNOPSIS
        Raw Win32_PnPEntity list (Name, DeviceID, PNPClass, Manufacturer).
        Wrapped so detection can be mocked in tests.
    #>
    [CmdletBinding()]
    param()
    return Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
        Select-Object Name, DeviceID, PNPClass, Manufacturer
}

function Get-VidPid {
    <#
        .SYNOPSIS
        Extracts "VVVV:PPPP" (upper-case hex) from a PnP DeviceID, or $null.
        Handles USB\, HID\, and similar VID_/PID_ device paths.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $DeviceId)

    if ([string]::IsNullOrWhiteSpace($DeviceId)) { return $null }
    $m = [regex]::Match($DeviceId, 'VID_(?<v>[0-9A-Fa-f]{4}).*?PID_(?<p>[0-9A-Fa-f]{4})')
    if ($m.Success) {
        return ('{0}:{1}' -f $m.Groups['v'].Value.ToUpperInvariant(), $m.Groups['p'].Value.ToUpperInvariant())
    }
    return $null
}

function Get-Peripherals {
    <#
        .SYNOPSIS
        Returns normalised devices { Name; DeviceId; VidPid; Class; Manufacturer }.
        Pass -Devices to inject raw objects (testing / dry runs).
    #>
    [CmdletBinding()]
    param([psobject[]] $Devices)

    if (-not $Devices) { $Devices = Get-PnpDeviceList }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in $Devices) {
        $deviceId = [string]$d.DeviceID
        $out.Add([pscustomobject]@{
            Name         = [string]$d.Name
            DeviceId     = $deviceId
            VidPid       = Get-VidPid -DeviceId $deviceId
            Class        = [string]$d.PNPClass
            Manufacturer = [string]$d.Manufacturer
        }) | Out-Null
    }
    return $out.ToArray()
}

Export-ModuleMember -Function Get-PnpDeviceList, Get-VidPid, Get-Peripherals
