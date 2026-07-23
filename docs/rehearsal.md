<!-- SPDX-License-Identifier: Apache-2.0 -->

# Rehearsal mode — the full-pipeline readiness self-check

`-Rehearse` walks the **entire** first-boot stack on the machine it runs on,
emulating every step as true-to-life as possible, and installs **nothing**. It
exists for two jobs:

1. **Bring-up self-check.** Prove the whole pipeline is ready to go on this
   machine before anything is allowed to install. *(While the shop's ordered
   install checklist is being finalised, a bare `bootstrap.ps1` run defaults to
   this self-check; the real run needs an explicit `-Install`.)*
2. **Cross-system dev diagnostics.** Run it on any dev/bench box and collect
   the super-verbose logs + the JSON report to see exactly how far the stack
   could get there and why.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1              # bare run = self-check (bring-up default)
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Rehearse    # explicit
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Rehearse -RehearseDownloads   # max fidelity
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Install     # the real first-boot run
```

No elevation is required (or requested) for a rehearsal.

## What is real vs. emulated, per phase

| Phase | Real (actually happens) | Emulated (logged, not executed) |
| --- | --- | --- |
| environment | full snapshot: OS/build, PS version+edition, elevation, TLS, winget, BITS, disk, RAM, TCP reachability of every vendor host in `defaults.json` | — |
| windows-prep | current service states + current registry values read | WU policy/service changes, UAC change (exact keys/values logged) |
| detect | CIM board/GPU/peripheral detection | — |
| mapping | mapping-table lookup + MS-code resolution | — |
| bios | vendor-host reachability, BIOS pick (non-beta latest), BIOS URL probe | download/extract/staging, state marker, `shutdown /r /fw` (exact command logged) |
| windows-update | live WUA scan (real offer count + titles, driver-class count), pending-reboot indicators | hold release, installs, RunOnce resume, reboots |
| mirror | mirror index fetch + board lookup (when configured) | file pulls |
| vendor | live provider resolve + driver-list API calls | — |
| drivers | per-file URL **probe** (HEAD, ranged-GET fallback: status + size); with `-RehearseDownloads` also real download, hash verify, extraction, .inf enumeration, packer detection | `pnputil` / silent EXE / `msiexec` execution — the **exact command line is logged** instead |
| gpu | NVIDIA headless lookup (real API), installer URL probe | silent install (exact command logged) |
| apps | catalog matching against real hardware, winget presence check, fallback-page probe | `winget install` (exact command logged), browser opening |
| tweaks | associations + taskbar XMLs **rendered** into the rehearsal area | dism import, registry writes, wallpaper broadcast (exact keys/values logged) |
| fallback | fallback URL construction | Chrome install + page opening |

Rules of thumb: reads and renders are real, side effects are logged. The only
writes a rehearsal performs are its own logs/artifacts under
`%ProgramData%\firstboot\` (plus the mapping self-heal cache, same as any run).

## Artifacts

Everything lands under `%ProgramData%\firstboot\`:

| Artifact | Path | Purpose |
| --- | --- | --- |
| Text log | `logs\firstboot_<stamp>.log` | human-readable transcript (phase-tagged; `REHEARSE` lines carry the would-run commands) |
| Structured log | `logs\firstboot_<stamp>.jsonl` | one JSON record per entry: `ts`, `level`, `phase`, `msg`, `data` (probe results, exact commands, env snapshot) — for machines/diffing |
| **Rehearsal report** | `logs\rehearsal_<stamp>.json` | the collectable: environment snapshot + board + phase ledger + every driver/gpu/app result |
| Staged artifacts | `work\rehearsal\` | rendered `firstboot-defaultapps.xml`, `LayoutModification.xml`; with `-RehearseDownloads`, downloaded + extracted driver packages |

The console ends with the same content as the report's ledger:

```
-------------------- rehearsal report (how far could this machine get?) --------------------
  environment     ok        13/13 vendor hosts reachable
  detect          ok        ASUSTeK COMPUTER INC. / ROG STRIX Z490-I GAMING -> asus
  mapping         ok        hit: 'ROG STRIX Z490-I GAMING' -> asus/ROG STRIX Z490-I GAMING
  mirror          skipped   no mirror configured
  vendor-resolve  ok        asus resolved 'ROG STRIX Z490-I GAMING'
  driver-list     ok        25 file(s) from asus
  drivers         ok        16 Rehearsed
  gpu             ok        NVIDIA GeForce RTX 3070: Rehearsed
  apps            ok        4 match(es): ...
  tweaks          ok        emulated (see REHEARSE lines)
```

**Ledger outcomes:** `ok` / `emulated` — phase fully worked; `degraded` — worked
with failures (some URLs dead, hosts unreachable); `blocked` — phase could not
proceed (this is where a real run would stop getting value); `skipped` —
intentionally not run (flag/config); `fallback` — the Chrome-page path would be
used.

## Collecting across machines

The report is one self-contained JSON per run. From several dev systems:

```powershell
Copy-Item "$env:ProgramData\firstboot\logs\rehearsal_*.json" \\bench-share\rehearsals\ -Force
```

Diff two machines' ledgers (or feed the JSONL logs to your tooling) to spot
environment-specific breakage — unreachable vendors, missing winget, stale
mappings, dead CDN URLs — before an install run ever happens.

## Fidelity levels

| | probes | downloads | extraction + packer detection | installs |
| --- | --- | --- | --- | --- |
| `-Rehearse` | ✅ | — | — | never |
| `-Rehearse -RehearseDownloads` | ✅ | ✅ (real files into `work\rehearsal\`) | ✅ | never |

`-RehearseDownloads` pulls every selected driver (can be GBs for GPU drivers) —
use it on a bench with disk/bandwidth to spare, optionally scoped with
`-Categories` / `-SkipGpu` / `-SkipApps`.

## Relationship to `-WhatIf`

`-WhatIf` is the *operator* dry run: quick planning output via ShouldProcess.
`-Rehearse` is the *developer* readiness check: it goes much deeper (probes,
real parsing, artifacts, structured logs, the report) and is the bring-up
default. They are independent; rehearsal does not use ShouldProcess gating —
its emulation branches return before any side-effectful code is reached.
