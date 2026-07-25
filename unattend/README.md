<!-- SPDX-License-Identifier: Apache-2.0 -->

# CEC bench answer file (`autounattend.xml`)

Front half of the "few button presses" goal: this takes a machine from *boot
the Windows installer* to *the provisioning pipeline running on screen* with
**one** deliberate technician interaction (picking the target disk).

**Target build: Windows 11 Pro 25H2 (26200).** 24H2 leaves Pro servicing on
**2026-10-13**, so don't build new media on it. (26H1/28000 is scoped by
Microsoft to new Snapdragon-class devices and isn't offered as an upgrade path —
ignore it unless you're building those.)

> **Status: proposed, not yet run on real hardware.** The XML is well-formed,
> element choices are verified against current Microsoft documentation (July
> 2026), and the launcher is tested locally — but it has never completed an
> actual install. **Validate before customer use** — see [Testing](#testing).

## What happens, in order

| # | Stage | Tech action |
| --- | --- | --- |
| 1 | Boot USB. Language/keyboard/EULA answered by the `windowsPE` pass. | none |
| 2 | Edition forced to Pro (generic key) and image pinned by name — no edition prompt. | none |
| 3 | **Disk selection** | **← the one click** |
| 4 | Image applies. `specialize`: computer name, timezone, **UAC off**, **NICs disabled**. | none |
| 5 | OOBE runs **offline** — no ZDP updates, no MSA wall (local account is pre-created), no wireless/EULA/OEM/express screens. | none |
| 6 | Auto-logon to the bench account. | none |
| 7 | `FirstLogonCommands` re-enables networking, finds `CEC-Autosetup` on any drive letter, launches `bootstrap.ps1 -Install` in its own visible window. | none |
| 8 | Pipeline runs: WU hold → BIOS → WU-in-full → ordered drivers → GPU → apps → tweaks → verify, rebooting and resuming itself. | watch |

## Edit before use (`CHANGEME` in the file)

1. **Bench account name + password** — in *both* `UserAccounts` and `AutoLogon`; they must match.
2. **TimeZone** — placeholder is `Central Standard Time`.
3. **`/IMAGE/NAME`** — must match your ISO exactly. Check with `dism /Get-WimInfo /WimFile:X:\sources\install.wim`.
4. **ComputerName** — `*` = random. Change if you want the work-order number in the name (the pipeline puts the machine name in its reports).
5. **InputLocale** — two places (`windowsPE` + `oobeSystem`), keep them in sync.
6. **`HideEULAPage`** — licensing decision, see below.

## Deliberate design decisions

### Networking is disabled during OOBE — the highest-value line in the file

Microsoft documents that critical zero-day-patch (ZDP) updates download during
OOBE *"after the user has connected to a network"* and that **"the user can't
opt out."** There is **no** answer-file element, policy, or registry key that
disables it — the only documented lever is the trigger condition itself.

Things that do **not** work, despite being widely recommended: `ProtectYourPC=3`
(controls express settings, not updates — the "updates" wording is stale Win7-era
text), WU Group Policy (doesn't apply until after first sign-in), unattend
`DynamicUpdate` (governs Windows *Setup*, an entirely different phase),
`AllowOOBEUpdates` (Microsoft's own note: *"doesn't control the zero-day patch
(ZDP) updates page"*), and `BypassNRO` (affects MSA enrollment, not networking).

Why we care beyond the 30+ minutes it can burn: **a mid-OOBE update restart
leaves the machine not automatically signed in, which is documented to break
autologon provisioning** — i.e. it can strand this exact hand-off before the
pipeline ever starts.

We lose nothing by deferring: the pipeline runs Windows Update to completion
itself, on our schedule, with our reboot/resume handling and our logging.

*To disable this behavior:* remove the `Disable-NetAdapter` command in
`specialize` **and** the `Enable-NetAdapter` call in `FirstLogonCommands`, then
just leave the ethernet unplugged during install instead. If the re-enable ever
fails, the machine comes up offline — the pipeline reports that in its
environment snapshot and degrades to its offline path rather than failing.

### Disk configuration is NOT automated

`WillWipeDisk` on `DiskID 0` is the most dangerous thing an answer file can do.
Microsoft's definition of `DiskID` is purely ordinal — *"0 specifies the first
disk"* — with **no** guarantee about which physical device that is; it's
firmware enumeration order and varies by board, by NVMe-vs-SATA, and after
hardware changes. There is no way to target a disk by serial, size, or bus.

Its only built-in guards are: the disk running Setup, the disk the OS booted
from, and a disk with an active page file. **Your USB stick is protected. A
customer's data drive plugged in for migration is not.**

One human click on a screen showing drive sizes beats an irreversible wrong-disk
wipe. The layout is in the file, commented, if you ever decide otherwise.

### UAC off in `specialize`

`specialize` runs as SYSTEM before OOBE, and `EnableLUA` is read at logon/boot —
so it's already in effect at first logon. (Doing it in `FirstLogonCommands`
would be too late to help the commands being run.) The native
`Microsoft-Windows-LUA-Settings\EnableLUA` element exists but is
`offlineServicing`-only and Microsoft says *"we do not recommend using this
setting"* — the registry write is the field-standard approach.

Worth knowing: `FirstLogonCommands` under an **admin** account already run
elevated, so the pipeline doesn't strictly need UAC off. This is belt-and-braces
against third-party installers raising a consent dialog mid-run. `EnableLUA=0`
does break some UWP/Store apps and Settings pages — fine for a bench window,
and exactly why it must be restored before ship.

### `LogonCount` is 12

The pipeline reboots repeatedly and each consumes an auto-logon; a stingy count
strands the run at a logon prompt. Note Windows **adds 1** when the value is >0,
so 12 yields ~13. Exactly one auto-logon is impossible via `LogonCount` alone.

### Elements deliberately absent

- **`HideLocalAccountScreen`** — Microsoft: *"applies only to the Windows Server
  editions."* A no-op on Pro, despite being the #1 cited "fix" for the *Who's
  going to use this device?* screen. Pre-creating the local account is what
  actually suppresses it.
- **`SkipMachineOOBE` / `SkipUserOOBE`** — deprecated, no longer listed as valid
  `OOBE` children, and Microsoft warns they can leave a machine half-configured.
  Any guide recommending them is stale.
- **`InstallTo` / `InstallToAvailablePartition`** — omitting both is what
  surfaces the disk picker. (`InstallToAvailablePartition` would happily land on
  a data drive; and setting it together with `InstallTo` makes Setup fail.)

## Security — this must be handled at ship-out

The bench credential is **not** protected in any meaningful sense, and it leaves
traces in three places:

1. **The answer file itself** — `PlainText=false` is base64 obfuscation, not
   encryption; one line of PowerShell reverses it.
2. **`HKLM\...\Winlogon\DefaultPassword`** — the autologon password lands here
   in **cleartext**, readable by authenticated users.
3. **`C:\Windows\Panther\unattend.xml`** — Windows caches the answer file and it
   **persists after install**. Microsoft: *"Before you deliver the computer to a
   customer, you must delete the cached answer file in the %WINDIR%\panther
   directory."*

**Ship-out stage requirements** (these belong in the pipeline's ship-out slice):

- [ ] Restore `EnableLUA` / `ConsentPromptBehaviorAdmin`
- [ ] Zero `AutoLogonCount`, delete `DefaultPassword` and `AutoAdminLogon`
- [ ] Delete `C:\Windows\Panther\unattend.xml`
- [ ] Disable, rename, or delete the bench account
- [ ] Delete `C:\Windows.old` — 24H2+ treats a clean install as an upgrade and
      leaves an empty one behind
- [ ] **Verify BitLocker state.** 24H2+ can silently enable device encryption
      during OOBE on capable hardware. A local account *usually* prevents it but
      not always — and shipping a customer a silently-encrypted drive with no
      escrowed recovery key is a support disaster. Check every machine.

Treat the bench password as throwaway, used only for imaging, rotated per media
revision, and never reused anywhere else.

## Reconciling with your current file

Drop yours next to this one and walk the list. The useful question per row isn't
"which is right" but "why did we each choose that" — differences usually encode
a real bench constraint.

| Area | Check |
| --- | --- |
| **Passes present** | Do you use `offlineServicing` / `auditSystem` / `generalize`? A sysprep/captured-image flow changes the whole shape — tell me and I'll rework this for it. **Important if so:** an `autounattend.xml` on the media root is documented to *overwrite* `C:\Windows\Panther\unattend.xml` mid-install, silently killing a baked-in sysprep answer file (and `CopyProfile` with it). Don't use both. |
| **Disk** | Do you automate `DiskConfiguration`? If yes, what guards the wrong-disk case? If you partition manually, note WinRE now wants ≥990 MB (Microsoft's current guidance) and should sit *after* the Windows partition so it can grow. |
| **Product key / edition** | Generic Pro key, real key, `MetaData` pin, or nothing? Any board with an embedded **Home** MSDM key will silently install Home without the forcing key. |
| **Account** | Local vs domain; name; admin group; is it removed at ship? |
| **Auto-logon** | Present? `LogonCount`? (Under ~8 risks stranding a multi-reboot run.) |
| **UAC** | Do you already disable it, and where — unattend, GPO, image, or not at all? |
| **OOBE elements** | Which suppressions do you use? If yours has ones mine lacks, they may cover a screen I haven't hit. |
| **Script launch** | `FirstLogonCommands` vs `SetupComplete.cmd` vs RunOnce vs scheduled task; hardcoded drive letter vs discovery. **See the `SetupComplete.cmd` trap below.** |
| **Network during OOBE** | Do you install with ethernet connected? That's the ZDP exposure discussed above. |
| **Hardware bypasses** | Using `LabConfig`? Only `BypassTPMCheck`, `BypassSecureBootCheck`, `BypassRAMCheck` are real — `BypassCPUCheck`/`BypassStorageCheck` don't exist in Setup and never did. |
| **Extra bits** | Bloat removal, registry tweaks, telemetry, Wi-Fi profiles — anything of yours worth folding in. |

### The `SetupComplete.cmd` trap

If your current file (or process) relies on `%WINDIR%\Setup\Scripts\SetupComplete.cmd`:
Microsoft documents that it is **disabled when an OEM product key is present**,
except on Enterprise/Server. `windeploy.exe` skips it, **by design and with no
error**, when it finds a firmware OEM key — which describes most prebuilt-class
boards. Also, the 24H2 upgrade path *purges* `C:\Windows\Setup\Scripts`.

If you need SYSTEM-context pre-logon work, use `Microsoft-Windows-Deployment\RunSynchronous`
in `specialize` (as this file does for UAC and the NICs) rather than
`SetupComplete.cmd`.

## Testing

Do this before any customer hardware:

1. **Validate the file properly first.** This file is hand-written. Two of the
   nastiest documented failure modes are pure XML/attribute errors that get
   misattributed to Windows: a missing `wcm:action="add"` makes commands
   **silently do nothing**, and a malformed `RunSynchronous` block can cause a
   **WinPE reboot loop with no error dialog**. Load it in Windows SIM (or paste
   the settings into <https://schneegans.de/windows/unattend-generator/>) to get
   real schema validation — "well-formed XML" is not the same as "valid answer
   file". *(All six elements here that require `wcm:action="add"` have been
   checked programmatically, but SIM validates the whole schema.)*
2. **Scratch VM, disk config still commented out.** Confirm: no language prompt,
   no EULA, no edition picker, no MSA wall, auto-logon reaches the desktop.
3. **Swap `-Install` for a bare run** so the pipeline self-checks instead of
   installing — proves the hand-off without a long driver run.
4. Confirm the launcher found the tool (loud red message if not).
5. Then a real `-Install` on a scratch bench machine.

**If OOBE settings appear ignored**, check these before blaming the answer file:
Windows display language not matching the installation medium's language (the #1
false positive), Rufus having injected *its own* answer file that outranks
yours, or a media-root file overwriting a baked-in `Panther` one. Diagnose with
`Shift+F10` → `notepad X:\Windows\setupact.log` during WinPE, and
`C:\Windows\Panther\setupact.log` after first reboot — look for
`Found usable unattend file for pass [windowsPE]`.

**One genuinely unresolved item:** 24H2 replaced the WinPE setup host (`setup.exe`
now launches `SetupHost.exe`/`SetupPrep.exe`, the in-place-upgrade engine, often
called "ConX"). Reports conflict on whether this causes `oobeSystem` settings to
be ignored — the maintainer of the most-used answer-file generator states his
files work in both modes and can't reproduce the failures, while other
credentialed users report the opposite. **Test your exact media end-to-end on
one machine before committing a batch.** If you do hit it, the reliable fallback
is patching `boot.wim` with a `winpeshl.ini` that calls `setup.exe /legacy` —
not the `HKLM\SYSTEM\Setup\CmdLine` registry trick, which multiple people
including the generator's author could not make work.

## Related

- [`docs/autounattend.md`](../docs/autounattend.md) — deployment-integration guide.
- [`docs/bios-stage.md`](../docs/bios-stage.md) — what the pipeline does first, and why UAC/WU state matters.
- [`docs/windows-update-strategy.md`](../docs/windows-update-strategy.md) — the researched WU strategy this file's network handling serves.
