# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Common.psm1') -Force
    Import-Module (Join-Path $src 'StressHarness.psm1') -Force
    Initialize-Log -Name 'stresstest' | Out-Null
}

AfterAll { Disable-Rehearsal }

Describe 'Stress: config' {
    It 'loads the shipped profiles + tools' {
        $c = Get-StressProfileConfig
        ($c.profiles.name) | Should -Contain 'smoke'
        ($c.profiles.name) | Should -Contain 'soak'
        ($c.tools.key) | Should -Contain 'prime95'
        ($c.tools.key) | Should -Contain 'cec-gpu-thrash'
    }
}

Describe 'Stress: device id' {
    It 'builds id fields from injected CIM objects' {
        $sys = [pscustomobject]@{ UUID = 'ABCD1234-5678-90AB-CDEF-001122334455' }
        $bd  = [pscustomobject]@{ SerialNumber = 'SN-007' }
        $id = Get-StressDeviceId -System $sys -Board $bd
        $id.Uuid | Should -Be 'ABCD1234-5678-90AB-CDEF-001122334455'
        $id.BoardSerial | Should -Be 'SN-007'
        $id.ShortId | Should -Be 'ABCD1234'
    }
    It 'degrades to unknown when the hardware exposes no UUID/serial' {
        $id = Get-StressDeviceId -System ([pscustomobject]@{}) -Board ([pscustomobject]@{})
        $id.ShortId | Should -Be 'unknown'
        $id.Uuid | Should -Be ''
    }
}

Describe 'Stress: QPC markers' {
    It 'stamps QPC ticks + frequency + wall clock' {
        $m = New-StressMarker -Seq 1 -EventKind 'stage-start' -Tool 'prime95' -Mode 'blend' -Extra @{ seconds = 60 }
        $m.event | Should -Be 'stage-start'
        $m.tool | Should -Be 'prime95'
        $m.qpcTicks | Should -BeGreaterThan 0
        $m.qpcFrequency | Should -BeGreaterThan 0
        $m.seconds | Should -Be 60
        { [datetime]::Parse($m.wall) } | Should -Not -Throw
    }
    It 'writes markers as JSONL' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ("mk_" + [Guid]::NewGuid().ToString('N') + '.jsonl')
        try {
            Write-StressMarker -MarkerFile $f -Marker (New-StressMarker -Seq 1 -EventKind 'run-start')
            Write-StressMarker -MarkerFile $f -Marker (New-StressMarker -Seq 2 -EventKind 'run-stop')
            $lines = Get-Content -LiteralPath $f
            $lines.Count | Should -Be 2
            ($lines[0] | ConvertFrom-Json).event | Should -Be 'run-start'
        } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Stress: tool adapter (no real load)' {
    BeforeAll {
        $script:tool = [pscustomobject]@{ key = 'prime95'; kind = 'cpu'; binary = 'prime95/prime95.exe' }
        $script:stage = [pscustomobject]@{ tool = 'prime95'; mode = 'blend'; seconds = 60 }
    }
    It 'reports Unavailable when the binary is not staged' {
        Mock -ModuleName StressHarness Test-StressToolAvailable { $false }
        (Invoke-StressTool -Tool $script:tool -Stage $script:stage).Status | Should -Be 'Unavailable'
    }
    It 'reports NeedsIntegration when present but no verified argsTemplate' {
        Mock -ModuleName StressHarness Test-StressToolAvailable { $true }
        (Invoke-StressTool -Tool $script:tool -Stage $script:stage).Status | Should -Be 'NeedsIntegration'
    }
    It 'rehearses the command without launching a process' {
        Mock -ModuleName StressHarness Test-StressToolAvailable { $true }
        Mock -ModuleName StressHarness Start-Process { throw 'must not launch a stress process' }
        $tool = [pscustomobject]@{ key = 'prime95'; kind = 'cpu'; binary = 'prime95/prime95.exe'; argsTemplate = '-t {seconds}' }
        Enable-Rehearsal
        try {
            $r = Invoke-StressTool -Tool $tool -Stage $script:stage
            $r.Status | Should -Be 'Rehearsed'
            $r.Detail | Should -Match '-t 60'
        } finally { Disable-Rehearsal }
        Should -Invoke -ModuleName StressHarness Start-Process -Times 0 -Exactly
    }
    It 'the -WhatIf/ShouldProcess gate blocks the launch (audit #5 regression)' {
        Mock -ModuleName StressHarness Test-StressToolAvailable { $true }
        Mock -ModuleName StressHarness Start-Process { throw 'must not launch under -WhatIf' }
        $tool = [pscustomobject]@{ key = 'prime95'; kind = 'cpu'; binary = 'prime95/prime95.exe'; argsTemplate = '-t {seconds}' }
        # Rehearsal OFF; -WhatIf must still short-circuit to Rehearsed before launch.
        $r = Invoke-StressTool -Tool $tool -Stage $script:stage -WhatIf
        $r.Status | Should -Be 'Rehearsed'
        Should -Invoke -ModuleName StressHarness Start-Process -Times 0 -Exactly
    }
    It 'tolerates a stage with no mode/seconds (audit #3 regression)' {
        Mock -ModuleName StressHarness Test-StressToolAvailable { $true }
        Mock -ModuleName StressHarness Start-Process { throw 'must not launch' }
        $tool = [pscustomobject]@{ key = 'prime95'; kind = 'cpu'; binary = 'prime95/prime95.exe'; argsTemplate = '-fixed' }
        $bareStage = [pscustomobject]@{ tool = 'prime95' }   # no mode, no seconds
        Enable-Rehearsal
        try { { Invoke-StressTool -Tool $tool -Stage $bareStage } | Should -Not -Throw }
        finally { Disable-Rehearsal }
    }
}

Describe 'Stress: verdict logic' {
    It 'passes when everything ran clean and WHEA is zero' {
        $stages = @([pscustomobject]@{ Status = 'Ran' }, [pscustomobject]@{ Status = 'Ran' })
        (Get-StressVerdict -Stages $stages -WheaCount 0).Verdict | Should -Be 'Pass'
    }
    It 'fails on any tool failure' {
        $stages = @([pscustomobject]@{ Status = 'Ran' }, [pscustomobject]@{ Status = 'Failed' })
        (Get-StressVerdict -Stages $stages -WheaCount 0).Verdict | Should -Be 'Fail'
    }
    It 'fails on any WHEA event even when tools passed' {
        $stages = @([pscustomobject]@{ Status = 'Ran' })
        $v = Get-StressVerdict -Stages $stages -WheaCount 1
        $v.Verdict | Should -Be 'Fail'
        $v.Detail | Should -Match 'WHEA'
    }
    It 'reports Partial when stages were skipped but nothing failed' {
        $stages = @([pscustomobject]@{ Status = 'Ran' }, [pscustomobject]@{ Status = 'Unavailable' })
        (Get-StressVerdict -Stages $stages -WheaCount 0).Verdict | Should -Be 'Partial'
    }
    It 'reports Rehearsed under rehearsal' {
        $stages = @([pscustomobject]@{ Status = 'Rehearsed' })
        (Get-StressVerdict -Stages $stages -WheaCount 0 -Rehearsed).Verdict | Should -Be 'Rehearsed'
    }
    It 'does NOT pass when the WHEA scan failed (audit #1 regression)' {
        $stages = @([pscustomobject]@{ Status = 'Ran' })
        $v = Get-StressVerdict -Stages $stages -WheaCount 0 -WheaScanFailed
        $v.Verdict | Should -Be 'Fail'
        $v.Detail | Should -Match 'cannot certify'
    }
}

Describe 'Stress: WHEA scan (real, read-only)' {
    It 'returns a countable array without throwing on a clean machine' {
        $script:ev = $null
        { $script:ev = @(Get-WheaEvents -Since (Get-Date).AddMinutes(-1)) } | Should -Not -Throw
        $script:ev.Count | Should -BeGreaterOrEqual 0   # array, usually empty
    }
}

Describe 'Stress: Invoke-StressRun orchestration (mocked tools, no load)' {
    BeforeAll {
        # Every tool "runs" successfully; nothing launches; no WHEA.
        Mock -ModuleName StressHarness Invoke-StressTool {
            [pscustomobject]@{ Status = 'Ran'; Detail = 'mock'; ExitCode = 0 }
        }
        Mock -ModuleName StressHarness Get-WheaEvents { @() }
    }
    It 'runs a profile end to end and writes a device-ID d report + markers' {
        $report = Invoke-StressRun -ProfileName 'smoke'
        $report.verdict | Should -Be 'Pass'
        $report.profile | Should -Be 'smoke'
        @($report.stages).Count | Should -Be 3
        Test-Path -LiteralPath $report.markersFile | Should -BeTrue
        # markers: run-start + (start/stop)*3 + run-stop = 8
        (Get-Content -LiteralPath $report.markersFile).Count | Should -Be 8
    }
    It 'fails the run when a WHEA event lands during the window' {
        Mock -ModuleName StressHarness Get-WheaEvents {
            @([pscustomobject]@{ Id = 19; Level = 3; TimeCreated = (Get-Date); Message = 'corrected' })
        }
        (Invoke-StressRun -ProfileName 'smoke').verdict | Should -Be 'Fail'
    }
    It 'throws on an unknown profile' {
        { Invoke-StressRun -ProfileName 'nope' } | Should -Throw
    }
    It '-WhatIf yields Rehearsed, not a green Pass (audit #2 regression)' {
        (Invoke-StressRun -ProfileName 'smoke' -WhatIf).verdict | Should -Be 'Rehearsed'
    }
    It 'fails the run (not Pass) when the WHEA scan itself throws (audit #1 regression)' {
        Mock -ModuleName StressHarness Get-WheaEvents { throw 'RPC server unavailable' }
        $r = Invoke-StressRun -ProfileName 'smoke'
        $r.verdict | Should -Be 'Fail'
        $r.whea.scanFailed | Should -BeTrue
    }
}
