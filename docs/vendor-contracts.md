<!-- SPDX-License-Identifier: Apache-2.0 -->

# Vendor contracts

> ⚠️ **These are undocumented, unofficial vendor endpoints and page structures.**
> They were captured from live traffic and **may change or break without
> notice.** Treat this file as ground truth for the implementation, but expect to
> re-capture when a vendor changes their site. Do **not** invent endpoints or
> parameters; if something stops working, surface it as an open item.

**Captured / verified:** 2026-06-18 (original runbook) and re-verified
2026-06-19 (this repo, with recorded fixtures under `tests/fixtures/`).

---

## 1. Hardware detection

```powershell
Get-CimInstance -ClassName Win32_BaseBoard | Select-Object Manufacturer, Product, Version
```

Map `Manufacturer` → provider:

| Manufacturer contains | Provider |
| --- | --- |
| `ASUSTeK` | `asus` |
| `Gigabyte` / `GIGA-BYTE` | `gigabyte` |
| `ASRock` | `asrock` |

`Product` is the model string, e.g. `ROG STRIX Z490-I GAMING`,
`B650 GAMING X AX V2`, `X870E Taichi`.

---

## 2. ASUS — internal JSON API (headless OK ✅)

### Step 1 — resolve model → numeric ProductID

```
GET https://odinapi.asus.com/recent-data/apiv2/PDInfo
    ?SystemCode=asus&WebsiteCode=global
    &SeriesWebPath={series}&ProductWebPath={modelSlug}
```

- `modelSlug` = model lower-cased, non-alphanumerics → hyphens.
- `series` = try slug candidates from the first **3**, then **2**, then **1**
  tokens of `modelSlug`; accept the first that returns a non-null
  `Result.ProductID`.
- `WebsiteCode` **must** be `global`. `us` returns nulls.

### Step 2 — driver list

```
GET https://www.asus.com/support/webapi/ProductV2/GetPDDrivers
    ?pdid={ProductID}&website=global&systemCode=asus&osid={osid}
```

- **Exactly** these four params. Adding empty `model=` / `cpu=` / `LevelTagId=`
  makes it return `Status=FAIL` (`傳入參數不正確`).
- Send header `Content-Type: text/plain`.

### Step 3 — parse

`Result.Obj[]` = categories; each `.Files[]` entry has `Title`, `Version`,
`FileSize`, `ReleaseDate`, `sha256` (often empty), `DownloadUrl.Global`.
Full URL = `https://dlcdnets.asus.com` + `DownloadUrl.Global`. Files within a
category are newest-first.

- **osid:** `52` = Windows 10/11 64-bit on current Intel desktop boards. It is
  **per-board**; if a call returns FAIL or 0 files, try other ids. There is no
  `GetPDOS` on the ProductV2 path — the implementation **probes** the candidate
  list in `config/defaults.json` (`asus.osidCandidates`) and keeps whichever
  returns the most files.

**Known-good vector (re-verified 2026-06-19):** model `ROG STRIX Z490-I GAMING`
→ series `rog-strix-z490` → **ProductID 14684**; `osid=52` → `Status=SUCCESS`,
`Count=25`. Recorded in `tests/fixtures/asus_pdinfo.json` and
`tests/fixtures/asus_getpddrivers.json`. CDN spot check:
`https://dlcdnets.asus.com/pub/ASUS/mb/03CHIPSET/DRV_MEI_Intel_Cons_TP_W11_64_V2334510_20230920R.zip`
→ HTTP 200, `application/zip`.

**Fallback URL:** `https://www.asus.com/supportonly/{model}/helpdesk_download/`
(verified to return the model's download page).

---

## 3. Gigabyte — server-rendered HTML (headless OK, mind Akamai ✅)

```
GET https://www.gigabyte.com/Motherboard/{slug}/support
```

with a real browser `User-Agent` **and** the `sec-ch-ua*` / `Sec-Fetch-*` /
`Upgrade-Insecure-Requests` headers (see `Get-GigabyteHeaders`). The full driver
table is rendered into the HTML. Extract by regex:

```
https://download.gigabyte.com/FileList/Driver/<file>.zip?v=<md5>   # drivers
https://download.gigabyte.com/FileList/BIOS/<file>.zip?v=<md5>     # BIOS
```

- **Document order = newest first.** Filename shape:
  `mb_driver_<driverId>_<name>_<version>[_<suffix>].zip`. Dedup by `driverId`,
  keep the **first** occurrence (= latest). The `?v=` value is the file's **MD5**.
- `slug` embeds the board revision (e.g. `B650-GAMING-X-AX-V2-rev-10-11-12`).
  **The revision is not exposed by `Win32_BaseBoard`**, and the no-revision slug
  **404s** (verified). The implementation builds a best-effort slug and, when the
  headless fetch fails, falls back to the Gigabyte support page in Chrome.
- `download.gigabyte.com` CDN is open. `www.gigabyte.com` sits behind **Akamai
  Bot Manager**: a single browser-like GET passes, but rapid automated hits get a
  403 challenge (~430-byte body). **Any response under ~50 KB is treated as a
  challenge** (`gigabyte.challengeMinBytes`) and the run falls back.

**Known-good vector (re-verified 2026-06-19):**
`B650-GAMING-X-AX-V2-rev-10-11-12` → **15 unique components** after dedup
(13 numeric `mb_driver_<id>`, one `mb_driver_preinstall_realtek8125bg` LAN
package, one non-`mb_driver` `PreInstall_9.3.2.255` RAID file). Chipset driver
**597** newest = `8.03.25.247` (older `7.12.04.858` is deduped out). Recorded in
`tests/fixtures/gigabyte_support.html`. The chipset zip
`mb_driver_597_chipset_8.03.25.247.zip` → HTTP 200, `application/zip`.

> Note: the original runbook (2026-06-18) reported 19 drivers and a latest
> chipset of `7.12.04.858`. Gigabyte has since refreshed the page; the recorded
> fixture and tests reflect the 2026-06-19 capture. This is expected churn for an
> undocumented page.

---

## 4. ASRock — browser-required, NOT headless ⚠️

- `www.asrock.com` is behind **Incapsula / Imperva**: plain HTTP (any UA,
  including Googlebot) returns a JS challenge stub.
- The product page does **not** server-render the driver/BIOS lists; they load
  via a client-side XHR. (The *Manual* section *is* server-rendered — a red
  herring. Manuals are reachable, drivers are not.)
- ⇒ A headless fetch yields manuals, not drivers. **`SupportsHeadless = $false`.**
- `download.asrock.com` CDN is **open** (verified:
  `https://download.asrock.com/Manual/X870E%20Taichi.pdf` → HTTP 200
  `application/pdf`), so downloads work once URLs are known.

**Behaviour:** fallback-only. Resolves
`https://www.asrock.com/mb/{AMD|Intel}/{Model}/index.asp#Download` (AMD/Intel
chosen from the chipset token) and hands it to the Chrome fallback. Verified for
`X870E Taichi` → `https://www.asrock.com/mb/AMD/X870E%20Taichi/index.asp#Download`.

---

## 5. Install primitives

- **INF packages:** `pnputil /add-driver "<extractDir>\*.inf" /subdirs /install`.
- **EXE installers:** no universal silent switch. Attempt by detected packer:
  - InstallShield → `/s /v"/qn"`
  - NSIS → `/S`
  - Inno Setup → `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`
  - Unknown → **not auto-run** (would hang an unattended boot); flagged for manual.
- **Checksums:** SHA256 when the provider supplies it (ASUS, often empty); MD5
  against the Gigabyte `?v=` value.

## 6. Chrome auto-install (the fallback substrate)

- **Primary:** Google enterprise MSI, silent:
  `https://dl.google.com/tag/s/dl/chrome/install/googlechromestandaloneenterprise64.msi`
  then `msiexec /i <msi> /qn /norestart` (verified HTTP 200, `application/x-msi`).
- **Fallback:** `winget install --id Google.Chrome -e --silent` (if winget present).
- Detect an existing install first (App Paths registry, `%ProgramFiles%` / LocalAppData).

## 7. Apps catalog (peripheral software)

Defined in `config/apps.json`. Install path: **winget** when a package id exists,
otherwise the **Chrome fallback** to the official download page.

| App | winget id | Official page | Match |
| --- | --- | --- | --- |
| SignalRGB | `WhirlwindFX.SignalRgb` (verified) | `https://signalrgb.com/` | RGB peripheral name patterns |
| Thermalright Control Center | *(none)* | `https://www.thermalright.com/support/download/` (HTTP 200) | TR cooler VID:PID + name |

---

## 8. Open items (do not silently resolve)

1. **ASRock driver XHR endpoint** — not captured. Needs a real browser / DevTools
   session (or Claude-in-Chrome) to record. Until then ASRock is fallback-only.
   See `TODO(asrock-xhr)` in `src/providers/Asrock.psm1`.
2. **Per-board ASUS `osid`** — `52` covers current Intel desktop boards;
   AMD/other-OS boards may differ. The probe in `Get-AsusDriverList` mitigates
   this, but the candidate list (`config/defaults.json`) is best-effort.
3. **EXE silent-install coverage** — packer flags are best-effort. Grow the map
   from the real packages the shop encounters.
4. **Thermalright VID:PID list** — the values in `config/apps.json` are
   **community-sourced** from the `thermalright-trcc-linux` project (HID LCD/LED,
   SCSI, bulk controllers). Confirm against official hardware; treat as a starting
   point, not authoritative.
5. **Code signing / SmartScreen** — running an unsigned `bootstrap.ps1` internally
   is fine; sign it if distributed.
6. **Vendor brittleness** — these are undocumented endpoints/markup. Consider a
   network-gated CI canary that flags when a live call starts returning FAIL or a
   challenge, separate from the offline unit suite.
7. **Copyright holder** — `NOTICE` and SPDX headers use "CEC-Autosetep
   contributors". Confirm the exact string before a public release.
