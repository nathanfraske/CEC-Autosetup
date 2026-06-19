<!-- SPDX-License-Identifier: Apache-2.0 -->

# Browser-agent retrieval tasks

These are the data gaps that **cannot be captured headlessly** — they need a real
browser session (e.g. a Claude Chrome agent) with DevTools. Each task says
exactly where to go, what to capture, and where to put it. Capture only what is
listed; do not guess values. Mark each with the capture date.

> Why these need a browser: the vendor `www` hosts are behind Akamai / Incapsula
> and load the data via client-side XHR, so a plain fetch returns a challenge stub
> or a page without the data. See `docs/vendor-contracts.md`.

---

## 1. ASRock — driver-list XHR endpoint  (highest value)

**Go to:** `https://www.asrock.com/mb/AMD/X870E%20Taichi/index.asp#Download`
(any ASRock board page works; this one is the known test vector).

**Do:**
1. Open DevTools → **Network** tab → filter **Fetch/XHR**. Clear it.
2. Click the **Download** / **Driver** tab on the page so the driver list loads.
3. Find the XHR that returns the driver/BIOS list (JSON or XML, not the manuals).

**Capture:**
- Full request **URL** and **method**, all **query params** and any required
  **headers** (especially cookies / tokens / referer).
- A **sample response** body (save as `tests/fixtures/asrock_drivers.<json|xml>`).
- How the response maps to: driver **name, version, category, download URL,
  checksum** (download URLs live on `download.asrock.com`).

**Put it in:** `docs/vendor-contracts.md` (ASRock section — replace the
`OPEN ITEM` note) and implement in `src/providers/Asrock.psm1` (set
`SupportsHeadless = $true`, fill `Get-DriverList`). Reference: the
`TODO(asrock-xhr)` marker in that file.

---

## 2. Gigabyte — `modellist` XHR (full catalog enumeration)

**Go to:** `https://www.gigabyte.com/Motherboard/All-Series`

**Do:**
1. DevTools → **Network** → Fetch/XHR. Scroll / change the chipset filter so more
   boards load.
2. Find the XHR that returns the **model list** (look for `modellist` or similar;
   the static HTML only renders a few boards — the rest come from this call).

**Capture:**
- The request **URL + params** (note any chipset `fid`/page params) and headers.
- The response shape: how to get **model name → support slug (with `-rev-…`) →
  download page** for each board.

**Put it in:** `docs/vendor-contracts.md` (Gigabyte section / open item #5). With
this, `tools/Build-GigabyteMapping.ps1` can be written to populate the Gigabyte
rows of `config/mapping.json`. (Per-board fetch already works headlessly; only
enumeration is blocked.)

---

## 3. MSI — `MS-xxxx` board-code → marketing name

Some MSI boards report a board code (e.g. `MS-7E26`) in SMBIOS instead of the
model name. For **each MSI board the shop images**:

**Go to:** the board's MSI product page (search `msi.com` for the model, or use a
known URL such as `https://www.msi.com/Motherboard/MAG-B650-TOMAHAWK-WIFI`).

**Capture (both printed on the spec/overview page):**
- The **marketing name** (e.g. `MAG B650 TOMAHAWK WIFI`).
- The **board code** `MS-xxxx` (often on the Specification page / support page).

**Put it in:** `config/msi-codes.json` under `codes`, e.g.:
```json
{ "codes": { "MS-7E26": "MAG B650 TOMAHAWK WIFI" } }
```
Only add pairs you actually verified on the page.

---

## 4. Thermalright (and other peripherals) — USB VID:PID

Best captured from real hardware, but a browser can confirm from the **TRCC
installer / INF**:

**Go to:** `https://www.thermalright.com/support/download/` → download the TRCC
package for the cooler in question.

**Capture:** open the driver `.inf`(s) and read the `USB\VID_xxxx&PID_xxxx`
hardware IDs they bind to (or, on a real machine, run
`pwsh -File tools/Get-DeviceIds.ps1 -UsbOnly`).

**Put it in:** `config/apps.json` → the Thermalright entry's `match.vidpid`
list, as `"VVVV:PPPP"` (upper-case hex). The current list is community-sourced;
replace/confirm with verified values.

---

## Notes for the agent

- **Verify, don't invent.** If you cannot capture a value, leave the open item as
  is and report what blocked you — do not fabricate an endpoint or ID.
- Record the **capture date** next to anything you add (the contracts are
  undocumented and drift).
- After updating fixtures/config, the offline test suite
  (`Invoke-Pester -Path ./tests`) and `tools/Test-VendorCanary.ps1` (live) should
  still pass.
