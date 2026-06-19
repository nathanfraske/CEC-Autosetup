# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors
#
# Detect-Hardware.psm1 - motherboard detection via Win32_BaseBoard, mapped to a
# provider vendor. The CIM call is isolated so the mapping logic is unit-testable
# on any platform by injecting a board object.

Set-StrictMode -Version Latest

function Get-BaseBoard {
    <#
        .SYNOPSIS
        Thin wrapper around Win32_BaseBoard so detection can be mocked in tests.
    #>
    [CmdletBinding()]
    param()
    return Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop |
        Select-Object -First 1 Manufacturer, Product, Version
}

function Resolve-Vendor {
    <#
        .SYNOPSIS
        Maps a manufacturer string to a provider key, or $null when unknown.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Manufacturer)

    switch -Regex ($Manufacturer) {
        '(?i)asrock'             { return 'asrock' }   # check before ASUS (distinct strings, but explicit)
        '(?i)asus'               { return 'asus' }
        '(?i)giga-?byte'         { return 'gigabyte' }
        '(?i)micro-?star|\bMSI\b' { return 'msi' }
        default                  { return $null }
    }
}

function Get-MotherboardInfo {
    <#
        .SYNOPSIS
        Returns { Vendor; Model; Manufacturer; Version }. Pass -BaseBoard to inject
        a board object (testing / dry runs); otherwise queries Win32_BaseBoard.
    #>
    [CmdletBinding()]
    param([psobject] $BaseBoard)

    if (-not $BaseBoard) {
        $BaseBoard = Get-BaseBoard
    }

    $manufacturer = [string]$BaseBoard.Manufacturer
    $model        = [string]$BaseBoard.Product
    $version      = [string]$BaseBoard.Version

    [pscustomobject]@{
        Vendor       = Resolve-Vendor -Manufacturer $manufacturer
        Model        = $model.Trim()
        Manufacturer = $manufacturer.Trim()
        Version      = $version.Trim()
    }
}

Export-ModuleMember -Function Get-BaseBoard, Resolve-Vendor, Get-MotherboardInfo
