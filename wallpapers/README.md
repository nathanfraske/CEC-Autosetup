<!-- SPDX-License-Identifier: Apache-2.0 -->

# Tier wallpapers

Drop a wallpaper image here for each tier defined in
[`../config/tiers.json`](../config/tiers.json). The filename must match the value
in that file — e.g. `tier1.jpg`, `flagship.jpg`.

At first boot, pass the tier to apply its wallpaper:

```
powershell -NoProfile -ExecutionPolicy Bypass -File X:\CEC-Autosetep\bootstrap.ps1 -Tier flagship
```

If no `-Tier` is given, `wallpaper.defaultTier` in `config/tweaks.json` is used
(or the wallpaper step is skipped when neither is set or the image is missing).

These images are **not** shipped in the repo — add your own branded artwork.
Recommended: full-resolution PNG/JPG matching the target display.
