# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.

BeforeAll {
    $src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    # Common first so every dependent module binds to the same fresh instance.
    Import-Module (Join-Path $src 'Common.psm1') -Force
    Import-Module (Join-Path $src 'Install-Chrome.psm1') -Force
    Import-Module (Join-Path $src 'Install-Engine.psm1') -Force
    Import-Module (Join-Path $src 'Tweaks.psm1') -Force
    Import-Module (Join-Path $src 'apps/AppCatalog.psm1') -Force
}

AfterAll {
    Disable-Rehearsal
}

Describe 'Rehearsal: state toggling' {
    It 'is off by default' {
        Test-Rehearsal | Should -BeFalse
        Test-RehearsalDownloads | Should -BeFalse
    }
    It 'turns on (probe-only) and off' {
        Enable-Rehearsal
        Test-Rehearsal | Should -BeTrue
        Test-RehearsalDownloads | Should -BeFalse
        Disable-Rehearsal
        Test-Rehearsal | Should -BeFalse
    }
    It 'tracks the downloads flag' {
        Enable-Rehearsal -Downloads
        Test-RehearsalDownloads | Should -BeTrue
        Disable-Rehearsal
        Test-RehearsalDownloads | Should -BeFalse
    }
}

Describe 'Rehearsal: structured JSONL logging' {
    BeforeAll {
        $script:logPath = Initialize-Log -Name 'rehearsaltest'
        $script:jsonPath = Get-JsonLogFile
    }

    It 'creates a JSONL sibling next to the text log' {
        $script:jsonPath | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $script:jsonPath | Should -BeTrue
        [IO.Path]::GetExtension($script:jsonPath) | Should -Be '.jsonl'
    }

    It 'stamps phase and data onto JSONL records' {
        Set-LogPhase 'unit-test'
        Write-Log 'structured entry' -Level Info -Data @{ answer = 42 }
        Set-LogPhase ''
        $last = (Get-Content -LiteralPath $script:jsonPath | Select-Object -Last 1) | ConvertFrom-Json
        $last.phase | Should -Be 'unit-test'
        $last.msg | Should -Be 'structured entry'
        $last.level | Should -Be 'info'
        $last.data.answer | Should -Be 42
    }

    It 'records Trace entries in JSONL even when not displayed' {
        Write-Log 'quiet trace' -Level Trace
        $last = (Get-Content -LiteralPath $script:jsonPath | Select-Object -Last 1) | ConvertFrom-Json
        $last.level | Should -Be 'trace'
        $last.msg | Should -Be 'quiet trace'
    }
}

Describe 'Rehearsal: Get-ContentRangeTotal' {
    It 'parses a standard Content-Range' {
        Get-ContentRangeTotal 'bytes 0-0/157192192' | Should -Be 157192192
    }
    It 'returns $null for a wildcard total' {
        Get-ContentRangeTotal 'bytes 0-0/*' | Should -BeNullOrEmpty
    }
    It 'returns $null for empty input' {
        Get-ContentRangeTotal '' | Should -BeNullOrEmpty
    }
}

Describe 'Rehearsal: Install-DriverPackage probe mode' {
    BeforeAll {
        Enable-Rehearsal   # probe-only
        Mock -ModuleName Install-Engine Save-Download { throw 'must not download in probe mode' }
        Mock -ModuleName Install-Engine Invoke-Pnputil { throw 'must not install' }
        Mock -ModuleName Install-Engine Invoke-ExeInstaller { throw 'must not install' }
    }
    AfterAll { Disable-Rehearsal }

    It 'reports Rehearsed with size when the URL probes OK' {
        Mock -ModuleName Install-Engine Invoke-HttpProbe {
            [pscustomobject]@{ Url = $Url; Ok = $true; StatusCode = 200; SizeBytes = 5MB; FinalUrl = $Url; Via = 'HEAD'; Error = $null }
        }
        $entry = [pscustomobject]@{
            Name = 'Probe Driver'; Category = 'Chipset'; Version = '1.0'
            Url = 'https://example.com/driver.zip'; Hash = ''; HashAlg = 'SHA256'
        }
        $r = Install-DriverPackage -Entry $entry
        $r.Status | Should -Be 'Rehearsed'
        $r.Method | Should -Be 'rehearse:probe'
        $r.Detail | Should -Match 'HTTP 200'
        Should -Invoke -ModuleName Install-Engine Save-Download -Times 0 -Exactly
    }

    It 'reports Blocked when the URL is unreachable' {
        Mock -ModuleName Install-Engine Invoke-HttpProbe {
            [pscustomobject]@{ Url = $Url; Ok = $false; StatusCode = $null; SizeBytes = $null; FinalUrl = $null; Via = $null; Error = 'no route' }
        }
        $entry = [pscustomobject]@{
            Name = 'Dead Driver'; Category = 'Audio'; Version = '2.0'
            Url = 'https://dead.example/driver.zip'; Hash = ''; HashAlg = 'SHA256'
        }
        $r = Install-DriverPackage -Entry $entry
        $r.Status | Should -Be 'Blocked'
        $r.Detail | Should -Match 'no route'
    }
}

Describe 'Rehearsal: Install-DriverPackage download mode' {
    BeforeAll {
        Enable-Rehearsal -Downloads
        $script:work = Join-Path ([IO.Path]::GetTempPath()) ("fb_rhz_" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:work -Force | Out-Null

        # A zip with a dummy .inf, staged by the Save-Download mock.
        $staging = Join-Path $script:work 'staging'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Set-Content -Path (Join-Path $staging 'dummy.inf') -Value '[Version]' -Encoding ASCII
        $script:zip = Join-Path $script:work 'rehearse.zip'
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $script:zip -Force

        Mock -ModuleName Install-Engine Save-Download {
            Copy-Item -LiteralPath $script:zip -Destination $Destination -Force
        }
        Mock -ModuleName Install-Engine Invoke-Pnputil { throw 'must not install' }
        Mock -ModuleName Install-Engine Invoke-ExeInstaller { throw 'must not install' }
    }
    AfterAll {
        Disable-Rehearsal
        Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'really downloads + extracts, then logs the pnputil command instead of running it' {
        $entry = [pscustomobject]@{
            Name = 'Fidelity Driver'; Category = 'Chipset'; Version = '3.0'
            Url = 'https://example.com/rehearse.zip'; Hash = ''; HashAlg = 'SHA256'
        }
        $r = Install-DriverPackage -Entry $entry
        $r.Status | Should -Be 'Rehearsed'
        $r.Method | Should -Be 'rehearse:pnputil'
        Should -Invoke -ModuleName Install-Engine Save-Download -Times 1 -Exactly
        Should -Invoke -ModuleName Install-Engine Invoke-Pnputil -Times 0 -Exactly
    }

    It 'detects the packer on a downloaded EXE without running it' {
        $exe = Join-Path $script:work 'nsis_setup.exe'
        [IO.File]::WriteAllText($exe, 'MZ ... Nullsoft.NSIS ... data')
        $result = [pscustomobject]@{ Name = 'x'; Category = 'Audio'; Version = '1'; Url = 'u'; Method = $null; Status = $null; Detail = $null }
        $r = Invoke-ExeRehearsal -Result $result -ExePath $exe
        $r.Status | Should -Be 'Rehearsed'
        $r.Method | Should -Be 'rehearse:exe:NSIS'
        $r.Detail | Should -Match '/S'
        Should -Invoke -ModuleName Install-Engine Invoke-ExeInstaller -Times 0 -Exactly
    }
}

Describe 'Rehearsal: apps layer' {
    BeforeAll { Enable-Rehearsal }
    AfterAll { Disable-Rehearsal }

    It 'logs the exact winget command without executing it' {
        Mock -ModuleName AppCatalog Test-Winget { $true }
        Mock -ModuleName AppCatalog Start-Process { throw 'must not execute' }
        $app = [pscustomobject]@{ name = 'Steam'; wingetId = 'Valve.Steam' }
        $r = Install-App -App $app
        $r.Status | Should -Be 'Rehearsed'
        $r.Method | Should -Be 'winget'
        $r.Detail | Should -Be 'winget install --id Valve.Steam -e --silent --accept-package-agreements --accept-source-agreements'
        Should -Invoke -ModuleName AppCatalog Start-Process -Times 0 -Exactly
    }

    It 'rehearses the fallback-url path without opening a browser' {
        Mock -ModuleName AppCatalog Test-Winget { $false }
        Mock -ModuleName AppCatalog Find-Chrome { 'C:\fake\chrome.exe' }
        Mock -ModuleName AppCatalog Invoke-HttpProbe {
            [pscustomobject]@{ Url = $Url; Ok = $true; StatusCode = 200; SizeBytes = $null; FinalUrl = $Url; Via = 'HEAD'; Error = $null }
        }
        $app = [pscustomobject]@{ name = 'Hyte Nexus'; fallbackUrl = 'https://hyte.com/nexus' }
        $r = Install-App -App $app
        $r.Status | Should -Be 'Rehearsed'
        $r.Method | Should -Be 'fallback-url'
        $r.Detail | Should -Match 'hyte.com/nexus'
    }
}

Describe 'Rehearsal: Chrome fallback substrate' {
    BeforeAll { Enable-Rehearsal }
    AfterAll { Disable-Rehearsal }

    It 'Open-Url logs instead of launching anything' {
        Mock -ModuleName Install-Chrome Start-Process { throw 'must not launch' }
        Mock -ModuleName Install-Chrome Find-Chrome { $null }
        { Open-Url -Url 'https://example.com/support' } | Should -Not -Throw
        Should -Invoke -ModuleName Install-Chrome Start-Process -Times 0 -Exactly
    }
}

Describe 'Rehearsal: tweaks render artifacts, mutate nothing' {
    BeforeAll {
        Enable-Rehearsal
        Mock -ModuleName Tweaks Invoke-Dism { throw 'must not run dism' }
    }
    AfterAll { Disable-Rehearsal }

    It 'renders the default-app associations XML into the rehearsal area without running dism' {
        Set-ChromeDefaultBrowser
        $staged = Join-Path (Get-RehearsalDirectory) 'firstboot-defaultapps.xml'
        Test-Path -LiteralPath $staged | Should -BeTrue
        (Get-Content -LiteralPath $staged -Raw) | Should -Match 'ChromeHTML'
        Should -Invoke -ModuleName Tweaks Invoke-Dism -Times 0 -Exactly
    }

    It 'renders the taskbar layout XML into the rehearsal area' {
        Set-ChromeTaskbarPin
        $staged = Join-Path (Get-RehearsalDirectory) 'LayoutModification.xml'
        Test-Path -LiteralPath $staged | Should -BeTrue
        (Get-Content -LiteralPath $staged -Raw) | Should -Match 'TaskbarPinList'
    }

    It 'Set-Wallpaper reports success without touching the registry' {
        $img = Join-Path ([IO.Path]::GetTempPath()) ("fb_wp_" + [Guid]::NewGuid().ToString('N') + '.jpg')
        Set-Content -Path $img -Value 'not really a jpg' -Encoding ASCII
        try {
            Set-Wallpaper -Path $img | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue
        }
    }
}
