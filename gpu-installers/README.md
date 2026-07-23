<!-- SPDX-License-Identifier: Apache-2.0 -->

# GPU installer staging (AMD / Intel)

AMD and Intel have **no clean headless driver-lookup API** (their download sites
are bot-walled), so to make their GPU drivers fully unattended you **supply the
installer once** and CEC-Autosetup silent-installs it.

Drop the latest vendor installer here:

```
gpu-installers/amd/   amd-software-adrenalin-edition-XX.X.X-...exe
gpu-installers/intel/ gfx_win_101.XXXX.exe   (Intel Arc/Graphics DCH)
```

`tools/Build-DriverLibrary.ps1` copies the newest `.exe` per vendor into the
served library (`gpu/<vendor>/`) and records it in `index.json` → `gpuInstallers`.
Clients then pull it over the LAN and run it silently:

- **AMD:** `Setup.exe -INSTALL` (AMD Radeon Software Command-Line guide)
- **Intel:** `Installer.exe -s`

(switches live in `config/defaults.json` → `amd.silentArgs` / `intel.silentArgs`).

Alternatively, skip the library and pin a direct URL in `config/defaults.json`
(`amd.url` / `intel.url`) — the client downloads + silent-installs from there.

A browser agent (`docs/browser-agent-tasks.md`) can fetch the current installer
URLs on a schedule, since discovery is the only bot-walled part.

**These binaries are not committed** (see `.gitignore`); they're supplied per
bench and can be large.
