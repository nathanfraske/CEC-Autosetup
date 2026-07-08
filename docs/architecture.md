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
   ├─ Mapping.psm1 ── normalize + lookup (config/mapping.json + cache) ──▶ catalog model + slug
   │        (MSI MS-xxxx codes via config/msi-codes.json; self-heals on success)
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
   ├─ GPU detection: Detect-Gpu.psm1 ─▶ GPUs { Name, Vendor: nvidia|amd|intel }
   │
   ├─ GPU driver phase (unless -SkipGpu):
   │        NVIDIA ─▶ Install-Gpu.psm1: lookup psid/pfid ─▶ DriverManualLookup
   │                  ─▶ download ─▶ silent install (.exe -s -noreboot)   [fully unattended]
   │        AMD / Intel ─▶ driver carried by the vendor app (apps phase)
   │
   ├─ apps phase (unless -SkipApps):
   │        Detect-Peripherals.psm1 ─▶ devices { Name, VidPid, Class }
   │        apps/AppCatalog.psm1: Find-MatchingApps (gpuVendor | VID:PID | name) ─▶ Install-App
   │            winget (if package id) | Chrome fallback (official page)
   │            GPU apps: NVIDIA App / AMD Adrenalin / Intel Arc
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

The apps layer mirrors the driver fallback philosophy for GPU and peripheral
software:

1. `Detect-Gpu.psm1` classifies each `Win32_VideoController` by PCI `VEN_` id
   (`nvidia`/`amd`/`intel`); `Detect-Peripherals.psm1` enumerates
   `Win32_PnPEntity`, extracting `VID:PID` from each `DeviceID`.
2. `apps/AppCatalog.psm1` loads `config/apps.json` and matches each app's
   `match.gpuVendor` / `match.vidpid` / `match.namePatterns` against the detected
   GPU vendors and devices.
3. `Install-App` installs via **winget** when the app has a `wingetId`, otherwise
   opens the app's `fallbackUrl` in Chrome — the same substrate as a holdout
   driver vendor.

For GPUs this installs the vendor app (NVIDIA App / AMD Adrenalin / Intel Arc),
which carries the driver. Apps are **data-driven**: add entries to
`config/apps.json`, no code change.

## Mapping layer (naming reconciliation)

`Mapping.psm1` bridges the gap between the SMBIOS `Product` string and what each
vendor's fetch needs:

- `Get-NormalizedModelKey` — lower-case, drop a trailing parenthetical board
  code, collapse punctuation.
- `Get-Mapping` — merges the shipped `config/mapping.json` with a writable
  runtime cache at `%ProgramData%\firstboot\mapping.cache.json` (cache wins).
- `Find-MappingEntry` — exact-normalized lookup, then a conservative containment
  fuzzy match. A hit supplies the catalog model and the vendor **slug** (the
  Gigabyte revision slug is not derivable from SMBIOS).
- `Save-MappingEntry` — best-effort write-back so the cache self-heals after a
  successful live resolve (never throws on a read-only medium).

The orchestrator also maps MSI `MS-xxxx` board codes via `config/msi-codes.json`.
ASUS rows are regenerable from the 897-board catalog with
`tools/Build-AsusMapping.ps1` (network-gated; not part of offline CI). The
mapping is a cache + reconciliation layer, **not** a hard dependency — with no
mapping at all, ASUS/MSI still resolve from the model name/slug.

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
