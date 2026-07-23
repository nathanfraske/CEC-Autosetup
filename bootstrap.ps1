# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# bootstrap.ps1 - the single first-boot entrypoint. Sets TLS 1.2 and a process
# ExecutionPolicy of Bypass, self-elevates when needed, locates the engine
# (local/USB copy or, for the online one-liner, downloads the repo), then runs
# src/FirstBoot.ps1 with any forwarded flags.
#
# BRING-UP DEFAULT: until the shop's ordered install checklist is wired in, a
# bare run performs the full-pipeline readiness SELF-CHECK (rehearsal: probes,
# emulation, verbose logs + JSON report; installs nothing). Pass -Install for
# the real first-boot install run.
#
# USB / image:   powershell -NoProfile -ExecutionPolicy Bypass -File X:\firstboot\bootstrap.ps1
# Online:        powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/nathanfraske/cec-autosetup/main/bootstrap.ps1 | iex"

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]   $Install,             # perform the real install run (bare runs self-check during bring-up)
    [switch]   $IncludeBios,
    [string[]] $Categories,
    [int]      $Osid = 0,
    [switch]   $SkipApps,
    [switch]   $SkipGpu,
    [switch]   $SkipTweaks,
    [string]   $Tier,
    [string[]] $InstallApps,
    [string]   $Mirror,
    [string]   $Model,
    [string]   $Vendor,
    [switch]   $Rehearse,            # dev dry run: emulate the full stack, install nothing
    [switch]   $RehearseDownloads,   # with -Rehearse: real downloads/extraction for fidelity
    [switch]   $SkipWindowsPrep,     # skip the WU-hold + UAC stage
    [switch]   $SkipBiosUpdate,      # skip BIOS staging + the reboot-to-UEFI hand-off
    [switch]   $SkipWindowsUpdateRun, # skip the run-WU-fully stage (post-BIOS)
    [string]   $Repo,                # owner/name override (default below)
    [string]   $Branch = 'main'
)

$ErrorActionPreference = 'Stop'

# --- TLS + execution policy ----------------------------------------------
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue } catch { }

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-ForwardArgs {
    param([System.Collections.IDictionary] $Bound)
    $list = @()
    foreach ($kv in $Bound.GetEnumerator()) {
        if ($kv.Key -in 'Repo', 'Branch') { continue }
        $v = $kv.Value
        if ($v -is [switch]) { if ($v.IsPresent) { $list += "-$($kv.Key)" } }
        elseif ($v -is [bool]) { if ($v) { $list += "-$($kv.Key)" } }
        elseif ($v -is [array]) { $list += "-$($kv.Key)"; $list += ($v -join ',') }
        else { $list += "-$($kv.Key)"; $list += "$v" }
    }
    return $list
}

# --- locate the engine ----------------------------------------------------
$scriptPath = $null
if ($MyInvocation.MyCommand.Path) { $scriptPath = $MyInvocation.MyCommand.Path }

$repoRoot = $null
if ($scriptPath) {
    $candidate = Split-Path -Parent $scriptPath
    if (Test-Path (Join-Path $candidate 'src/FirstBoot.ps1')) { $repoRoot = $candidate }
}

if (-not $repoRoot) {
    # Online one-liner: no local repo. Download a snapshot and run from there.
    if (-not $Repo) {
        $Repo = if ($env:FIRSTBOOT_REPO) { $env:FIRSTBOOT_REPO } else { 'nathanfraske/cec-autosetup' }
    }
    $zipUrl = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("firstboot_" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'repo.zip'
    Write-Host "Downloading engine from $zipUrl ..."
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $repoRoot = Get-ChildItem -LiteralPath $tmp -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'src/FirstBoot.ps1') } |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $repoRoot) { throw "Downloaded archive did not contain src/FirstBoot.ps1." }
    $scriptPath = Join-Path $repoRoot 'bootstrap.ps1'
}

$firstBoot = Join-Path $repoRoot 'src/FirstBoot.ps1'

# --- bring-up default: self-check unless -Install --------------------------
if (-not $Install -and -not $Rehearse -and -not $WhatIfPreference) {
    Write-Host 'No -Install flag: running the pipeline READINESS SELF-CHECK (installs nothing).' -ForegroundColor Yellow
    Write-Host 'Pass -Install to perform the real first-boot install run.' -ForegroundColor Yellow
    $Rehearse = $true
}

# --- self-elevate (skip for dry runs and rehearsals) ----------------------
if (-not (Test-IsAdmin) -and -not $WhatIfPreference -and -not $Rehearse) {
    Write-Host "Elevation required; relaunching as administrator..."
    $fwd = Get-ForwardArgs -Bound $PSBoundParameters
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $fwd
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

# --- run ------------------------------------------------------------------
$fbParams = @{}
foreach ($k in $PSBoundParameters.Keys) {
    if ($k -in 'Repo', 'Branch', 'Install') { continue }   # bootstrap-only flags
    $fbParams[$k] = $PSBoundParameters[$k]
}
# Rehearse may have been defaulted on above (bring-up self-check), so pass the
# effective value, not just the bound one.
$fbParams['Rehearse'] = [bool]$Rehearse

& $firstBoot @fbParams
exit $LASTEXITCODE
