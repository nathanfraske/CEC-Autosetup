<!-- SPDX-License-Identifier: Apache-2.0 -->

# Driver install order (researched spec for the ordered pipeline)

Researched 2026-07-23 (web sources cited at the bottom; see confidence notes).
**Implemented**: `config/install-order.json` + `src/DriverOrder.psm1` turn this
spec into the runtime plan — entries are grouped and installed in this order,
conditional rules skip with a logged reason, and `restartAfter` boundaries
force a reboot with resume-task resume (progress tracked in `state.json`, so each
boot continues from the next group). The rehearsal self-check prints the full
plan with `[RESTART]` markers. Each step maps to a vendor download-page
CATEGORY string.

Assumes: BIOS already updated (stage 1), Windows 11 at desktop, and — per shop
practice, pending the WU-strategy research — Windows Update has already run
fully, so these vendor installs REPLACE inbox drivers.

**Imaging-time pre-step (both platforms):** disable the firmware auto-driver
installers (ASUS Armoury Crate popup / DriverHub, Gigabyte APP Center / GCC
assistant, MSI Driver Utility Installer, ASRock Auto Driver Installer) in BIOS
so they can't race the automation. **Intel APO-eligible builds** additionally
need the BIOS enable set here: "IPF" on 800-series, "Intel DTT" on 600/700
(forces its own reboot at imaging, before Windows ever runs).

## Recommended order

| # | INTEL platform | AMD platform |
|---|---|---|
| 1 | **Chipset** — Intel Chipset Device Software (INF). Silent: `SetupChipset.exe -s -norestart`, then force our own reboot. **[RESTART]** | **Chipset** — AMD Chipset Drivers bundle (PPM provisioning, Ryzen power plans, PSP, GPIO, SMBus, USB4/PCIe filters). Silent, then reboot. **[RESTART]** |
| 2 | **Intel ME** — MEI package. Reboot folds into step 4's restart unless the installer demands one. | *(none — AMD PSP ships inside the step-1 bundle; never standalone)* |
| 3 | **Serial IO** — only if the board's page lists it. No reboot. | *(rarely listed; skip unless listed)* |
| 4a | **Platform Performance (IPPP)** — "Intel Platform Performance Package" = DTT + IPF + PPM Provisioning (+ APO driver component) in one installer; on pages without IPPP, the standalone **DTT ≥ 11405** driver fills this slot. CONDITIONAL: APO-eligible builds (14th-gen K on 600/700, Core Ultra 200S on 800-series), Win11 only, BIOS knob pre-enabled. Reboot rides step 4's restart. | *(Intel-only; no AMD equivalent)* |
| 4b | **NPU driver** ("Intel AI Boost") — CONDITIONAL: Core Ultra 200S / 800-series only (replaces GNA); vendor package or let WU place it; keeps Device Manager clean. No reboot. | *(Intel-only)* |
| 4 | **Storage (Intel RST/VMD)** — CONDITIONAL (VMD/RAID enabled only). **[RESTART]** here regardless, flushing ME/SerialIO/IPPP/storage before network + GPU. | **RAID (RAIDXpert2)** — CONDITIONAL (BIOS RAID mode only). **[RESTART]** only if steps 2–4 installed anything. |
| 5 | **LAN / Ethernet** — Intel I225-V/I226-V or Realtek RTL8125. No reboot. | Same packages. No reboot. |
| 6 | **Bluetooth** — Intel Wireless Bluetooth, BEFORE Wi-Fi on AX combos. Vendor filenames use the **"IBT" = Intel BlueTooth** token (Gigabyte `mb_driver_ibt_*`, ASRock `Intel_BT(v…)`) — map IBT-token entries to this step. (Distinct from **iBOT**, the Intel Binary Optimization Tool — step 15a.) | Same (MediaTek: vendor's listed order, BT first when both exist). |
| 7 | **Wireless / WLAN** — Intel Wi-Fi driver-only package (not PROSet software). | Same. |
| 8 | **VGA (iGPU)** — Intel Graphics, CONDITIONAL (iGPU enabled). Before dGPU. | **APU graphics** — Adrenalin, CONDITIONAL (APU builds); Radeon dGPU + APU = one Adrenalin at step 9. |
| 9 | **Graphics (dGPU)** — NVIDIA (driver-only, clean-install) / AMD Adrenalin (no Factory Reset on fresh builds) / Intel Arc. **[RESTART]** | Same. **[RESTART]** |
| 10 | **Audio** — Realtek UWD/UAD vendor build for the board. | Same. |
| 11 | **Audio APO layer** (DTS/Sonic/Nahimic) — default-deny; never two stacks. **[RESTART]** after the audio stack either way. | Same. **[RESTART]** |
| 12 | **Thunderbolt/USB4** — CONDITIONAL: discrete TB4 controller/AIC only; Win11 inbox USB4 covers native. | **USB4** — skip (chipset bundle + inbox). |
| 13 | **Card reader / misc I/O** — only for unknown devices in Device Manager. | Same. |
| 14 | **Utilities / RGB / monitoring** — default-deny; explicit order flag only. | Same. |
| 14a | **APO Store app** ("Intel Application Optimization", Microsoft Store) — CONDITIONAL: APO-eligible CPUs, AFTER step 4a's driver + restart (errors "not supported" otherwise). Per-game whitelisted (26+ titles); Intel claims up to 13–14%, independent testing ~2% (14900K) — ship on gaming builds, don't oversell. No reboot. | *(Intel-only)* |
| 15 | **Windows Update sweep** — one WU pass for residue, final **[RESTART]**, Device Manager audit: zero unknown/error devices = pass. | Same. |
| 15a | **iBOT enable** ("Intel Binary Optimization Tool") — CONDITIONAL config step, **AFTER QC benchmarking** (Geekbench 6.7+ detects and flags iBOT-enabled runs as non-comparable): APO Store app → Advanced Mode → Binary Optimization Tool toggle. **[RESTART]** after enabling. Not a download — ships inside **IPPP ≥ 26.06.100.32** (enforce that version at step 4a on eligible CPUs; pull IPPP from Intel Download Center 869519, board pages lag). Eligible: Core Ultra 200S **"Plus"** desktop (270K/250K/250KF Plus) + HX Plus / Core Ultra 300 mobile — NOT 285K-class 200S, NOT 14th-gen. No documented programmatic toggle — treat as manual/scripted-UI until proven otherwise. | *(Intel-only)* |

Forced restarts: after chipset (always) → after the platform block (Intel
always; AMD if anything installed) → after dGPU → after the audio stack →
final validation. Five worst-case, typically three on AMD.

## Why (one line each)

1. Chipset INF describes the platform; Intel: install before all others, restart required. AMD bundle carries PPM/power plans that load at boot.
2. Dell's canonical order: chipset before ME; quiets MEI device + power features later drivers assume.
3. Serial IO is tiny I2C/UART plumbing; near-zero risk in the platform block.
4. Storage filter drivers must be right before heavy payloads; useless/refused on non-VMD/non-RAID (deny rule).
5. Inbox 2.5GbE coverage is basic-to-absent (I225/I226 disconnect+EEE fixes live in current Intel drivers).
6. Intel's stated AX-combo order is BT package first (BT rides USB, Wi-Fi rides CNVi/PCIe); wrong order = "BT missing" tickets.
7. Wi-Fi driver-only completes the radio.
8. Bring up the platform display engine before the dGPU installer sees the topology; Quick Sync needs it anyway.
9. GPU installers bind against PCIe/power topology from step 1's reboot; reboot-after is the most consistent GPU guidance anywhere.
10. GPU drivers add HDMI/DP audio endpoints; Realtek after avoids endpoint churn.
11. APO effect services register at boot (hence restart); stacking two is a known conflict source.
12. Win11 has a native USB4 connection manager; only discrete TB controllers need vendor packages.
13. Install-on-demand keeps images lean.
14. Armoury Crate / MSI Center / Nahimic are top named stability offenders — software, not drivers.
15. Cheap final net + the pass/fail gate for the build.

## Skip / conditional rules (for the future ordering config)

- **Intel RST/VMD**: only when VMD enabled in BIOS or an RST VMD controller enumerates (PCI\VEN_8086 DEV_09AB/A77F). Default builds: VMD off → skip; inbox storahci/stornvme own it.
- **AMD RAIDXpert2**: BIOS RAID mode only.
- **Intel Optane**: always deny (discontinued).
- **Intel GNA**: hard-deny on all new builds (GNA is dead: OpenVINO dropped it in 2024.0; Core Ultra replaces it with the NPU — install the NPU driver on 800-series instead, per step 4b).
- **Intel Dynamic Tuning (DTT/DPTF)**: allow ONLY on APO-eligible desktops (it is APO's delivery vehicle — 14th-gen K / Core Ultra 200S, via IPPP or standalone DTT ≥ 11405); deny everywhere else. (Supersedes the earlier blanket desktop deny.)
- **iBOT** (Binary Optimization Tool, rides IPPP + APO app): default-ON for gaming builds on eligible "Plus"/300-series CPUs, but only **after** QC benchmarks (it rewrites whitelisted game/benchmark binaries — Geekbench flags optimized runs; ~8–10% average FPS measured independently, up to 18–27% peak on the 19 whitelisted titles). Kernel-anti-cheat titles (CS2/Valorant/OW) are not and likely never will be whitelisted. Skip on all other CPUs.
- **Intel PROSet full software / Killer Suite**: deny — driver-only packages (Killer = rebranded Intel).
- **SSD-vendor NVMe drivers**: deny on Win11 (StorNVMe is the supported path).
- **Thunderbolt Control Center / TB driver**: discrete TB4 controller + Win11-listed package only.
- **iGPU driver**: only when iGPU enabled in the build spec.
- **Audio APO layers**: default-deny; opt-in = exactly one.
- **Vendor utility bundles** (Armoury Crate/AURA, MSI Center, GCC/APP Center, A-Tuning/Polychrome, bundled AV/trialware): default-deny + disable their BIOS auto-install hooks at imaging.
- **Standalone "AMD PSP driver"**: deny — arrives via chipset bundle/WU.
- **SIO/monitoring drivers**: only when vendor lists them as a *driver* and a device is unknown.

## Inbox-driver interaction

- **Inbox good — do not layer vendor drivers**: NVMe (StorNVMe), SATA AHCI, USB3 xHCI, USB4/TB4 CM, generic HID.
- **Inbox adequate — always replace**: GPU (basic display), Realtek HD Audio (want the board's UWD build), recent Intel AX Wi-Fi/BT (replace for fixes).
- **Inbox weak — vendor required**: 2.5GbE (I225/I226: current driver, consider disabling EEE per Intel advisory; RTL8125 often absent at OOBE — preload in image or `lan-drivers/`), MediaTek/Qualcomm Wi-Fi, discrete TB AICs.

## Confidence + conflicts

- **High**: chipset-first + forced restart; chipset before ME; GPU after chipset reboot with its own reboot; RST/VMD conditional-only; inbox StorNVMe/USB4 sufficiency; utilities default-deny.
- **Medium**: BT-before-Wi-Fi (Intel-moderated threads, not a formal doc; costs nothing — adopted). Restart after plain UWD audio (required only when APO layers install; kept as hygiene).
- **Conflicts noted**: "only chipset order truly matters" (Dell/veterans) vs strict vendor lists — full ordering adopted as cheap determinism; steps 1, 2 and the GPU placement are the load-bearing ones. "GPU first" (CGDirector) rejected against Intel/AMD/ASUS/Dell. Old vendor-USB3/SATA advice obsolete on Win11.

## Intel follow-up sources (iBOT)

Intel support article 000102604 (Binary Optimization Tool) · game.intel.com iBOT game-support story (eligible CPUs, 19 titles, enable steps, IPPP 26.06.100.32) · Intel APO Advanced Mode article 000098240 · Tom's Hardware iBOT tested (up to 18%, ~8% avg) · LTT Labs "worth it for the few?" (+10% avg FPS/+8% lows) · PC Gamer hands-on · Geekbench blog 2026-03 (iBOT rewrites benchmark binaries; GB 6.7 flags runs) + HotHardware/VideoCardz/TweakTown coverage · TechPowerUp vectorization analysis · igor'sLAB launch analysis · Station-Drivers IPPP 26.06.100.32 timing. (Earlier "IBOT = IBT/Bluetooth" claim retracted — iBOT is unrelated to Bluetooth.)

## Intel follow-up sources (IPPP / IBT / DTT+APO / GNA+NPU)

ASUS IPPP FAQ: asus.com/support/faq/1056779 — Intel IPPP download + overview: intel.com/content/www/us/en/download/869519 · support article 000102685 — IPPP contents (DTT+IPF+PPM): techspot.com/downloads/7854, station-drivers.com IPPP threads — ASRock Z890 platform-power driver coverage: wccftech.com, tweaktown.com/news/101855 — Intel APO overview + requirements: intel.com support articles 000095419, games list 000098266 — vendor APO how-tos: asus.com/global/support/faq/1053613, msi.com/blog (APO on MSI boards), asrock.com/support/faq id=533 — APO uplift claims vs measured: tomshardware.com (up to 14%), gamersnexus.net 285K review (~1.9% on 14900K) — IBT naming: intel.com article 000005489, Gigabyte/ASRock/Dell BT package listings — GNA deprecation + NPU successor: OpenVINO 2024.1 release notes, docs.openvino.ai 2023.3 GNA plugin, pcworld.com Arrow Lake NPU, Gigabyte Z890 support listings (Intel AI Boost, PCI DEV_AD1D).

## Sources

Intel chipset INF (order + restart + silent switches): intel.com/content/www/us/en/support/articles/000005533 · downloadmirror.intel.com/727318/Readme.txt · intel.com/content/www/us/en/support/articles/000006373 — AMD chipset bundle notes: amd.com/en/resources/support-articles/release-notes/RN-RYZEN-CHIPSET-7-06-02-123.html — Adrenalin Factory-Reset caveat: amd.com/en/support/kb/release-notes/rn-rad-win-21-5-2 — Dell driver order: dell.com/support/kbdoc/en-us/000132394 — ASUS install FAQ + VMD/RST: asus.com/us/support/faq/1048815 · asus.com/us/support/faq/1044458 — MSI driver order + LAN preload: msi.com/support/technical_details/MB_Driver_Update — Intel RST non-RAID block: community.intel.com/t5/Rapid-Storage-Technology/Why-RST-blocked-all-Non-RAID-driver/td-p/1560758 — Intel BT-first threads: community.intel.com/t5/Wireless/...(1721758, 1726201) — I225-V EEE advisory: intel.com/content/www/us/en/support/articles/000091005 — StorNVMe/inbox drivers: learn.microsoft.com (nvme-features-supported-by-stornvme, inbox-network-drivers) — Win11 USB4 inbox: learn.microsoft.com/en-us/answers/questions/1859813 — NVIDIA clean install: nvidia.custhelp.com/app/answers/detail/a_id/10 — Nahimic incompatibilities: nahimic.helprace.com/i737 · forums.developer.nvidia.com/t/187309 — platform-driver needs: elevenforum.com/t/35352, /t/24189 — community consensus: tenforums.com/t/103049, tomshardware.com/t/3708421, rog-forum.asus.com/t/843028 — Puget Systems update practice: pugetsystems.com — Glenn Berry AMD checklist: glennsqlperformance.com/2020/11/01.
