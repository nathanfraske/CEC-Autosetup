# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors
#
# Gigabyte.psm1 - Gigabyte provider (headless, server-rendered HTML).
# The support page renders the full driver table; we regex out the CDN URLs,
# dedup by driverId keeping document order (newest first), and use the ?v=
# query value as the file's MD5. www.gigabyte.com sits behind Akamai Bot
# Manager, so an undersized response is treated as a challenge.
# Contract + live vectors: docs/vendor-contracts.md (2.3).

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.psm1')

function Get-GigabyteHeaders {
    return @{
        'User-Agent'                = (Get-DefaultHttpHeaders)['User-Agent']
        'Accept'                    = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
        'Accept-Language'           = 'en-US,en;q=0.9'
        'sec-ch-ua'                 = '"Chromium";v="126", "Google Chrome";v="126", "Not.A/Brand";v="24"'
        'sec-ch-ua-mobile'          = '?0'
        'sec-ch-ua-platform'        = '"Windows"'
        'Sec-Fetch-Dest'            = 'document'
        'Sec-Fetch-Mode'            = 'navigate'
        'Sec-Fetch-Site'            = 'none'
        'Upgrade-Insecure-Requests' = '1'
    }
}

function Get-GigabyteSlug {
    <#
        .SYNOPSIS
        Best-effort slug from the model (UPPER, spaces -> hyphen). Gigabyte
        support URLs also embed a board revision that is not exposed by
        Win32_BaseBoard; pass -Slug explicitly when the revision is known.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Model)
    $slug = $Model.Trim().ToUpperInvariant()
    $slug = $slug -replace '[^A-Z0-9]+', '-'
    $slug = $slug -replace '-+', '-'
    return $slug.Trim('-')
}

function Resolve-GigabyteProduct {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Model,
        [string] $Slug
    )
    if (-not $Slug) { $Slug = Get-GigabyteSlug -Model $Model }
    $supportUrl = ('{0}/{1}/support' -f (Get-Settings).gigabyte.supportBase, $Slug)
    return [pscustomobject]@{
        Vendor     = 'gigabyte'
        Model      = $Model
        Slug       = $Slug
        SupportUrl = $supportUrl
    }
}

function Test-GigabyteChallenge {
    <#
        .SYNOPSIS
        $true when the response looks like an Akamai bot-challenge stub: empty,
        or smaller than the configured minimum (default 50 KB).
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $Content)

    if ([string]::IsNullOrEmpty($Content)) { return $true }
    $min = 51200
    try { $min = [int](Get-Settings).gigabyte.challengeMinBytes } catch { }
    return ($Content.Length -lt $min)
}

function Get-GigabyteCategory {
    <#
        .SYNOPSIS
        Best-effort component category from a Gigabyte driver name token. Used for
        display and the allow/deny filter; none of these map to the deny-list, so
        the precise label does not change which Gigabyte drivers are installed.
    #>
    [CmdletBinding()]
    param([string] $Name)
    $n = ([string]$Name).ToLowerInvariant()
    switch -Regex ($n) {
        '8125|8168|8111|gbe|ethernet|killer|_lan|^lan' { return 'LAN' }
        '8922|8852|amdwifi|wifi|wireless|wlan'         { return 'Wireless' }
        'bluetooth|_bt$|^bt'                           { return 'Bluetooth' }
        'realtekdch|audio|nahimic'                     { return 'Audio' }
        'chipset'                                      { return 'Chipset' }
        'apu|vga|graphics|radeon|amdgpu|display|dchsetup' { return 'VGA' }
        'raid|sata|rste?|_rst'                         { return 'SATA' }
        'mei|managementengine|^me$'                    { return 'ME' }
        'usb'                                          { return 'USB' }
        'thunderbolt|tbt'                              { return 'Thunderbolt' }
        default { if ($Name) { return (Get-Culture).TextInfo.ToTitleCase($n) } else { return 'Driver' } }
    }
}

function Get-GigabyteDriverEntry {
    <#
        .SYNOPSIS
        Parses one Gigabyte driver filename + md5 into a uniform entry.
        Filename shape: mb_driver_<driverId>_<name>_<version>[_<suffix>]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FileBase,  # filename without extension
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $Md5
    )

    $driverId = $null
    $name = $FileBase
    $version = ''

    $m = [regex]::Match($FileBase, '^mb_driver_(?<id>[^_]+)_(?<rest>.+)$')
    if ($m.Success) {
        $driverId = $m.Groups['id'].Value
        $rest = $m.Groups['rest'].Value
        $vm = [regex]::Match($rest, '^(?<name>.+?)[_\.](?<ver>[A-Za-z]?\d+(?:[._]\d+)+.*)$')
        if ($vm.Success) {
            $name    = $vm.Groups['name'].Value
            $version = $vm.Groups['ver'].Value
        }
        else {
            $name = $rest
        }
    }

    return [pscustomobject]@{
        Provider = 'gigabyte'
        DriverId = $driverId
        Category = Get-GigabyteCategory -Name $name
        Name     = $name
        Version  = $version
        Url      = $Url
        Hash     = $Md5
        HashAlg  = 'MD5'
    }
}

function ConvertFrom-GigabyteSupport {
    <#
        .SYNOPSIS
        Extracts driver entries from a Gigabyte support page. Document order is
        newest-first; we dedup by driverId and keep the first (latest) occurrence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Html)

    $pattern = 'https://download\.gigabyte\.com/FileList/Driver/(?<file>[^"''?\s]+)\.zip\?v=(?<md5>[a-fA-F0-9]+)'
    $regexMatches = [regex]::Matches($Html, $pattern)

    $seen = New-Object System.Collections.Generic.HashSet[string]
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($match in $regexMatches) {
        $fileBase = $match.Groups['file'].Value
        $md5      = $match.Groups['md5'].Value
        $url      = $match.Value
        $entry    = Get-GigabyteDriverEntry -FileBase $fileBase -Url $url -Md5 $md5

        $key = if ($entry.DriverId) { 'id:' + $entry.DriverId } else { 'file:' + $fileBase }
        if ($seen.Add($key)) {
            $entries.Add($entry) | Out-Null
        }
    }
    return $entries.ToArray()
}

function Get-GigabyteDriverList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Identity,
        [int] $Osid = 0   # not applicable to Gigabyte; kept for contract parity
    )

    $html = Invoke-Http -Url $Identity.SupportUrl -Headers (Get-GigabyteHeaders)

    if (Test-GigabyteChallenge -Content $html) {
        throw "Gigabyte returned an undersized response (Akamai bot challenge) for $($Identity.SupportUrl). Falling back to browser."
    }

    $entries = ConvertFrom-GigabyteSupport -Html $html
    if (@($entries).Count -eq 0) {
        throw "Gigabyte support page yielded 0 drivers for slug '$($Identity.Slug)' (the slug may need a board revision)."
    }
    Write-Log "Gigabyte parsed $(@($entries).Count) driver component(s) for '$($Identity.Slug)'" -Level Success
    return $entries
}

function Get-GigabyteFallbackUrl {
    [CmdletBinding()]
    param($Identity, [string] $Model)
    if ($Identity -and $Identity.SupportUrl) { return $Identity.SupportUrl }
    return (Resolve-GigabyteProduct -Model $Model).SupportUrl
}

function Get-GigabyteProvider {
    [pscustomobject]@{
        Name             = 'gigabyte'
        SupportsHeadless = $true
        ResolveProduct   = ${function:Resolve-GigabyteProduct}
        GetDriverList    = ${function:Get-GigabyteDriverList}
        GetFallbackUrl   = ${function:Get-GigabyteFallbackUrl}
    }
}

Export-ModuleMember -Function `
    Get-GigabyteHeaders, Get-GigabyteSlug, Resolve-GigabyteProduct, `
    Test-GigabyteChallenge, Get-GigabyteCategory, Get-GigabyteDriverEntry, `
    ConvertFrom-GigabyteSupport, Get-GigabyteDriverList, Get-GigabyteFallbackUrl, `
    Get-GigabyteProvider
