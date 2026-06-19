# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Test-VendorCanary.ps1 - LIVE early-warning check against each vendor's
# known-good vector, exercising the real provider code paths. NETWORK-GATED:
# run manually or on a schedule, NEVER in the offline unit suite. Exits non-zero
# if any vendor's live call breaks (so a scheduled job can alert), which is how
# we learn an undocumented endpoint moved before it bites a real build.

[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/Common.psm1') -Force
Import-Module (Join-Path $root 'src/providers/Provider.psm1') -Force

$results = New-Object System.Collections.Generic.List[object]
function Add-Result($Vendor, $Ok, $Detail) {
    $results.Add([pscustomobject]@{ Vendor = $Vendor; Ok = $Ok; Detail = $Detail }) | Out-Null
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0,-8}] {1}  {2}" -f $Vendor, $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Detail) -ForegroundColor $color
}

# ASUS - model-keyed call on a known board.
try {
    $p = Get-Provider -Vendor asus
    $id = & $p.ResolveProduct 'ROG STRIX Z490-I GAMING' $null
    $d = & $p.GetDriverList $id 52
    $n = @($d).Count
    Add-Result -Vendor 'asus' -Ok ($n -ge 1 -and $id.ProductID -eq 14684) -Detail "ProductID $($id.ProductID), $n drivers"
} catch { Add-Result -Vendor 'asus' -Ok $false -Detail $_.Exception.Message }

# MSI - os/panel for a known slug.
try {
    $p = Get-Provider -Vendor msi
    $id = & $p.ResolveProduct 'MAG B650 TOMAHAWK WIFI' $null
    $d = & $p.GetDriverList $id 0
    Add-Result -Vendor 'msi' -Ok (@($d).Count -ge 1) -Detail "$(@($d).Count) drivers"
} catch { Add-Result -Vendor 'msi' -Ok $false -Detail $_.Exception.Message }

# Gigabyte - support HTML for a known rev-slug.
try {
    $p = Get-Provider -Vendor gigabyte
    $id = & $p.ResolveProduct 'B650 GAMING X AX V2' 'B650-GAMING-X-AX-V2-rev-10-11-12'
    $d = & $p.GetDriverList $id 0
    Add-Result -Vendor 'gigabyte' -Ok (@($d).Count -ge 1) -Detail "$(@($d).Count) components"
} catch { Add-Result -Vendor 'gigabyte' -Ok $false -Detail $_.Exception.Message }

# ASRock - CDN connectivity sanity (driver list is browser-only by design).
try {
    $cdn = (Get-Settings).asrock.cdnBase + '/Manual/X870E%20Taichi.pdf'
    Invoke-Http -Url $cdn -Method HEAD | Out-Null
    Add-Result -Vendor 'asrock' -Ok $true -Detail "CDN reachable ($cdn)"
} catch { Add-Result -Vendor 'asrock' -Ok $false -Detail "CDN check failed: $($_.Exception.Message)" }

$failed = @($results | Where-Object { -not $_.Ok })
Write-Host ""
Write-Host ("Canary: {0}/{1} vendors OK." -f ($results.Count - $failed.Count), $results.Count)
if ($failed.Count -gt 0) {
    Write-Host "FAILURES: $($failed.Vendor -join ', ') - a vendor endpoint may have moved; re-capture." -ForegroundColor Red
    exit 1
}
exit 0
