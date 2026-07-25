<!-- SPDX-License-Identifier: Apache-2.0 -->

# CEC bench answer file (`autounattend.xml`)

Front half of the "few button presses" goal: this takes a machine from *boot
the Windows installer* to *the provisioning pipeline running on screen* with
**one** deliberate technician interaction (picking the target disk).

**Status: proposed, unvalidated on real hardware.** The XML is well-formed and
the structure is standard, but it has not been run against a real install yet.
Test on a scratch VM first — see [Testing](#testing) — and reconcile against
your current file before it touches a customer build.

## What happens, in order

| # | Stage | Tech action |
| --- | --- | --- |
| 1 | Boot USB. Language/keyboard/EULA answered by `windowsPE` pass. | none |
| 2 | Edition selected by the generic Pro key (no "which edition?" prompt). | none |
| 3 | **Disk selection** | **← the one click** |
| 4 | Image applies; `specialize` sets computer name, timezone, **UAC off**. | none |
| 5 | OOBE: EULA/OEM-registration/wireless/express-settings all suppressed; local bench admin created (no Microsoft-account wall). | none |
| 6 | Auto-logon to the bench account. | none |
| 7 | `FirstLogonCommands` finds `CEC-Autosetup` on any drive letter and launches `bootstrap.ps1 -Install` in its own visible window. | none |
| 8 | Pipeline runs: WU hold → BIOS → WU-in-full → ordered drivers → GPU → apps → tweaks → verify, rebooting and resuming itself as needed. | watch |

## Edit before use (`CHANGEME` in the file)

1. **Bench account name + password** — in *both* `UserAccounts` and `AutoLogon`; they must match.
2. **TimeZone** — placeholder is `Central Standard Time`.
3. **ComputerName** — `*` = random. Change if you want the work-order number in the name (the pipeline puts the machine name in its reports, so an order-number scheme makes reports self-identifying).
4. **InputLocale** — two places (`windowsPE` + `oobeSystem`), keep them in sync.
5. **ProductKey** — remove the block if your ISO is single-edition Pro.

## Deliberate design decisions

**Disk configuration is NOT automated.** An answer file that wipes `DiskID 0`
is the most dangerous thing on the stick: disk ordering isn't guaranteed to
match what the tech thinks is the boot drive, so on a multi-drive build — or
one with a customer's data drive attached for migration — it can irreversibly
destroy the wrong disk. One screen is cheap; a wiped customer drive is not.
The commented-out block in the file shows the layout if you ever decide the
bench is controlled enough, but it should be a conscious decision.

**UAC is disabled in `specialize`, not at runtime.** The pipeline's docs already
call the unattend the preferred permanent home for this. Setting it here means
the bench admin's token is unsplit at first logon, so the pipeline and its
SYSTEM resume task never meet a consent prompt on an unattended reboot. The
pipeline's `WindowsPrep` stage detects it's already `0` and records that; the
ship-out stage restores it before delivery. **If you remove it here, the runtime
stage sets it instead** — same end state, one extra reboot to take effect.

**`LogonCount` is 12.** The pipeline reboots several times (BIOS hand-off, WU
catch-up cycles, driver-order restart boundaries), and each consumes one
auto-logon. A stingy count strands the run at a logon prompt mid-pipeline. The
SYSTEM resume task doesn't depend on auto-logon, but the tech-visible console
does.

**The launcher is drive-letter agnostic.** It scans every filesystem root for
`\CEC-Autosetup\bootstrap.ps1`, then a flat `\bootstrap.ps1`, so the stick can
land on any letter. It `Start-Process`es and returns immediately, so the desktop
appears while the pipeline runs in its own `-NoExit` window the tech can watch
and scroll. If the stick is missing it says so loudly rather than failing
silently.

**Dry-run variant:** drop `-Install` from the `CommandLine` and a bare run does
the readiness **self-check** and installs nothing. Use this on the first machine
you test the file against.

## Security notes

- The bench password is **plaintext in the XML on a USB stick that walks around
  the shop**. Windows' `PlainText=false` only base64-encodes it — that is
  obfuscation, not encryption. Treat this as a throwaway local bench credential:
  never a password used anywhere else, and never one that unlocks anything but
  this bench account.
- Consider having the ship-out stage **remove or rename the bench account** (and
  re-enable UAC) before delivery, so no shop credential ships to a customer.
- UAC is off for the whole provisioning window. That's a deliberate, bounded
  tradeoff on a machine that isn't yet the customer's — it must be restored
  before ship. That restore belongs in the ship-out stage.

## Reconciling with your current file

Drop your existing `autounattend.xml` next to this one and walk this list. The
useful question for each row isn't "which is right" but "why did we each choose
that" — differences usually encode a real bench constraint.

| Area | Check |
| --- | --- |
| **Passes present** | Do you use `offlineServicing` / `auditSystem` / `generalize`? Sysprep-based imaging changes the whole shape — say so and I'll rework this for a captured-image flow rather than a clean-install flow. |
| **Disk** | Do you automate `DiskConfiguration`? If yes, what protects against the wrong-disk case? |
| **Product key** | Edition selector, real key, or omitted? |
| **Account** | Local vs domain vs MSA; name; admin group; password policy; is the account removed at ship? |
| **Auto-logon** | Present? `LogonCount` value? (Anything under ~8 risks stranding a multi-reboot pipeline run.) |
| **UAC** | Do you already disable it, and where — unattend, GPO, image, or not at all? |
| **OOBE elements** | Which suppressions do you use? If yours has ones mine lacks, they may be covering a screen I haven't hit yet. |
| **Script launch** | `FirstLogonCommands` vs `SetupComplete.cmd` vs RunOnce vs scheduled task; hardcoded drive letter vs discovery. |
| **Network during OOBE** | Do you install with ethernet plugged in? Affects mandatory zero-day-patch updates during OOBE, and therefore how long OOBE takes and what's already installed before the pipeline's WU stage runs. |
| **Locale/TZ/keyboard** | Straight comparison. |
| **Extra bits** | Bloat removal, `RunSynchronous` commands, registry tweaks, telemetry settings, Wi-Fi profiles — anything of yours worth folding in. |

## Testing

Do this before any customer hardware:

1. **Scratch VM, disk-config still commented out.** Boot the ISO with this file
   at the USB/ISO root and confirm: no language prompt, no EULA, no edition
   picker, no MSA wall, auto-logon lands on the desktop.
2. **Swap `-Install` for a bare run first** so the pipeline self-checks instead
   of installing — that proves the hand-off works without a long driver run.
3. Confirm the launcher found the tool (it prints the loud red message if not).
4. Then a real `-Install` on a scratch bench machine — still the outstanding
   live-fire test for the pipeline itself.

## Related

- [`docs/autounattend.md`](../docs/autounattend.md) — the deployment-integration guide (`FirstLogonCommands` / `SetupComplete.cmd` wiring, flags).
- [`docs/bios-stage.md`](../docs/bios-stage.md) — what the pipeline does first, and why UAC/WU state matters.
