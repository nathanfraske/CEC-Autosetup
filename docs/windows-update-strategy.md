<!-- SPDX-License-Identifier: Apache-2.0 -->

# Windows Update strategy (researched 2026-07-23)

The shop's empirical sequence — hold WU, BIOS first, let WU run **fully**,
then vendor drivers on top — was researched against Microsoft docs, the 2026
driver-targeting announcements, and vendor advisories. **Verdict: sound, with
caveats.** The order stays; three mechanics change (all reflected in the code).

## Why the sequence is right

- **AMD confirmed the failure mode** the shop observed: a Windows Update
  running concurrently with a driver install can corrupt driver registration
  (worst with Adrenalin "Factory Reset"), even leaving Windows unbootable.
  AMD's official mitigation is this exact sequence: all system updates
  applied **or paused** before installing drivers.
- **"Vendor driver on top wins" is correct in the mainline case.** Windows
  picks drivers by *rank* (signature + feature score + HWID specificity);
  date/version only break ties. The latest vendor driver at the same 4-part
  HWID outranks-or-ties WU's older package, so WU does not re-offer it.
- **Caveat — the GPU downgrade hole:** Microsoft admitted (May 2026) that
  broadly-targeted or CHID-targeted OEM display drivers can outrank a newer
  installed driver, so WU "legitimately" downgrades GPUs. The fix (2-part
  HWID + CHID targeting) enforces Q4 2026–Q1 2027, new submissions only.
  Until then a **post-driver verification scan is mandatory** (below); Intel
  iGPU drivers are the documented repeat offender.

## The mechanics (what the code does / will do)

| Step | Mechanism | Status |
| --- | --- | --- |
| Hold (stage 1) | Policy pair: `HKLM\...\WindowsUpdate\AU\NoAutoUpdate=1` + `HKLM\...\WindowsUpdate\ExcludeWUDriversInQualityUpdate=1`; stop `wuauserv`/`UsoSvc` once to cancel in-flight work | **Supported** — implemented in `WindowsPrep.psm1` |
| ~~Disable the services~~ | ~~`Set-Service Disabled`~~ | **Rejected** — unsupported; WaaSMedic re-enables them on its own schedule = the exact nondeterminism the hold exists to remove |
| ~~SearchOrderConfig=0~~ | ~~PnP device-installation knob~~ | **Rejected** — blunter than needed; the policy pair already excludes driver offers |
| Release (post-BIOS stage) | **Delete** the two values (never leave `=0` — ship policy-clean); restart services | Implemented (`Restore-WindowsUpdate`) |
| Run WU fully | WUA COM API directly (`Microsoft.Update.Session` search → download → install; in-box, zero deps) looping with resume-task-resumed reboots until clean — implemented in `WindowsUpdateRun.psm1` (max-cycle guard, state marker) | **Implemented** (stage 2) |
| "Fully done" test | BOTH: a fresh WUA scan returns zero applicable non-hidden updates AND no pending reboot (CBS `RebootPending`, WU `RebootRequired`, `PendingFileRenameOperations` all clear) | **Implemented** (`Get-PendingRebootStatus` + scan loop) |
| ~~UsoClient~~ | ~~`StartScan/StartDownload/StartInstall`~~ | **Rejected** — undocumented, internal-only per Microsoft |
| Vendor drivers | Ordered install per [`driver-install-order.md`](driver-install-order.md), WU idle | next slices |
| Verification pass | One final WU scan: expect zero driver offers; any re-offer is **hidden per-update** via WUA `IsHidden` and recorded — never blanket-blocked; plus the problem-device audit + pending-reboot check | **Implemented** (stage 4, `BuildVerification.psm1`) |

Also worth knowing: OOBE's zero-day-patch updates cannot be opted out once
OOBE has network, and WU does no background work until first sign-in —
audit mode (`sysprep /audit`) is the sanctioned window for all of this if the
imaging flow ever moves there.

## Ship policy: leave WU driver offers ENABLED

Do **not** ship `ExcludeWUDriversInQualityUpdate=1`:

1. Every mainstream OEM (Dell/HP/Lenovo) ships with WU drivers enabled — they
   distribute their own drivers through it.
2. Blocked driver offers = dead new peripherals for the customer (post-2004,
   Windows goes straight to WU for missing drivers).
3. Security fixes for Wi-Fi/BT/GPU stacks reach consumers only via WU.
4. The protection is small (ranking already protects newer vendor drivers)
   and the display-class hole is being engineered out by early 2027.
5. The policy is Pro-scoped and fragile across feature updates on Home.

Known-bad re-offers get handled **per-update, per-SKU** (hide + record), with
any blanket deviation documented with an expiry. The restore path ships
policy-clean automatically (values absent before the hold are deleted, not
zeroed).

## Sources (key)

Microsoft Learn: driver distribution rules, driver ranking/selection, WU
settings (`waas-wu-settings`), Policy CSP Update, OOBE ZDP, audit mode, WUA
API docs. Microsoft Hardware Dev Center: 4-part→2-part HWID+CHID graphics
policy (2026). AMD advisory coverage (Tom's Hardware / PCWorld / HWCooling).
Intel articles on WU rolling back graphics drivers (000087834, 000091899).
UsoClient undocumented status; WaaSMedic service re-enable behavior;
PSWindowsUpdate + pending-reboot detection references; Puget Systems build
practice. Full URL list preserved in the research transcript.
