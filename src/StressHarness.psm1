# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# StressHarness.psm1 - QC stress orchestration (docs/stress-harness.md). Runs a
# profile of load stages (CPU/RAM/GPU/VRAM/storage/power), stamping QPC-precision
# markers around every stage so an external 1kHz+ power-monitoring rig can align
# to the load transitions, sampling on-box telemetry when available, watching for
# WHEA hardware errors, and writing a DEVICE-ID'D JSONL report for later retrieval.
#
# This is a SEPARATE QC step (tools/Invoke-StressTest.ps1), never part of the
# first-boot provisioning pipeline. Actual load tools live under stress-tools/;
# a tool whose binary is absent - or whose verified CLI mapping is not yet wired -
# is reported honestly (Unavailable / NeedsIntegration), never guessed at, so the
# harness can never launch a fabricated command against a real machine.
#
# Design seams (mockable, so the whole orchestration is testable offline and this
# harness never stresses the dev box): Invoke-StressTool (the only process launch)
# and Get-StressTelemetrySample (the LibreHardwareMonitor reader).

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

# ---------------------------------------------------------------------------
# Config + device identity
# ---------------------------------------------------------------------------

function Get-StressProfileConfig {
    [CmdletBinding()]
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path (Get-FirstBootRoot) 'config/stress-profiles.json' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Stress-profiles config not found: $Path" }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-StressToolsRoot {
    <#
        .SYNOPSIS
        Where load-tool binaries live (stress-tools/ under the repo root by
        default; override for a bench-wide share).
    #>
    [CmdletBinding()]
    param([string] $Root)
    if ($Root) { return $Root }
    return (Join-Path (Get-FirstBootRoot) 'stress-tools')
}

function Get-StressDeviceId {
    <#
        .SYNOPSIS
        Stable identity for keying reports to the device: SMBIOS UUID + board
        serial + computer name, plus a short id (first UUID group) for filenames.
        Pass -System/-Board to inject for tests.
    #>
    [CmdletBinding()]
    param($System, $Board)

    if ($null -eq $System) { try { $System = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop } catch { } }
    if ($null -eq $Board)  { try { $Board  = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop } catch { } }

    $uuid = if ($System -and $System.PSObject.Properties['UUID']) { [string]$System.UUID } else { '' }
    $serial = if ($Board -and $Board.PSObject.Properties['SerialNumber']) { [string]$Board.SerialNumber } else { '' }
    $short = if ($uuid -and $uuid -match '^([0-9A-Fa-f]+)') { $Matches[1] } else { 'unknown' }

    return [pscustomobject]@{
        Uuid         = $uuid
        BoardSerial  = $serial
        ComputerName = $env:COMPUTERNAME
        ShortId      = $short
    }
}

# ---------------------------------------------------------------------------
# QPC markers (external-rig correlation)
# ---------------------------------------------------------------------------

function Get-QpcTimestamp {
    # Raw QueryPerformanceCounter ticks + frequency; the precise clock the
    # external 1kHz rig aligns to.
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        Ticks     = [System.Diagnostics.Stopwatch]::GetTimestamp()
        Frequency = [System.Diagnostics.Stopwatch]::Frequency
    }
}

function New-StressMarker {
    <#
        .SYNOPSIS
        Builds a marker record for a load transition: QPC ticks + frequency,
        an ISO wall-clock stamp, the event kind, and tool/mode context. Pure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $Seq,
        [Parameter(Mandatory)][string] $EventKind,
        [string] $Tool = '',
        [string] $Mode = '',
        [hashtable] $Extra
    )
    $qpc = Get-QpcTimestamp
    $m = [ordered]@{
        seq          = $Seq
        event        = $EventKind
        tool         = $Tool
        mode         = $Mode
        qpcTicks     = $qpc.Ticks
        qpcFrequency = $qpc.Frequency
        wall         = (Get-Date).ToString('o')
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $m[$k] = $Extra[$k] } }
    return [pscustomobject]$m
}

function Write-StressMarker {
    # Appends a marker to the run's marker JSONL (best-effort; never throws).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $MarkerFile,
        [Parameter(Mandatory)] $Marker
    )
    try {
        Add-Content -LiteralPath $MarkerFile -Value (ConvertTo-Json -InputObject $Marker -Compress -Depth 6) `
            -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
    } catch { }
}

# ---------------------------------------------------------------------------
# WHEA (hardware-error watch)
# ---------------------------------------------------------------------------

function Get-WheaEvents {
    <#
        .SYNOPSIS
        WHEA-Logger events since -Since (whole log when omitted). Zero events
        over a stress window = PASS; any corrected error (e.g. ID 19 CPU, ID 17
        PCIe) is a margin failure even without a crash. Returns
        { Id; Level; TimeCreated; Message } records; empty on a clean window.
    #>
    [CmdletBinding()]
    param([datetime] $Since)

    $filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' }
    if ($Since) { $filter['StartTime'] = $Since }
    try {
        return @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Id          = [int]$_.Id
                Level       = [int]$_.Level
                TimeCreated = $_.TimeCreated
                Message     = [string]$_.Message
            }
        })
    } catch {
        # "No events were found" is the healthy case, not an error.
        return @()
    }
}

# ---------------------------------------------------------------------------
# Telemetry seam (LibreHardwareMonitor - graceful when absent)
# ---------------------------------------------------------------------------

function Test-StressTelemetryAvailable {
    <#
        .SYNOPSIS
        $true when LibreHardwareMonitorLib.dll is staged under stress-tools/.
        NOTE: its sensor driver is WinRing0-lineage and can be blocked by
        HVCI / the vulnerable-driver blocklist - validate the pinned build on
        an HVCI-enabled image before relying on it (docs/stress-harness.md).
    #>
    [CmdletBinding()]
    param([string] $ToolsRoot)
    $dll = Join-Path (Get-StressToolsRoot -Root $ToolsRoot) 'LibreHardwareMonitorLib.dll'
    return (Test-Path -LiteralPath $dll)
}

function Get-StressTelemetrySample {
    <#
        .SYNOPSIS
        One telemetry sample (CPU/GPU power+temp, etc.) via LibreHardwareMonitor.
        Returns $null when telemetry is unavailable - the harness then gates on
        WHEA + tool results alone. This is the mockable seam; the periodic
        background sampler is phase 2 (needs the HVCI-validated DLL).
    #>
    [CmdletBinding()]
    param([string] $ToolsRoot)
    if (-not (Test-StressTelemetryAvailable -ToolsRoot $ToolsRoot)) { return $null }
    # Phase 2: Add-Type the DLL, Update() the Computer, read sensors. Kept as a
    # seam so phase-1 orchestration is complete and testable without the DLL.
    return $null
}

# ---------------------------------------------------------------------------
# Tool adapters (the only real process launch - mockable)
# ---------------------------------------------------------------------------

function Test-StressToolAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Tool,
        [string] $ToolsRoot
    )
    $bin = Join-Path (Get-StressToolsRoot -Root $ToolsRoot) ([string]$Tool.binary)
    return (Test-Path -LiteralPath $bin)
}

function Invoke-StressTool {
    <#
        .SYNOPSIS
        Runs one load tool for one stage. Returns { Status; Detail; ExitCode }.
        Status: Ran | Failed | Unavailable | NeedsIntegration | Rehearsed.
        The ONLY function that launches a stress process - mocked in tests so the
        orchestration never actually loads the dev box. A tool with no verified
        'argsTemplate' returns NeedsIntegration rather than a guessed command
        (verify tool CLIs against the real binaries before wiring templates).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Tool,
        [Parameter(Mandatory)] $Stage,
        [string] $ToolsRoot
    )

    $result = [pscustomobject]@{ Status = $null; Detail = $null; ExitCode = $null }

    if (-not (Test-StressToolAvailable -Tool $Tool -ToolsRoot $ToolsRoot)) {
        $result.Status = 'Unavailable'; $result.Detail = "binary not staged: $($Tool.binary)"
        return $result
    }
    $hasTemplate = ($Tool.PSObject.Properties['argsTemplate'] -and $Tool.argsTemplate)
    if (-not $hasTemplate) {
        $result.Status = 'NeedsIntegration'
        $result.Detail = "no verified argsTemplate for '$($Tool.key)' - wire + verify against the real CLI first"
        return $result
    }

    $bin = Join-Path (Get-StressToolsRoot -Root $ToolsRoot) ([string]$Tool.binary)
    $toolArgs = [string]$Tool.argsTemplate
    $toolArgs = $toolArgs.Replace('{seconds}', [string]$Stage.seconds).Replace('{mode}', [string]$Stage.mode)

    if (Test-Rehearsal) {
        Write-Log ("REHEARSE: would run stress tool: `"{0}`" {1}" -f $bin, $toolArgs) -Level Info -Data @{ command = "$bin $toolArgs" }
        $result.Status = 'Rehearsed'; $result.Detail = "$bin $toolArgs"
        return $result
    }
    if (-not $PSCmdlet.ShouldProcess($Tool.key, "run for $($Stage.seconds)s ($($Stage.mode))")) {
        $result.Status = 'Rehearsed'; $result.Detail = 'WhatIf'
        return $result
    }

    $p = Start-Process -FilePath $bin -ArgumentList $toolArgs -Wait -PassThru -NoNewWindow
    $result.ExitCode = $p.ExitCode
    $result.Status = if ($p.ExitCode -eq 0) { 'Ran' } else { 'Failed' }
    $result.Detail = "exit $($p.ExitCode)"
    return $result
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Invoke-StressStage {
    <#
        .SYNOPSIS
        Runs one profile stage: start marker -> telemetry sample -> tool ->
        telemetry sample -> stop marker. Returns the stage result record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Stage,
        [Parameter(Mandatory)] $Tool,
        [Parameter(Mandatory)][string] $MarkerFile,
        [Parameter(Mandatory)][ref] $Seq,
        [string] $ToolsRoot
    )

    $mode = if ($Stage.PSObject.Properties['mode']) { [string]$Stage.mode } else { '' }
    $secs = if ($Stage.PSObject.Properties['seconds']) { [int]$Stage.seconds } else { 0 }

    $Seq.Value++
    Write-StressMarker -MarkerFile $MarkerFile -Marker (New-StressMarker -Seq $Seq.Value -EventKind 'stage-start' -Tool $Tool.key -Mode $mode -Extra @{ seconds = $secs })
    $telemetryStart = Get-StressTelemetrySample -ToolsRoot $ToolsRoot

    Write-Log ("Stress stage: {0} ({1}) for {2}s" -f $Tool.key, $mode, $secs) -Level Info
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-StressTool -Tool $Tool -Stage $Stage -ToolsRoot $ToolsRoot
    $sw.Stop()

    $telemetryEnd = Get-StressTelemetrySample -ToolsRoot $ToolsRoot
    $Seq.Value++
    Write-StressMarker -MarkerFile $MarkerFile -Marker (New-StressMarker -Seq $Seq.Value -EventKind 'stage-stop' -Tool $Tool.key -Mode $mode -Extra @{ status = $run.Status })

    $doneKind = switch ($run.Status) { 'Failed' { 'fail' } 'Ran' { 'ok' } 'Rehearsed' { 'ok' } default { 'skip' } }
    Write-StepDone -Label ("stress: {0} ({1}) -> {2}" -f $Tool.key, $mode, $run.Status) -Seconds $sw.Elapsed.TotalSeconds -Kind $doneKind

    return [pscustomobject]@{
        Tool           = [string]$Tool.key
        Kind           = [string]$Tool.kind
        Mode           = $mode
        Seconds        = $secs
        Status         = $run.Status
        Detail         = $run.Detail
        ExitCode       = $run.ExitCode
        ElapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        TelemetryStart = $telemetryStart
        TelemetryEnd   = $telemetryEnd
    }
}

function Get-StressVerdict {
    <#
        .SYNOPSIS
        Pure verdict from stage results + WHEA count. Fail on any tool failure
        or any WHEA event; Partial when stages were skipped (unavailable / not
        yet integrated) but nothing failed; Rehearsed when the run was a
        rehearsal; else Pass. Returns { Verdict; Detail }.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][array] $Stages,
        [int] $WheaCount = 0,
        [switch] $Rehearsed
    )
    $failed  = @($Stages | Where-Object { $_.Status -eq 'Failed' })
    $skipped = @($Stages | Where-Object { $_.Status -in 'Unavailable', 'NeedsIntegration' })
    $ran     = @($Stages | Where-Object { $_.Status -in 'Ran', 'Rehearsed' })

    if ($Rehearsed) { return [pscustomobject]@{ Verdict = 'Rehearsed'; Detail = "$($ran.Count) stage(s) planned" } }
    if ($failed.Count -gt 0) {
        return [pscustomobject]@{ Verdict = 'Fail'; Detail = "$($failed.Count) stage failure(s)$(if($WheaCount){"; $WheaCount WHEA event(s)"})" }
    }
    if ($WheaCount -gt 0) {
        return [pscustomobject]@{ Verdict = 'Fail'; Detail = "$WheaCount WHEA event(s) during the stress window (margin failure)" }
    }
    if ($skipped.Count -gt 0) {
        return [pscustomobject]@{ Verdict = 'Partial'; Detail = "$($ran.Count) ran, $($skipped.Count) skipped (tool unavailable / not integrated)" }
    }
    return [pscustomobject]@{ Verdict = 'Pass'; Detail = "$($ran.Count) stage(s) clean, zero WHEA" }
}

function Invoke-StressRun {
    <#
        .SYNOPSIS
        Runs a named profile end to end: device id, marker file, per-stage
        markers/telemetry/tool, WHEA scan over the whole window, verdict, and a
        device-ID'd JSON report under the log directory. Returns the report.
        NOTE: real tool execution requires staged binaries + verified
        argsTemplates; absent those, stages report Unavailable/NeedsIntegration
        and the harness still produces a complete (Partial) report.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ProfileName,
        $Config,
        [string] $ToolsRoot
    )

    if (-not $Config) { $Config = Get-StressProfileConfig }
    $prof = $Config.profiles | Where-Object { $_.name -eq $ProfileName } | Select-Object -First 1
    if (-not $prof) { throw "Stress profile not found: '$ProfileName'." }

    $device = Get-StressDeviceId
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logDir = Get-LogDirectory
    $markerFile = Join-Path $logDir ("stress_{0}_{1}.markers.jsonl" -f $device.ShortId, $stamp)
    $reportFile = Join-Path $logDir ("stress_{0}_{1}.json" -f $device.ShortId, $stamp)
    New-Item -ItemType File -Path $markerFile -Force -WhatIf:$false | Out-Null

    Write-Log ("Stress run: profile '{0}' on {1} (uuid {2})" -f $ProfileName, $device.ComputerName, $device.Uuid) -Level Info -Data @{ device = $device }
    $runStart = Get-Date
    $seq = [ref]0
    Write-StressMarker -MarkerFile $markerFile -Marker (New-StressMarker -Seq $seq.Value -EventKind 'run-start' -Extra @{ profile = $ProfileName; device = $device.ShortId })

    $stageResults = New-Object System.Collections.Generic.List[object]
    foreach ($stage in $prof.stages) {
        $tool = $Config.tools | Where-Object { $_.key -eq $stage.tool } | Select-Object -First 1
        if (-not $tool) {
            Write-Log "Unknown tool '$($stage.tool)' in profile '$ProfileName'; skipping." -Level Warn
            $stageResults.Add([pscustomobject]@{ Tool = [string]$stage.tool; Kind = ''; Mode = ''; Seconds = 0; Status = 'Unavailable'; Detail = 'unknown tool key'; ExitCode = $null; ElapsedSeconds = 0; TelemetryStart = $null; TelemetryEnd = $null }) | Out-Null
            continue
        }
        $stageResults.Add((Invoke-StressStage -Stage $stage -Tool $tool -MarkerFile $markerFile -Seq $seq -ToolsRoot $ToolsRoot)) | Out-Null
    }

    $seq.Value++
    Write-StressMarker -MarkerFile $markerFile -Marker (New-StressMarker -Seq $seq.Value -EventKind 'run-stop')

    $whea = @(Get-WheaEvents -Since $runStart)
    if ($whea.Count -gt 0) {
        foreach ($e in $whea) { Write-Log ("WHEA during stress: id {0} level {1} @ {2}" -f $e.Id, $e.Level, $e.TimeCreated) -Level Error }
    }
    $verdict = Get-StressVerdict -Stages $stageResults.ToArray() -WheaCount $whea.Count -Rehearsed:(Test-Rehearsal)

    $report = [pscustomobject]@{
        generatedAt        = (Get-Date).ToString('o')
        profile            = $ProfileName
        device             = $device
        markersFile        = $markerFile
        telemetryAvailable = (Test-StressTelemetryAvailable -ToolsRoot $ToolsRoot)
        stages             = $stageResults.ToArray()
        whea               = [pscustomobject]@{ count = $whea.Count; events = $whea }
        verdict            = $verdict.Verdict
        verdictDetail      = $verdict.Detail
        elapsedSeconds     = [Math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
    }
    ConvertTo-Json -InputObject $report -Depth 8 | Set-Content -LiteralPath $reportFile -Encoding UTF8 -WhatIf:$false

    $lvl = switch ($verdict.Verdict) { 'Fail' { 'Error' } 'Partial' { 'Warn' } default { 'Success' } }
    Write-Log ("STRESS {0}: {1}. Report: {2}" -f $verdict.Verdict.ToUpperInvariant(), $verdict.Detail, $reportFile) -Level $lvl
    return $report
}

Export-ModuleMember -Function `
    Get-StressProfileConfig, Get-StressToolsRoot, Get-StressDeviceId, `
    Get-QpcTimestamp, New-StressMarker, Write-StressMarker, `
    Get-WheaEvents, Test-StressTelemetryAvailable, Get-StressTelemetrySample, `
    Test-StressToolAvailable, Invoke-StressTool, Invoke-StressStage, `
    Get-StressVerdict, Invoke-StressRun
