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

    # 28591 = ISO-8859-1; the [Text.Encoding]::Latin1 shortcut is .NET 5+ only
    # and does not exist on Windows PowerShell 5.1 (.NET Framework).
    $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
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

    if (Test-Rehearsal) {
        return (Invoke-DriverPackageRehearsal -Result $result -Entry $Entry)
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

function Invoke-DriverPackageRehearsal {
    <#
        .SYNOPSIS
        Rehearses one driver entry true-to-life without installing anything.
        Default: probes the URL (reachability + size) and logs the exact
        pipeline a real run would execute. With rehearsal downloads enabled it
        really downloads, hash-verifies, extracts, enumerates .infs and detects
        the EXE packer - then logs the exact install command instead of running it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] $Entry
    )

    $fileName = [IO.Path]::GetFileName(($Entry.Url -split '\?')[0])
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = ($Entry.Name -replace '[^\w.-]', '_') + '.bin' }
    $ext = [IO.Path]::GetExtension($fileName).ToLowerInvariant()

    $hash = ''
    $hashAlg = ''
    if ($Entry.PSObject.Properties['Hash'])    { $hash    = [string]$Entry.Hash }
    if ($Entry.PSObject.Properties['HashAlg']) { $hashAlg = [string]$Entry.HashAlg }

    Write-Log ("REHEARSE driver [{0}] {1} {2}" -f $Entry.Category, $Entry.Name, $Entry.Version) -Level Info
    Write-Log 'entry detail' -Level Trace -Data @{
        url = [string]$Entry.Url; file = $fileName; ext = $ext; hash = $hash; hashAlg = $hashAlg
    }

    if (-not (Test-RehearsalDownloads)) {
        $probe = Invoke-HttpProbe -Url $Entry.Url
        if (-not $probe.Ok) {
            Write-Log ("REHEARSE: source unreachable: {0} :: {1}" -f $Entry.Url, $probe.Error) -Level Warn -Data @{
                url = [string]$Entry.Url; error = [string]$probe.Error
            }
            $Result.Status = 'Blocked'; $Result.Method = 'rehearse:probe'
            $Result.Detail = "probe failed: $($probe.Error)"
            return $Result
        }

        $sizeTxt = if ($probe.SizeBytes) { '{0:N1} MB' -f ($probe.SizeBytes / 1MB) } else { 'size unknown' }
        $next = switch ($ext) {
            '.zip' { 'extract, then pnputil /add-driver <extracted>\*.inf /subdirs /install (or the largest EXE with packer-specific silent args)' }
            '.exe' { 'detect packer, then run silently with the packer-specific switch' }
            '.msi' { 'msiexec /i "<file>" /qn /norestart' }
            default { "unhandled extension '$ext' -> NeedsManual" }
        }
        Write-Log ("REHEARSE: reachable (HTTP {0}, {1}, via {2}); would download to <work>\{3}, verify {4}, then {5}" -f `
            $probe.StatusCode, $sizeTxt, $probe.Via, $fileName, $(if ($hash) { $hashAlg } else { 'nothing (no hash supplied)' }), $next) -Level Info -Data @{
            statusCode = $probe.StatusCode; sizeBytes = $probe.SizeBytes; via = [string]$probe.Via
            finalUrl = [string]$probe.FinalUrl; nextStep = $next
        }
        $Result.Status = 'Rehearsed'; $Result.Method = 'rehearse:probe'
        $Result.Detail = "HTTP $($probe.StatusCode), $sizeTxt"
        return $Result
    }

    # Full-fidelity rehearsal: real download + extraction into the rehearsal
    # staging area. Everything except the final install commands.
    $workDir = Join-Path (Get-RehearsalDirectory) 'drivers'
    if (-not (Test-Path -LiteralPath $workDir)) { New-Item -ItemType Directory -Path $workDir -Force -WhatIf:$false | Out-Null }
    $dest = Join-Path $workDir $fileName

    try {
        Write-Log "REHEARSE: downloading $($Entry.Name) for inspection..." -Level Info
        Save-Download -Url $Entry.Url -Destination $dest -Activity "Rehearsing $($Entry.Category): $($Entry.Name)" | Out-Null
    } catch {
        Write-Log "REHEARSE: download failed: $($_.Exception.Message)" -Level Warn
        $Result.Status = 'Blocked'; $Result.Method = 'rehearse:download'; $Result.Detail = $_.Exception.Message
        return $Result
    }

    $verified = Test-FileHash -Path $dest -ExpectedHash $hash -Algorithm $(if ($hashAlg) { $hashAlg } else { 'SHA256' })
    Write-Log ("REHEARSE: downloaded {0:N1} MB; hash verified: {1}" -f ((Get-Item -LiteralPath $dest).Length / 1MB), $verified) -Level Trace -Data @{
        sizeBytes = (Get-Item -LiteralPath $dest).Length; hashVerified = [bool]$verified
    }
    if (-not $verified) {
        $Result.Status = 'HashFailed'; $Result.Method = 'rehearse:verify'
        $Result.Detail = "expected $hashAlg $hash"
        return $Result
    }

    if ($ext -eq '.zip') {
        $extractDir = Expand-DriverArchive -Path $dest -WhatIf:$false
        $infs = @(Get-ChildItem -LiteralPath $extractDir -Recurse -Filter *.inf -ErrorAction SilentlyContinue)
        if ($infs.Count -gt 0) {
            $pattern = Join-Path $extractDir '*.inf'
            Write-Log ("REHEARSE: {0} .inf file(s); would run: pnputil.exe /add-driver ""{1}"" /subdirs /install" -f $infs.Count, $pattern) -Level Info -Data @{
                infCount = $infs.Count; command = "pnputil.exe /add-driver `"$pattern`" /subdirs /install"
            }
            $Result.Status = 'Rehearsed'; $Result.Method = 'rehearse:pnputil'
            $Result.Detail = "$($infs.Count) .inf"
            return $Result
        }
        $exe = @(Get-ChildItem -LiteralPath $extractDir -Recurse -Filter *.exe -ErrorAction SilentlyContinue |
                 Sort-Object Length -Descending | Select-Object -First 1)
        if ($exe.Count -gt 0) {
            return (Invoke-ExeRehearsal -Result $Result -ExePath $exe[0].FullName)
        }
        Write-Log 'REHEARSE: archive has no .inf or .exe; a real run would flag NeedsManual.' -Level Warn
        $Result.Status = 'Rehearsed'; $Result.Method = 'rehearse:manual'; $Result.Detail = 'archive had no .inf/.exe'
        return $Result
    }
    elseif ($ext -eq '.exe') {
        return (Invoke-ExeRehearsal -Result $Result -ExePath $dest)
    }
    elseif ($ext -eq '.msi') {
        Write-Log ("REHEARSE: would run: msiexec.exe /i ""{0}"" /qn /norestart" -f $dest) -Level Info -Data @{
            command = "msiexec.exe /i `"$dest`" /qn /norestart"
        }
        $Result.Status = 'Rehearsed'; $Result.Method = 'rehearse:msiexec'; $Result.Detail = 'msi'
        return $Result
    }

    Write-Log "REHEARSE: unhandled file type '$ext'; a real run would flag NeedsManual." -Level Warn
    $Result.Status = 'Rehearsed'; $Result.Method = 'rehearse:manual'; $Result.Detail = "unhandled extension $ext"
    return $Result
}

function Invoke-ExeRehearsal {
    <#
        .SYNOPSIS
        Rehearses the EXE-install branch: real packer detection on the real
        binary, then logs the exact silent command instead of running it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)][string] $ExePath
    )
    $packer = Get-PackerType -Path $ExePath
    $silentArgs = Get-SilentArgs -PackerType $packer
    $Result.Method = "rehearse:exe:$packer"
    if (-not $silentArgs) {
        Write-Log ("REHEARSE: packer for {0} is Unknown; a real run would NOT auto-run it (NeedsManual)." -f (Split-Path -Leaf $ExePath)) -Level Warn
        $Result.Status = 'Rehearsed'; $Result.Detail = 'unknown packer; no safe silent switch'
        return $Result
    }
    Write-Log ("REHEARSE: packer {0}; would run: ""{1}"" {2}" -f $packer, $ExePath, $silentArgs) -Level Info -Data @{
        packer = $packer; command = "`"$ExePath`" $silentArgs"
    }
    $Result.Status = 'Rehearsed'; $Result.Detail = "exe:$packer $silentArgs"
    return $Result
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
    Invoke-Pnputil, Invoke-ExeInstaller, Install-DriverPackage, Install-ExeEntry, `
    Invoke-DriverPackageRehearsal, Invoke-ExeRehearsal
