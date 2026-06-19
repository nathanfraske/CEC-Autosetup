# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Common.psm1 - shared utilities: settings, logging, HTTP, hashing, admin checks.
# Targets Windows PowerShell 5.1+ (in-box on Windows 10/11). Pure-logic helpers
# are written to run cross-platform so the offline test suite can exercise them.

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

$script:Settings = $null

function Get-FirstBootRoot {
    <#
        .SYNOPSIS
        Repository root (the parent of src/). Used to locate config/ and providers.
    #>
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-Settings {
    <#
        .SYNOPSIS
        Loads config/defaults.json once and caches it. Pass -Path to override,
        -Force to reload.
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [switch] $Force
    )

    if ($script:Settings -and -not $Force -and -not $Path) {
        return $script:Settings
    }

    if (-not $Path) {
        $Path = Join-Path (Get-FirstBootRoot) 'config/defaults.json'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Settings file not found: $Path"
    }

    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Settings = $json
    return $script:Settings
}

function Get-AppName {
    try { return (Get-Settings).appName } catch { return 'firstboot' }
}

# ---------------------------------------------------------------------------
# Paths / logging
# ---------------------------------------------------------------------------

$script:LogFile = $null

function Get-ProgramDataRoot {
    <#
        .SYNOPSIS
        %ProgramData%\<appName> on Windows; a temp-based equivalent elsewhere
        (so tests and dev on non-Windows do not blow up).
    #>
    $app = Get-AppName
    if ($env:ProgramData) {
        $root = Join-Path $env:ProgramData $app
    }
    else {
        $base = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
        $root = Join-Path $base $app
    }
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return $root
}

function Get-LogDirectory {
    $dir = Join-Path (Get-ProgramDataRoot) 'logs'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-WorkDirectory {
    $dir = Join-Path (Get-ProgramDataRoot) 'work'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Initialize-Log {
    <#
        .SYNOPSIS
        Picks a timestamped log file under the log directory and returns its path.
    #>
    [CmdletBinding()]
    param([string] $Name = 'firstboot')

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFile = Join-Path (Get-LogDirectory) ("{0}_{1}.log" -f $Name, $stamp)
    # Touch the file so callers can rely on it existing.
    New-Item -ItemType File -Path $script:LogFile -Force | Out-Null
    return $script:LogFile
}

function Get-LogFile { return $script:LogFile }

function Write-Log {
    <#
        .SYNOPSIS
        Writes a timestamped line to the host and appends it to the active log
        file (if Initialize-Log has been called). Never throws on logging errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('Info', 'Warn', 'Error', 'Success', 'Debug')]
        [string] $Level = 'Info'
    )

    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message)

    switch ($Level) {
        'Error'   { Write-Host $line -ForegroundColor Red }
        'Warn'    { Write-Host $line -ForegroundColor Yellow }
        'Success' { Write-Host $line -ForegroundColor Green }
        'Debug'   { Write-Verbose $line }
        default   { Write-Host $line }
    }

    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop }
        catch { <# logging must never break the run #> }
    }
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

function Set-Tls12 {
    <#
        .SYNOPSIS
        Ensures TLS 1.2 (and 1.3 when the runtime supports it) is enabled.
        Default .NET on Windows PowerShell 5.1 negotiates older protocols that
        modern vendor endpoints reject.
    #>
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13
    } catch { <# Tls13 enum absent on older runtimes; ignore #> }
}

function Get-DefaultHttpHeaders {
    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
    try { $ua = (Get-Settings).http.userAgent } catch { }
    return @{
        'User-Agent'      = $ua
        'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.9,*/*;q=0.8'
        'Accept-Language' = 'en-US,en;q=0.9'
    }
}

function Invoke-Http {
    <#
        .SYNOPSIS
        HTTP GET with TLS 1.2, a browser User-Agent, and exponential-backoff
        retries. Returns response text by default, or downloads to -OutFile.
        Throws after exhausting retries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [hashtable] $Headers,
        [string] $OutFile,
        [int] $TimeoutSec,
        [int] $Retries,
        [int] $BackoffBaseMs,
        [string] $Method = 'GET'
    )

    Set-Tls12

    $settings = $null
    try { $settings = Get-Settings } catch { }
    if (-not $TimeoutSec)    { $TimeoutSec    = if ($settings) { [int]$settings.http.timeoutSec }    else { 60 } }
    if (-not $Retries)       { $Retries       = if ($settings) { [int]$settings.http.retries }       else { 4 } }
    if (-not $BackoffBaseMs) { $BackoffBaseMs = if ($settings) { [int]$settings.http.backoffBaseMs } else { 1000 } }

    $mergedHeaders = Get-DefaultHttpHeaders
    if ($Headers) {
        foreach ($k in $Headers.Keys) { $mergedHeaders[$k] = $Headers[$k] }
    }

    $attempt = 0
    $lastErr = $null
    while ($attempt -le $Retries) {
        try {
            $params = @{
                Uri             = $Url
                Headers         = $mergedHeaders
                Method          = $Method
                TimeoutSec      = $TimeoutSec
                UseBasicParsing = $true
                ErrorAction     = 'Stop'
            }
            if ($OutFile) { $params['OutFile'] = $OutFile }

            $resp = Invoke-WebRequest @params
            if ($OutFile) { return $OutFile }
            return $resp.Content
        }
        catch {
            $lastErr = $_
            $attempt++
            if ($attempt -gt $Retries) { break }
            $delay = [int]($BackoffBaseMs * [Math]::Pow(2, $attempt - 1))
            Write-Log ("HTTP attempt {0}/{1} for {2} failed: {3}. Retrying in {4} ms." -f `
                $attempt, $Retries, $Url, $_.Exception.Message, $delay) -Level Warn
            Start-Sleep -Milliseconds $delay
        }
    }
    throw ("HTTP request failed after {0} attempt(s): {1} :: {2}" -f ($Retries + 1), $Url, $lastErr.Exception.Message)
}

# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------

function Get-FileHashValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('SHA256', 'MD5', 'SHA1')] [string] $Algorithm = 'SHA256'
    )
    return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash
}

function Test-FileHash {
    <#
        .SYNOPSIS
        Verifies a file against an expected hash. When the expected hash is
        empty/null (common for ASUS), returns $true and logs that nothing was
        verified - the caller decided the download was acceptable without one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $ExpectedHash,
        [ValidateSet('SHA256', 'MD5', 'SHA1')] [string] $Algorithm = 'SHA256'
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) {
        Write-Log ("No {0} hash supplied for {1}; skipping verification." -f $Algorithm, (Split-Path -Leaf $Path)) -Level Debug
        return $true
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $actual = Get-FileHashValue -Path $Path -Algorithm $Algorithm
    $ok = ($actual -ieq $ExpectedHash.Trim())
    if (-not $ok) {
        Write-Log ("{0} mismatch for {1}: expected {2}, got {3}" -f `
            $Algorithm, (Split-Path -Leaf $Path), $ExpectedHash, $actual) -Level Error
    }
    return $ok
}

# ---------------------------------------------------------------------------
# Admin / elevation
# ---------------------------------------------------------------------------

function Test-Admin {
    <#
        .SYNOPSIS
        $true if the current process is elevated. On non-Windows (dev/test) we
        report based on the effective uid so the suite can run unprivileged.
    #>
    if ($IsWindows -eq $false) {
        try { return ((id -u) -eq 0) } catch { return $false }
    }
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        throw 'Administrator privileges are required. Re-run from an elevated prompt or via bootstrap.ps1.'
    }
}

Export-ModuleMember -Function `
    Get-FirstBootRoot, Get-Settings, Get-AppName, `
    Get-ProgramDataRoot, Get-LogDirectory, Get-WorkDirectory, `
    Initialize-Log, Get-LogFile, Write-Log, `
    Set-Tls12, Get-DefaultHttpHeaders, Invoke-Http, `
    Get-FileHashValue, Test-FileHash, `
    Test-Admin, Assert-Admin
