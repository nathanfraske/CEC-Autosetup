<!-- SPDX-License-Identifier: Apache-2.0 -->

# Contributing

Thanks for helping improve CEC-Autosetep.

## Ground rules

- **Verify, don't invent.** Every vendor endpoint must come from captured live
  traffic, recorded as a fixture under `tests/fixtures/` and documented in
  `docs/vendor-contracts.md` with the capture date. Never guess a URL or
  parameter to make a test pass. If something is undocumented, leave a clearly
  marked `TODO` pointing at `docs/vendor-contracts.md`.
- **Drivers, not BIOS.** The first-boot path never flashes BIOS.
- **Runtime target is Windows PowerShell 5.1+** (in-box on Windows 10/11). Do not
  introduce a dependency that isn't already on a clean Windows image (no Python,
  no PowerShell 7 requirement, no package manager) for the *runtime* path. Dev and
  CI may use PowerShell 7.
- **Offline CI.** The Pester suite must pass with no network — fixtures only.
- **Apache-2.0 + SPDX.** Every source file (`.ps1`, `.psm1`) starts with:
  ```powershell
  # SPDX-License-Identifier: Apache-2.0
  # Copyright 2026 Nathan M. Fraske, Critical Error Computing L.L.C.
  ```

## Workflow

1. Branch from `main`.
2. Make the change. Keep parsing separate from fetching, and hide
   platform-specific calls behind thin, mockable wrappers.
3. Lint and test locally:
   ```powershell
   Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
   Invoke-Pester -Path ./tests
   ```
   The analyzer must report **no errors**; all tests must pass.
4. Open a pull request. CI runs the analyzer and the offline Pester suite on
   `windows-latest`.

## Adding things

- A new board vendor → see [`docs/adding-a-provider.md`](docs/adding-a-provider.md).
- A new peripheral app → add an entry to `config/apps.json` (no code).

## Live smoke tests

Live vendor calls are for local dev and manual smoke tests only — never in the
offline CI suite. When you re-capture a vendor response, update the matching
fixture and the capture date in `docs/vendor-contracts.md`.
