# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Tweaks.psm1 - post-setup provisioning (the "tweaks" phase): set Chrome as the
# default browser, pin Chrome to the taskbar, disable OneDrive startup + Windows
# Copilot, and set a tier-based wallpaper. Driven by config/tweaks.json and
# config/tiers.json. Every action is best-effort, idempotent, logged, and honors
# -WhatIf. Pure helpers (XML builders, tier resolution) are unit-tested; the
# Windows-only actions guard on the OS so the suite runs anywhere.
# See docs/provisioning.md.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'Install-Chrome.psm1')

function Test-IsWindowsOs {
    # $IsWindows only exists on PowerShell Core; on 5.1 (Desktop) a bare
    # reference throws under StrictMode, and Desktop only runs on Windows.
    if ($PSVersionTable.PSEdition -eq 'Core') { return [bool]$IsWindows }
    return $true
}

function Get-TweaksConfig {
    [CmdletBinding()]
    param([string] $Path)
    if (-not $Path) { $Path = Join-Path (Get-FirstBootRoot) 'config/tweaks.json' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Tweaks config not found: $Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# Default browser (DISM default app associations - the supported imaging path)
# ---------------------------------------------------------------------------

function New-AppAssociationsXml {
    <#
        .SYNOPSIS
        Builds a DISM DefaultAssociations XML mapping the web protocols/types to a
        ProgId (Chrome's is ChromeHTML). Pure - returns the XML string.
    #>
    [CmdletBinding()]
    param(
        [string] $ProgId = 'ChromeHTML',
        [string] $AppName = 'Google Chrome',
        [string[]] $Identifiers = @('http', 'https', '.htm', '.html', '.shtml', '.svg', '.webp')
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine('<DefaultAssociations>')
    foreach ($id in $Identifiers) {
        [void]$sb.AppendLine(('  <Association Identifier="{0}" ProgId="{1}" ApplicationName="{2}" />' -f $id, $ProgId, $AppName))
    }
    [void]$sb.AppendLine('</DefaultAssociations>')
    return $sb.ToString()
}

function Invoke-Dism {
    # Mockable wrapper around dism.exe.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]] $ArgumentList)
    if ($PSCmdlet.ShouldProcess('dism.exe', ($ArgumentList -join ' '))) {
        $p = Start-Process -FilePath 'dism.exe' -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
        return $p.ExitCode
    }
    return 0
}

function Set-ChromeDefaultBrowser {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $ProgId = 'ChromeHTML')
    if (-not (Test-IsWindowsOs)) { Write-Log 'Default-browser: skipped (non-Windows).' -Level Debug; return }
    if (Test-Rehearsal) {
        $xml = New-AppAssociationsXml -ProgId $ProgId
        $staged = Join-Path (Get-RehearsalDirectory) 'firstboot-defaultapps.xml'
        Set-Content -LiteralPath $staged -Value $xml -Encoding UTF8 -WhatIf:$false
        Write-Log ("REHEARSE: rendered default-app associations XML -> {0}; would run: dism.exe /Online /Import-DefaultAppAssociations:<work>\firstboot-defaultapps.xml" -f $staged) -Level Info -Data @{
            progId = $ProgId; stagedXml = $staged
            command = 'dism.exe /Online /Import-DefaultAppAssociations:<work>\firstboot-defaultapps.xml'
        }
        return
    }
    if ($PSCmdlet.ShouldProcess('Default browser', "import default associations -> $ProgId")) {
        try {
            $xml = New-AppAssociationsXml -ProgId $ProgId
            $path = Join-Path (Get-WorkDirectory) 'firstboot-defaultapps.xml'
            Set-Content -LiteralPath $path -Value $xml -Encoding UTF8
            $code = Invoke-Dism -ArgumentList @('/Online', '/Import-DefaultAppAssociations:' + $path)
            if ($code -eq 0) { Write-Log 'Set Chrome as default browser (default app associations imported).' -Level Success }
            else { Write-Log "dism Import-DefaultAppAssociations exit $code." -Level Warn }
        } catch { Write-Log "Default-browser tweak failed: $($_.Exception.Message)" -Level Warn }
    }
}

# ---------------------------------------------------------------------------
# Taskbar pin (LayoutModification.xml - applies to new user profiles)
# ---------------------------------------------------------------------------

function New-TaskbarLayoutXml {
    <#
        .SYNOPSIS
        Builds a taskbar LayoutModification XML pinning the given desktop-app
        link paths. Pure - returns the XML string. PinListPlacement=Replace gives
        a known taskbar (edit the template to Append/extend per shop preference).
    #>
    [CmdletBinding()]
    param([string[]] $LinkPaths = @('%ProgramFiles%\Google\Chrome\Application\chrome.exe'))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-8"?>')
    [void]$sb.AppendLine('<LayoutModificationTemplate')
    [void]$sb.AppendLine('    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"')
    [void]$sb.AppendLine('    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"')
    [void]$sb.AppendLine('    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"')
    [void]$sb.AppendLine('    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"')
    [void]$sb.AppendLine('    Version="1">')
    [void]$sb.AppendLine('  <CustomTaskbarLayoutCollection PinListPlacement="Replace">')
    [void]$sb.AppendLine('    <defaultlayout:TaskbarLayout>')
    [void]$sb.AppendLine('      <taskbar:TaskbarPinList>')
    foreach ($p in $LinkPaths) {
        [void]$sb.AppendLine(('        <taskbar:DesktopApp DesktopApplicationLinkPath="{0}" />' -f $p))
    }
    [void]$sb.AppendLine('      </taskbar:TaskbarPinList>')
    [void]$sb.AppendLine('    </defaultlayout:TaskbarLayout>')
    [void]$sb.AppendLine('  </CustomTaskbarLayoutCollection>')
    [void]$sb.AppendLine('</LayoutModificationTemplate>')
    return $sb.ToString()
}

function Set-ChromeTaskbarPin {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-IsWindowsOs)) { Write-Log 'Taskbar pin: skipped (non-Windows).' -Level Debug; return }
    # A real .lnk is most reliable; fall back to the exe path.
    $chrome = Find-Chrome
    $link = if ($chrome) { $chrome } else { '%ProgramFiles%\Google\Chrome\Application\chrome.exe' }
    if (Test-Rehearsal) {
        $xml = New-TaskbarLayoutXml -LinkPaths @($link)
        $staged = Join-Path (Get-RehearsalDirectory) 'LayoutModification.xml'
        Set-Content -LiteralPath $staged -Value $xml -Encoding UTF8 -WhatIf:$false
        $target = Join-Path $env:SystemDrive 'Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml'
        Write-Log ("REHEARSE: rendered taskbar layout XML -> {0}; would write it to {1} (applies to new user profiles)" -f $staged, $target) -Level Info -Data @{
            link = $link; stagedXml = $staged; targetPath = $target
        }
        return
    }
    if ($PSCmdlet.ShouldProcess('Taskbar', "pin Chrome via LayoutModification ($link)")) {
        try {
            $xml = New-TaskbarLayoutXml -LinkPaths @($link)
            $shellDir = Join-Path $env:SystemDrive 'Users\Default\AppData\Local\Microsoft\Windows\Shell'
            if (-not (Test-Path -LiteralPath $shellDir)) { New-Item -ItemType Directory -Path $shellDir -Force | Out-Null }
            Set-Content -LiteralPath (Join-Path $shellDir 'LayoutModification.xml') -Value $xml -Encoding UTF8
            Write-Log 'Wrote taskbar LayoutModification (Chrome) to the Default profile (applies to new users).' -Level Success
        } catch { Write-Log "Taskbar-pin tweak failed: $($_.Exception.Message)" -Level Warn }
    }
}

# ---------------------------------------------------------------------------
# OneDrive startup + Copilot (registry)
# ---------------------------------------------------------------------------

function Disable-OneDriveStartup {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-IsWindowsOs)) { Write-Log 'OneDrive startup: skipped (non-Windows).' -Level Debug; return }
    if (Test-Rehearsal) {
        $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $present = [bool](Get-ItemProperty -Path $run -Name 'OneDrive' -ErrorAction SilentlyContinue)
        Write-Log ("REHEARSE: would remove 'OneDrive' from {0} (currently present: {1}) and mark it disabled (0x03) under ...\Explorer\StartupApproved\Run" -f $run, $present) -Level Info -Data @{
            runKey = $run; startupEntryPresent = $present
            approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        }
        return
    }
    if ($PSCmdlet.ShouldProcess('OneDrive', 'remove from startup')) {
        try {
            $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            if (Get-ItemProperty -Path $run -Name 'OneDrive' -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -Path $run -Name 'OneDrive' -ErrorAction SilentlyContinue
            }
            # Mark it disabled in StartupApproved so it does not get re-added as enabled.
            $approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
            if (-not (Test-Path $approved)) { New-Item -Path $approved -Force | Out-Null }
            $disabled = [byte[]](0x03,0,0,0,0,0,0,0,0,0,0,0)
            Set-ItemProperty -Path $approved -Name 'OneDrive' -Value $disabled -Type Binary
            Write-Log 'Disabled OneDrive startup.' -Level Success
        } catch { Write-Log "OneDrive-startup tweak failed: $($_.Exception.Message)" -Level Warn }
    }
}

function Disable-WindowsCopilot {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not (Test-IsWindowsOs)) { Write-Log 'Copilot: skipped (non-Windows).' -Level Debug; return }
    if (Test-Rehearsal) {
        Write-Log "REHEARSE: would set TurnOffWindowsCopilot=1 (DWord) under HKCU:+HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot and ShowCopilotButton=0 under HKCU:...\Explorer\Advanced" -Level Info -Data @{
            policyValue = 'TurnOffWindowsCopilot=1'
            keys = @('HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot',
                     'HKLM:\Software\Policies\Microsoft\Windows\WindowsCopilot')
        }
        return
    }
    if ($PSCmdlet.ShouldProcess('Windows Copilot', 'turn off via policy')) {
        try {
            foreach ($root in 'HKCU:', 'HKLM:') {
                $pol = "$root\Software\Policies\Microsoft\Windows\WindowsCopilot"
                if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
                Set-ItemProperty -Path $pol -Name 'TurnOffWindowsCopilot' -Value 1 -Type DWord
            }
            $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            if (Test-Path $adv) { Set-ItemProperty -Path $adv -Name 'ShowCopilotButton' -Value 0 -Type DWord -ErrorAction SilentlyContinue }
            Write-Log 'Disabled Windows Copilot.' -Level Success
        } catch { Write-Log "Copilot tweak failed: $($_.Exception.Message)" -Level Warn }
    }
}

# ---------------------------------------------------------------------------
# Wallpaper by ship tier
# ---------------------------------------------------------------------------

function Get-TierWallpaper {
    <#
        .SYNOPSIS
        Resolves a tier name to a full wallpaper path using a tiers map. Pure;
        pass -Tiers to inject the map (testing). Returns $null when the tier is
        unknown. The file is not required to exist here (caller checks).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Tier,
        $Tiers,
        [string] $WallpaperDir = 'wallpapers',
        [string] $Root
    )
    if ([string]::IsNullOrWhiteSpace($Tier)) { return $null }
    if (-not $Tiers) {
        $tiersPath = Join-Path (Get-FirstBootRoot) 'config/tiers.json'
        if (-not (Test-Path -LiteralPath $tiersPath)) { return $null }
        $Tiers = (Get-Content -LiteralPath $tiersPath -Raw -Encoding UTF8 | ConvertFrom-Json).tiers
    }
    $prop = $Tiers.PSObject.Properties | Where-Object { $_.Name -ieq $Tier } | Select-Object -First 1
    if (-not $prop) { return $null }
    $file = [string]$prop.Value
    if ([string]::IsNullOrWhiteSpace($file)) { return $null }
    if (-not $Root) { $Root = Get-FirstBootRoot }
    if ([System.IO.Path]::IsPathRooted($file)) { return $file }
    return (Join-Path (Join-Path $Root $WallpaperDir) $file)
}

function Set-Wallpaper {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-IsWindowsOs)) { Write-Log 'Wallpaper: skipped (non-Windows).' -Level Debug; return $false }
    if (-not (Test-Path -LiteralPath $Path)) { Write-Log "Wallpaper image not found: $Path" -Level Warn; return $false }
    if (Test-Rehearsal) {
        Write-Log ("REHEARSE: would set HKCU:\Control Panel\Desktop Wallpaper='{0}' (style Fill) and broadcast SystemParametersInfo(SPI_SETDESKWALLPAPER)" -f $Path) -Level Info -Data @{
            wallpaper = $Path; style = 'Fill'
        }
        return $true
    }
    if ($PSCmdlet.ShouldProcess('Desktop wallpaper', $Path)) {
        try {
            $desk = 'HKCU:\Control Panel\Desktop'
            Set-ItemProperty -Path $desk -Name 'Wallpaper' -Value $Path
            Set-ItemProperty -Path $desk -Name 'WallpaperStyle' -Value '10'   # Fill
            Set-ItemProperty -Path $desk -Name 'TileWallpaper' -Value '0'
            Add-Type -ErrorAction SilentlyContinue -Namespace FirstBoot -Name NativeWp -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@
            [FirstBoot.NativeWp]::SystemParametersInfo(0x0014, 0, $Path, 0x03) | Out-Null   # SPI_SETDESKWALLPAPER, UPDATEINIFILE|SENDCHANGE
            Write-Log "Set wallpaper: $Path" -Level Success
            return $true
        } catch { Write-Log "Set-Wallpaper failed: $($_.Exception.Message)" -Level Warn; return $false }
    }
    return $false
}

function Set-TierWallpaper {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Tier,
        [string] $WallpaperDir = 'wallpapers'
    )
    $path = Get-TierWallpaper -Tier $Tier -WallpaperDir $WallpaperDir
    if (-not $path) { Write-Log "Wallpaper: no mapping for tier '$Tier'; skipping." -Level Info; return }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "Wallpaper: tier '$Tier' maps to '$path' but the file is missing (add it to $WallpaperDir/)." -Level Warn
        return
    }
    Set-Wallpaper -Path $path | Out-Null
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Invoke-Tweaks {
    <#
        .SYNOPSIS
        Runs the enabled provisioning tweaks from config/tweaks.json. -Tier selects
        the wallpaper (overrides wallpaper.defaultTier). Honors -WhatIf throughout.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Tier,
        $Config
    )
    if (-not $Config) { $Config = Get-TweaksConfig }

    if ($Config.PSObject.Properties['setChromeDefaultBrowser'] -and $Config.setChromeDefaultBrowser) { Set-ChromeDefaultBrowser }
    if ($Config.PSObject.Properties['pinChromeToTaskbar']     -and $Config.pinChromeToTaskbar)     { Set-ChromeTaskbarPin }
    if ($Config.PSObject.Properties['disableOneDriveStartup'] -and $Config.disableOneDriveStartup) { Disable-OneDriveStartup }
    if ($Config.PSObject.Properties['disableCopilot']         -and $Config.disableCopilot)         { Disable-WindowsCopilot }

    $wp = if ($Config.PSObject.Properties['wallpaper']) { $Config.wallpaper } else { $null }
    if ($wp -and $wp.enabled) {
        $useTier = if ($Tier) { $Tier } elseif ($wp.PSObject.Properties['defaultTier']) { [string]$wp.defaultTier } else { '' }
        $dir = if ($wp.PSObject.Properties['wallpaperDir'] -and $wp.wallpaperDir) { [string]$wp.wallpaperDir } else { 'wallpapers' }
        if ($useTier) { Set-TierWallpaper -Tier $useTier -WallpaperDir $dir }
        else { Write-Log 'Wallpaper: no -Tier and no defaultTier; skipping.' -Level Info }
    }
}

Export-ModuleMember -Function `
    Get-TweaksConfig, New-AppAssociationsXml, Invoke-Dism, Set-ChromeDefaultBrowser, `
    New-TaskbarLayoutXml, Set-ChromeTaskbarPin, Disable-OneDriveStartup, Disable-WindowsCopilot, `
    Get-TierWallpaper, Set-Wallpaper, Set-TierWallpaper, Invoke-Tweaks
