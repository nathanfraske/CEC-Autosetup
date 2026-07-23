<!-- SPDX-License-Identifier: Apache-2.0 -->

# BIOS/firmware settings — verify from Windows vs set from software

Researched 2026-07-23. Verdict up front: **verification is automatable and
belongs in the stage-4 gate** (checklist below is implementation-ready);
**setting consumer-board BIOS options from Windows is unsupported** — the shop
paths are pinned-BIOS golden profiles now, KVM keystroke automation later,
SCEWIN as a risky power-tool option.

## Verify-from-Windows checklist (stage-4 additions; run elevated, PS 5.1)

| Check | Command / API | PASS criterion | Confidence |
|---|---|---|---|
| Secure Boot | `Confirm-SecureBootUEFI` (throws on legacy/CSM) | `True` (a "not supported" throw = CSM boot = FAIL) | High |
| TPM 2.0 ready | `Get-Tpm`; spec via `root\cimv2\Security\MicrosoftTpm` `Win32_Tpm.SpecVersion` | `TpmPresent` + `TpmReady` true, SpecVersion has "2.0" | High |
| TPM attestation (local gate) | `tpmtool getdeviceinformation` → `Ready For Attestation`, `Is Attestation Capable`; `certutil -tpminfo` EK chain; AIK via `AikCertEnrollTask` / `EkCertificatePresent` | Both fields True + clean EK chain. Log raw tpmtool output (field names may drift across builds). | High cmds / Medium field stability |
| TPM attestation — **end-to-end "Microsoft actually accepts it"** | `certreq -enrollaik -config ""` (cmd, elevated, online) — performs a live AIK enrollment against Microsoft's attestation CA | Enrollment succeeds / AIK cert issued = Microsoft accepted this TPM's EK. This is the field test for the known attestation bug that gets Warzone/COD (Ricochet) players kicked despite locally-"ready" TPMs — a locally-green TPM can still be rejected by the CA. Needs network; capture full output (exact success/failure strings verified at implementation). | High that the check is right / verify output parsing on bench |
| ReBAR — NVIDIA | `nvidia-smi -q` → **BAR1 Memory Usage: Total** | BAR1 Total ≈ full VRAM (256 MiB = inactive). Don't rely on the NVCP row (being phased out). | High |
| ReBAR — AMD (SAM) | ADLX SDK `GetSmartAccessMemoryStatus()` (one-time compiled helper), or vendor-neutral fallback: prefetchable BAR length ≥ VRAM via PnP resources | SAM enabled / BAR ≥ VRAM | Medium |
| ReBAR — Intel Arc | BAR-length fallback (no CLI; Arc *requires* ReBAR for rated perf) | BAR ≥ VRAM | Low-Med |
| XMP/EXPO active | `Win32_PhysicalMemory` → `ConfiguredClockSpeed` per DIMM | Equals the kit's rated MT/s **from the build BOM** (allow rounding, 5996≈6000). Gotcha: `Speed` is SPD max, sometimes JEDEC base — never compare Speed vs ConfiguredClockSpeed alone; compare against the BOM. | High (with BOM) |
| dGPU seated x16 | `Get-PnpDeviceProperty` `DEVPKEY_PciDevice_CurrentLinkWidth/CurrentLinkSpeed/MaxLinkWidth/MaxLinkSpeed`; NVIDIA cross-check `nvidia-smi --query-gpu=pcie.link.*` | `CurrentLinkWidth = 16` always (width never downtrains for power — x8 = seating/slot/lane-sharing problem). Link **gen** downtrains at idle by design: check under load or gate on Max gen + width. | High |
| VBS / HVCI | `root\Microsoft\Windows\DeviceGuard` `Win32_DeviceGuard` | Shop policy: VBS status `2` (running); HVCI in `SecurityServicesRunning`. NOTE: HVCI-ON collides with WinRing0-lineage sensor drivers (see stress-harness doc) — validate before gating both. | High |

## Setting BIOS options from software — verdicts (consumer boards)

| Mechanism | Verdict |
|---|---|
| **Vendor CLI/WMI** (ASUS/MSI/Gigabyte/ASRock consumer) | **Does not exist** (unlike Dell/HP/Lenovo enterprise WMI). Don't plan on one appearing. |
| **BIOS profiles on USB** (ASUS .CMO / MSI / Gigabyte / ASRock profiles) | **Supported but version-locked** — profiles only load on the exact BIOS version that made them. Shop fit: pin one BIOS per model batch → flash pinned BIOS → load golden profile → done. Re-capture at every BIOS bump. |
| **AMI SCEWIN / AMISCE** (NVRAM setup-variable edit from Windows) | **Risky-conditional.** Real AMI OEM tool; only semi-official channel is MSI Center's bundled copy; community mirrors redistribute without license. Can toggle XMP/ReBAR/GNA incl. hidden options. Constraints: variable maps are per-board **and** per-BIOS-version; Z790-era boards password-protect runtime variables (documented workarounds); bad writes → no-POST (recover via CMOS clear/Flashback). If adopted: pinned BIOS versions, tested per-model maps, no redistribution, legal read first. |
| **KVM keystroke automation** (PiKVM/NanoKVM + OCR verify) | **Feasible DIY, real precedent, fragile across BIOS updates.** `pikvm-lib` gives send-keys + OCR snapshots + ATX control; pair with `shutdown /r /fw` to land in Setup deterministically. No turnkey product — per-board menu scripts, maintained per BIOS bump. Dovetails with the NanoKVM harness in the AllMyStuff design. |

## GNA verdict (+ BIOS labeling nuance)

**The thing we actually want enabled on 800-series is the NPU ("Intel AI
Boost"); legacy GNA itself stays irrelevant** (OpenVINO dropped the plugin at
2024.0) and must never be a PASS criterion on its own. BIOS labeling nuance
(shop field observation): some boards' setup may still present a
"GNA"-labelled toggle even on NPU-era platforms — Arrow Lake datasheets
document BOTH a legacy GNA 3.5 block and the NPU, so **do not assume a "GNA"
toggle is the NPU**. Where a board only shows "GNA": verify once per board
model what it actually controls (flip it and watch whether the Intel AI Boost
device, PCI\VEN_8086&DEV_AD1D, appears/disappears in Device Manager), record
the answer in that board's golden-profile notes, and gate stage 4 on **NPU
device presence**, never on the BIOS label.

## Sources (key)

Microsoft Learn (Get-PnpDeviceProperty, Win32_PhysicalMemory,
Confirm-SecureBootUEFI, Win32_DeviceGuard/HVCI) · call4cloud.nl (tpmtool
attestation fields, AikCertEnrollTask) · nvidia-smi BAR1 method + ReBarUEFI
discussions + MSI FAQ 4035 · GPUOpen ADLX SAM API · SCEHUB (github) + SECO
AMISCE overview + Win-Raid Z690/Z790 protected-variable guide · ASUS FAQ
1053878 + ROG forum version-lock threads · pikvm.org + pikvm-lib ·
OpenVINO 2024.x release notes + Intel ARL-S datasheet (GNA 3.5).
