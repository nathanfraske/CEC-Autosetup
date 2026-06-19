# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $src 'Install-Engine.psm1') -Force
}

Describe 'Install-Engine: Get-SilentArgs' {
    It 'maps <packer> to <expected>' -TestCases @(
        @{ packer = 'InstallShield'; expected = '/s /v"/qn"' }
        @{ packer = 'NSIS';          expected = '/S' }
        @{ packer = 'Inno';          expected = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
    ) {
        param($packer, $expected)
        Get-SilentArgs -PackerType $packer | Should -Be $expected
    }
    It 'returns $null for Unknown (no auto-run)' {
        Get-SilentArgs -PackerType 'Unknown' | Should -BeNullOrEmpty
    }
}

Describe 'Install-Engine: Get-PackerType' {
    BeforeAll {
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) ("fb_pack_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        function New-MarkerFile($name, $marker) {
            $p = Join-Path $script:dir $name
            [IO.File]::WriteAllText($p, ('MZ padding ' + $marker + ' more bytes'))
            return $p
        }
        $script:inno = New-MarkerFile 'inno.exe' 'Inno Setup Setup Data'
        $script:nsis = New-MarkerFile 'nsis.exe' 'Nullsoft.NSIS.exehead'
        $script:is   = New-MarkerFile 'is.exe'   'InstallShield Setup'
        $script:none = New-MarkerFile 'none.exe' 'no markers here'
    }
    AfterAll { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'detects Inno'          { Get-PackerType -Path $script:inno | Should -Be 'Inno' }
    It 'detects NSIS'          { Get-PackerType -Path $script:nsis | Should -Be 'NSIS' }
    It 'detects InstallShield' { Get-PackerType -Path $script:is   | Should -Be 'InstallShield' }
    It 'returns Unknown otherwise' { Get-PackerType -Path $script:none | Should -Be 'Unknown' }
}

Describe 'Install-Engine: Install-DriverPackage INF branch' {
    BeforeAll {
        $script:work = Join-Path ([IO.Path]::GetTempPath()) ("fb_inf_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:work -Force | Out-Null

        # Build a zip containing a dummy .inf.
        $staging = Join-Path $script:work 'staging'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Set-Content -Path (Join-Path $staging 'dummy.inf') -Value '[Version]' -Encoding ASCII
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath (Join-Path $script:work 'test.zip') -Force

        Mock -ModuleName Install-Engine Save-Download { }            # file already staged at $dest
        Mock -ModuleName Install-Engine Invoke-Pnputil { 0 }
    }
    AfterAll { Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue }

    It 'takes the pnputil branch for an archive with an .inf' {
        $entry = [pscustomobject]@{
            Name = 'Test Chipset'; Category = 'Chipset'; Version = '1.0'
            Url = 'https://example.com/test.zip'; Hash = ''; HashAlg = 'SHA256'
        }
        $r = Install-DriverPackage -Entry $entry -WorkDir $script:work
        $r.Method | Should -Be 'pnputil'
        $r.Status | Should -Be 'Installed'
        Should -Invoke -ModuleName Install-Engine Invoke-Pnputil -Times 1
    }

    It 'plans only under -WhatIf (no download, no install)' {
        $entry = [pscustomobject]@{
            Name = 'WhatIf Driver'; Category = 'Chipset'; Version = '2.0'
            Url = 'https://example.com/whatif.zip'; Hash = ''; HashAlg = 'SHA256'
        }
        $r = Install-DriverPackage -Entry $entry -WorkDir $script:work -WhatIf
        $r.Status | Should -Be 'WhatIf'
    }
}

Describe 'Install-Engine: EXE branch picks packer-specific args' {
    BeforeAll {
        $script:exedir = Join-Path ([IO.Path]::GetTempPath()) ("fb_exe_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:exedir -Force | Out-Null
        $script:nsisExe = Join-Path $script:exedir 'app.exe'
        [IO.File]::WriteAllText($script:nsisExe, 'MZ ... Nullsoft.NSIS ... data')
        Mock -ModuleName Install-Engine Invoke-ExeInstaller { 0 }
    }
    AfterAll { Remove-Item -LiteralPath $script:exedir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'runs an NSIS installer with /S' {
        $result = [pscustomobject]@{ Name = 'x'; Category = 'Audio'; Version = '1'; Url = 'u'; Method = $null; Status = $null; Detail = $null }
        $r = Install-ExeEntry -Result $result -ExePath $script:nsisExe
        $r.Method | Should -Be 'exe:NSIS'
        $r.Status | Should -Be 'Installed'
        Should -Invoke -ModuleName Install-Engine Invoke-ExeInstaller -Times 1 -ParameterFilter { $Arguments -eq '/S' }
    }
}
