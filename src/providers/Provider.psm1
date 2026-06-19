# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors
#
# Provider.psm1 - the provider contract + registry.
#
# Every vendor module exports a factory (Get-<Vendor>Provider) that returns a
# provider object with this shape:
#
#   [pscustomobject]@{
#       Name             = 'asus'                       # provider key
#       SupportsHeadless = $true                         # can Get-DriverList work without a browser?
#       ResolveProduct   = { param($Model) ... }         # -> identity object or $null
#       GetDriverList    = { param($Identity,$Osid) ... }# -> array of driver entries, or throws
#       GetFallbackUrl   = { param($Identity,$Model) ...}# -> human-openable support/download URL
#   }
#
# Driver entry shape (uniform across providers):
#   [pscustomobject]@{ Category; Name; Version; Url; Hash; HashAlg; ... }
#
# The factory's script blocks are created inside the vendor module, so they keep
# that module's session state and can call its private helpers. This keeps the
# orchestrator vendor-agnostic and avoids function-name collisions between
# providers. See docs/adding-a-provider.md.

Set-StrictMode -Version Latest

$script:Registry = @{
    asus     = @{ Module = 'Asus.psm1';     Factory = 'Get-AsusProvider' }
    msi      = @{ Module = 'Msi.psm1';      Factory = 'Get-MsiProvider' }
    gigabyte = @{ Module = 'Gigabyte.psm1'; Factory = 'Get-GigabyteProvider' }
    asrock   = @{ Module = 'Asrock.psm1';   Factory = 'Get-AsrockProvider' }
}

function Get-SupportedVendors {
    return ($script:Registry.Keys | Sort-Object)
}

function Get-Provider {
    <#
        .SYNOPSIS
        Imports the vendor module for $Vendor and returns its provider object,
        or $null when the vendor is not registered.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Vendor)

    if ([string]::IsNullOrWhiteSpace($Vendor)) { return $null }
    $key = $Vendor.ToLowerInvariant()
    if (-not $script:Registry.ContainsKey($key)) { return $null }

    $entry = $script:Registry[$key]
    $modulePath = Join-Path $PSScriptRoot $entry.Module
    Import-Module $modulePath -Force
    return (& $entry.Factory)
}

Export-ModuleMember -Function Get-SupportedVendors, Get-Provider
