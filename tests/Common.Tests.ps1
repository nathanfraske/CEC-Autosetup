# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Common.psm1') -Force
}

Describe 'Common: Get-Settings' {
    It 'loads defaults.json with the expected keys' {
        $s = Get-Settings -Force
        $s.appName | Should -Be 'firstboot'
        $s.asus.cdnBase | Should -Be 'https://dlcdnets.asus.com'
        $s.gigabyte.challengeMinBytes | Should -BeGreaterThan 0
    }
}

Describe 'Common: Test-FileHash' {
    BeforeAll {
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ("fb_hash_" + [Guid]::NewGuid().ToString('N') + '.txt')
        # exact bytes "firstboot" (no newline)
        [IO.File]::WriteAllBytes($script:tmp, [Text.Encoding]::ASCII.GetBytes('firstboot'))
        $script:sha = 'b870ad8e3787c7912029b5574a52dd741b064f160b3492632014c66a87cb21ed'
        $script:md5 = '41ac1d723eab0169e248b772bc718072'
    }
    AfterAll { Remove-Item -LiteralPath $script:tmp -Force -ErrorAction SilentlyContinue }

    It 'matches a correct SHA256 (case-insensitive)' {
        Test-FileHash -Path $script:tmp -ExpectedHash $script:sha.ToUpper() -Algorithm SHA256 | Should -BeTrue
    }
    It 'matches a correct MD5' {
        Test-FileHash -Path $script:tmp -ExpectedHash $script:md5 -Algorithm MD5 | Should -BeTrue
    }
    It 'rejects a wrong hash' {
        Test-FileHash -Path $script:tmp -ExpectedHash ('0' * 64) -Algorithm SHA256 | Should -BeFalse
    }
    It 'returns true when no hash is supplied (nothing to verify)' {
        Test-FileHash -Path $script:tmp -ExpectedHash '' -Algorithm SHA256 | Should -BeTrue
    }
}

Describe 'Common: Set-Tls12' {
    It 'enables TLS 1.2 without throwing' {
        { Set-Tls12 } | Should -Not -Throw
        ([Net.ServicePointManager]::SecurityProtocol.ToString()) | Should -Match 'Tls12'
    }
}
