# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Mapping.psm1 - naming reconciliation + the model->vendor cache.
#
# The SMBIOS Win32_BaseBoard.Product string is not always the vendor's catalog
# name (ASUS suffix drift, Gigabyte rev-slugs, MSI MS-xxxx board codes). This
# module normalizes the model, looks it up in a shipped table (config/mapping.json)
# overlaid by a writable runtime cache (%ProgramData%\firstboot\mapping.cache.json),
# and lets the orchestrator self-heal the cache after a successful live resolve.
# See docs/architecture.md (Mapping layer) and the maintainer reference.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

function Get-NormalizedModelKey {
    <#
        .SYNOPSIS
        Lower-cases, drops a trailing parenthetical board code, and collapses
        punctuation/whitespace to single spaces.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Model)
    $m = $Model.ToLowerInvariant()
    $m = $m -replace '\s*\([^)]*\)\s*$', ''   # drop trailing "(...)" board code
    $m = $m -replace '[^a-z0-9]+', ' '
    return $m.Trim()
}

function Get-MappingCachePath {
    return (Join-Path (Get-ProgramDataRoot) 'mapping.cache.json')
}

function Import-MappingFile {
    param([string] $Path)
    $table = @{}
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $entries = if ($json.PSObject.Properties['entries']) { $json.entries } else { $json }
            foreach ($p in $entries.PSObject.Properties) {
                $table[(Get-NormalizedModelKey $p.Name)] = $p.Value
            }
        } catch {
            Write-Log "Mapping file unreadable ($Path): $($_.Exception.Message)" -Level Warn
        }
    }
    return $table
}

function Get-Mapping {
    <#
        .SYNOPSIS
        Returns the merged mapping (shipped config overlaid by the runtime cache),
        as a hashtable keyed by normalized model key. Empty when nothing is found.
    #>
    [CmdletBinding()]
    param([string] $Path)

    if (-not $Path) { $Path = Join-Path (Get-FirstBootRoot) 'config/mapping.json' }
    $merged = Import-MappingFile -Path $Path
    foreach ($kv in (Import-MappingFile -Path (Get-MappingCachePath)).GetEnumerator()) {
        $merged[$kv.Key] = $kv.Value   # cache overrides shipped
    }
    return $merged
}

function Find-MappingEntry {
    <#
        .SYNOPSIS
        Exact-normalized lookup, then a conservative containment fuzzy match
        (one key is a token-prefix of the other). Returns the entry or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Mapping,
        [Parameter(Mandatory)][string] $Model
    )
    if (-not $Mapping -or $Mapping.Count -eq 0) { return $null }
    $key = Get-NormalizedModelKey $Model
    if ($Mapping.ContainsKey($key)) { return $Mapping[$key] }

    foreach ($k in $Mapping.Keys) {
        if ($key.StartsWith("$k ") -or $k.StartsWith("$key ")) {
            Write-Log "Mapping fuzzy match: '$key' ~ '$k'" -Level Debug
            return $Mapping[$k]
        }
    }
    return $null
}

function Save-MappingEntry {
    <#
        .SYNOPSIS
        Best-effort write-back to the runtime cache so the table self-heals. Never
        throws (the USB / config dir may be read-only).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Model,
        [Parameter(Mandatory)] $Entry
    )
    $path = Get-MappingCachePath
    if (-not $PSCmdlet.ShouldProcess($path, "cache mapping for '$Model'")) { return }
    try {
        $doc = [ordered]@{ entries = [ordered]@{} }
        if (Test-Path -LiteralPath $path) {
            $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing.PSObject.Properties['entries']) {
                foreach ($p in $existing.entries.PSObject.Properties) { $doc.entries[$p.Name] = $p.Value }
            }
        }
        $doc.entries[(Get-NormalizedModelKey $Model)] = $Entry
        $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
        Write-Log "Cached mapping for '$Model'." -Level Debug
    } catch {
        Write-Log "Could not write mapping cache: $($_.Exception.Message)" -Level Debug
    }
}

Export-ModuleMember -Function `
    Get-NormalizedModelKey, Get-MappingCachePath, Get-Mapping, Find-MappingEntry, Save-MappingEntry
