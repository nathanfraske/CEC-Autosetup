<!-- SPDX-License-Identifier: Apache-2.0 -->

# stress-tools/ — QC load-tool binaries

The stress harness ([`docs/stress-harness.md`](../docs/stress-harness.md),
`tools/Invoke-StressTest.ps1`) looks here for the actual load generators. A
tool whose binary is missing is reported **Unavailable** and its stages are
skipped — the harness never fabricates a command. Drop the binaries in once,
and every stick copy carries them.

Expected layout (matches `config/stress-profiles.json` `tools[].binary`):

```
stress-tools/
  prime95/prime95.exe                     CPU/FPU torture (mersenne.org; free for commercial use)
  memtest_vulkan/memtest_vulkan.exe       VRAM (GpuZelenograd; open)
  diskspd/diskspd.exe                     storage (Microsoft; MIT)
  cec-gpu-thrash/cec-gpu-thrash.exe       our CubeCL burner (built separately; shipped compiled)
  LibreHardwareMonitorLib.dll             telemetry (MPL-2.0) - VALIDATE against the HVCI-on image first
```

Two gates before a tool actually runs:

1. **Binary present** here (per the paths above).
2. **A verified `argsTemplate`** for that tool in
   `config/stress-profiles.json` — the exact CLI, confirmed against the real
   binary. Until it's filled in, the tool reports **NeedsIntegration** rather
   than running a guessed command line. (This is deliberate: "verify, don't
   invent" applies to stress commands too — a wrong flag can mean a
   non-terminating or destructive run.)

Licensing per tool is tracked in `config/stress-profiles.json` (`tools[].license`)
and `docs/stress-harness.md`. Do not commit tool binaries you don't have the
right to redistribute (e.g. Prime95 — pull per-machine from mersenne.org).

`LibreHardwareMonitorLib.dll` loads a WinRing0-lineage kernel driver that
Microsoft's vulnerable-driver blocklist / HVCI can block. Validate the pinned
build on the shop's HVCI-enabled image before relying on telemetry; the
harness degrades to WHEA + tool-exit gating when telemetry is absent.
