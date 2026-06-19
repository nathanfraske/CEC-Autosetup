# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Build-DriverLibrary.ps1 - pre-pull drivers for a list of boards into a local
# library tree (mirrors vendor CDN paths) + index.json, for serving on the LAN
# (tools/Serve-DriverLibrary.ps1). Runs on Ubuntu/Linux under pwsh (reuses the
# providers). Idempotent: existing, hash-verified files are skipped. NETWORK-GATED.
# ASRock is skipped (Incapsula blocks headless). See docs/driver-library.md.
#
#   pwsh -File tools/Build-DriverLibrary.ps1                 # build into ./library
#   pwsh -File tools/Build-DriverLibrary.ps1 -OutputDir /srv/drivers
#   pwsh -File tools/Build-DriverLibrary.ps1 -WhatIf        # plan only

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $OutputDir,
    [string] $BoardsPath,
    [switch] $ExplicitOnly    # only config/library-boards.json (skip the chipset-filtered catalog)
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/Common.psm1') -Force
Import-Module (Join-Path $root 'src/Mapping.psm1') -Force
Import-Module (Join-Path $root 'src/Install-Engine.psm1') -Force
Import-Module (Join-Path $root 'src/DriverLibrary.psm1') -Force
Import-Module (Join-Path $root 'src/providers/Provider.psm1') -Force

$s = Get-Settings
if (-not $OutputDir)  { $OutputDir  = Join-Path $root ([string]$s.library.outputDir) }
if (-not $BoardsPath) { $BoardsPath = Join-Path $root ([string]$s.library.boardsPath) }

# Board list = explicit supplement (library-boards.json) UNION the current +
# last-gen catalog (config/mapping.json filtered by config/library-chipsets.json).
$boards = New-Object System.Collections.Generic.List[object]
$seenBoards = New-Object System.Collections.Generic.HashSet[string]
function Add-LibraryBoard($b) {
    $k = Get-NormalizedModelKey ([string]$b.model)
    if ($k -and $seenBoards.Add($k)) { $boards.Add($b) | Out-Null }
}
if (Test-Path -LiteralPath $BoardsPath) {
    foreach ($b in (Get-Content -LiteralPath $BoardsPath -Raw | ConvertFrom-Json).boards) { Add-LibraryBoard $b }
    Write-Host ("Explicit boards (library-boards.json): {0}" -f $boards.Count)
}
if (-not $ExplicitOnly) {
    $tokens = @(Get-LibraryChipsetTokens)
    $mapBoards = Select-LibraryBoards -Mapping (Get-Mapping) -Tokens $tokens
    foreach ($b in $mapBoards) { Add-LibraryBoard $b }
    Write-Host ("Current+last-gen from mapping ({0} chipset tokens): {1} board(s)." -f @($tokens).Count, @($mapBoards).Count)
}
if ($boards.Count -eq 0) {
    throw "No boards to build. Populate config/mapping.json (Build-AsusMapping / Build-GigabyteMapping) and/or config/library-boards.json."
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Write-Host ("Driver library -> {0} ({1} board(s) total)" -f $OutputDir, $boards.Count)

$index = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd'); boards = [ordered]@{} }
$totalFiles = 0
$totalBytes = 0L

foreach ($b in $boards) {
    $vendor = [string]$b.vendor
    $model  = [string]$b.model
    $slug   = if ($b.PSObject.Properties['slug']) { [string]$b.slug } else { $null }
    $osid   = if ($b.PSObject.Properties['osid']) { [int]$b.osid } else { 0 }
    Write-Host ""
    Write-Host "=== $vendor / $model ==="

    $provider = Get-Provider -Vendor $vendor
    if (-not $provider -or -not $provider.SupportsHeadless) {
        Write-Log "Skipping '$model' ($vendor): not headless-pullable." -Level Warn
        continue
    }

    try {
        $identity = & $provider.ResolveProduct $model $slug
        $drivers  = & $provider.GetDriverList $identity $osid
    } catch {
        Write-Log "Resolve/list failed for '$model': $($_.Exception.Message)" -Level Warn
        continue
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($d in $drivers) {
        $rel = Get-MirrorRelativePath -Url $d.Url
        if (-not $rel) { Write-Log "  skip (unknown CDN host): $($d.Url)" -Level Warn; continue }
        $dest = Join-Path $OutputDir $rel

        $have = (Test-Path -LiteralPath $dest) -and (Test-FileHash -Path $dest -ExpectedHash $d.Hash -Algorithm $d.HashAlg)
        if (-not $have) {
            if ($PSCmdlet.ShouldProcess($rel, "download $($d.Url)")) {
                try {
                    Save-Download -Url $d.Url -Destination $dest -Activity "[$model] $($d.Category): $($d.Name)" | Out-Null
                    if (-not (Test-FileHash -Path $dest -ExpectedHash $d.Hash -Algorithm $d.HashAlg)) {
                        Write-Log "  hash mismatch, skipping: $rel" -Level Error; continue
                    }
                } catch { Write-Log "  download failed: $($d.Url) :: $($_.Exception.Message)" -Level Warn; continue }
            } else { continue }
        } else {
            Write-Log "  cached: $rel" -Level Debug
        }

        $len = if (Test-Path -LiteralPath $dest) { (Get-Item -LiteralPath $dest).Length } else { 0 }
        $totalFiles++; $totalBytes += $len
        $entries.Add([ordered]@{
            category = [string]$d.Category; name = [string]$d.Name; version = [string]$d.Version
            relPath = $rel; hash = [string]$d.Hash; hashAlg = [string]$d.HashAlg; size = $len
        }) | Out-Null
    }

    if ($entries.Count -gt 0) {
        $index.boards[$model] = [ordered]@{ vendor = $vendor; model = $model; entries = $entries.ToArray() }
        Write-Host ("  {0} file(s) mirrored." -f $entries.Count)
    }
}

Write-Host ""
Write-Host ("Total: {0} files, {1:N1} GB across {2} board(s)." -f $totalFiles, ($totalBytes / 1GB), $index.boards.Count)
$indexPath = Join-Path $OutputDir 'index.json'
if ($PSCmdlet.ShouldProcess($indexPath, 'write index.json')) {
    ($index | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $indexPath -Encoding UTF8
    Write-Host "Wrote $indexPath"
    Write-Host "Serve it:  pwsh -File tools/Serve-DriverLibrary.ps1 -Root '$OutputDir' -Port 8080"
}
