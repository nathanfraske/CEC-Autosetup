<!-- SPDX-License-Identifier: Apache-2.0 -->

# Stage 1 — Windows prep + BIOS update hand-off

The first stage of the shop's ordered checklist, implemented end-to-end:

1. **Hold Windows Update** before it can grab anything (it likes to break
   fresh builds mid-provisioning), using the supported policy pair —
   `NoAutoUpdate=1` + `ExcludeWUDriversInQualityUpdate=1` — with
   `wuauserv`/`UsoSvc` stopped once to cancel in-flight work (**never
   disabled**: WaaSMedic re-enables disabled update services unpredictably).
   **Temporary by design** — priors are captured into
   `%ProgramData%\firstboot\state.json`, and `Restore-WindowsUpdate` releases
   the hold in the post-BIOS stage (deleting values that were absent, so
   machines ship policy-clean). Then, per validated shop practice, Windows
   Update runs **fully** before the vendor drivers go on — see
   [`docs/windows-update-strategy.md`](windows-update-strategy.md).
2. **Disable UAC** for the unattended provisioning window (`EnableLUA=0`,
   effective on this stage's reboot; prior captured for `Restore-Uac`).
   The preferred permanent home is `autounattend.xml` — see
   [`docs/autounattend.md`](autounattend.md).
3. **Acquire the latest NON-BETA BIOS** for the detected board:
   1. **Driver library / LAN server** — *stubbed* (`Get-LibraryBios`) until
      the server side exists; it will answer "do we have it and is it latest".
   2. **Vendor** — BIOS/Firmware-category entries from the provider's driver
      list, beta releases filtered, newest picked (`Select-LatestBios`).
      *Reality check (verified live 2026-07-23): ASUS's model-keyed driver API
      returns no BIOS category for at least Z490 boards, so today ASUS lands
      on the operator fallback below. The plumbing lights up the moment a
      provider or the library surfaces BIOS entries.*
   3. **Operator fallback** — no headless source: the support page opens in
      Chrome with instructions to grab the BIOS onto FAT32 media and run
      `shutdown /r /fw` when ready. **No auto-reboot in this path.**
4. **Stage the firmware file** where the UEFI flash tool can see it: the
   package is downloaded, hash-verified when the vendor supplies one,
   extracted, and the firmware image (`.cap`/`.rom`/`.bin`/`.bio`/`.fd`/
   Gigabyte `.Fnn`) is copied to the **root of the USB stick** (`<stick>:\BIOS\`)
   when the tool runs from removable media, else `%ProgramData%\firstboot\bios\`.
5. **Reboot straight into UEFI setup** (`shutdown /r /fw`) — only when a file
   was actually staged. The technician flashes with the board's built-in tool
   (EZ Flash / Q-Flash / M-Flash / Instant Flash). **The tool never flashes
   BIOS** — staging and the reboot are the entire automation surface.

## Re-entry after the flash

Before rebooting, the stage writes a **state marker**
(`state.json: biosStage.completed`). On the next run the stage skips itself —
no reboot loop — and the pipeline continues (Windows Update stage, then
drivers/GPU/apps/tweaks). Delete the marker file to force the stage again.

Flags: `-SkipWindowsPrep`, `-SkipBiosUpdate` (bootstrap + FirstBoot).

## Offline (no internet at first boot)

Rare on the bench. Current behavior: probe the vendor host; when unreachable,
try `pnputil` on any INF packs staged under [`lan-drivers/`](../lan-drivers/README.md),
re-probe, and otherwise stop with a clear **manual step** (get networking up,
re-run; the stage resumes from where it left off).

Brainstormed fixes, in rough order of value:

| Option | Effort | Notes |
| --- | --- | --- |
| **Ship LAN INF packs on the stick** (`lan-drivers/`) | done (mechanism) | pnputil-installs staged packs automatically; shop just has to drop the Intel/Realtek packs in once |
| **LAN driver-library mirror** | exists (`-Mirror`) | "no internet" ≠ "no LAN": the mirror can still serve BIOS + drivers; BIOS side arrives with the `Get-LibraryBios` server work |
| Bench USB NIC | none (kit habit) | in-box RNDIS/NCM drivers make a known-good USB dongle plug-and-play |
| Phone USB tethering | none | same in-box driver path; slower, fine for a BIOS zip |
| Slipstream LAN drivers into the image (`autounattend` + `$WinPEDriver$`) | medium | permanent fix at the imaging layer; belongs with the unattend work |

## What rehearsal shows for this stage

`bootstrap.ps1` (bare run = self-check) rehearses the whole stage: logs the
exact registry/service operations the WU hold would perform, the UAC change
with its current value, the BIOS pick + URL probe + staging destination, and
the exact `shutdown /r /fw` command — executing none of it, and leaving
`state.json` untouched.
