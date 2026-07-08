# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Install-Chrome.psm1 - the fallback substrate. Detect Chrome, silently install
# it from Google's enterprise MSI (winget fallback), and open a URL in it so a
# human or browser agent can finish a holdout vendor. See vendor-contracts.md 2.6.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

function Test-Winget {
    return [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

function Find-Chrome {
    <#
        .SYNOPSIS
        Returns the path to chrome.exe if installed, else $null. Checks the
        App Paths registry first, then the usual install locations.
    #>
    [CmdletBinding()]
    param()

    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )
    foreach ($rp in $regPaths) {
        try {
            $val = (Get-ItemProperty -Path $rp -ErrorAction Stop).'(default)'
            if ($val -and (Test-Path -LiteralPath $val)) { return $val }
        } catch { }
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Install-Chrome {
    <#
        .SYNOPSIS
        Ensures Chrome is present. Returns the chrome.exe path, or $null if every
        install path failed. Order: detect -> enterprise MSI -> winget.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $existing = Find-Chrome
    if ($existing) {
        Write-Log "Chrome already present: $existing" -Level Info
        return $existing
    }

    $settings = Get-Settings
    $msiUrl = $settings.chrome.msiUrl

    # Primary: official enterprise MSI, silent.
    if ($PSCmdlet.ShouldProcess('Google Chrome', "Download + silent install from $msiUrl")) {
        try {
            $msi = Join-Path (Get-WorkDirectory) 'googlechromestandaloneenterprise64.msi'
            Write-Log "Downloading Chrome enterprise MSI..." -Level Info
            Invoke-Http -Url $msiUrl -OutFile $msi | Out-Null
            Write-Log "Installing Chrome silently (msiexec /qn /norestart)..." -Level Info
            $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
            if ($p.ExitCode -eq 0) {
                $path = Find-Chrome
                if ($path) { Write-Log "Chrome installed: $path" -Level Success; return $path }
            }
            else {
                Write-Log "msiexec returned exit code $($p.ExitCode)." -Level Warn
            }
        } catch {
            Write-Log "Chrome MSI install failed: $($_.Exception.Message)" -Level Warn
        }

        # Fallback: winget (only if present).
        if (Test-Winget) {
            try {
                Write-Log "Trying winget install $($settings.chrome.wingetId)..." -Level Info
                Start-Process -FilePath 'winget' -ArgumentList @(
                    'install', '--id', $settings.chrome.wingetId, '-e', '--silent',
                    '--accept-package-agreements', '--accept-source-agreements'
                ) -Wait -PassThru | Out-Null
                $path = Find-Chrome
                if ($path) { Write-Log "Chrome installed via winget: $path" -Level Success; return $path }
            } catch {
                Write-Log "winget Chrome install failed: $($_.Exception.Message)" -Level Warn
            }
        }
        Write-Log "Could not install Chrome automatically. URLs will open in the default browser." -Level Error
    }
    return $null
}

function Open-Url {
    <#
        .SYNOPSIS
        Opens a URL in Chrome (installing it first if needed). Falls back to the
        default browser when Chrome is unavailable.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Url,
        [string] $ChromePath
    )

    if (-not $ChromePath) { $ChromePath = Find-Chrome }
    if (-not $ChromePath) { $ChromePath = Install-Chrome }

    if ($PSCmdlet.ShouldProcess($Url, 'Open in browser')) {
        try {
            if ($ChromePath) {
                Start-Process -FilePath $ChromePath -ArgumentList $Url | Out-Null
            } else {
                Start-Process $Url | Out-Null
            }
            Write-Log "Opened: $Url" -Level Info
        } catch {
            Write-Log "Failed to open URL '$Url': $($_.Exception.Message)" -Level Warn
        }
    }
}

Export-ModuleMember -Function Test-Winget, Find-Chrome, Install-Chrome, Open-Url
