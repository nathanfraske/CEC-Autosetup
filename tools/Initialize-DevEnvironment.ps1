# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Initialize-DevEnvironment.ps1 - one-command dev/test setup on a fresh Windows
# install. The RUNTIME needs nothing beyond in-box Windows PowerShell 5.1; this
# provisions only the DEV tooling (Pester 5.5+, PSScriptAnalyzer) so the offline
# test suite and lint run anywhere. Idempotent: satisfied requirements are
# skipped. Everything installs CurrentUser-scope from the official PSGallery -
# no admin needed.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/Initialize-DevEnvironment.ps1
#   powershell ... -File tools/Initialize-DevEnvironment.ps1 -CheckOnly   # report, change nothing

[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [version] $PesterMinimum = '5.5.0'
)

$ErrorActionPreference = 'Stop'

# Fresh 5.1 boxes negotiate TLS below 1.2 and PSGallery refuses the connection.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Write-Step {
    param([string] $Message, [string] $Color = 'Gray')
    Write-Host ("  {0}" -f $Message) -ForegroundColor $Color
}

$failures = 0

Write-Host "CEC-Autosetup dev environment check ($(if ($CheckOnly) { 'check only' } else { 'install missing' }))" -ForegroundColor Cyan
Write-Host ("  PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

# --- NuGet package provider (needed by Install-Module on 5.1) --------------
$nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if ($nuget -and $nuget.Version -ge [version]'2.8.5.201') {
    Write-Step "NuGet provider $($nuget.Version): OK" 'Green'
} elseif ($CheckOnly) {
    Write-Step 'NuGet provider: MISSING (Install-Module would bootstrap it)' 'Yellow'
} else {
    Write-Step 'NuGet provider: installing...'
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        Write-Step 'NuGet provider: installed' 'Green'
    } catch {
        $failures++
        Write-Step "NuGet provider install failed: $($_.Exception.Message)" 'Red'
        Write-Step 'Offline? The dev tooling needs one-time internet access to PSGallery (www.powershellgallery.com).' 'Yellow'
    }
}

# --- PSGallery trust (avoids the interactive Untrusted prompt) -------------
$gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if ($gallery -and $gallery.InstallationPolicy -eq 'Trusted') {
    Write-Step 'PSGallery: already trusted' 'Green'
} elseif ($CheckOnly) {
    Write-Step "PSGallery: $(if ($gallery) { $gallery.InstallationPolicy } else { 'not registered' })" 'Yellow'
} else {
    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Write-Step 'PSGallery: marked trusted' 'Green'
    } catch {
        $failures++
        Write-Step "PSGallery trust failed: $($_.Exception.Message)" 'Red'
    }
}

# --- modules ---------------------------------------------------------------
# Pester needs -SkipPublisherCheck: the in-box 3.4.0 is signed by Microsoft and
# the gallery version is signed by the Pester team, which 5.1 treats as a
# publisher change.
$wanted = @(
    @{ Name = 'Pester';           Minimum = $PesterMinimum;      ExtraArgs = @{ SkipPublisherCheck = $true } },
    @{ Name = 'PSScriptAnalyzer'; Minimum = [version]'1.21.0';   ExtraArgs = @{} }
)

foreach ($m in $wanted) {
    $have = Get-Module -ListAvailable -Name $m.Name |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($have -and $have.Version -ge $m.Minimum) {
        Write-Step "$($m.Name) $($have.Version): OK (>= $($m.Minimum))" 'Green'
        continue
    }
    $state = if ($have) { "outdated ($($have.Version) < $($m.Minimum))" } else { 'missing' }
    if ($CheckOnly) {
        Write-Step "$($m.Name): $state" 'Yellow'
        continue
    }
    Write-Step "$($m.Name): $state - installing from PSGallery..."
    try {
        $installArgs = @{
            Name           = $m.Name
            MinimumVersion = $m.Minimum
            Scope          = 'CurrentUser'
            Force          = $true
            Repository     = 'PSGallery'
        } + $m.ExtraArgs
        Install-Module @installArgs
        $now = Get-Module -ListAvailable -Name $m.Name | Sort-Object Version -Descending | Select-Object -First 1
        Write-Step "$($m.Name) $($now.Version): installed" 'Green'
    } catch {
        $failures++
        Write-Step "$($m.Name) install failed: $($_.Exception.Message)" 'Red'
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "Dev environment NOT ready ($failures failure(s) above)." -ForegroundColor Red
    exit 1
}
if ($CheckOnly) {
    Write-Host 'Check complete (nothing changed). Re-run without -CheckOnly to install anything marked yellow.' -ForegroundColor Cyan
} else {
    Write-Host 'Dev environment ready. Next:' -ForegroundColor Green
    Write-Host '  Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1'
    Write-Host '  Invoke-Pester -Path ./tests'
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1   # readiness self-check'
}
exit 0
