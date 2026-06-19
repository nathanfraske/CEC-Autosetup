# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'providers/Asrock.psm1') -Force
}

Describe 'ASRock: platform classification' {
    It 'classifies <model> as <platform>' -TestCases @(
        @{ model = 'X870E Taichi';        platform = 'AMD' }
        @{ model = 'B650E PG Riptide';    platform = 'AMD' }
        @{ model = 'Z790 PG Lightning';   platform = 'Intel' }
        @{ model = 'B760M Pro RS';        platform = 'Intel' }
    ) {
        param($model, $platform)
        Get-AsrockPlatform -Model $model | Should -Be $platform
    }
}

Describe 'ASRock: fallback-only provider' {
    It 'reports SupportsHeadless = $false' {
        (Get-AsrockProvider).SupportsHeadless | Should -BeFalse
    }
    It 'builds the exact index.asp#Download URL for X870E Taichi' {
        Get-AsrockFallbackUrl -Identity $null -Model 'X870E Taichi' |
            Should -Be 'https://www.asrock.com/mb/AMD/X870E%20Taichi/index.asp#Download'
    }
    It 'Get-DriverList throws NotSupported (headless not available)' {
        { Get-AsrockDriverList -Identity ([pscustomobject]@{}) } | Should -Throw
    }
}
