<!-- SPDX-License-Identifier: Apache-2.0 -->

# Adding a board vendor (provider)

A provider teaches CEC-Autosetep how to fetch drivers for one motherboard vendor.
Providers are vendor-agnostic to the orchestrator: each exports a factory that
returns a provider object with a fixed shape.

## 1. Create the module

`src/providers/Acme.psm1`:

```powershell
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.psm1')   # no -Force (shared module)

function Resolve-AcmeProduct {
    param([Parameter(Mandatory)][string] $Model)
    # Use Invoke-Http (TLS + retries + browser UA) to resolve the model to an
    # identity object, or return $null if it cannot be resolved.
    return [pscustomobject]@{ Vendor = 'acme'; Model = $Model; <# ...ids... #> }
}

function Get-AcmeDriverList {
    param([Parameter(Mandatory)] $Identity, [int] $Osid = 0)
    # Return an array of uniform entries, or THROW if the list cannot be obtained
    # headlessly (the orchestrator will then fall back to the browser).
    return @(
        [pscustomobject]@{
            Provider = 'acme'; Category = 'Chipset'; Name = 'Chipset'; Version = '1.0'
            Url = 'https://cdn.acme.com/...'; Hash = ''; HashAlg = 'SHA256'
        }
    )
}

function Get-AcmeFallbackUrl {
    param($Identity, [string] $Model)
    return "https://www.acme.com/support/$([uri]::EscapeDataString($Model))"
}

function Get-AcmeProvider {
    [pscustomobject]@{
        Name             = 'acme'
        SupportsHeadless = $true                      # $false => always falls back
        ResolveProduct   = ${function:Resolve-AcmeProduct}
        GetDriverList    = ${function:Get-AcmeDriverList}
        GetFallbackUrl   = ${function:Get-AcmeFallbackUrl}
    }
}

Export-ModuleMember -Function Resolve-AcmeProduct, Get-AcmeDriverList, Get-AcmeFallbackUrl, Get-AcmeProvider
```

### Rules

- **Separate fetching from parsing.** Put the parse in its own exported function
  (`ConvertFrom-AcmeXxx`) that takes raw text, so it can be unit-tested against a
  recorded fixture with no network.
- **Uniform entries.** `GetDriverList` returns objects with at least
  `Category; Name; Version; Url; Hash; HashAlg`.
- **Throw to fall back.** If you can't list headlessly, throw — the orchestrator
  catches it and opens `GetFallbackUrl` in Chrome.
- **Verify, don't invent.** Only use endpoints you have captured from live
  traffic. Document them in `docs/vendor-contracts.md` with the capture date. If
  something is undocumented, leave a clearly marked `TODO` pointing there.

## 2. Register it

`src/providers/Provider.psm1`:

```powershell
$script:Registry = @{
    asus     = @{ Module = 'Asus.psm1';     Factory = 'Get-AsusProvider' }
    gigabyte = @{ Module = 'Gigabyte.psm1'; Factory = 'Get-GigabyteProvider' }
    asrock   = @{ Module = 'Asrock.psm1';   Factory = 'Get-AsrockProvider' }
    acme     = @{ Module = 'Acme.psm1';     Factory = 'Get-AcmeProvider' }   # <-- add
}
```

## 3. Map the manufacturer string

`src/Detect-Hardware.psm1` → `Resolve-Vendor`: add a regex branch that maps the
`Win32_BaseBoard.Manufacturer` string to your provider key.

## 4. Add tests + a fixture

- Record a real response into `tests/fixtures/acme_*.json|html`.
- Add `tests/Acme.Tests.ps1` that imports the module and asserts your parser
  returns the expected entries from the fixture (offline).

## 5. Run the suite

```powershell
Invoke-ScriptAnalyzer -Path ./src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path ./tests
```

Both must be clean (no analyzer errors; all tests green) before opening a PR.

---

## Adding a peripheral app (no code)

To install software for a detected peripheral, add an entry to
`config/apps.json` — no module needed:

```json
{
  "name": "Acme Fan Control",
  "wingetId": "Acme.FanControl",
  "fallbackUrl": "https://acme.com/download",
  "match": { "vidpid": ["1234:5678"], "namePatterns": ["Acme Fan"] }
}
```

`wingetId` installs silently via winget when present; otherwise `fallbackUrl`
opens in Chrome. Match on USB `VID:PID` and/or device-name patterns.
