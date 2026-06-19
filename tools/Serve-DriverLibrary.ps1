# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
#
# Serve-DriverLibrary.ps1 - serve a built driver library over HTTP on the LAN
# (index.json + files), zero extra deps (System.Net.HttpListener; runs on Ubuntu
# under pwsh). Clients point at it with -Mirror http://<host>:<port>.
# Alternatives (see docs/driver-library.md): `python3 -m http.server` or nginx.
#
#   pwsh -File tools/Serve-DriverLibrary.ps1 -Root /srv/drivers -Port 8080
#
# If binding http://+:<port> needs privileges, pass -Prefix http://<ip>:<port>/.

[CmdletBinding()]
param(
    [string] $Root,
    [int]    $Port = 8080,
    [string] $Prefix
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path (Split-Path -Parent $PSScriptRoot) 'library' }
$rootFull = [IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootFull)) { throw "Library root not found: $rootFull (run Build-DriverLibrary.ps1 first)." }
if (-not $Prefix) { $Prefix = "http://+:$Port/" }

$ctypes = @{
    '.zip' = 'application/zip'; '.exe' = 'application/octet-stream'; '.msi' = 'application/x-msi'
    '.json' = 'application/json'; '.pdf' = 'application/pdf'; '.inf' = 'text/plain'
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($Prefix)
try { $listener.Start() }
catch { throw "Could not bind $Prefix ($($_.Exception.Message)). Try -Prefix http://<this-host-ip>:$Port/ or run elevated." }

Write-Host "Serving $rootFull on $Prefix  (Ctrl+C to stop)"
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        try {
            $rel = [uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.json' }
            $full = [IO.Path]::GetFullPath((Join-Path $rootFull $rel))
            if (-not $full.StartsWith($rootFull)) { $res.StatusCode = 403 }      # path traversal guard
            elseif (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $res.StatusCode = 404 }
            else {
                $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
                $res.ContentType = if ($ctypes.ContainsKey($ext)) { $ctypes[$ext] } else { 'application/octet-stream' }
                $fs = [IO.File]::OpenRead($full)
                try { $res.ContentLength64 = $fs.Length; $fs.CopyTo($res.OutputStream) } finally { $fs.Dispose() }
            }
            Write-Host ("{0} {1} -> {2}" -f $req.HttpMethod, $rel, $res.StatusCode)
        } catch {
            $res.StatusCode = 500
            Write-Host "ERROR $($req.Url.AbsolutePath): $($_.Exception.Message)"
        } finally { $res.OutputStream.Close() }
    }
} finally { $listener.Stop(); $listener.Close() }
