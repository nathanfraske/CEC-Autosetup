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
- Returns `Result.ProductID`, `Result.Pdhashedid` (string, newer boards only),
  and `Result.Name` (canonical catalog name; may be null on older boards).

### Step 2 — driver list (version-agnostic, keyed on model name)

```
GET https://www.asus.com/support/webapi/ProductV2/GetPDDrivers
    ?website=global&model={name}&pdhashedid={hash-or-empty}&cpu=&osid={osid}
```

- Send header `Content-Type: text/plain`.
- **CRITICAL CORRECTION over the original runbook.** Do **not** send `pdid`. The
  legacy `pdid={ProductID}&systemCode=asus` shape works only for older products;
  newer boards (Z890 / X870E and current gen) throw
  `Input string was not in a correct format` when `pdid` is present. The
  model-keyed call works across all generations. Verified 2026-06-19:
  - Z890 model-keyed → `SUCCESS`, 59 files; Z890 legacy `pdid` → `FAIL "Input
    string was not in a correct format."`
  - Z490 model-keyed → `SUCCESS`, 25 files (same as legacy).
- `pdhashedid`: pass `Result.Pdhashedid` from PDInfo when present, empty
  otherwise. The endpoint falls back to model-name resolution, so an empty hash on
  an older board still returns its drivers. Because of this, `Resolve-Product`
  always returns an identity (drivers resolve from the name alone).

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

**Enumeration — one call returns the whole catalog:**
```
GET https://odinapi.asus.com/recent-data/apiv2/SeriesFilterResult
    ?SystemCode=asus&WebsiteCode=global
    &ProductLevel1Code=Motherboards-Components&ProductLevel2Code=Motherboards
```
`Result.ProductList` = **897 boards** (verified 2026-06-19). Per entry:
`SalesModelName`/`CategoryName` (model), `ProductURL` (append
`helpdesk_download/` for the download page), `ProductHashedID`, `RealProductID`.
ROG boards carry `rog.asus.com` URLs, mainstream `www.asus.com`. Used by
`tools/Build-AsusMapping.ps1` to regenerate ASUS mapping rows.

**Known-good vectors (re-verified 2026-06-19):**
- `ROG STRIX Z490-I GAMING` → ProductID **14684**; model-keyed `osid=52` →
  `SUCCESS`, **25** files. Recorded in `tests/fixtures/asus_pdinfo.json` +
  `tests/fixtures/asus_getpddrivers.json`. CDN spot check:
  `…/mb/03CHIPSET/DRV_MEI_Intel_Cons_TP_W11_64_V2334510_20230920R.zip` → HTTP 200.
- `TUF GAMING Z890-PLUS WIFI` → ProductID 29693, Pdhashedid `snrwk900sg1paule`;
  model-keyed `osid=52` → `SUCCESS`, **59** files. PDInfo recorded in
  `tests/fixtures/asus_pdinfo_z890.json`.

**Fallback URL:** `https://www.asus.com/supportonly/{model}/helpdesk_download/`
(verified to return the model's download page).

---

## MSI — internal JSON API, keyed on model slug (headless OK, mind Akamai) ✅

A clean JSON API like ASUS, but keyed on the **model slug** (model name with
non-alphanumerics → hyphens, case preserved, e.g. `MAG B650 TOMAHAWK WIFI` →
`MAG-B650-TOMAHAWK-WIFI`). The slug is constructible from the name, so no catalog
lookup is strictly required. All endpoints under
`https://www.msi.com/api/v1/product/support/`, keyed on `product={slug}`:

```
GET …/os?product={slug}&type=driver               # -> result[] of OS strings
GET …/panel?product={slug}&type=driver&os=Win11 64 # -> result.downloads
```

- **OS values are exact strings** (`"Win11 64"`, `"Win10 64"`), not "Windows 11".
  Default to `Win11 64`, fall back to `Win10 64`. The `os` query param is
  **required** or `downloads` comes back `false`.
- **`panel` parse:** `result.downloads` is a dict whose keys are category names
  (`System & Chipset Drivers`, `LAN Drivers`, …), each a list, **plus metadata
  keys `type_title` and `os` which must be skipped.** Each entry:
  `download_title`, `download_version`, `download_release`, `download_size`,
  `download_sha256` (format `SHA-256:<hex>` with a trailing `<br>` — extract the
  64-hex), `download_url`, `os[]`.
- **Headless: yes, but Akamai.** `www.msi.com` returns `Access Denied` to bare
  requests; passes with a full browser header set **+ a `Referer` of the product
  support page**. A sudden `Access Denied` mid-run is throttling, not a contract
  change — back off.
- **CDN:** `download.msi.com` 302-redirects to a numbered mirror
  (`download-2.msi.com`); follow redirects. SHA-256 is present on every file.
- Do **not** pass `product_id` (500s). Key on the slug.

**Known-good vector (verified 2026-06-19):** `MAG B650 TOMAHAWK WIFI` (slug
`MAG-B650-TOMAHAWK-WIFI`), `type=driver`, `os=Win11 64` → System & Chipset = AMD
Chipset Driver 7.12.04.858; `download.msi.com/dvr_exe/mb/amd_chipset_drivers_am4_am5.zip`
→ 302 → `download-2.msi.com`, HTTP 200. Recorded in `tests/fixtures/msi_os.json`
and `tests/fixtures/msi_panel.json`.

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

## 4. ASRock — contract captured, but browser-required ⚠️

**Contract (captured 2026-06-19, browser):** the Download tab is **not** a JSON
XHR — it loads a static HTML fragment from the board's own directory via jQuery
`.load()`:

```
GET https://www.asrock.com/mb/<Brand>/<Model>/Download.html
```
(siblings `BIOS.html`, `Manual.html`). Rows: a description `"<name> ver:<version>"`,
a `SHA256:<hex>` line, and Global/China links on `download.asrock.com`:
```
https://download.asrock.com/Drivers/All/<Category>/<Name>(v<version>).zip
```
`Category`, `Name`, and `Version` are derivable from that URL alone
(`ConvertFrom-AsrockDownloadHtml` parses it; verified against the captured Realtek
audio row → `…/Drivers/All/Audio/Realtek_Audio(v2422_UAD_WHQL).zip`).

**Headless blocker (verified):** `www.asrock.com` is behind **Incapsula**, which
serves a ~212-byte JS-challenge stub (containing `_Incapsula_Resource`) to
non-browser clients — **even when carrying the board page's cookies**, because
clearance requires executing the challenge JS. A cookie-jar `curl`/`Invoke-WebRequest`
of both the board page and `Download.html` returned the stub (re-verified here
2026-06-19). So plain PowerShell cannot fetch the fragment ⇒ **`SupportsHeadless
= $false`**, ASRock routes to the Chrome fallback
(`…/mb/{AMD|Intel}/{Model}/index.asp#Download`).

**Ready to flip:** the parser, the `Download.html` URL builder, the Incapsula
challenge guard, and `Get-DriverList` (fetch → detect-challenge → parse) are all
implemented and tested. Flip `SupportsHeadless` to `$true` the day a JS-capable
fetch supplies the fragment/cookies (the tool driving headless Chrome, or a
browser agent). `download.asrock.com` CDN is open (manual PDF → HTTP 200).

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
| NVIDIA App | `NVIDIA.app` (verified) | `https://www.nvidia.com/en-us/software/nvidia-app/` | GPU vendor `nvidia` |
| AMD Software: Adrenalin Edition | *(none)* | `https://www.amd.com/en/support/download/drivers.html` (HTTP 200) | GPU vendor `amd` |
| Intel Arc / Graphics Software | *(none)* | `https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html` | GPU vendor `intel` |
| SignalRGB | `WhirlwindFX.SignalRgb` (verified) | `https://signalrgb.com/` | RGB peripheral name patterns |
| Thermalright Control Center | *(none)* | `https://www.thermalright.com/support/download/` (HTTP 200) | TR cooler VID:PID + name |

---

## GPU drivers (vendor-app approach)

GPUs are detected from `Win32_VideoController`'s PCI `VEN_` id (`10DE` = NVIDIA,
`1002` = AMD, `8086` = Intel; `src/Detect-Gpu.psm1`). **Every detected GPU vendor
is handled** — no iGPU-vs-dGPU classification — so mixed setups (Intel iGPU +
NVIDIA dGPU, AMD iGPU + Intel Arc, etc.) each get their vendor's driver.

**NVIDIA — fully unattended (headless, built; `src/Install-Gpu.psm1`):**
1. `https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3` → all
   products; each `LookupValue` has `Name`, `pfid` (Value), series `psid`
   (ParentID). Match the `Win32_VideoController` name by **normalized exact match**
   (strip a leading `NVIDIA`, lower-case, collapse punctuation) so `RTX 4090` does
   not collide with `RTX 4090 D` / `Laptop GPU`.
2. `https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid={psid}&pfid={pfid}&osID=57&languageCode=1033&isWHQL=1&dch=1`
   → `IDS[0].downloadInfo.{Version,DownloadURL}` — a `.exe` on
   `us.download.nvidia.com`. `osID=57` = Windows 11 64-bit (`config/defaults.json
   nvidia.osId`).
3. Download + **silent install** `<driver>.exe -s -noreboot`.
   The **NVIDIA App** (winget `NVIDIA.app`) is also installed (apps phase) for
   setup/management. If a card does not resolve in the catalog, the headless step
   is skipped and the NVIDIA App handles the driver.
   *Known-good (verified 2026-06-19): `NVIDIA GeForce RTX 4090` → psid 127 /
   pfid 995 → osID 57 → GeForce Game Ready Driver 610.62.*

**AMD / Intel — unattended *given an installer*.** Neither has a clean headless
driver-lookup API (download sites are bot-walled), so *discovery* of the latest
installer can't be automated headlessly. The **silent install is** automatable
once you have the file:

- **AMD** Adrenalin: `Setup.exe -INSTALL` (AMD Radeon Software Command-Line guide;
  `-boot` for auto-reboot). The installer **is** the driver package.
- **Intel** graphics (DCH): `Installer.exe -s` (`--overwrite` to force).

`Install-GpuVendorDriver` downloads + silent-installs given an installer URL.
Provide that URL one of two ways: pin it in `config/defaults.json`
(`amd.url` / `intel.url`), or **stage the installer in the driver library**
(`gpu-installers/<vendor>/` → published to `gpu/<vendor>/` + `index.json`
`gpuInstallers`), so clients pull + silent-install it over the LAN. With neither,
AMD/Intel fall back to installing the **vendor app** (Adrenalin / Intel Arc) via
the apps phase, which carries the driver. A browser agent can refresh the
installer URLs on a schedule (discovery is the only bot-walled part).

---

## Mapping & naming reconciliation

The SMBIOS `Win32_BaseBoard.Product` string is the input; the vendor's
catalog/slug name is what the fetch needs, and they do not always match (ASUS
suffix drift, Gigabyte rev-slugs, MSI `MS-xxxx` board codes). The lookup layer
(`src/Mapping.psm1`):

1. Normalizes (case, punctuation, drops a trailing parenthetical board code).
2. Looks up `config/mapping.json` (shipped seed) overlaid by
   `%ProgramData%\firstboot\mapping.cache.json` (runtime self-heal) — exact, then
   a conservative containment fuzzy match.
3. On a hit, supplies the catalog model and the vendor slug (notably the
   Gigabyte rev-slug, which is **not** derivable from SMBIOS).
4. On a miss, resolves live (ASUS/MSI from the name/slug) and writes the result
   back so the table self-heals.

MSI `MS-xxxx` codes map via `config/msi-codes.json` (verified data only). ASUS
rows are regenerable from the 897-board catalog via `tools/Build-AsusMapping.ps1`;
the shipped seed is kept small for portability.

**Populate strategy (lean + self-heal + scheduled refresh):**
- **ASUS** — fully crawlable; `tools/Build-AsusMapping.ps1` (one call → 897 boards).
- **Self-heal** — every live resolve writes back to the runtime cache, so the
  long tail fills in as machines are imaged.
- **Refresh + canary** — `.github/workflows/refresh-mapping.yml` (network-gated,
  weekly + manual) runs `tools/Test-VendorCanary.ps1` against each vendor's
  known-good vector and regenerates the ASUS catalog into a downloadable artifact
  (the committed seed stays lean). Separate from the offline `ci.yml`.
- **Gigabyte** — `tools/Build-GigabyteMapping.ps1` enumerates the catalog via the
  `modellist` API (captured 2026-06-19) → `model → rev-slug` rows. Akamai blocks
  datacenter IPs, so run from a normal network / the scheduled job.
- **Peripherals** — `tools/Get-DeviceIds.ps1` dumps a machine's USB VID:PIDs to
  capture entries for `config/apps.json`.
- **Browser-only** — the ASRock driver fragment (Incapsula JS challenge) and the
  HYTE/Thermalright USB VID:PIDs still need a browser or real hardware.

---

## Open items (do not silently resolve)

1. **ASRock headless fetch** — contract **captured** (the `Download.html` fragment;
   parser implemented). Remaining blocker: Incapsula's JS challenge stops a
   non-browser fetch (re-verified 2026-06-19), so `SupportsHeadless=$false` until a
   JS-capable fetch (headless Chrome / browser agent) supplies the fragment. See
   the ASRock section above and `src/providers/Asrock.psm1`.
2. **Per-board ASUS `osid`** — `52` covers current Intel/AMD desktop boards;
   exotic boards or other OSes may differ. The probe in `Get-AsusDriverList`
   mitigates this, but the candidate list (`config/defaults.json`) is best-effort.
3. **MSI / Gigabyte Akamai throttling** — both `www` hosts are Akamai-fronted.
   Keep request pacing conservative; treat a sudden `Access Denied` as throttling.
4. **MSI `MS-xxxx` code map** — the board code is the BIOS-filename prefix on the
   model's BIOS panel (`type=bios`); e.g. files `7D75v1x` ⇒ `MS-7D75`. Verified
   2026-06-19: **MS-7D75 = MAG B650 TOMAHAWK WIFI** (seeded in
   `config/msi-codes.json`; corrects the runbook's `MS-7E26` placeholder, which is
   a different board). Add more pairs as the shop encounters coded boards.
5. **Gigabyte enumeration** — **captured**: `POST .../GetConsumerListPageModelList/Motherboard`
   (`{page,fid:"",order:0,length:50}`) returns `data.modelList[]` (`productName`,
   `productUrl` with `-rev-…`) + `data.totalRow`; `data.perPage` is 16.
   `tools/Build-GigabyteMapping.ps1` pages through it to populate the Gigabyte
   mapping rows. Akamai blocks datacenter IPs, so run from a normal network.
6. **EXE silent-install coverage** — packer flags are best-effort. Grow the map
   from the real packages the shop encounters.
7. **Thermalright VID:PID list** — the values in `config/apps.json` are
   **community-sourced** from the `thermalright-trcc-linux` project (HID LCD/LED,
   SCSI, bulk controllers). Confirm against official hardware (e.g. via
   `tools/Get-DeviceIds.ps1` on a real build); treat as a starting point.
8. **Code signing / SmartScreen** — running an unsigned `bootstrap.ps1` internally
   is fine; sign it if distributed.
9. **Vendor brittleness** — these are undocumented endpoints/markup. The
   network-gated canary (`tools/Test-VendorCanary.ps1`, run by
   `refresh-mapping.yml`) flags when a live call starts returning FAIL/challenge,
   separate from the offline unit suite.
10. **Copyright holder** — resolved: `NOTICE` and SPDX headers use
    "Nathan M. Fraske, Critical Error Computing L.L.C." (2026-06-19).
