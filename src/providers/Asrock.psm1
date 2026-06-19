# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors
#
# Asrock.psm1 - ASRock provider (fallback-only).
#
# www.asrock.com is behind Incapsula/Imperva and the driver/BIOS lists load via
# a client-side XHR, so a headless fetch yields manuals, not drivers. This
# provider therefore reports SupportsHeadless=$false and routes to the Chrome
# fallback with the model's index.asp#Download page. The download CDN
# (download.asrock.com) is open, so downloads work once URLs are known.
#
# TODO(asrock-xhr): The driver XHR endpoint behind www.asrock.com is NOT
# publicly documented and has not been captured. Recording it requires a real
# browser DevTools session (or a browser agent / Claude-in-Chrome). Until then,
# ASRock stays fallback-only. Do NOT invent an endpoint to make a test pass.
# See docs/vendor-contracts.md (2.4) and its "Open items" section.

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.psm1')

# Per the provider contract, exposed both as a module variable and via the
# factory's SupportsHeadless property.
$script:SupportsHeadless = $false

$script:AmdChipsets = @(
    'X870E', 'X870', 'X670E', 'X670', 'B650E', 'B650', 'B850', 'A620',
    'X570', 'B550', 'A520', 'X470', 'B450', 'X370', 'B350', 'A320',
    'TRX50', 'TRX40', 'WRX90', 'WRX80'
)
$script:IntelChipsets = @(
    'Z890', 'B860', 'H810', 'Z790', 'B760', 'H770', 'Z690', 'B660', 'H670',
    'H610', 'Z590', 'B560', 'H510', 'Q570', 'Z490', 'H470', 'B460', 'H410',
    'Z390', 'Z370', 'H370', 'B365', 'B360', 'H310', 'Z270', 'Z170'
)

function Get-AsrockPlatform {
    <#
        .SYNOPSIS
        Classifies a model as 'AMD' or 'Intel' from its chipset token. Defaults to
        'AMD' (with a logged warning) when the chipset is unrecognized; the result
        only affects the fallback URL path segment.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Model)

    $first = ($Model.Trim() -split '\s+')[0].ToUpperInvariant()
    foreach ($c in $script:AmdChipsets)   { if ($first.StartsWith($c)) { return 'AMD' } }
    foreach ($c in $script:IntelChipsets) { if ($first.StartsWith($c)) { return 'Intel' } }
    Write-Log "ASRock: could not classify '$Model' as AMD/Intel; defaulting to AMD for the fallback URL." -Level Warn
    return 'AMD'
}

function Resolve-AsrockProduct {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Model, [string] $Slug)   # $Slug ignored (URL constructible)

    $platform = Get-AsrockPlatform -Model $Model
    $enc = [uri]::EscapeDataString($Model.Trim())
    $url = ('{0}/{1}/{2}/index.asp#Download' -f (Get-Settings).asrock.supportBase, $platform, $enc)

    return [pscustomobject]@{
        Vendor     = 'asrock'
        Model      = $Model
        Platform   = $platform
        SupportUrl = $url
    }
}

function Get-AsrockDriverList {
    <#
        .SYNOPSIS
        Always throws: ASRock cannot be listed headlessly (see module TODO).
    #>
    [CmdletBinding()]
    param($Identity, [int] $Osid = 0)
    throw [System.NotSupportedException]::new(
        'ASRock driver listing is not available headlessly (Incapsula + client-side XHR). Use the Chrome fallback. See Asrock.psm1 TODO(asrock-xhr).')
}

function Get-AsrockFallbackUrl {
    [CmdletBinding()]
    param($Identity, [string] $Model)
    if ($Identity -and $Identity.SupportUrl) { return $Identity.SupportUrl }
    return (Resolve-AsrockProduct -Model $Model).SupportUrl
}

function Get-AsrockProvider {
    [pscustomobject]@{
        Name             = 'asrock'
        SupportsHeadless = $false
        ResolveProduct   = ${function:Resolve-AsrockProduct}
        GetDriverList    = ${function:Get-AsrockDriverList}
        GetFallbackUrl   = ${function:Get-AsrockFallbackUrl}
    }
}

Export-ModuleMember -Function `
    Get-AsrockPlatform, Resolve-AsrockProduct, Get-AsrockDriverList, `
    Get-AsrockFallbackUrl, Get-AsrockProvider
