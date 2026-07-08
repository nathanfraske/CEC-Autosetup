<!-- SPDX-License-Identifier: Apache-2.0 -->

# Local driver library (LAN mirror)

Pre-pull drivers for the current + last-generation boards onto an Ubuntu box,
serve them on the LAN, and have first-boot clients grab everything from there —
fast, and offline-from-the-internet. It cleanly separates **acquisition** (where
files come from) from **resolution** (which files a board needs, done by the
providers).

```
                Ubuntu mirror host                         imaged PC (first boot)
  ┌──────────────────────────────────────┐        ┌──────────────────────────────┐
  │ Build-DriverLibrary.ps1               │        │ bootstrap.ps1 -Mirror http://…│
  │   providers resolve current+last-gen  │        │   detect board → identifier   │
  │   download → library/ (mirrors CDN    │  LAN   │   GET /index.json             │
  │   paths) + index.json (by identifier) │◄──────►│   pull this board's files     │
  │ nginx (systemd) serves library/ :8080 │  HTTP  │   hash-verify → install       │
  └──────────────────────────────────────┘        │   (vendor fallback on a miss) │
                                                    └──────────────────────────────┘
```

## 1. Build the library (on the Ubuntu host)

Needs `pwsh` (PowerShell 7) — the builder reuses the providers.

```bash
# Populate the catalog mapping first (one cheap ASUS call + the Gigabyte modellist):
pwsh -File tools/Build-AsusMapping.ps1
pwsh -File tools/Build-GigabyteMapping.ps1

# Pull current + last-gen drivers (chipset set: config/library-chipsets.json):
pwsh -File tools/Build-DriverLibrary.ps1 -OutputDir /srv/cec-drivers
pwsh -File tools/Build-DriverLibrary.ps1 -OutputDir /srv/cec-drivers -WhatIf   # plan only
```

- **Scope** = `config/library-chipsets.json` (`current` + `lastGen`, AMD + Intel).
  Boards are selected from the catalog mapping whose model contains one of those
  chipset tokens; `config/library-boards.json` is an always-included manual
  supplement. `-ExplicitOnly` uses just the supplement.
- The tree mirrors each vendor CDN path under a per-vendor dir, plus `index.json`
  keyed by normalized board identifier:
  ```
  /srv/cec-drivers/
    index.json
    asus/pub/ASUS/mb/03CHIPSET/DRV_...zip
    gigabyte/FileList/Driver/mb_driver_...zip
    msi/dvr_exe/mb/...zip
  ```
- **Idempotent**: files already present and hash-verified are skipped, so re-runs
  only fetch what's new.
- **ASRock is not included** — Incapsula blocks headless fetches, so ASRock stays
  client-side browser-fallback.
- **AMD/Intel GPU installers** — drop the latest Adrenalin / Intel graphics `.exe`
  into `gpu-installers/amd/` and `gpu-installers/intel/`; the builder publishes
  them to `gpu/<vendor>/` + `index.json` so clients silent-install them over the
  LAN (AMD `-INSTALL`, Intel `-s`). See `gpu-installers/README.md`. (NVIDIA needs
  no staging — it resolves + installs headlessly on the client.)
- **Disk**: current + last-gen across ASUS/MSI/Gigabyte is roughly the order of a
  few hundred GB. Point `-OutputDir` at a roomy volume.

## 2. Serve it (nginx + systemd — the chosen path)

```bash
sudo cp tools/nginx/cec-driver-library.conf /etc/nginx/sites-available/cec-driver-library
sudo ln -s /etc/nginx/sites-available/cec-driver-library /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx      # nginx.service is the systemd unit
```

Serves `/srv/cec-drivers` on port 8080 (read-only). Alternatives if you don't
want nginx:

```bash
# Zero-dep PowerShell server shipped in the repo:
sudo cp tools/systemd/cec-driver-library.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now cec-driver-library
# …or a quick one-off:
python3 -m http.server 8080 --directory /srv/cec-drivers
```

## 3. Refresh on a schedule (systemd timer)

```bash
sudo cp tools/systemd/cec-driver-library-build.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now cec-driver-library-build.timer
```

The oneshot service re-runs the ASUS/Gigabyte mapping refresh and re-pulls
current + last-gen drivers weekly (`OnCalendar=Sun 03:30`). Edit paths/user
(`CEC_HOME`, `CEC_LIBRARY`, `cec`) in the unit files to match your host.

## 4. Point the clients at it

```
powershell -NoProfile -ExecutionPolicy Bypass -File X:\CEC-Autosetep\bootstrap.ps1 -Mirror http://10.0.0.10:8080
```

…or bake it in so every USB/image uses the mirror by default —
`config/defaults.json`:
```json
"mirror": { "enabled": true, "baseUrl": "http://10.0.0.10:8080" }
```

On first boot the client detects the board, fetches `index.json`, and if the
board is in the library it pulls the list **and** files over the LAN
(hash-verified, with the live progress bar). If the board isn't mirrored, it
falls back to the normal online vendor path automatically.

## Notes

- The mirror is keyed by **normalized identifier** (same normalization as the
  mapping layer), so SMBIOS-name quirks still match.
- Hashes in `index.json` are the providers' hashes (Gigabyte MD5, ASUS/MSI
  SHA-256), so LAN downloads are verified exactly like vendor downloads.
- Keep the mirror host on the same trusted LAN segment as the bench; it serves
  read-only over plain HTTP.
