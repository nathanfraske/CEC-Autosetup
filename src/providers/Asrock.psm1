# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Asrock.psm1 - ASRock provider.
#
# Captured contract (2026-06-19, browser): the Download tab loads a static HTML
# fragment from the board's own directory via jQuery .load():
#   GET https://www.asrock.com/mb/<Brand>/<Model>/Download.html
# Rows: description "<name> ver:<version>", a "SHA256:<hex>" line, and Global/China
# links on download.asrock.com:
#   https://download.asrock.com/Drivers/All/<Category>/<Name>(v<version>).zip
#
# HEADLESS BLOCKER (verified): www.asrock.com is behind Incapsula, which serves a
# ~212-byte JS-challenge stub (with _Incapsula_Resource) to non-browser clients -
# even when carrying the board page's cookies, because clearance requires running
# the challenge JS. Plain PowerShell/Invoke-WebRequest therefore cannot fetch the
# fragment, so SupportsHeadless stays $false and ASRock routes to the Chrome
# fallback. The parser + URL builder below are ready: flip SupportsHeadless to
# $true the day a JS-capable fetch path supplies the fragment (e.g. the tool
# driving headless Chrome, or a browser agent handing over the HTML/cookies).
# See docs/vendor-contracts.md (ASRock).

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.psm1')

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
        'AMD' (with a logged warning) when unrecognized; only affects the URL path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Model)

    $first = ($Model.Trim() -split '\s+')[0].ToUpperInvariant()
    foreach ($c in $script:AmdChipsets)   { if ($first.StartsWith($c)) { return 'AMD' } }
    foreach ($c in $script:IntelChipsets) { if ($first.StartsWith($c)) { return 'Intel' } }
    Write-Log "ASRock: could not classify '$Model' as AMD/Intel; defaulting to AMD for the URL." -Level Warn
    return 'AMD'
}

function Get-AsrockDownloadUrl {
    <#
        .SYNOPSIS
        The board's Download.html fragment URL (the jQuery .load() target).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Platform, [Parameter(Mandatory)][string] $Model)
    $enc = [uri]::EscapeDataString($Model.Trim())
    return ('{0}/{1}/{2}/Download.html' -f (Get-Settings).asrock.supportBase, $Platform, $enc)
}

function Resolve-AsrockProduct {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Model, [string] $Slug)   # $Slug ignored (URL constructible)

    $platform = Get-AsrockPlatform -Model $Model
    $enc = [uri]::EscapeDataString($Model.Trim())
    return [pscustomobject]@{
        Vendor          = 'asrock'
        Model           = $Model
        Platform        = $platform
        SupportUrl      = ('{0}/{1}/{2}/index.asp#Download' -f (Get-Settings).asrock.supportBase, $platform, $enc)
        DownloadHtmlUrl = Get-AsrockDownloadUrl -Platform $platform -Model $Model
    }
}

function Test-AsrockChallenge {
    <#
        .SYNOPSIS
        $true if the body is an Incapsula challenge stub rather than the fragment.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string] $Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return $true }
    if ($Content -match '_Incapsula_Resource|Incapsula incident') { return $true }
    return ($Content.Length -lt 1024)
}

function ConvertFrom-AsrockDownloadHtml {
    <#
        .SYNOPSIS
        Parses a Download.html fragment into uniform driver entries. Category, Name,
        and Version come from the download.asrock.com URL
        (/Drivers/All/<Category>/<Name>(v<version>).zip); deduped by URL.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Html)

    $pattern = 'https://download\.asrock\.com/Drivers/(?:All/)?(?<cat>[^/]+)/(?<file>[^"''<>\s]+?)\.zip'
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($m in [regex]::Matches($Html, $pattern)) {
        $url = $m.Value
        if (-not $seen.Add($url)) { continue }
        $cat  = $m.Groups['cat'].Value
        $file = $m.Groups['file'].Value
        $name = $file
        $version = ''
        $vm = [regex]::Match($file, '^(?<name>.+?)\(v(?<ver>[^)]+)\)$')
        if ($vm.Success) { $name = $vm.Groups['name'].Value; $version = $vm.Groups['ver'].Value }
        $entries.Add([pscustomobject]@{
            Provider = 'asrock'
            Category = $cat
            Name     = $name
            Version  = $version
            Url      = $url
            Hash     = ''           # SHA256 line present in fragment; per-row mapping TBD
            HashAlg  = 'SHA256'
        }) | Out-Null
    }
    return $entries.ToArray()
}

function Get-AsrockDriverList {
    <#
        .SYNOPSIS
        Attempts the Download.html fragment and parses it. Throws on the Incapsula
        challenge (the headless case today) so the orchestrator falls back to the
        browser. Wired and tested for the day a JS-capable fetch is available.
    #>
    [CmdletBinding()]
    param($Identity, [int] $Osid = 0)

    $url = if ($Identity -and $Identity.DownloadHtmlUrl) { $Identity.DownloadHtmlUrl }
           else { Get-AsrockDownloadUrl -Platform (Get-AsrockPlatform -Model $Identity.Model) -Model $Identity.Model }

    $html = $null
    try { $html = Invoke-Http -Url $url -Headers (@{ 'X-Requested-With' = 'XMLHttpRequest' }) } catch { }
    if (Test-AsrockChallenge -Content $html) {
        throw [System.NotSupportedException]::new(
            "ASRock returned an Incapsula challenge for $url (browser required). Use the Chrome fallback.")
    }
    $entries = ConvertFrom-AsrockDownloadHtml -Html $html
    if (@($entries).Count -eq 0) { throw "ASRock Download.html yielded 0 drivers for $url." }
    Write-Log "ASRock parsed $(@($entries).Count) driver(s) from Download.html." -Level Success
    return $entries
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
        SupportsHeadless = $false   # Incapsula JS challenge blocks non-browser fetch (see header)
        ResolveProduct   = ${function:Resolve-AsrockProduct}
        GetDriverList    = ${function:Get-AsrockDriverList}
        GetFallbackUrl   = ${function:Get-AsrockFallbackUrl}
    }
}

Export-ModuleMember -Function `
    Get-AsrockPlatform, Get-AsrockDownloadUrl, Resolve-AsrockProduct, `
    Test-AsrockChallenge, ConvertFrom-AsrockDownloadHtml, Get-AsrockDriverList, `
    Get-AsrockFallbackUrl, Get-AsrockProvider
