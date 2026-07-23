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
$script:JsonLogFile = $null
$script:LogPhase = ''

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
        # -WhatIf:$false: log/work paths must exist even in dry runs so a
        # transcript is always produced (they are the tool's own scratch, not
        # system state).
        New-Item -ItemType Directory -Path $root -Force -WhatIf:$false | Out-Null
    }
    return $root
}

function Get-LogDirectory {
    $dir = Join-Path (Get-ProgramDataRoot) 'logs'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    }
    return $dir
}

function Get-WorkDirectory {
    $dir = Join-Path (Get-ProgramDataRoot) 'work'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    }
    return $dir
}

function Initialize-Log {
    <#
        .SYNOPSIS
        Picks a timestamped log file under the log directory and returns its
        path. Also opens a structured JSONL sibling (<name>_<stamp>.jsonl) that
        receives every Write-Log entry with its phase and data for machine
        consumption (cross-system dev diffing).
    #>
    [CmdletBinding()]
    param([string] $Name = 'firstboot')

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFile = Join-Path (Get-LogDirectory) ("{0}_{1}.log" -f $Name, $stamp)
    $script:JsonLogFile = Join-Path (Get-LogDirectory) ("{0}_{1}.jsonl" -f $Name, $stamp)
    # Touch the files so callers can rely on them existing; -WhatIf:$false so a
    # transcript is produced even under -WhatIf (documented design intent).
    New-Item -ItemType File -Path $script:LogFile -Force -WhatIf:$false | Out-Null
    New-Item -ItemType File -Path $script:JsonLogFile -Force -WhatIf:$false | Out-Null
    return $script:LogFile
}

function Get-LogFile { return $script:LogFile }
function Get-JsonLogFile { return $script:JsonLogFile }

function Set-LogPhase {
    <#
        .SYNOPSIS
        Sets the current phase label stamped onto subsequent log entries (text
        tag + JSONL 'phase' field). Pass '' to clear.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Phase)
    $script:LogPhase = $Phase
}

function Write-Log {
    <#
        .SYNOPSIS
        Writes a timestamped line to the host, appends it to the active text log,
        and appends a structured record to the JSONL log (if Initialize-Log has
        been called). -Data attaches machine-readable detail to the JSONL record.
        'Trace' is the super-verbose level: shown on screen during rehearsal,
        verbose-stream otherwise. Never throws on logging errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('Info', 'Warn', 'Error', 'Success', 'Debug', 'Trace')]
        [string] $Level = 'Info',

        [string] $Phase,
        [hashtable] $Data
    )

    $curPhase = if ($PSBoundParameters.ContainsKey('Phase')) { $Phase } else { $script:LogPhase }
    $tag = if ($curPhase) { "[$curPhase] " } else { '' }
    $line = ('[{0}] [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $tag, $Message)

    switch ($Level) {
        'Error'   { Write-Host $line -ForegroundColor Red }
        'Warn'    { Write-Host $line -ForegroundColor Yellow }
        'Success' { Write-Host $line -ForegroundColor Green }
        'Trace'   { if (Test-Rehearsal) { Write-Host $line -ForegroundColor DarkGray } else { Write-Verbose $line } }
        'Debug'   { Write-Verbose $line }
        default   { Write-Host $line }
    }

    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop -WhatIf:$false }
        catch { <# logging must never break the run #> }
    }

    if ($script:JsonLogFile) {
        try {
            $entry = [ordered]@{
                ts    = (Get-Date).ToString('o')
                level = $Level.ToLowerInvariant()
                phase = $curPhase
                msg   = $Message
            }
            if ($Data) { $entry['data'] = $Data }
            Add-Content -LiteralPath $script:JsonLogFile -Value (ConvertTo-Json -InputObject $entry -Compress -Depth 8) `
                -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
        }
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
        [string] $Method = 'GET',
        [string] $Body,
        [string] $ContentType
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
            if ($PSBoundParameters.ContainsKey('Body') -and $Body) { $params['Body'] = $Body }
            if ($ContentType) { $params['ContentType'] = $ContentType }

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
# Cross-boot state (stage markers, captured prior settings for restores)
# ---------------------------------------------------------------------------

function Get-FirstBootStatePath {
    return (Join-Path (Get-ProgramDataRoot) 'state.json')
}

function Get-FirstBootState {
    <#
        .SYNOPSIS
        Loads the cross-boot state object (%ProgramData%\<app>\state.json), or an
        empty object when none exists. Used for stage markers (e.g. "BIOS already
        staged; don't reboot-loop") and captured prior settings for restores.
    #>
    [CmdletBinding()]
    param()
    $path = Get-FirstBootStatePath
    if (Test-Path -LiteralPath $path) {
        try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{}
}

function Set-FirstBootStateValue {
    <#
        .SYNOPSIS
        Sets one top-level property on the state object and persists it. Callers
        decide when a write is appropriate (rehearsal/-WhatIf paths do not call).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][AllowNull()] $Value
    )
    $state = Get-FirstBootState
    $state | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    ConvertTo-Json -InputObject $state -Depth 8 |
        Set-Content -LiteralPath (Get-FirstBootStatePath) -Encoding UTF8 -WhatIf:$false
    return $state
}

# ---------------------------------------------------------------------------
# Rehearsal mode (dev dry-run: emulate everything, mutate nothing)
# ---------------------------------------------------------------------------

$script:Rehearsal = $false
$script:RehearsalDownloads = $false

function Enable-Rehearsal {
    <#
        .SYNOPSIS
        Turns on rehearsal mode. Install/tweak functions then emulate their work
        true-to-life - probe URLs, render artifacts into the rehearsal work area,
        and log the exact commands they would run - without touching the system.
        -Downloads additionally performs real downloads + extraction + packer
        detection (files only; still no installs or registry/system changes).
    #>
    [CmdletBinding()]
    param([switch] $Downloads)
    $script:Rehearsal = $true
    $script:RehearsalDownloads = [bool]$Downloads
}

function Disable-Rehearsal {
    [CmdletBinding()]
    param()
    $script:Rehearsal = $false
    $script:RehearsalDownloads = $false
}

function Test-Rehearsal { return $script:Rehearsal }
function Test-RehearsalDownloads { return ($script:Rehearsal -and $script:RehearsalDownloads) }

function Get-RehearsalDirectory {
    <#
        .SYNOPSIS
        Staging area for rehearsal artifacts (downloads, extracted archives,
        rendered XMLs). Files only; nothing here is system state.
    #>
    $dir = Join-Path (Get-WorkDirectory) 'rehearsal'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    }
    return $dir
}

# ---------------------------------------------------------------------------
# HTTP probe (reachability + size without downloading)
# ---------------------------------------------------------------------------

function Get-ContentRangeTotal {
    <#
        .SYNOPSIS
        Total size from a Content-Range header value ('bytes 0-0/12345' -> 12345),
        or $null when absent/unparseable.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string] $ContentRange)
    if ($ContentRange -and $ContentRange -match '/\s*(\d+)\s*$') { return [int64]$Matches[1] }
    return $null
}

function Invoke-HttpProbe {
    <#
        .SYNOPSIS
        Checks a URL without downloading its body: HEAD first, then a 1-byte
        ranged GET (several vendor CDNs reject HEAD). Returns
        { Url; Ok; StatusCode; SizeBytes; FinalUrl; Via; Error }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Url,
        [int] $TimeoutSec = 30
    )

    Set-Tls12
    $headers = Get-DefaultHttpHeaders
    $lastErr = $null

    foreach ($mode in 'HEAD', 'RANGE') {
        $resp = $null
        try {
            $req = [Net.HttpWebRequest]::Create($Url)
            $req.Timeout = $TimeoutSec * 1000
            $req.AllowAutoRedirect = $true
            $req.UserAgent = $headers['User-Agent']
            $req.Accept = $headers['Accept']
            if ($mode -eq 'HEAD') { $req.Method = 'HEAD' }
            else { $req.Method = 'GET'; $req.AddRange(0, 0) }

            $resp = $req.GetResponse()
            $size = $null
            if ($mode -eq 'RANGE') { $size = Get-ContentRangeTotal ([string]$resp.Headers['Content-Range']) }
            if (-not $size -and $mode -eq 'HEAD' -and $resp.ContentLength -ge 0) { $size = [int64]$resp.ContentLength }

            return [pscustomobject]@{
                Url        = $Url
                Ok         = $true
                StatusCode = [int]$resp.StatusCode
                SizeBytes  = $size
                FinalUrl   = [string]$resp.ResponseUri
                Via        = $mode
                Error      = $null
            }
        }
        catch {
            $lastErr = $_.Exception.Message
        }
        finally {
            if ($resp) { try { $resp.Close() } catch { } }
        }
    }

    return [pscustomobject]@{
        Url = $Url; Ok = $false; StatusCode = $null; SizeBytes = $null
        FinalUrl = $null; Via = $null; Error = $lastErr
    }
}

# ---------------------------------------------------------------------------
# Environment snapshot (portability + rehearsal diagnostics)
# ---------------------------------------------------------------------------

function Test-HostReachable {
    <#
        .SYNOPSIS
        $true when a TCP connection to the host:port succeeds within the timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $TargetHost,
        [int] $Port = 443,
        [int] $TimeoutMs = 3000
    )
    $client = New-Object Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Get-SettingsUrlHosts {
    <#
        .SYNOPSIS
        Distinct hostnames from the endpoint URLs in config/defaults.json - the
        exact hosts a real run would contact. Used for reachability probes.
    #>
    [CmdletBinding()]
    param()
    $paths = @(
        'asus.pdInfoBase', 'asus.driversBase', 'asus.cdnBase', 'asus.fallbackBase',
        'msi.apiBase', 'msi.cdnBase', 'gigabyte.supportBase', 'gigabyte.cdnBase',
        'asrock.supportBase', 'asrock.cdnBase', 'nvidia.lookupUrl', 'nvidia.driverLookupBase',
        'chrome.msiUrl'
    )
    $hosts = New-Object System.Collections.Generic.List[string]
    $settings = $null
    try { $settings = Get-Settings } catch { return @() }
    foreach ($p in $paths) {
        $node = $settings
        foreach ($seg in $p.Split('.')) {
            if ($null -ne $node -and $node.PSObject.Properties[$seg]) { $node = $node.PSObject.Properties[$seg].Value }
            else { $node = $null; break }
        }
        if ($node -is [string] -and $node -match '^https?://') {
            try {
                $h = ([uri]$node).Host
                if ($h -and -not $hosts.Contains($h)) { $hosts.Add($h) | Out-Null }
            } catch { }
        }
    }
    return $hosts.ToArray()
}

function Get-EnvironmentSnapshot {
    <#
        .SYNOPSIS
        Captures the machine/runtime facts a dev needs to interpret a log from
        another system: OS, PowerShell, elevation, TLS, tooling presence, disk,
        memory, and (unless -SkipNetworkProbes) TCP reachability of every vendor
        host in config/defaults.json.
    #>
    [CmdletBinding()]
    param([switch] $SkipNetworkProbes)

    $os = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
    $cs = $null
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }

    $wingetVersion = $null
    $wingetPresent = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    if ($wingetPresent) {
        try { $wingetVersion = [string](& winget --version) } catch { }
    }

    $bits = $null
    try { $bits = [string](Get-Service -Name BITS -ErrorAction Stop).Status } catch { }

    $freeGb = $null
    try {
        $sysDrive = ($env:SystemDrive).TrimEnd(':')
        if ($sysDrive) { $freeGb = [Math]::Round((Get-PSDrive -Name $sysDrive -ErrorAction Stop).Free / 1GB, 1) }
    } catch { }

    $memGb = $null
    if ($cs) { try { $memGb = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1) } catch { } }

    $hostsProbed = @()
    if (-not $SkipNetworkProbes) {
        $hostsProbed = @(Get-SettingsUrlHosts | ForEach-Object {
            [pscustomobject]@{ Host = $_; Reachable = (Test-HostReachable -TargetHost $_) }
        })
    }

    return [pscustomobject]@{
        ComputerName    = $env:COMPUTERNAME
        OsCaption       = if ($os) { [string]$os.Caption } else { [string][Environment]::OSVersion.VersionString }
        OsVersion       = if ($os) { [string]$os.Version } else { $null }
        OsBuild         = if ($os) { [string]$os.BuildNumber } else { $null }
        PsVersion       = $PSVersionTable.PSVersion.ToString()
        PsEdition       = [string]$PSVersionTable.PSEdition
        Elevated        = Test-Admin
        ExecutionPolicy = [string](Get-ExecutionPolicy)
        TlsProtocols    = [string][Net.ServicePointManager]::SecurityProtocol
        WingetPresent   = $wingetPresent
        WingetVersion   = $wingetVersion
        BitsService     = $bits
        SystemDriveFreeGB = $freeGb
        MemoryGB        = $memGb
        VendorHosts     = $hostsProbed
    }
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
    # $IsWindows only exists on PowerShell Core; on 5.1 (Desktop, Windows-only)
    # a bare reference throws under StrictMode, so only consult it on Core.
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
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
    Initialize-Log, Get-LogFile, Get-JsonLogFile, Set-LogPhase, Write-Log, `
    Set-Tls12, Get-DefaultHttpHeaders, Invoke-Http, `
    Get-FileHashValue, Test-FileHash, `
    Get-FirstBootStatePath, Get-FirstBootState, Set-FirstBootStateValue, `
    Enable-Rehearsal, Disable-Rehearsal, Test-Rehearsal, Test-RehearsalDownloads, `
    Get-RehearsalDirectory, Get-ContentRangeTotal, Invoke-HttpProbe, `
    Test-HostReachable, Get-SettingsUrlHosts, Get-EnvironmentSnapshot, `
    Test-Admin, Assert-Admin
