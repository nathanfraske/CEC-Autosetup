<!-- SPDX-License-Identifier: Apache-2.0 -->

# Architecture

## Data flow

```
bootstrap.ps1
   │  set TLS 1.2 + process ExecutionPolicy Bypass
   │  locate engine (local/USB copy, or download snapshot for the online one-liner)
   │  self-elevate if needed
   ▼
src/FirstBoot.ps1  (orchestrator)
   │
   ├─ Detect-Hardware.psm1 ── Win32_BaseBoard ──▶ { Vendor, Model }
   │
   ├─ providers/Provider.psm1 ── Get-Provider $Vendor ──▶ provider object
   │        │
   │        ├─ Resolve-Product(Model)      ─▶ identity (or $null)
   │        ├─ Get-DriverList(identity,osid)─▶ uniform driver entries (or throws)
   │        └─ Get-FallbackUrl(identity,Model)─▶ human-openable page
   │
   ├─ if SupportsHeadless and list obtained:
   │        Install-Engine.psm1 per entry:
   │            Save-Download (BITS → HTTP) ─▶ Test-FileHash ─▶ Expand-Archive
   │            ─▶ pnputil (INF)  |  packer-specific silent EXE  |  msiexec (MSI)
   │
   ├─ else (not headless, list failed, or unresolved):
   │        Install-Chrome.psm1: ensure Chrome ─▶ Open-Url(fallback) ─▶ print checklist
   │
   ├─ apps phase (unless -SkipApps):
   │        Detect-Peripherals.psm1 ─▶ devices { Name, VidPid, Class }
   │        apps/AppCatalog.psm1: Find-MatchingApps ─▶ Install-App
   │            winget (if package id) | Chrome fallback (official page)
   │
   └─ write summary; transcript at %ProgramData%\firstboot\logs\
```

## The provider contract

`Get-Provider -Vendor` (in `providers/Provider.psm1`) imports the vendor module
and returns a **provider object**:

```powershell
[pscustomobject]@{
    Name             = 'asus'                          # provider key
    SupportsHeadless = $true                           # can Get-DriverList work without a browser?
    ResolveProduct   = { param($Model) ... }           # -> identity object or $null
    GetDriverList    = { param($Identity,$Osid) ... }  # -> driver entries, or throws
    GetFallbackUrl   = { param($Identity,$Model) ... } # -> human-openable support/download URL
}
```

The script blocks are created **inside** the vendor module, so they keep that
module's session state and can call its private helpers. This keeps the
orchestrator vendor-agnostic and avoids function-name collisions between
providers. The orchestrator invokes them with `& $provider.ResolveProduct $model`.

### Uniform driver entry

Every provider's `GetDriverList` returns objects with at least:

```powershell
[pscustomobject]@{ Category; Name; Version; Url; Hash; HashAlg }
```

`HashAlg` is `SHA256` (ASUS, often with an empty `Hash`) or `MD5` (Gigabyte, from
the `?v=` value). `Install-Engine` verifies the hash only when one is present.

## Orchestrator logic

`resolve → if SupportsHeadless try Get-DriverList → on success download+install →
on any failure (or SupportsHeadless=$false, or unresolved) ensure Chrome and open
Get-FallbackUrl with a printed checklist.` The tool never dead-ends.

### Category filtering

- Default: keep everything **except** `config/defaults.json` →
  `categories.denyDefault` (utilities, Armoury Crate, BIOS, firmware, …).
- `-Categories a,b`: explicit allow-list instead.
- `-IncludeBios`: BIOS entries are **listed** but **never flashed** — the install
  loop short-circuits BIOS/firmware categories to a `ListedOnly` result.

## Apps layer

The apps layer mirrors the driver fallback philosophy for peripheral software:

1. `Detect-Peripherals.psm1` enumerates `Win32_PnPEntity`, extracting `VID:PID`
   from each `DeviceID`.
2. `apps/AppCatalog.psm1` loads `config/apps.json` and matches each app's
   `match.vidpid` / `match.namePatterns` against the devices.
3. `Install-App` installs via **winget** when the app has a `wingetId`, otherwise
   opens the app's `fallbackUrl` in Chrome — the same substrate as a holdout
   driver vendor.

Apps are **data-driven**: add entries to `config/apps.json`, no code change.

## Logging

`Common.psm1` `Initialize-Log` creates
`%ProgramData%\firstboot\logs\firstboot_<timestamp>.log`; `Write-Log` writes
coloured, timestamped lines to the console and appends to that file. On
non-Windows (dev/test) it degrades to a temp directory so the suite runs anywhere.

## Testability

Each module isolates its platform-specific call (`Get-BaseBoard`,
`Get-PnpDeviceList`, `Invoke-Pnputil`, `Invoke-ExeInstaller`, `Save-Download`,
`Invoke-Http`) behind a thin wrapper, and separates **parsing** from **fetching**.
The offline Pester suite parses recorded fixtures and mocks the wrappers, so it
runs on any platform with no network — including `windows-latest` CI.
