# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors
#
# Msi.psm1 - MSI provider (headless JSON API, keyed on model slug).
# Frontend call sequence under https://www.msi.com/api/v1/product/support/ :
#   os?product={slug}&type=driver           -> available OS strings (exact)
#   panel?product={slug}&type=driver&os=... -> driver data (result.downloads dict)
# Akamai-fronted: needs a full browser header set + a Referer of the support page;
# treat a sudden Access Denied as throttling. SHA-256 is present on every file.
# Contract + live vectors: docs/vendor-contracts.md (MSI).

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.psm1')

function Get-MsiProp {
    param($Obj, [string] $Name)
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) {
        return $Obj.PSObject.Properties[$Name].Value
    }
    return $null
}

function Get-MsiSlug {
    <#
        .SYNOPSIS
        MSI slug = model name with non-alphanumerics collapsed to hyphens, case
        preserved. e.g. 'MAG B650 TOMAHAWK WIFI' -> 'MAG-B650-TOMAHAWK-WIFI'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Model)
    $slug = $Model.Trim() -replace '[^A-Za-z0-9]+', '-'
    return $slug.Trim('-')
}

function Get-MsiHeaders {
    param([string] $Referer)
    $h = @{
        'User-Agent'         = (Get-DefaultHttpHeaders)['User-Agent']
        'Accept'             = 'application/json, text/plain, */*'
        'Accept-Language'    = 'en-US,en;q=0.9'
        'sec-ch-ua'          = '"Chromium";v="126", "Google Chrome";v="126", "Not.A/Brand";v="24"'
        'sec-ch-ua-mobile'   = '?0'
        'sec-ch-ua-platform' = '"Windows"'
        'Sec-Fetch-Dest'     = 'empty'
        'Sec-Fetch-Mode'     = 'cors'
        'Sec-Fetch-Site'     = 'same-origin'
    }
    if ($Referer) { $h['Referer'] = $Referer }
    return $h
}

function Resolve-MsiProduct {
    <#
        .SYNOPSIS
        Builds an MSI identity from the model. The slug is constructible, so no
        network call is needed to resolve.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Model, [string] $Slug)   # $Slug ignored (constructible)
    $slug = Get-MsiSlug -Model $Model
    return [pscustomobject]@{
        Vendor     = 'msi'
        Model      = $Model
        Slug       = $slug
        SupportUrl = ('{0}/{1}/support' -f (Get-Settings).msi.supportBase, $slug)
    }
}

function Get-MsiOsList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $JsonText)
    try { $json = $JsonText | ConvertFrom-Json } catch { return @() }
    $res = Get-MsiProp $json 'result'
    if (-not $res) { return @() }
    return @($res)
}

function Select-MsiOs {
    [CmdletBinding()]
    param([string[]] $OsList, [string[]] $Preferred)
    foreach ($p in $Preferred) { if ($OsList -contains $p) { return $p } }
    if (@($OsList).Count -gt 0) { return $OsList[0] }
    return $null
}

function ConvertFrom-MsiPanel {
    <#
        .SYNOPSIS
        Parses a panel body into uniform driver entries. result.downloads is a
        dict of category -> entry list, plus metadata keys type_title/os (skipped).
        download_sha256 is formatted 'SHA-256:<hex>'; we extract the 64-hex.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $JsonText)

    try { $json = $JsonText | ConvertFrom-Json } catch { return $null }
    $status = Get-MsiProp (Get-MsiProp $json 'status') 'code'
    if ($status -and [int]$status -ne 200) { return $null }

    $result    = Get-MsiProp $json 'result'
    $downloads = Get-MsiProp $result 'downloads'
    if (-not $downloads) { return @() }   # 'false' when os param missing

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($prop in $downloads.PSObject.Properties) {
        if ($prop.Name -in 'type_title', 'os') { continue }
        foreach ($e in @($prop.Value)) {
            $url = [string](Get-MsiProp $e 'download_url')
            if ([string]::IsNullOrWhiteSpace($url)) { continue }
            $rawHash = [string](Get-MsiProp $e 'download_sha256')
            $hash = ''
            $m = [regex]::Match($rawHash, '[a-fA-F0-9]{64}')
            if ($m.Success) { $hash = $m.Value }
            $entries.Add([pscustomobject]@{
                Provider    = 'msi'
                Category    = $prop.Name
                Name        = [string](Get-MsiProp $e 'download_title')
                Version     = [string](Get-MsiProp $e 'download_version')
                Url         = $url
                Hash        = $hash
                HashAlg     = 'SHA256'
                ReleaseDate = [string](Get-MsiProp $e 'download_release')
                FileSize    = [string](Get-MsiProp $e 'download_size')
            }) | Out-Null
        }
    }
    return $entries.ToArray()
}

function Get-MsiDriverList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Identity,
        [int] $Osid = 0   # MSI uses OS strings, not numeric osid; kept for parity
    )

    $s = Get-Settings
    $slug = $Identity.Slug
    $headers = Get-MsiHeaders -Referer $Identity.SupportUrl

    $osBody = Invoke-Http -Url ('{0}/os?product={1}&type=driver' -f $s.msi.apiBase, $slug) -Headers $headers
    $osList = Get-MsiOsList -JsonText $osBody
    $os = Select-MsiOs -OsList $osList -Preferred @($s.msi.preferredOs)
    if (-not $os) {
        throw "MSI returned no OS options for '$slug' (possible Akamai challenge)."
    }

    $panelUrl = ('{0}/panel?product={1}&type=driver&os={2}' -f $s.msi.apiBase, $slug, [uri]::EscapeDataString($os))
    $panelBody = Invoke-Http -Url $panelUrl -Headers $headers
    $entries = ConvertFrom-MsiPanel -JsonText $panelBody
    if (@($entries).Count -eq 0) {
        throw "MSI returned 0 drivers for '$slug' (os=$os)."
    }
    Write-Log "MSI parsed $(@($entries).Count) driver(s) for '$slug' (os=$os)" -Level Success
    return $entries
}

function Get-MsiFallbackUrl {
    [CmdletBinding()]
    param($Identity, [string] $Model)
    if ($Identity -and $Identity.SupportUrl) { return $Identity.SupportUrl }
    return (Resolve-MsiProduct -Model $Model).SupportUrl
}

function Get-MsiProvider {
    [pscustomobject]@{
        Name             = 'msi'
        SupportsHeadless = $true
        ResolveProduct   = ${function:Resolve-MsiProduct}
        GetDriverList    = ${function:Get-MsiDriverList}
        GetFallbackUrl   = ${function:Get-MsiFallbackUrl}
    }
}

Export-ModuleMember -Function `
    Get-MsiSlug, Get-MsiHeaders, Resolve-MsiProduct, Get-MsiOsList, Select-MsiOs, `
    ConvertFrom-MsiPanel, Get-MsiDriverList, Get-MsiFallbackUrl, Get-MsiProvider
