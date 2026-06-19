# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# bootstrap.ps1 - the single first-boot entrypoint. Sets TLS 1.2 and a process
# ExecutionPolicy of Bypass, self-elevates when needed, locates the engine
# (local/USB copy or, for the online one-liner, downloads the repo), then runs
# src/FirstBoot.ps1 with any forwarded flags.
#
# USB / image:   powershell -NoProfile -ExecutionPolicy Bypass -File X:\firstboot\bootstrap.ps1
# Online:        powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/nathanfraske/cec-autosetep/main/bootstrap.ps1 | iex"

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]   $IncludeBios,
    [string[]] $Categories,
    [int]      $Osid = 0,
    [switch]   $SkipApps,
    [switch]   $SkipGpu,
    [switch]   $SkipTweaks,
    [string]   $Tier,
    [string]   $Model,
    [string]   $Vendor,
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
        $Repo = if ($env:FIRSTBOOT_REPO) { $env:FIRSTBOOT_REPO } else { 'nathanfraske/cec-autosetep' }
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

# --- self-elevate (skip for dry runs) ------------------------------------
if (-not (Test-IsAdmin) -and -not $WhatIfPreference) {
    Write-Host "Elevation required; relaunching as administrator..."
    $fwd = Get-ForwardArgs -Bound $PSBoundParameters
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $fwd
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

# --- run ------------------------------------------------------------------
$fbParams = @{}
foreach ($k in $PSBoundParameters.Keys) {
    if ($k -in 'Repo', 'Branch') { continue }
    $fbParams[$k] = $PSBoundParameters[$k]
}

& $firstBoot @fbParams
exit $LASTEXITCODE
