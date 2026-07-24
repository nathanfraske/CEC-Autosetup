# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Invoke-StressTest.ps1 - QC stress entrypoint (docs/stress-harness.md). SEPARATE
# from first-boot provisioning: run it on a finished build to soak/characterize
# the machine. Emits QPC-precision markers for the external 1kHz power rig, scans
# WHEA, and writes a device-ID'd report under %ProgramData%\firstboot\logs\.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/Invoke-StressTest.ps1 -Profile smoke
#   ... -Profile soak            # full QC soak
#   ... -Profile power           # power-draw characterization for the 1kHz rig
#   ... -Profile smoke -Rehearse # plan + markers only, run no load (safe anywhere)
#   ... -List                    # list profiles and tool availability
#
# Real load requires the tool binaries under stress-tools/ AND verified
# argsTemplates in config/stress-profiles.json; until both are present, stages
# report Unavailable / NeedsIntegration and the report is Partial (never a
# fabricated command against the machine).

[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('Profile')]
    [string] $ProfileName = 'smoke',
    [switch] $Rehearse,
    [switch] $List,
    [string] $ToolsRoot
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $here 'src/Common.psm1') -Force
Import-Module (Join-Path $here 'src/StressHarness.psm1') -Force

Initialize-Log -Name 'stress' | Out-Null
if ($Rehearse) { Enable-Rehearsal }

$config = Get-StressProfileConfig

if ($List) {
    Write-Host "Profiles:" -ForegroundColor Cyan
    foreach ($p in $config.profiles) {
        Write-Host ("  {0,-8} {1}" -f $p.name, $p.description)
    }
    Write-Host "`nTools (availability under $(Get-StressToolsRoot -Root $ToolsRoot)):" -ForegroundColor Cyan
    foreach ($t in $config.tools) {
        $have = Test-StressToolAvailable -Tool $t -ToolsRoot $ToolsRoot
        Write-Host ("  [{0}] {1,-16} {2}" -f $(if ($have) { 'x' } else { ' ' }), $t.key, $t.title) -ForegroundColor $(if ($have) { 'Green' } else { 'DarkGray' })
    }
    Write-Host ("`nTelemetry (LibreHardwareMonitor): {0}" -f $(if (Test-StressTelemetryAvailable -ToolsRoot $ToolsRoot) { 'available' } else { 'absent' }))
    return
}

$report = Invoke-StressRun -ProfileName $ProfileName -Config $config -ToolsRoot $ToolsRoot
$exit = switch ($report.verdict) { 'Fail' { 1 } default { 0 } }
exit $exit
