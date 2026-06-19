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
- **Live on-screen status.** The operator sees per-step status plus a real
  download progress bar (percent, MB, speed) — important for the large GPU driver.

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
| `-SkipApps` | Skip the apps phase (GPU vendor apps + peripheral + baseline software). |
| `-SkipGpu` | Skip the NVIDIA headless GPU-driver install. |
| `-SkipTweaks` | Skip the provisioning phase (default browser, taskbar, OneDrive/Copilot, wallpaper). |
| `-Tier <name>` | Ship tier → wallpaper (e.g. `-Tier Dreadnought`); see [provisioning](docs/provisioning.md). |
| `-InstallApps a,b` | Force-install named catalog apps regardless of detection (e.g. `-InstallApps "Hyte Nexus"`). |
| `-Mirror <url>` | Pull drivers from a [local LAN mirror](docs/driver-library.md) first (e.g. `http://10.0.0.10:8080`). |
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
| **NVIDIA driver** | NVIDIA GPU (VEN_10DE) | **fully unattended** — headless lookup → silent `.exe -s -noreboot` |
| NVIDIA App | NVIDIA GPU (VEN_10DE) | winget `NVIDIA.app` (for setup/management) |
| AMD Software: Adrenalin Edition | AMD GPU (VEN_1002) | opens AMD drivers page (no winget; Adrenalin **installs the driver when run**) |
| Intel Arc / Graphics Software | Intel GPU (VEN_8086) | opens Intel Arc/Graphics download page |
| SignalRGB | common RGB peripherals (Corsair, Razer, Aura, …) | winget `WhirlwindFX.SignalRgb` |
| Thermalright Control Center | TR cooler USB controllers / "Thermalright" devices | opens official download page (no winget package) |
| Hyte Nexus | "HYTE" device name, or `-InstallApps "Hyte Nexus"` | opens hyte.com/nexus (no winget package) |
| Steam | baseline (`match.always` — every build) | winget `Valve.Steam` |

> Apps with no reliable auto-detection (e.g. Hyte Nexus — the Y70 Touch screen's
> USB VID:PID isn't documented) can be forced with `-InstallApps "<name>"`.

> **GPU drivers:** **NVIDIA is fully unattended** — resolves the exact driver via
> NVIDIA's lookup API and silent-installs it (`-s -noreboot`), plus the NVIDIA App.
> **AMD/Intel can be fully unattended too** when you supply the installer (pin
> `amd.url`/`intel.url` in `config/defaults.json`, or stage it in the driver
> library under `gpu-installers/<vendor>/`): the client downloads it and runs the
> verified silent switch (AMD `-INSTALL`, Intel `-s`). With no installer supplied,
> AMD/Intel fall back to installing the vendor app, which carries the driver.
> Every detected GPU vendor is handled (no iGPU-vs-dGPU guessing), so mixed setups
> all get each vendor's driver. `-SkipGpu` skips the GPU-driver step.

## Local driver library (LAN mirror)

For a bench imaging many machines: pre-pull **current + last-generation** board
drivers onto an Ubuntu box once, serve them on the LAN, and have first-boot
clients grab from there — fast and offline-from-the-internet.

```bash
# On the Ubuntu host (needs pwsh):
pwsh -File tools/Build-AsusMapping.ps1 ; pwsh -File tools/Build-GigabyteMapping.ps1
pwsh -File tools/Build-DriverLibrary.ps1 -OutputDir /srv/cec-drivers   # current+last-gen
# Serve with nginx + systemd (see docs), then on each client:
#   bootstrap.ps1 -Mirror http://10.0.0.10:8080
```

Mirror-first, vendor-fallback: the client pulls the driver list **and** files
(hash-verified) from the mirror when the board is present, else uses the normal
online path. Scope is `config/library-chipsets.json`. Full guide:
[`docs/driver-library.md`](docs/driver-library.md).

## Provisioning (tweaks phase)

After drivers/GPU/apps, a **provisioning phase** applies shop tweaks (skip with
`-SkipTweaks`; honors `-WhatIf`), driven by [`config/tweaks.json`](config/tweaks.json):

- Set **Chrome as the default browser** (DISM default app associations).
- **Pin Chrome to the taskbar** (taskbar `LayoutModification.xml`).
- **Disable OneDrive** from startup and **disable Windows Copilot**.
- Set a **wallpaper by ship tier** — `-Tier <name>` → image from
  [`config/tiers.json`](config/tiers.json) (drop artwork in `wallpapers/`).

> The default-browser and taskbar-pin tweaks are most reliable applied during
> imaging/OOBE (they configure new user profiles). See
> [`docs/provisioning.md`](docs/provisioning.md) for the caveats and the
> `SetupComplete.cmd` route.

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
  Install-Gpu.psm1       NVIDIA headless driver lookup + silent install
  Tweaks.psm1            provisioning: default browser, taskbar, OneDrive/Copilot, wallpaper
  Mapping.psm1           naming reconciliation + model->vendor cache (self-heal)
  DriverLibrary.psm1     local LAN mirror source (mirror-first, vendor-fallback)
  Install-Engine.psm1    download -> verify -> extract -> pnputil/EXE install
  Install-Chrome.psm1    silent Chrome install + open-url fallback substrate
  providers/             Asus / Msi / Gigabyte / Asrock + the provider contract
  apps/AppCatalog.psm1   peripheral -> software matching + install
config/                  defaults.json, apps.json, mapping.json, msi-codes.json,
                         tweaks.json, tiers.json, library-boards.json, library-chipsets.json
wallpapers/              per-tier wallpaper images (you supply; shipped on the USB)
tools/                   catalog refresh (Build-AsusMapping/Build-GigabyteMapping),
                         driver library (Build-/Serve-DriverLibrary), Test-VendorCanary,
                         Get-DeviceIds; nginx/ + systemd/ units for the LAN mirror
docs/                    vendor contracts, architecture, autounattend, provisioning,
                         driver-library, browser-agent-tasks, adding a provider
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
