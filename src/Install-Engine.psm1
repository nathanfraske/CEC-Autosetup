# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Install-Engine.psm1 - takes a uniform driver entry through:
#   download (BITS, Invoke-WebRequest fallback) -> verify hash when present ->
#   extract -> install (INF via pnputil; EXE via packer-specific silent flags) ->
#   log outcome. Install primitives are documented in vendor-contracts.md 2.5.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Common.psm1')

function Save-Download {
    <#
        .SYNOPSIS
        Downloads a URL to a destination with a live progress bar (async BITS),
        falling back to HTTP. Returns the destination path.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $Destination,
        [string] $Activity
    )

    if (-not $Activity) { $Activity = "Downloading $(Split-Path -Leaf $Destination)" }
    if (-not $PSCmdlet.ShouldProcess($Destination, "Download $Url")) { return $Destination }

    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        $job = $null
        try {
            $job = Start-BitsTransfer -Source $Url -Destination $Destination -Asynchronous -DisplayName 'firstboot' -ErrorAction Stop
            while ($job.JobState -in 'Connecting', 'Queued', 'Transferring', 'TransientError') {
                $total = [double]$job.BytesTotal
                $done  = [double]$job.BytesTransferred
                $pct   = if ($total -gt 0) { [int][Math]::Min(100, ($done / $total) * 100) } else { 0 }
                $mbps  = if ($sw.Elapsed.TotalSeconds -gt 0) { ($done / 1MB) / $sw.Elapsed.TotalSeconds } else { 0 }
                $status = if ($total -gt 0) {
                    "{0:N1} / {1:N1} MB  ({2:N1} MB/s)" -f ($done / 1MB), ($total / 1MB), $mbps
                } else {
                    "{0:N1} MB  ({1:N1} MB/s)" -f ($done / 1MB), $mbps
                }
                Write-Progress -Id 1 -Activity $Activity -Status $status -PercentComplete $pct
                Start-Sleep -Milliseconds 500
            }
            if ($job.JobState -eq 'Transferred') {
                Complete-BitsTransfer -BitsJob $job
                Write-Progress -Id 1 -Activity $Activity -Completed
                $mb = (Get-Item -LiteralPath $Destination).Length / 1MB
                Write-Log ("Downloaded {0} ({1:N1} MB in {2:N0}s)" -f (Split-Path -Leaf $Destination), $mb, $sw.Elapsed.TotalSeconds) -Level Info
                return $Destination
            }
            throw "BITS job ended in state '$($job.JobState)': $($job.ErrorDescription)"
        } catch {
            Write-Progress -Id 1 -Activity $Activity -Completed
            if ($job) { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue }
            Write-Log "BITS transfer failed ($($_.Exception.Message)); falling back to HTTP." -Level Warn
        }
    }

    Write-Log "Downloading $(Split-Path -Leaf $Destination) via HTTP..." -Level Info
    Invoke-Http -Url $Url -OutFile $Destination | Out-Null   # Invoke-WebRequest shows its own progress
    return $Destination
}

function Get-PackerType {
    <#
        .SYNOPSIS
        Best-effort installer packer detection by scanning the EXE for known
        marker strings. Returns 'Inno' | 'NSIS' | 'InstallShield' | 'Unknown'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $cap = 96MB
    $bytes = $null
    try {
        $len = (Get-Item -LiteralPath $Path).Length
        $read = [Math]::Min([int64]$len, [int64]$cap)
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buffer = New-Object byte[] $read
            [void]$fs.Read($buffer, 0, $read)
            $bytes = $buffer
        } finally { $fs.Dispose() }
    } catch {
        return 'Unknown'
    }

    $text = [Text.Encoding]::Latin1.GetString($bytes)
    if ($text -match 'Inno Setup')    { return 'Inno' }
    if ($text -match 'Nullsoft')      { return 'NSIS' }
    if ($text -match 'InstallShield') { return 'InstallShield' }
    return 'Unknown'
}

function Get-SilentArgs {
    <#
        .SYNOPSIS
        Silent-install arguments per packer (vendor-contracts.md 2.5). Returns
        $null for Unknown so first-boot never launches an interactive installer
        that would hang an unattended run.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $PackerType)

    switch ($PackerType) {
        'InstallShield' { return '/s /v"/qn"' }
        'NSIS'          { return '/S' }
        'Inno'          { return '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
        default         { return $null }
    }
}

function Expand-DriverArchive {
    <#
        .SYNOPSIS
        Extracts a .zip to a fresh directory and returns that directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Destination
    )
    if (-not $Destination) {
        $Destination = Join-Path (Split-Path -Parent $Path) ((Split-Path -Leaf $Path) + '_x')
    }
    if ($PSCmdlet.ShouldProcess($Path, "Extract to $Destination")) {
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Expand-Archive -LiteralPath $Path -DestinationPath $Destination -Force
    }
    return $Destination
}

function Invoke-Pnputil {
    <#
        .SYNOPSIS
        Wrapper around pnputil so the install branch is mockable in tests.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $InfPattern)
    if ($PSCmdlet.ShouldProcess($InfPattern, 'pnputil /add-driver /subdirs /install')) {
        & pnputil.exe /add-driver $InfPattern /subdirs /install
        return $LASTEXITCODE
    }
    return 0
}

function Invoke-ExeInstaller {
    <#
        .SYNOPSIS
        Wrapper around running an EXE installer so the branch is mockable.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Arguments
    )
    if ($PSCmdlet.ShouldProcess($Path, "run installer ($Arguments)")) {
        if ($Arguments) {
            $p = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
        } else {
            $p = Start-Process -FilePath $Path -Wait -PassThru
        }
        return $p.ExitCode
    }
    return 0
}

function Install-DriverPackage {
    <#
        .SYNOPSIS
        Full pipeline for one driver entry. Returns a result object describing the
        outcome. Honors -WhatIf (plans only, downloads/installs nothing).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Entry,
        [string] $WorkDir
    )

    $result = [pscustomobject]@{
        Name     = $Entry.Name
        Category = $Entry.Category
        Version  = $Entry.Version
        Url      = $Entry.Url
        Method   = $null
        Status   = $null
        Detail   = $null
    }

    if (-not $PSCmdlet.ShouldProcess($Entry.Name, "download + install from $($Entry.Url)")) {
        Write-Log ("PLAN: install [{0}] {1} {2} <- {3}" -f $Entry.Category, $Entry.Name, $Entry.Version, $Entry.Url) -Level Info
        $result.Status = 'WhatIf'
        $result.Method = 'plan'
        return $result
    }

    if (-not $WorkDir) { $WorkDir = Get-WorkDirectory }
    $fileName = [IO.Path]::GetFileName(($Entry.Url -split '\?')[0])
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = ($Entry.Name -replace '[^\w.-]', '_') + '.bin' }
    $dest = Join-Path $WorkDir $fileName

    try {
        Write-Log "Downloading $($Entry.Name) ($($Entry.Version))..." -Level Info
        Save-Download -Url $Entry.Url -Destination $dest -Activity "Downloading $($Entry.Category): $($Entry.Name)" | Out-Null
    } catch {
        Write-Log "Download failed for $($Entry.Name): $($_.Exception.Message)" -Level Error
        $result.Status = 'Failed'; $result.Method = 'download'; $result.Detail = $_.Exception.Message
        return $result
    }

    if (-not (Test-FileHash -Path $dest -ExpectedHash $Entry.Hash -Algorithm $Entry.HashAlg)) {
        $result.Status = 'HashFailed'; $result.Method = 'verify'
        $result.Detail = "Expected $($Entry.HashAlg) $($Entry.Hash)"
        return $result
    }

    $ext = [IO.Path]::GetExtension($fileName).ToLowerInvariant()

    if ($ext -eq '.zip') {
        $extractDir = Expand-DriverArchive -Path $dest
        $infs = @(Get-ChildItem -LiteralPath $extractDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
        if ($infs.Count -gt 0) {
            $pattern = Join-Path $extractDir '*.inf'
            Write-Log "Installing INF package via pnputil ($($infs.Count) .inf found)..." -Level Info
            $code = Invoke-Pnputil -InfPattern $pattern
            $result.Method = 'pnputil'
            # pnputil returns 0 success, 3010 success-reboot-required.
            $result.Status = if ($code -in 0, 3010) { 'Installed' } else { 'Failed' }
            $result.Detail = "exit $code"
            return $result
        }

        $exe = @(Get-ChildItem -LiteralPath $extractDir -Recurse -Filter *.exe -ErrorAction SilentlyContinue |
                 Sort-Object Length -Descending | Select-Object -First 1)
        if ($exe.Count -gt 0) {
            return (Install-ExeEntry -Result $result -ExePath $exe[0].FullName)
        }

        Write-Log "No .inf or .exe found in $($Entry.Name); manual handling needed." -Level Warn
        $result.Status = 'NeedsManual'; $result.Method = 'none'; $result.Detail = 'archive had no .inf/.exe'
        return $result
    }
    elseif ($ext -eq '.exe') {
        return (Install-ExeEntry -Result $result -ExePath $dest)
    }
    elseif ($ext -eq '.msi') {
        Write-Log "Installing MSI via msiexec /qn /norestart..." -Level Info
        $code = Invoke-ExeInstaller -Path 'msiexec.exe' -Arguments ('/i "{0}" /qn /norestart' -f $dest)
        $result.Method = 'msiexec'
        $result.Status = if ($code -in 0, 3010) { 'Installed' } else { 'Failed' }
        $result.Detail = "exit $code"
        return $result
    }

    Write-Log "Unhandled file type '$ext' for $($Entry.Name)." -Level Warn
    $result.Status = 'NeedsManual'; $result.Method = 'none'; $result.Detail = "unhandled extension $ext"
    return $result
}

function Install-ExeEntry {
    <#
        .SYNOPSIS
        Detects packer, picks silent args, and runs an EXE installer. Unknown
        packers are not auto-run (would hang an unattended first boot).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)][string] $ExePath
    )

    $packer = Get-PackerType -Path $ExePath
    $silentArgs = Get-SilentArgs -PackerType $packer
    $Result.Method = "exe:$packer"

    if (-not $silentArgs) {
        Write-Log "Packer for $(Split-Path -Leaf $ExePath) is Unknown; skipping silent run (manual install needed)." -Level Warn
        $Result.Status = 'NeedsManual'
        $Result.Detail = 'unknown packer; no safe silent switch'
        return $Result
    }

    Write-Log "Installing EXE ($packer) silently: $silentArgs" -Level Info
    $code = Invoke-ExeInstaller -Path $ExePath -Arguments $silentArgs
    $Result.Status = if ($code -in 0, 3010) { 'Installed' } else { 'Failed' }
    $Result.Detail = "exit $code"
    return $Result
}

Export-ModuleMember -Function `
    Save-Download, Get-PackerType, Get-SilentArgs, Expand-DriverArchive, `
    Invoke-Pnputil, Invoke-ExeInstaller, Install-DriverPackage, Install-ExeEntry
