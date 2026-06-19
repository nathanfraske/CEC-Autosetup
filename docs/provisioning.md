<!-- SPDX-License-Identifier: Apache-2.0 -->

# Provisioning (the tweaks phase)

After drivers, GPU, and apps, the **tweaks phase** applies shop provisioning.
It's driven by [`config/tweaks.json`](../config/tweaks.json), runs unless
`-SkipTweaks` is passed, and honors `-WhatIf`. Every action is best-effort,
idempotent, and logged — a failure is warned and the run continues.

```jsonc
// config/tweaks.json
{
  "setChromeDefaultBrowser": true,
  "pinChromeToTaskbar": true,
  "disableOneDriveStartup": true,
  "disableCopilot": true,
  "wallpaper": { "enabled": true, "defaultTier": null, "tiersPath": "config/tiers.json", "wallpaperDir": "wallpapers" }
}
```

## What each toggle does

| Toggle | Action | Reliability |
| --- | --- | --- |
| `setChromeDefaultBrowser` | `dism /online /Import-DefaultAppAssociations` with http/https/.html → `ChromeHTML` | **Imaging-time** method — applies to new user profiles |
| `pinChromeToTaskbar` | Writes a taskbar `LayoutModification.xml` to the **Default** user profile | **Imaging-time** — applies to new user profiles (see caveat) |
| `disableOneDriveStartup` | Removes the `OneDrive` Run entry + marks it disabled in `StartupApproved` | Reliable (current user) |
| `disableCopilot` | `TurnOffWindowsCopilot=1` policy (HKCU+HKLM) and hides the taskbar button | Reliable |
| `wallpaper` | Sets the desktop wallpaper for the selected tier | Reliable (current user) |

**Steam** and any other always-install software live in
[`config/apps.json`](../config/apps.json) as `"match": { "always": true }` and are
installed in the apps phase (Steam → winget `Valve.Steam`).

## Important caveats (Windows 11)

Microsoft locked down two of these at the user level — they are reliable only
when applied **during imaging / OOBE**, because they configure *new* user
profiles rather than mutating an existing signed-in session:

- **Default browser** — `Import-DefaultAppAssociations` sets the defaults a new
  profile inherits. An already-configured user keeps their choice. Apply before
  the operator user logs in (e.g. via `SetupComplete.cmd`, see
  [autounattend.md](autounattend.md)) for it to take effect.
- **Taskbar pin** — the taskbar pin list is checksum-protected per user; the
  supported route is the Default-profile `LayoutModification.xml`, which applies
  to profiles created *after* it is written. The phase writes it to
  `C:\Users\Default\...\Shell\LayoutModification.xml`. `PinListPlacement="Replace"`
  gives a clean, known taskbar (edit `New-TaskbarLayoutXml` to extend the set).

Running CEC-Autosetep from `SetupComplete.cmd` (pre-OOBE) gives both of these the
best chance to "stick." `disableOneDriveStartup`, `disableCopilot`, and the
wallpaper apply to the current user immediately.

## Wallpaper by ship tier

A small framework: a tier name → image, selected at first boot.

1. Define tiers in [`config/tiers.json`](../config/tiers.json):
   ```json
   { "tiers": { "tier1": "tier1.jpg", "flagship": "flagship.png" } }
   ```
2. Drop the matching images into [`wallpapers/`](../wallpapers/) (ship them on the
   USB so it works offline).
3. Select the tier at first boot:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File X:\CEC-Autosetep\bootstrap.ps1 -Tier flagship
   ```
   With no `-Tier`, `wallpaper.defaultTier` in `tweaks.json` is used; if neither is
   set or the image is missing, the wallpaper step is skipped (warned, not fatal).

Tier names are yours — the shipped names are examples. The mapping accepts a
filename (resolved under `wallpaperDir`) or an absolute path.
