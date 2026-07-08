# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Asus.psm1 - ASUS provider (headless). Implements the internal JSON API:
#   1. PDInfo        : model slug -> numeric ProductID
#   2. GetPDDrivers  : ProductID + osid -> driver list
# Contract and live test vectors are documented in docs/vendor-contracts.md (2.2).

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.psm1')

function Get-PropValue {
    param($Obj, [string] $Name)
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) {
        return $Obj.PSObject.Properties[$Name].Value
    }
    return $null
}

function Get-AsusModelSlug {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Model)
    $slug = $Model.Trim().ToLowerInvariant()
    $slug = $slug -replace '[^a-z0-9]+', '-'   # spaces and punctuation -> hyphen
    $slug = $slug -replace '-+', '-'
    return $slug.Trim('-')
}

function Get-AsusSeriesCandidates {
    <#
        .SYNOPSIS
        Series slug candidates from the first 3, then 2, then 1 token(s) of the
        model slug, per the ASUS contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ModelSlug)

    $tokens = $ModelSlug.Split('-') | Where-Object { $_ -ne '' }
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($n in 3, 2, 1) {
        if ($tokens.Count -ge $n) {
            $candidates.Add(($tokens[0..($n - 1)] -join '-')) | Out-Null
        }
    }
    return ($candidates | Select-Object -Unique)
}

function Get-AsusProductIdFromPdInfo {
    <#
        .SYNOPSIS
        Parses a PDInfo JSON body and returns Result.ProductID as [int], or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $JsonText)

    try { $json = $JsonText | ConvertFrom-Json } catch { return $null }
    $result = Get-PropValue $json 'Result'
    $productId = Get-PropValue $result 'ProductID'
    if ($null -ne $productId -and "$productId" -ne '' -and [int]$productId -gt 0) {
        return [int]$productId
    }
    return $null
}

function Get-AsusPdInfo {
    <#
        .SYNOPSIS
        Parses a PDInfo body into { ProductID; Pdhashedid; Name }, or $null when
        there is no resolvable product. Pdhashedid is present only on newer boards;
        Name is the canonical catalog name (may be null on older boards).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $JsonText)

    try { $json = $JsonText | ConvertFrom-Json } catch { return $null }
    $result    = Get-PropValue $json 'Result'
    $productId = Get-PropValue $result 'ProductID'
    $hasId     = ($null -ne $productId -and "$productId" -ne '' -and [int]$productId -gt 0)
    if (-not $hasId) { return $null }

    return [pscustomobject]@{
        ProductID  = [int]$productId
        Pdhashedid = [string](Get-PropValue $result 'Pdhashedid')
        Name       = [string](Get-PropValue $result 'Name')
    }
}

function Resolve-AsusProduct {
    <#
        .SYNOPSIS
        Resolves a board model to an ASUS identity. PDInfo enrichment (canonical
        Name + Pdhashedid + ProductID) is attempted across series-slug candidates,
        but ASUS drivers resolve from the model name alone, so this ALWAYS returns
        an identity (falling back to the raw model with an empty Pdhashedid).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Model, [string] $Slug)   # $Slug ignored (uniform contract)

    $s = Get-Settings
    $modelSlug  = Get-AsusModelSlug -Model $Model
    $candidates = Get-AsusSeriesCandidates -ModelSlug $modelSlug

    foreach ($series in $candidates) {
        $url = ('{0}?SystemCode={1}&WebsiteCode={2}&SeriesWebPath={3}&ProductWebPath={4}' -f `
            $s.asus.pdInfoBase, $s.asus.systemCode, $s.asus.websiteCode, $series, $modelSlug)
        try {
            $body = Invoke-Http -Url $url
        } catch {
            Write-Log "ASUS PDInfo request failed for series '$series': $($_.Exception.Message)" -Level Warn
            continue
        }
        $pd = Get-AsusPdInfo -JsonText $body
        if ($pd) {
            $name = if ($pd.Name) { $pd.Name } else { $Model }
            Write-Log "ASUS resolved '$Model' -> series '$series', ProductID $($pd.ProductID)$(if($pd.Pdhashedid){" (pdhashedid $($pd.Pdhashedid))"})" -Level Success
            return [pscustomobject]@{
                Vendor     = 'asus'
                Model      = $Model
                Name       = $name
                ModelSlug  = $modelSlug
                SeriesPath = $series
                ProductID  = $pd.ProductID
                Pdhashedid = $pd.Pdhashedid
            }
        }
    }

    # No PDInfo hit: the model-keyed driver call still works from the name alone.
    Write-Log "ASUS PDInfo did not resolve '$Model'; will fetch drivers by model name (empty pdhashedid)." -Level Warn
    return [pscustomobject]@{
        Vendor     = 'asus'
        Model      = $Model
        Name       = $Model
        ModelSlug  = $modelSlug
        SeriesPath = $null
        ProductID  = $null
        Pdhashedid = ''
    }
}

function ConvertFrom-AsusDriverJson {
    <#
        .SYNOPSIS
        Parses a GetPDDrivers JSON body into uniform driver entries. Returns
        $null when Status is not SUCCESS so callers can probe other osids.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $JsonText)

    try { $json = $JsonText | ConvertFrom-Json } catch { return $null }

    $status = Get-PropValue $json 'Status'
    if ($status -ne 'SUCCESS') { return $null }

    $result = Get-PropValue $json 'Result'
    $obj    = Get-PropValue $result 'Obj'
    if (-not $obj) { return @() }

    $cdnBase = (Get-Settings).asus.cdnBase
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($cat in $obj) {
        $files = Get-PropValue $cat 'Files'
        if (-not $files) { continue }
        foreach ($f in $files) {
            $dl  = Get-PropValue $f 'DownloadUrl'
            $rel = Get-PropValue $dl 'Global'
            if ([string]::IsNullOrWhiteSpace($rel)) { continue }
            $entries.Add([pscustomobject]@{
                Provider    = 'asus'
                Category    = [string](Get-PropValue $cat 'Name')
                Name        = [string](Get-PropValue $f 'Title')
                Version     = [string](Get-PropValue $f 'Version')
                Url         = $cdnBase + $rel
                Hash        = [string](Get-PropValue $f 'sha256')
                HashAlg     = 'SHA256'
                ReleaseDate = [string](Get-PropValue $f 'ReleaseDate')
                FileSize    = [string](Get-PropValue $f 'FileSize')
            }) | Out-Null
        }
    }
    return $entries.ToArray()
}

function Get-AsusDriverList {
    <#
        .SYNOPSIS
        Fetches the ASUS driver list for an identity. With a specific -Osid, makes
        one call; otherwise probes the configured osid candidates and keeps the
        response with the most entries (open item: per-board osid).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Identity,
        [int] $Osid = 0
    )

    $s = Get-Settings
    # Version-agnostic contract: key on model name + pdhashedid, NEVER pdid.
    # pdid breaks newer boards (Z890/X870E) with "Input string was not in a
    # correct format"; the model-keyed call works across all generations.
    $modelName = if ($Identity.Name) { $Identity.Name } else { $Identity.Model }
    $hash = if ($Identity.Pdhashedid) { $Identity.Pdhashedid } else { '' }
    $encModel = [uri]::EscapeDataString([string]$modelName)
    $encHash  = [uri]::EscapeDataString([string]$hash)

    $osidsToTry = if ($Osid -gt 0) { @($Osid) } else { @($s.asus.osidCandidates) }

    $best = $null
    $bestOsid = 0
    foreach ($osid in $osidsToTry) {
        $url = ('{0}?website={1}&model={2}&pdhashedid={3}&cpu=&osid={4}' -f `
            $s.asus.driversBase, $s.asus.websiteCode, $encModel, $encHash, $osid)
        try {
            $body = Invoke-Http -Url $url -Headers @{ 'Content-Type' = 'text/plain' }
        } catch {
            Write-Log "ASUS GetPDDrivers osid=$osid failed: $($_.Exception.Message)" -Level Warn
            continue
        }
        $entries = ConvertFrom-AsusDriverJson -JsonText $body
        $count = if ($entries) { @($entries).Count } else { 0 }
        Write-Log "ASUS osid=$osid -> $count driver file(s)" -Level Debug
        if ($count -gt 0 -and (-not $best -or $count -gt @($best).Count)) {
            $best = $entries
            $bestOsid = $osid
        }
        if ($Osid -gt 0) { break }
    }

    if (-not $best) {
        throw "ASUS returned no drivers for '$modelName' (tried osid: $($osidsToTry -join ', '))."
    }
    Write-Log "ASUS selected osid=$bestOsid with $(@($best).Count) driver file(s)" -Level Success
    return $best
}

function Get-AsusFallbackUrl {
    [CmdletBinding()]
    param($Identity, [string] $Model)
    if (-not $Model -and $Identity) { $Model = $Identity.Model }
    $enc = [uri]::EscapeDataString(([string]$Model).Trim())
    return ('{0}/{1}/helpdesk_download/' -f (Get-Settings).asus.fallbackBase, $enc)
}

function Get-AsusProvider {
    [pscustomobject]@{
        Name             = 'asus'
        SupportsHeadless = $true
        ResolveProduct   = ${function:Resolve-AsusProduct}
        GetDriverList    = ${function:Get-AsusDriverList}
        GetFallbackUrl   = ${function:Get-AsusFallbackUrl}
    }
}

Export-ModuleMember -Function `
    Get-AsusModelSlug, Get-AsusSeriesCandidates, Get-AsusProductIdFromPdInfo, `
    Get-AsusPdInfo, Resolve-AsusProduct, ConvertFrom-AsusDriverJson, `
    Get-AsusDriverList, Get-AsusFallbackUrl, Get-AsusProvider
