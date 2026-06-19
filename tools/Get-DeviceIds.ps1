# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Get-DeviceIds.ps1 - dump a machine's USB/PnP devices (VID:PID, name, class) to
# help capture peripheral identifiers for config/apps.json (e.g. Thermalright
# coolers, RGB gear). Run on a real build, then paste the VID:PIDs into the
# matching app's match.vidpid list.
#
#   pwsh -File tools/Get-DeviceIds.ps1                 # table of all devices
#   pwsh -File tools/Get-DeviceIds.ps1 -UsbOnly        # only devices with a VID:PID
#   pwsh -File tools/Get-DeviceIds.ps1 -Filter Thermal # name/class regex filter
#   pwsh -File tools/Get-DeviceIds.ps1 -UsbOnly -Json  # JSON list of "VVVV:PPPP"

[CmdletBinding()]
param(
    [switch] $UsbOnly,
    [string] $Filter,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/Detect-Peripherals.psm1') -Force

$devices = Get-Peripherals
if ($UsbOnly) { $devices = $devices | Where-Object { $_.VidPid } }
if ($Filter)  { $devices = $devices | Where-Object { "$($_.Name) $($_.Class) $($_.Manufacturer)" -match $Filter } }

if ($Json) {
    $devices | Where-Object { $_.VidPid } |
        Select-Object -ExpandProperty VidPid -Unique |
        Sort-Object | ConvertTo-Json
    return
}

$devices |
    Sort-Object @{ Expression = { [bool]$_.VidPid }; Descending = $true }, Name |
    Format-Table @{ N = 'VID:PID'; E = { if ($_.VidPid) { $_.VidPid } else { '-' } } }, Class, Name -AutoSize

Write-Host ""
Write-Host "Tip: add the relevant VID:PID(s) to the app's match.vidpid in config/apps.json." -ForegroundColor Cyan
