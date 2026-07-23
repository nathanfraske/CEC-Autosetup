# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# DriverLibrary.psm1 - the local-mirror "source" layer. Separates driver
# acquisition (where files come from) from resolution (which files a board needs,
# done by the providers). A shop runs tools/Build-DriverLibrary.ps1 on an Ubuntu
# box to pre-pull drivers into a tree that mirrors the vendor CDN paths + an
# index.json keyed by normalized board identifier, serves it on the LAN
# (tools/Serve-DriverLibrary.ps1), and points clients at it with -Mirror. The
# client then pulls the list AND files from the LAN (hash-verified), falling back
# to the vendor online on a miss. See docs/driver-library.md.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Mapping.psm1')

# Vendor CDN host -> mirror subdir key. The mirror reproduces each CDN's path
# under <key>/..., so the client just swaps the host.
function Get-VendorCdnKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Url)
    $h = ''
    try { $h = ([uri]$Url).Host } catch { return $null }
    switch -Regex ($h) {
        '(?i)dlcdnets\.asus\.com'        { return 'asus' }
        '(?i)download(-\d+)?\.msi\.com'  { return 'msi' }
        '(?i)download\.gigabyte\.com'    { return 'gigabyte' }
        '(?i)download\.asrock\.com'      { return 'asrock' }
        '(?i)download\.nvidia\.com'      { return 'nvidia' }
        default                          { return $null }
    }
}

function Get-MirrorRelativePath {
    <#
        .SYNOPSIS
        Maps a vendor CDN URL to its mirror-relative path "<key>/<cdn path>"
        (query stripped, %-decoded). $null when the host isn't a known CDN.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Url)
    $key = Get-VendorCdnKey -Url $Url
    if (-not $key) { return $null }
    $path = ([uri]$Url).LocalPath        # decoded, no query
    return ($key + $path) -replace '//+', '/'
}

function Get-MirrorUrl {
    <#
        .SYNOPSIS
        Builds the mirror URL for a relative path under a mirror base, escaping
        each path segment so the static server resolves it to the decoded file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][string] $MirrorBase
    )
    $segs = $RelativePath.Trim('/').Split('/') | ForEach-Object {
        # .NET Framework's EscapeDataString (RFC 2396) leaves !'()* bare; encode
        # them too so mirror URLs are byte-identical on PowerShell 5.1 and 7.
        [uri]::EscapeDataString($_).Replace('!', '%21').Replace("'", '%27').
            Replace('(', '%28').Replace(')', '%29').Replace('*', '%2A')
    }
    return ($MirrorBase.TrimEnd('/') + '/' + ($segs -join '/'))
}

function ConvertTo-MirrorDriverEntry {
    <#
        .SYNOPSIS
        Turns a library index entry into the uniform driver entry the install
        engine consumes, with the Url pointing at the mirror.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $LibEntry,
        [Parameter(Mandatory)][string] $MirrorBase
    )
    return [pscustomobject]@{
        Provider = 'mirror'
        Category = [string]$LibEntry.category
        Name     = [string]$LibEntry.name
        Version  = [string]$LibEntry.version
        Url      = Get-MirrorUrl -RelativePath ([string]$LibEntry.relPath) -MirrorBase $MirrorBase
        Hash     = [string]$LibEntry.hash
        HashAlg  = if ($LibEntry.PSObject.Properties['hashAlg'] -and $LibEntry.hashAlg) { [string]$LibEntry.hashAlg } else { 'SHA256' }
    }
}

function Get-LibraryIndex {
    <#
        .SYNOPSIS
        Fetches index.json from a mirror base (or reads a local path). Returns the
        parsed object, or $null on failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $MirrorBase)
    try {
        if ($MirrorBase -match '^https?://') {
            return (Invoke-Http -Url (($MirrorBase.TrimEnd('/')) + '/index.json') | ConvertFrom-Json)
        }
        $p = Join-Path $MirrorBase 'index.json'
        if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) }
    } catch { Write-Log "Mirror index unavailable ($MirrorBase): $($_.Exception.Message)" -Level Warn }
    return $null
}

function Find-LibraryEntries {
    <#
        .SYNOPSIS
        Returns the raw library entries for a board (matched by normalized model
        key), or @() if the board isn't in the mirror.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Index,
        [Parameter(Mandatory)][string] $Model
    )
    if (-not $Index -or -not $Index.PSObject.Properties['boards']) { return @() }
    $key = Get-NormalizedModelKey $Model
    foreach ($p in $Index.boards.PSObject.Properties) {
        if ((Get-NormalizedModelKey $p.Name) -eq $key) {
            if ($p.Value.PSObject.Properties['entries']) { return @($p.Value.entries) }
        }
    }
    return @()
}

function Get-LibraryChipsetTokens {
    <#
        .SYNOPSIS
        Flattens config/library-chipsets.json (current + lastGen, all platforms)
        into a single token list. Pass -Chipsets to inject (testing).
    #>
    [CmdletBinding()]
    param($Chipsets)
    if (-not $Chipsets) {
        $p = Join-Path (Get-FirstBootRoot) 'config/library-chipsets.json'
        if (-not (Test-Path -LiteralPath $p)) { return @() }
        $Chipsets = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    }
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($plat in $Chipsets.PSObject.Properties) {
        if ($plat.Name -eq '_comment') { continue }
        foreach ($gen in 'current', 'lastGen') {
            if ($plat.Value.PSObject.Properties[$gen]) {
                foreach ($t in @($plat.Value.$gen)) { $tokens.Add([string]$t) | Out-Null }
            }
        }
    }
    return ($tokens | Select-Object -Unique)
}

function Select-LibraryBoards {
    <#
        .SYNOPSIS
        From a mapping table (normalized key -> {vendor,model,slug}), returns the
        headless-pullable boards (asus/msi/gigabyte) whose model contains one of
        the chipset tokens (whole-token, case-insensitive). Deduped by model.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Mapping,
        [Parameter(Mandatory)][string[]] $Tokens
    )
    if (-not $Tokens -or $Tokens.Count -eq 0) { return @() }
    $rx = '(?i)(^|[^0-9A-Za-z])(' + (($Tokens | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')([^0-9A-Za-z]|$)'
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($kv in $Mapping.GetEnumerator()) {
        $e = $kv.Value
        $vendor = [string]$e.vendor
        if ($vendor -notin 'asus', 'msi', 'gigabyte') { continue }   # ASRock not headless-pullable
        $model = [string]$e.model
        if (-not ($model -match $rx)) { continue }
        if (-not $seen.Add($kv.Key)) { continue }
        $slug = if ($e.PSObject.Properties['slug']) { [string]$e.slug } else { $null }
        $out.Add([pscustomobject]@{ vendor = $vendor; model = $model; slug = $slug }) | Out-Null
    }
    return $out.ToArray()
}

function Get-LibraryGpuInstaller {
    <#
        .SYNOPSIS
        Returns the mirror URL of a staged GPU-vendor installer (amd|intel) from
        the library index's optional gpuInstallers map, or $null. Lets a shop drop
        the latest Adrenalin/Intel installer in the library and have clients
        silent-install it over the LAN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Index,
        [Parameter(Mandatory)][string] $Vendor,
        [Parameter(Mandatory)][string] $MirrorBase
    )
    if (-not $Index -or -not $Index.PSObject.Properties['gpuInstallers']) { return $null }
    $prop = $Index.gpuInstallers.PSObject.Properties | Where-Object { $_.Name -ieq $Vendor } | Select-Object -First 1
    if (-not $prop) { return $null }
    $rel = [string]$prop.Value.relPath
    if ([string]::IsNullOrWhiteSpace($rel)) { return $null }
    return ($MirrorBase.TrimEnd('/') + '/' + $rel.TrimStart('/'))
}

Export-ModuleMember -Function `
    Get-VendorCdnKey, Get-MirrorRelativePath, Get-MirrorUrl, ConvertTo-MirrorDriverEntry, `
    Get-LibraryIndex, Find-LibraryEntries, Get-LibraryChipsetTokens, Select-LibraryBoards, `
    Get-LibraryGpuInstaller
