<!-- SPDX-License-Identifier: Apache-2.0 -->

# Wiring into Windows deployment

CEC-Autosetup is a single entrypoint (`bootstrap.ps1`) you can call from any
first-boot mechanism. Two common integrations follow. Both are copy-paste ready.

> **A complete, ready-to-edit bench answer file lives in
> [`unattend/autounattend.xml`](../unattend/autounattend.xml)** — full OOBE
> skip, local bench admin, auto-logon, UAC-off, and a drive-letter-agnostic
> launcher that starts the pipeline at first logon. See
> [`unattend/README.md`](../unattend/README.md) for the design decisions,
> security notes, and the checklist for reconciling it with an existing file.
> The snippets below remain the reference for wiring into *your own* answer
> file or `SetupComplete.cmd`.

> `bootstrap.ps1` already sets TLS 1.2, sets a process-scoped
> `ExecutionPolicy Bypass`, and self-elevates. You only need to invoke it.

---

## 1. Online one-liner

Use when the repo is reachable and the machine has network at first boot. No files
need to be staged — `bootstrap.ps1` downloads a snapshot and runs it.

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/nathanfraske/cec-autosetup/main/bootstrap.ps1 | iex"
```

Override the source repo/branch with environment variables if you fork it:

```
setx FIRSTBOOT_REPO "yourorg/yourfork"   :: optional; default is nathanfraske/cec-autosetup
```

---

## 2. Offline / USB / image-embedded

Copy the repo (at minimum `bootstrap.ps1`, `src/`, and `config/`) onto the image
or a branded USB stick, then call it.

### From `autounattend.xml` (`FirstLogonCommands`, post-OOBE)

```xml
<FirstLogonCommands>
  <SynchronousCommand wcm:action="add">
    <Order>1</Order>
    <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -File X:\CEC-Autosetup\bootstrap.ps1</CommandLine>
    <Description>CEC-Autosetup driver setup</Description>
  </SynchronousCommand>
</FirstLogonCommands>
```

Replace `X:\CEC-Autosetup` with the path where the repo lives (the USB drive
letter or the image path). Add flags after the file path, e.g.
`... bootstrap.ps1 -SkipApps`.

### From `SetupComplete.cmd` (pre-OOBE)

Windows runs `%WINDIR%\Setup\Scripts\SetupComplete.cmd` automatically at the end
of setup, before the first interactive logon. Place this file there (e.g. baked
into the image):

```bat
@echo off
REM %WINDIR%\Setup\Scripts\SetupComplete.cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "X:\CEC-Autosetup\bootstrap.ps1"
exit /b 0
```

`SetupComplete.cmd` already runs as SYSTEM, so no elevation prompt occurs.

> **⚠ TRAP — `SetupComplete.cmd` is silently skipped on machines with an OEM
> product key.** Microsoft documents this setting as *"disabled when using OEM
> product keys, except on Enterprise editions and Windows Server"*: `windeploy.exe`
> finds a firmware (MSDM) key and skips the script **by design, with no error and
> no log entry you'd notice**. That describes most prebuilt-class boards. The
> 24H2+ upgrade path also *purges* `C:\Windows\Setup\Scripts`.
>
> It also runs in **session 0**, so its console window is invisible — a tech
> can't watch the pipeline run.
>
> **Prefer `FirstLogonCommands`** (as [`unattend/autounattend.xml`](../unattend/autounattend.xml)
> does): it runs in the interactive session so the window is on screen, and it
> runs elevated when the logged-on account is an admin. If you need SYSTEM-context
> work *before* logon, use `Microsoft-Windows-Deployment\RunSynchronous` in the
> `specialize` pass instead of `SetupComplete.cmd`.

---

## Disabling UAC in the unattend (preferred over the runtime tweak)

Stage 1 ([`docs/bios-stage.md`](bios-stage.md)) disables UAC at runtime
(`EnableLUA=0`) for images that don't carry the setting, but the right
permanent home is the unattend itself. A schema-proof way is a plain
`reg add` in `FirstLogonCommands`, ordered **before** the bootstrap call:

```xml
<FirstLogonCommands>
  <SynchronousCommand wcm:action="add">
    <Order>1</Order>
    <CommandLine>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f</CommandLine>
    <Description>Disable UAC for the provisioning window</Description>
  </SynchronousCommand>
  <SynchronousCommand wcm:action="add">
    <Order>2</Order>
    <CommandLine>powershell -NoProfile -ExecutionPolicy Bypass -File X:\CEC-Autosetup\bootstrap.ps1</CommandLine>
    <Description>CEC-Autosetup driver setup</Description>
  </SynchronousCommand>
</FirstLogonCommands>
```

When the unattend carries this, the runtime `Disable-Uac` step just records
"already 0" and moves on (it only captures the prior once). Re-enabling before
the machine ships is the later checklist stage (`Restore-Uac`).

---

## Tips

- **Dry run first.** On a reference machine, run
  `powershell -NoProfile -ExecutionPolicy Bypass -File X:\CEC-Autosetup\bootstrap.ps1 -WhatIf`
  and read the transcript at `%ProgramData%\firstboot\logs\` to confirm the plan.
- **Re-running is safe.** The tool is idempotent; `pnputil` skips drivers already
  present and installers no-op when up to date.
- **Skip the apps phase** with `-SkipApps` if you only want drivers.
- **Holdout vendors** (ASRock today) open a Chrome window with a checklist; a
  human or browser agent finishes those.
