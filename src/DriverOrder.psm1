# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# DriverOrder.psm1 - stage 3: the ordered driver pipeline. Turns the flat
# vendor driver list into the researched install order (config/install-order.json,
# spec: docs/driver-install-order.md): chipset first, platform block, LAN,
# BT-before-Wi-Fi, iGPU, audio - with forced-restart boundaries and
# conditional skip rules (RST/VMD only when enabled, GNA hard-deny, ...).
# The planner (Get-DriverOrderPlan) is pure; runtime facts come from
# Get-PlatformKind + Get-DriverOrderConditions (CIM probes).

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

function Get-InstallOrderConfig {
    <#
        .SYNOPSIS
        Loads config/install-order.json (or -Path override) and returns its
        groups[].
    #>
    [CmdletBinding()]
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path (Get-FirstBootRoot) 'config/install-order.json' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Install-order config not found: $Path" }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json).groups
}

function Get-PlatformKind {
    <#
        .SYNOPSIS
        'intel' or 'amd' from the CPU manufacturer; 'unknown' when undetectable.
    #>
    [CmdletBinding()]
    param()
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        switch -Regex ([string]$cpu.Manufacturer) {
            'GenuineIntel' { return 'intel' }
            'AuthenticAMD' { return 'amd' }
        }
    } catch { }
    return 'unknown'
}

function Get-DriverOrderConditions {
    <#
        .SYNOPSIS
        Computes the runtime facts the order config's 'condition' names refer
        to. Conservative: probes that fail default to $false (skip = safe).
        'never' is the hard-deny anchor and is always $false.
    #>
    [CmdletBinding()]
    param()

    $vmd = $false
    try {
        $vmd = [bool](Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object { ($_.Name -match '(?i)RST.*VMD|VMD.*Controller|RAID') -or ($_.DeviceID -match '(?i)DEV_09AB|DEV_A77F') } |
            Select-Object -First 1)
    } catch { }

    $cpuName = ''
    try { $cpuName = [string](Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name } catch { }
    # APO-eligible: 14th-gen K-series (i5-14600K and up) or Core Ultra 200S.
    $apo = ($cpuName -match '(?i)i[579]-14[679]00K') -or ($cpuName -match '(?i)Core\s*\(?TM\)?\s*Ultra\s+[579]\s+2\d{2}')
    # 800-series platform approximated by a Core Ultra 2xx CPU (NPU-bearing).
    $s800 = ($cpuName -match '(?i)Core\s*\(?TM\)?\s*Ultra\s+[579]\s+2\d{2}')

    $igpu = $false
    try {
        $igpu = [bool](Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.Name -match '(?i)Intel|Radeon.*Graphics' } | Select-Object -First 1)
    } catch { }

    return @{
        never       = $false
        vmdOrRaid   = $vmd
        apoEligible = [bool]$apo
        series800   = [bool]$s800
        igpuPresent = $igpu
    }
}

function Test-OrderGroupMatch {
    <#
        .SYNOPSIS
        $true when an entry's Category (or, failing that, Name) matches any of
        the group's regex patterns. '*' matches everything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $Group
    )
    $cat = [string]$Entry.Category
    $name = [string]$Entry.Name
    foreach ($p in @($Group.match)) {
        if ($p -eq '*') { return $true }
        if ($cat -match "(?i)$p") { return $true }
        if ($name -match "(?i)$p") { return $true }
    }
    return $false
}

function Get-DriverOrderPlan {
    <#
        .SYNOPSIS
        Pure planner: assigns each driver entry to the first order group valid
        for the platform whose patterns match, applies condition-based skips,
        and returns the ordered groups:
        @( @{ Key; Title; RestartAfter; Skipped; SkipReason; Entries } ... ).
        Every input entry lands in exactly one group ('*' catch-all last).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][array] $Drivers = @(),
        [ValidateSet('intel', 'amd', 'unknown')][string] $Platform = 'unknown',
        [hashtable] $Conditions = @{},
        $Config
    )

    if (-not $Config) { $Config = Get-InstallOrderConfig }

    # Groups applicable to this platform, in config order.
    $groups = @()
    foreach ($g in $Config) {
        $plats = if ($g.PSObject.Properties['platforms'] -and $g.platforms) { @($g.platforms) } else { $null }
        if ($plats -and $Platform -ne 'unknown' -and ($plats -notcontains $Platform)) { continue }
        $cond = if ($g.PSObject.Properties['condition']) { [string]$g.condition } else { '' }
        $condOk = $true
        if ($cond) { $condOk = [bool]($Conditions[$cond]) }
        $groups += [pscustomobject]@{
            Key          = [string]$g.key
            Title        = [string]$g.title
            Match        = @($g.match)
            RestartAfter = [bool]($g.PSObject.Properties['restartAfter'] -and $g.restartAfter)
            Skipped      = (-not $condOk)
            SkipReason   = $(if (-not $condOk) { "condition '$cond' not met" } else { $null })
            Entries      = New-Object System.Collections.Generic.List[object]
        }
    }

    foreach ($d in $Drivers) {
        foreach ($g in $groups) {
            if (Test-OrderGroupMatch -Entry $d -Group ([pscustomobject]@{ match = $g.Match })) {
                $g.Entries.Add($d) | Out-Null
                break
            }
        }
    }

    # Materialize Entries as arrays for callers/tests.
    return @($groups | ForEach-Object {
        [pscustomobject]@{
            Key          = $_.Key
            Title        = $_.Title
            RestartAfter = $_.RestartAfter
            Skipped      = $_.Skipped
            SkipReason   = $_.SkipReason
            Entries      = $_.Entries.ToArray()
        }
    })
}

function Format-DriverOrderPlan {
    <#
        .SYNOPSIS
        One-line-per-group human summary of a plan for logs/ledger.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][array] $Plan)
    $parts = @()
    foreach ($g in $Plan) {
        if ($g.Entries.Count -eq 0 -and -not $g.Skipped) { continue }
        $tag = if ($g.Skipped) { " SKIP ($($g.SkipReason))" } elseif ($g.RestartAfter -and $g.Entries.Count -gt 0) { ' [RESTART]' } else { '' }
        if ($g.Entries.Count -gt 0 -or $g.Skipped) {
            $parts += ('{0}({1}){2}' -f $g.Key, $g.Entries.Count, $tag)
        }
    }
    return ($parts -join ' -> ')
}

function Restart-ForDriverPhase {
    <#
        .SYNOPSIS
        Reboot at an ordered-install restart boundary; the pipeline resumes via
        the resume task the caller registers first.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([int] $DelaySeconds = 10)
    if (Test-Rehearsal) {
        Write-Log ("REHEARSE: would run: shutdown.exe /r /t {0} (driver-phase restart boundary; resume-task resume)" -f $DelaySeconds) -Level Info
        return $true
    }
    if ($PSCmdlet.ShouldProcess('this machine', "restart at driver-order boundary in $DelaySeconds s")) {
        & shutdown.exe /r /t $DelaySeconds /c 'firstboot: restarting between driver install groups'
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

Export-ModuleMember -Function `
    Get-InstallOrderConfig, Get-PlatformKind, Get-DriverOrderConditions, `
    Test-OrderGroupMatch, Get-DriverOrderPlan, Format-DriverOrderPlan, `
    Restart-ForDriverPhase
