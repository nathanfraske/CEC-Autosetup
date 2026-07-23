# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# AppCatalog.psm1 - the "apps" layer. Matches detected peripherals against a
# data-driven catalog (config/apps.json) and installs the corresponding software:
# winget when a package exists, otherwise the same Chrome fallback used for
# holdout driver vendors. New apps are added in JSON, not code.
# See docs/architecture.md (Apps layer) and docs/vendor-contracts.md (Open items).

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.psm1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-Chrome.psm1')

function Get-AppCatalog {
    <#
        .SYNOPSIS
        Loads the app catalog (default config/apps.json) and returns its apps[].
    #>
    [CmdletBinding()]
    param([string] $Path)

    if (-not $Path) {
        $rel = 'config/apps.json'
        try { $rel = (Get-Settings).apps.catalogPath } catch { }
        $Path = Join-Path (Get-FirstBootRoot) $rel
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "App catalog not found: $Path"
    }
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return $json.apps
}

function Test-AppMatch {
    <#
        .SYNOPSIS
        Returns a match reason string if the app matches the detected hardware -
        by GPU vendor, USB VID:PID, or device-name pattern; otherwise $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $App,
        [Parameter(Mandatory)][AllowEmptyCollection()] $Devices,
        [string[]] $GpuVendors = @()
    )

    $vidpids = @()
    $patterns = @()
    $gpuVendor = @()
    if ($App.match) {
        if ($App.match.PSObject.Properties['always'] -and $App.match.always) { return 'baseline (always)' }
        if ($App.match.PSObject.Properties['vidpid'] -and $App.match.vidpid) { $vidpids = @($App.match.vidpid) }
        if ($App.match.PSObject.Properties['namePatterns'] -and $App.match.namePatterns) { $patterns = @($App.match.namePatterns) }
        if ($App.match.PSObject.Properties['gpuVendor'] -and $App.match.gpuVendor) { $gpuVendor = @($App.match.gpuVendor) }
    }

    foreach ($g in $gpuVendor) {
        if ($GpuVendors -contains ([string]$g).ToLowerInvariant()) { return "GPU vendor '$g'" }
    }

    foreach ($d in $Devices) {
        if ($d.VidPid) {
            foreach ($vp in $vidpids) {
                if ($d.VidPid -ieq ([string]$vp)) { return "device $($d.VidPid) ($($d.Name))" }
            }
        }
        $name = [string]$d.Name
        if ($name) {
            foreach ($p in $patterns) {
                if ($name -match [regex]::Escape([string]$p)) { return "name '$name' ~ '$p'" }
            }
        }
    }
    return $null
}

function Find-MatchingApps {
    <#
        .SYNOPSIS
        Returns apps whose match rules hit at least one device, each annotated
        with a Reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()] $Devices,
        $Catalog,
        [string[]] $GpuVendors = @(),
        [string[]] $Include = @()
    )
    if (-not $Catalog) { $Catalog = Get-AppCatalog }

    $hits = New-Object System.Collections.Generic.List[object]
    foreach ($app in $Catalog) {
        $reason = Test-AppMatch -App $app -Devices $Devices -GpuVendors $GpuVendors
        if ($reason) {
            $hits.Add([pscustomobject]@{ App = $app; Name = $app.name; Reason = $reason }) | Out-Null
        }
    }

    # Force-include explicitly requested apps (e.g. -InstallApps 'Hyte Nexus').
    foreach ($name in $Include) {
        if (@($hits | Where-Object { $_.Name -ieq $name }).Count -gt 0) { continue }
        $app = $Catalog | Where-Object { $_.name -ieq $name } | Select-Object -First 1
        if ($app) {
            $hits.Add([pscustomobject]@{ App = $app; Name = $app.name; Reason = 'requested (-InstallApps)' }) | Out-Null
        } else {
            Write-Log "Requested app '$name' is not in the catalog." -Level Warn
        }
    }
    return $hits.ToArray()
}

function Install-App {
    <#
        .SYNOPSIS
        Installs an app: winget when a package id is present, otherwise opens the
        official download page in Chrome (same fallback substrate as ASRock).
        Honors -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $App)

    $result = [pscustomobject]@{
        Name   = $App.name
        Method = $null
        Status = $null
        Detail = $null
    }

    $wingetId = $null
    if ($App.PSObject.Properties['wingetId']) { $wingetId = $App.wingetId }
    $fallbackUrl = $null
    if ($App.PSObject.Properties['fallbackUrl']) { $fallbackUrl = $App.fallbackUrl }

    if ($wingetId -and -not (Test-Winget)) {
        Write-Log ("winget not present; '{0}' will use the fallback path." -f $App.name) -Level Trace -Data @{
            app = [string]$App.name; wingetId = [string]$wingetId
        }
    }

    if ($wingetId -and (Test-Winget)) {
        $result.Method = 'winget'
        if (Test-Rehearsal) {
            $cmd = 'winget install --id {0} -e --silent --accept-package-agreements --accept-source-agreements' -f $wingetId
            Write-Log ("REHEARSE: would run: {0}" -f $cmd) -Level Info -Data @{
                app = [string]$App.name; command = $cmd
            }
            $result.Status = 'Rehearsed'; $result.Detail = $cmd
            return $result
        }
        if ($PSCmdlet.ShouldProcess($App.name, "winget install $wingetId")) {
            try {
                $p = Start-Process -FilePath 'winget' -ArgumentList @(
                    'install', '--id', $wingetId, '-e', '--silent',
                    '--accept-package-agreements', '--accept-source-agreements'
                ) -Wait -PassThru
                $result.Status = if ($p.ExitCode -eq 0) { 'Installed' } else { 'Failed' }
                $result.Detail = "winget exit $($p.ExitCode)"
            } catch {
                $result.Status = 'Failed'; $result.Detail = $_.Exception.Message
            }
        } else {
            $result.Status = 'WhatIf'; $result.Detail = "would winget install $wingetId"
        }
        return $result
    }

    if ($fallbackUrl) {
        $result.Method = 'fallback-url'
        if (Test-Rehearsal) {
            $chrome = Find-Chrome
            $opener = if ($chrome) { "Chrome ($chrome)" } else { 'Chrome (would be installed first) or the default browser' }
            $probe = Invoke-HttpProbe -Url $fallbackUrl
            $reach = if ($probe.Ok) { "reachable (HTTP $($probe.StatusCode))" } else { "NOT reachable ($($probe.Error))" }
            Write-Log ("REHEARSE: would open {0} in {1}; page {2}" -f $fallbackUrl, $opener, $reach) -Level Info -Data @{
                app = [string]$App.name; url = [string]$fallbackUrl
                chromePath = [string]$chrome; pageOk = [bool]$probe.Ok; statusCode = $probe.StatusCode
            }
            $result.Status = 'Rehearsed'; $result.Detail = "would open $fallbackUrl"
            return $result
        }
        if ($PSCmdlet.ShouldProcess($App.name, "open $fallbackUrl in Chrome")) {
            Open-Url -Url $fallbackUrl
            $result.Status = 'OpenedFallback'; $result.Detail = $fallbackUrl
        } else {
            $result.Status = 'WhatIf'; $result.Detail = "would open $fallbackUrl"
        }
        return $result
    }

    $result.Method = 'none'; $result.Status = 'NeedsManual'
    $result.Detail = 'no winget id and no fallback url'
    return $result
}

Export-ModuleMember -Function Get-AppCatalog, Test-AppMatch, Find-MatchingApps, Install-App
