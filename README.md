<!-- SPDX-License-Identifier: Apache-2.0 -->

# CEC-Autosetep

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![CI](https://github.com/nathanfraske/cec-autosetep/actions/workflows/ci.yml/badge.svg)](https://github.com/nathanfraske/cec-autosetep/actions/workflows/ci.yml)

> Turn a freshly imaged Windows PC into a fully driver-equipped machine with **one
> script on first boot.** Detect the motherboard, fetch the **latest official
> drivers** straight from the vendor, install them silently, and — for anything
> that can't be fetched headlessly — install Chrome and open the right vendor page
> so a human (or a browser agent) finishes the job. The tool never dead-ends.

Licensed under the **Apache License 2.0** (see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE)).

---

## Why

A custom-PC shop images many machines across mixed board brands. Drivers are the
tedious, error-prone last mile. CEC-Autosetep automates it:

1. **Detect** the motherboard (`Win32_BaseBoard`).
2. **Identify** the vendor (ASUS / Gigabyte / ASRock today).
3. **Fetch** the latest official drivers from that vendor.
4. **Install** them silently (`pnputil` for INF packages; packer-specific silent
   switches for EXE installers).
5. **Fall open to a human** for any vendor or file it can't fetch headlessly:
   install Chrome and open the vendor's download page with a checklist.

It then optionally runs an **apps phase** that detects peripherals and installs
their companion software (e.g. SignalRGB for RGB gear, Thermalright Control
Center for TR coolers) — winget where a package exists, the same Chrome fallback
where it doesn't.

## Lightweight & portable by design

- **No runtime to install.** Pure **Windows PowerShell 5.1** plus in-box Windows
  tools (`pnputil`, `msiexec`, BITS, CIM). No Python, no PowerShell 7, no package
  manager required on the target.
- **Runs from a flash drive from the get-go.** Copy the repo to a USB stick and
  run `bootstrap.ps1`. The runtime payload is tiny — only `bootstrap.ps1`,
  `src/`, and `config/` are needed on the stick (`tests/` and `docs/` are
  dev-only).
- **Idempotent and logged.** Re-running is safe. Everything is transcripted to
  `%ProgramData%\firstboot\logs\firstboot_<timestamp>.log`.

## Quickstart

### From a USB stick / imaged drive (offline-friendly)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File X:\CEC-Autosetep\bootstrap.ps1
```

`bootstrap.ps1` sets TLS 1.2, sets a process-scoped `ExecutionPolicy Bypass`,
self-elevates if needed, then runs the engine. Add flags as needed:

```powershell
# Dry run: show exactly what would be installed, install nothing.
powershell -NoProfile -ExecutionPolicy Bypass -File X:\CEC-Autosetep\bootstrap.ps1 -WhatIf
```

### Online one-liner (repo public + network at first boot)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/nathanfraske/cec-autosetep/main/bootstrap.ps1 | iex"
```

When run this way (no local copy), `bootstrap.ps1` downloads a snapshot of the
repo and runs it.

See [`docs/autounattend.md`](docs/autounattend.md) to wire this into
`autounattend.xml` / `SetupComplete.cmd` for a hands-off deployment.

## Flags

| Flag | Effect |
| --- | --- |
| `-WhatIf` | Dry run. Plans everything, installs nothing. |
| `-IncludeBios` | List BIOS entries. **Never flashes** — listing only. |
| `-Categories a,b` | Explicit category allow-list (default: skip pure utilities). |
| `-Osid <int>` | ASUS `osid` override (default: probe candidates). |
| `-SkipApps` | Skip the peripheral-software (apps) phase. |
| `-Model` / `-Vendor` | Override hardware detection (testing / odd boards). |

## Supported boards

| Vendor | Method | Keyed on | Headless | Verified live vector (2026-06-19) |
| --- | --- | --- | --- | --- |
| **ASUS** | internal JSON API (`PDInfo` → `GetPDDrivers`, **model-keyed**) | model name | ✅ | `ROG STRIX Z490-I GAMING` → **25** files; `TUF GAMING Z890-PLUS WIFI` → **59** files |
| **MSI** | internal JSON API (`os`/`panel`) | model slug | ✅ (mind Akamai) | `MAG B650 TOMAHAWK WIFI` → AMD Chipset `7.12.04.858`, SHA-256 on every file |
| **Gigabyte** | server-rendered support HTML | URL slug w/ revision | ✅ (mind Akamai) | `B650-GAMING-X-AX-V2-rev-10-11-12` → **15** components; chipset `8.03.25.247` |
| **ASRock** | browser-required (Incapsula + XHR) | constructed URL | ⚠️ fallback-only | `X870E Taichi` → opens `…/mb/AMD/X870E%20Taichi/index.asp#Download` |

> **ASUS is model-keyed, not `pdid`-keyed.** Sending the legacy `pdid` breaks
> current-gen boards (Z890/X870E); CEC-Autosetep keys on the model name +
> `pdhashedid`, which works across all generations.

ASRock is **fallback-only**: the driver list loads via an undocumented
client-side XHR that has not been captured. CEC-Autosetep opens the correct
ASRock page in Chrome instead.

A small **mapping table** (`config/mapping.json`) reconciles SMBIOS names to
catalog names/slugs (notably the Gigabyte revision slug and MSI `MS-xxxx`
codes), self-heals at runtime, and is regenerable via
[`tools/Build-AsusMapping.ps1`](tools/Build-AsusMapping.ps1). See
[`docs/vendor-contracts.md`](docs/vendor-contracts.md).

## Apps phase (hardware → software)

Triggered by **GPU vendor** (`Win32_VideoController`), **USB/PnP VID:PID**, or
device-name patterns; installed via winget or the Chrome fallback. Defined in
[`config/apps.json`](config/apps.json) — **add apps in JSON, not code.**

| App | Trigger | Install |
| --- | --- | --- |
| NVIDIA App | NVIDIA GPU (VEN_10DE) | winget `NVIDIA.app` (app then fetches the driver) |
| AMD Software: Adrenalin Edition | AMD GPU (VEN_1002) | opens AMD drivers page (no winget; Adrenalin **installs the driver when run**) |
| Intel Arc / Graphics Software | Intel GPU (VEN_8086) | opens Intel Arc/Graphics download page |
| SignalRGB | common RGB peripherals (Corsair, Razer, Aura, …) | winget `WhirlwindFX.SignalRgb` |
| Thermalright Control Center | TR cooler USB controllers / "Thermalright" devices | opens official download page (no winget package) |

> **GPU driver note:** the GPU phase installs the *vendor app*, which carries the
> driver. **AMD Adrenalin installs the GPU driver when run.** The **NVIDIA App**
> and **Intel** software fetch/offer the latest driver (a fully-silent headless
> driver install is a documented future option — NVIDIA exposes a driver-lookup
> API; see [`docs/vendor-contracts.md`](docs/vendor-contracts.md)).

## Safety

- **Drivers, not BIOS.** The first-boot path **never flashes BIOS.** BIOS may be
  *listed* with `-IncludeBios`, but flashing is out of scope.
- **Checksums** are verified when the vendor supplies one (Gigabyte MD5 from the
  `?v=` value; ASUS SHA256 when present — often empty).
- **Verify, don't invent.** Every vendor endpoint here was captured from live
  traffic. No fabricated URLs. See [`docs/vendor-contracts.md`](docs/vendor-contracts.md).
- **Unsigned script.** Running an unsigned `bootstrap.ps1` on first boot is fine
  internally; sign it if you distribute, to avoid SmartScreen friction.

## Repo layout

```
bootstrap.ps1            single first-boot entrypoint (TLS, elevate, run)
src/
  FirstBoot.ps1          orchestrator
  Common.psm1            logging, HTTP, hashing, admin, settings
  Detect-Hardware.psm1   Win32_BaseBoard -> {vendor, model}
  Detect-Peripherals.psm1 USB/PnP enumeration for the apps phase
  Detect-Gpu.psm1        Win32_VideoController -> GPU vendor (nvidia/amd/intel)
  Mapping.psm1           naming reconciliation + model->vendor cache (self-heal)
  Install-Engine.psm1    download -> verify -> extract -> pnputil/EXE install
  Install-Chrome.psm1    silent Chrome install + open-url fallback substrate
  providers/             Asus / Msi / Gigabyte / Asrock + the provider contract
  apps/AppCatalog.psm1   peripheral -> software matching + install
config/                  defaults.json, apps.json, mapping.json, msi-codes.json
tools/                   Build-AsusMapping.ps1 (catalog refresh), Test-VendorCanary.ps1
                         (live early-warning), Get-DeviceIds.ps1 (capture VID:PIDs)
docs/                    vendor contracts, architecture, autounattend, adding a provider
tests/                   offline Pester suite + recorded fixtures
.github/workflows/       ci.yml (offline lint+test), refresh-mapping.yml (network-gated)
```

## Development

Requires PowerShell (Windows PowerShell 5.1 for runtime; PowerShell 7+ is fine
for dev/test). The test suite is **offline** — it uses only `tests/fixtures/`.

```powershell
Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./tests
```

CI runs both on `windows-latest` with no network access to vendor sites.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — data flow, provider contract, fallback flow, apps layer.
- [`docs/vendor-contracts.md`](docs/vendor-contracts.md) — the live vendor contracts, dated, with a "this is undocumented and may change" banner, plus open items.
- [`docs/autounattend.md`](docs/autounattend.md) — wiring into `autounattend.xml` / `SetupComplete.cmd`.
- [`docs/adding-a-provider.md`](docs/adding-a-provider.md) — add a board vendor.

## License

Apache-2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
