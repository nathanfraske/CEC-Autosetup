<!-- SPDX-License-Identifier: Apache-2.0 -->

# QC stress harness — design + build-vs-buy (researched 2026-07-23)

Goal: OCCT-class stress coverage (CPU / RAM / GPU / storage / combined POWER
test) with verbose, device-ID'd logging, fast enough to cross-correlate with
the shop's external 1kHz+ power-monitoring rig.

## Recommendation: hybrid

- **Buy** the certified, customer-facing stress/report layer: **OCCT Pro**
  (professional use + CSV export; **Enterprise** adds the command-line
  edition — get a quote) or PassMark BurnInTest as the alternative. FurMark
  commercial license is cheap if FurMark specifically is wanted.
- **Build** the unattended gating layer from license-clean parts, orchestrated
  CoreCycler-style in PowerShell 5.1:
  - CPU: **Prime95** (free for commercial use; pull from mersenne.org, don't
    bundle) — plus optional custom AVX FMA burner later.
  - VRAM: **memtest_vulkan** (open, Windows, NVIDIA/AMD/Intel) — adopt
    immediately; already used by builders/repair shops.
  - Storage: **diskspd** (MIT) and/or **fio** (GPL-2.0, use unrestricted).
  - RAM (Windows-stage): MemTest86 Pro/Site for automated boot-stage gate, or
    MemTest86+ (GPL). TestMem5/anta777: license-unverified — substitute Karhu
    (paid, commercial-friendly) if wanted.
  - Telemetry: **LibreHardwareMonitorLib** (MPL-2.0, loads into PS 5.1 via
    `Add-Type`).
  - **WHEA watcher**: `Get-WinEvent` on `Microsoft-Windows-WHEA-Logger`
    scoped to the stress window. Gate: **zero WHEA events of any severity =
    PASS**; corrected errors (ID 19 CPU, ID 17 PCIe) = margin failure even
    without a crash. Archive Kernel-WHEA + LiveKernelReports at QC end.
- **Skipped as license-unverifiable**: y-cruncher, Linpack Xtreme commercial
  terms (omittable without capability loss; Intel's own oneMKL benchmark
  binaries under ISSL are the clean Linpack route).

**Prior art to copy:** CoreCycler (sp00n) — PowerShell orchestrator driving
external stress EXEs with output parsing, per-core affinity, error detection,
logging. That is the architecture for our harness.

## Telemetry + the 1kHz correlation design

- Realistic LibreHardwareMonitor polling: **1–2 Hz full sweep** (SuperIO/EC
  reads are tens-to-hundreds of ms), **5–10 Hz for CPU/GPU-only subsets**.
  Software sensors cannot do 1kHz — and don't need to:
- **The harness's job for the external rig is markers, not bandwidth**: every
  load transition (profile start/stop/step, per-core moves, TDR events) gets a
  QPC-timestamped JSONL marker at ms precision, so the 1kHz analog capture is
  aligned externally. Sensor sweeps ride the same JSONL between markers.
- Reports are **device-ID'd** (`Win32_ComputerSystemProduct.UUID` + board
  serial + order number) and ship over the reports channel from
  [`allmystuff-networking.md`](allmystuff-networking.md) for retrieval.
- **Hard caveat:** LibreHardwareMonitor loads a WinRing0-lineage kernel driver
  — Microsoft's vulnerable-driver blocklist / **HVCI can block older builds**,
  which collides with the stage-4 "HVCI on" posture. Validate the current
  release on an HVCI-enabled image and pin it before the sensor layer ships.
- Consumer-board sensor gaps are real: per-phase VRM temps mostly not exposed;
  ASUS EC partially covered; new SuperIO revisions lag support by months.
  Treat VRM thermals as best-effort, never a gate.

## GPU thrasher: custom, in Rust (CubeCL) — DECIDED direction

No maintained open-source Windows GPU power-virus exists (gpu-burn is
CUDA/Linux; FurMark/Kombustor/OCCT are closed) — and shop experience says
steady 100% load (even FurMark) **misses real bugs anyway**. The plan is a
custom thrasher, because the point is *load choreography*, not just wattage:

- **Stack:** Rust + **CubeCL** (the Burn-ecosystem GPU compute language;
  wgpu/CUDA/ROCm backends → one binary covers NVIDIA/AMD/Intel), shipped as a
  **compiled binary in the repo/USB payload** (fits the shop's existing Rust
  competence: cec-support-agent, AllMyStuff). Verify CubeCL's current backend
  maturity on all three vendors at project start; wgpu/Vulkan compute is the
  safe floor.
- **Load-shape engine — the actual differentiator:** scripted scenarios, not
  a fixed burn: steady FMA saturation; **bursty duty-cycled loads**
  (ms-scale on/off square waves that hammer VRM transient response and clock
  ramping); load sweeps; VRAM thrash patterns; and **cross-load choreography**
  with the CPU side (CPU pinned while the GPU sees burst trains — the
  worst-case transients that kill marginal builds in games but pass
  steady-state tests). Scenario files define the choreography so QC can grow
  a library of known-killer patterns.
- **Markers built in:** the binary itself emits the QPC-timestamped
  load-transition markers (every step edge) into the harness JSONL, so burst
  edges align with the external 1kHz power capture with no inference.
- **Wattage test mode (closed-loop power targeting):** the thrasher reads GPU
  board power at 1–10 Hz (NVML on NVIDIA, ADLX on AMD, LHM fallback) and
  servos the load mix — dispatch occupancy, FMA:memory-traffic ratio, duty
  cycle — to hold a commanded power profile: hold-at-N-watts, staircase
  steps, ramps, sine sweeps. That is OCCT's power test, but scriptable and
  marker-correlated. **Self-optimizing:** a calibration pass per GPU model
  auto-searches the load-mix space for the max-sustained-power operating
  point and stores the per-model profile (device-ID'd, shipped back over the
  reports channel) so subsequent QC runs start already tuned. Note the
  control-loop reality: software power servo reacts at ~100ms-1s scale —
  fast enough to HOLD wattage targets; the ms-scale transient attacks come
  from the open-loop burst scenarios above, with the 1kHz rig as the judge.
- Compute results checksummed (error detection, not just crash detection);
  TDR handling; per-vendor telemetry hooks.

Estimate stands at ~1–3 weeks for a v1 plus per-GPU-generation smoke tests.
memtest_vulkan is still adopted immediately for the VRAM stage; a licensed
OCCT/BurnInTest remains optional as the certified customer-facing report
layer, not the QC engine.

## Licensing table (shop = commercial use)

| Tool | Terms | Verdict |
|---|---|---|
| OCCT | Free = personal only; **Pro** = professional use + CSV (company-wide, unlimited machines); **Enterprise** = CLI + schedules + report compare; pricing on request | Buy candidate (CLI needs Enterprise) |
| Prime95 | Free incl. commercial; no explicit redistribution grant → download per-machine | Use freely |
| FurMark/2 | Freeware **excluding** commercial; Geeks3D commercial license exists; v2 has proper CLI | Cheap buy if wanted |
| y-cruncher / Linpack Xtreme / TestMem5 | Commercial terms unpublished | Flagged — omit or get written OK |
| MemTest86 | Free edition OK for business; automation (config/report/PXE) is Pro/Site | Buy Pro/Site for automated gate, or MemTest86+ (GPL) |
| diskspd / fio | MIT / GPL-2.0 | Use freely |
| memtest_vulkan | Open (GpuZelenograd) | Adopt now |
| LibreHardwareMonitorLib | MPL-2.0 | Use freely (see HVCI caveat) |

## Phasing

1. **Phase 1 (days):** orchestrator + profiles (CPU=Prime95, storage=diskspd,
   VRAM=memtest_vulkan), LHM telemetry at 1–10 Hz, WHEA watcher,
   QPC-timestamped markers, device-ID'd JSONL reports.
2. **Phase 2:** OCCT/BurnInTest licensed layer wrapped for the certified
   customer-facing report; combined power profile (CPU+GPU simultaneous).
3. **Phase 3:** custom Vulkan burner (if warranted), RAM pattern tester,
   per-core cycling (CoreCycler-style), report dashboard on the designated
   server.

## Sources (key)

ocbase.com/purchase (+ Enterprise launch coverage) · mersenne.org/legal ·
Geeks3D forum topic 8070 + shop · memtest86.com license page · memtest.org ·
Intel oneMKL license FAQ · github: microsoft/diskspd, GpuZelenograd/
memtest_vulkan, sp00n/corecycler, LibreHardwareMonitor (LICENSE, NuGet),
Lifailon/PowerShell.HardwareMonitor · WHEA Event-19 threads (tomshardware,
overclock.net).
