<!-- SPDX-License-Identifier: Apache-2.0 -->

# lan-drivers/ — offline LAN fallback packs

When a first-boot machine has **no internet** (rare on the bench), the BIOS
stage can't reach the vendor. Before giving up to a manual step, the tool
tries to install any driver INFs staged **here** via
`pnputil /add-driver /subdirs /install`, then re-checks connectivity.

Stage the universal wired/wireless packs once and every stick copy carries
them:

```
lan-drivers/
  intel-lan/     Intel Ethernet driver pack (I219/I225/I226 etc.) — extracted, with .inf files
  realtek-lan/   Realtek PCIe GbE/2.5GbE pack (RTL8111/8125) — extracted
  intel-wifi/    (optional) Intel Wi-Fi pack for AX200/AX201/AX210/AX211
```

Rules:

- **Extracted INF packages only** (folders containing `.inf` + `.sys` + `.cat`),
  not setup EXEs. pnputil installs everything under this folder recursively.
- Keep packs current-and-last-gen, same scope as the driver library.
- Empty folder = the offline path becomes the documented manual step
  ("load the LAN driver by hand, then re-run").

Other offline options, in preference order: the LAN driver-library mirror
(`-Mirror`) still works without internet; a known-good USB NIC in the bench
kit (in-box RNDIS/NCM drivers); phone USB tethering. See
[`docs/bios-stage.md`](../docs/bios-stage.md).
