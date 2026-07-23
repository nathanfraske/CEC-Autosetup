<!-- SPDX-License-Identifier: Apache-2.0 -->

# AllMyStuff networking integration — design (proposal)

**Status: DESIGN ONLY** (researched + written 2026-07-23; nothing implemented).
Directive: shop networking rides [AllMyStuff](https://github.com/mrjeeves/AllMyStuff)
directly; first-boot installs it; a designated server anchors the mesh; techs
can "ping" and harness in-progress installs from anywhere on the network.

## What AllMyStuff actually is (verified from the repos, 2026-07-23)

- **A remote-access application over a private P2P mesh** — not a VPN, not an
  IP overlay, not file sync. Remote desktop (H.264), remote shell (`amst
  <machine>` — real PTY, no SSH daemon), shared terminals, clipboard, file
  browse/transfer, hardware inventory. End-to-end encrypted; peers addressed
  by device identity (ed25519) + display name — **no virtual IPs, no mesh
  DNS** a plain HTTP client could use.
- **Rust; one `allmystuff-serve` node per machine** (GUI is a thin client); it
  supervises the **MyOwnMesh** daemon (identity, discovery, WebRTC/ICE
  transport). Windows is first-class: portable zips + MSI + setup EXE with
  `.sha256`/`.minisig` sidecars; `irm https://allmystuff.works/install.ps1 | iex`
  (flags: `-NoGui -NoMesh -NoAmst -DryRun -Prefix`; **no offline mode** — the
  offline path must stage the zips itself). Headless service:
  `allmystuff service install` / `service --system install` (Windows SCM
  supported); `ALLMYSTUFF_CLAIMABLE=1` starts adoptable. Service log:
  `C:\ProgramData\AllMyStuff\logs\allmystuff-serve.log`.
- **Fleets:** owner/manager/member with cryptographically signed membership;
  **claiming is LAN-first and owner-initiated** (mDNS-only rendezvous
  `allmystuff-local-claim-v1`, zero internet needed; public claims off unless
  a device-local toggle + one-time code). **The client never carries an
  enrollment secret.**
- **Sites** = transparent L4 tunnel over the media channel, in-source
  documented as "for light/occasional access, not bulk throughput" → ruled
  out as the driver/BIOS transfer path.
- **MyOwnMesh self-hosting** (docs/SERVICES.md): signaling relay (:4848),
  STUN (:3478), TURN, roster-gated relay — designed to make a **fully
  internet-isolated network** practical. This is the designated-server role.
- **KVM appliances** (NanoKVM-class) join the graph — screen/keyboard with
  the OS down, **BIOS included** — covering the reboot-to-UEFI window.
- **CEC already lives here:** upstream carries `allmystuff-cec-protocol` /
  `allmystuff-cec-consent` (CEC Support: hub-topology help mesh, SupportIds,
  Once/ThreeHours/Forever consent), and `cec-` NanoKVM claim meshes;
  `cec-support-agent` is the engine behind the AllMyStuff brain; the encoder
  fork gives an existing upstream PR relationship.

**Unverified (flagged):** owner-side headless claim CLI (GUI-only today);
serve-side Sites port config; headless per-network signaling config; the
minisign pubkey location; exact `service --system` semantics on Windows.
Phase 0 tests these.

## Architecture

Mesh = **control plane** (presence, remote hands, report shipping). Existing
HTTP mirror = **data plane** (drivers, BIOS, installer zips) — unchanged.

```
                      CEC bench LAN (single trusted segment)
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │  DESIGNATED SERVER (the existing Ubuntu mirror host, e.g. 10.0.0.10)         │
 │  ┌───────────────────────────────────────────────────────────┐               │
 │  │ nginx :8080         /srv/cec-drivers (drivers, BIOS,      │ ◄─── HTTP ─┐  │
 │  │                     + /allmystuff/ pinned release zips)   │            │  │
 │  │ nginx :8080/reports write-only drop box (ledgers/jsonl)   │ ◄────────┐ │  │
 │  │ myownmesh daemon    signaling :4848, STUN :3478, relay    │          │ │  │
 │  │ allmystuff serve    fleet MANAGER node "cec-bench-server" │          │ │  │
 │  │ (phase 2) claim-watcher + reports dashboard               │          │ │  │
 │  └───────────────────────────────────────────────────────────┘          │ │  │
 │        ▲ mesh (encrypted P2P; mDNS + self-hosted signaling)             │ │  │
 │  ┌─────┴──────────────┐  presence("ping"), amst shell,                  │ │  │
 │  │ NEW INSTALL        │  screen console, files plane                    │ │  │
 │  │ firstboot client   │◄───────────────────────┐                        │ │  │
 │  │ allmystuff-serve   │── reports POST ────────┼────────────────────────┘ │  │
 │  │ (member; claimable │── driver/BIOS pulls ───┼──────────────────────────┘  │
 │  │  during bring-up)  │                        │                             │
 │  └────────────────────┘                 ┌──────┴─────────────┐               │
 │  ┌────────────────────┐  UEFI window   │ TECH HARNESS(ES)    │               │
 │  │ NanoKVM (optional) │◄──────────────►│ AllMyStuff desktop  │               │
 │  └────────────────────┘                │ (owner/manager)     │               │
 │                                        └─────────────────────┘               │
 └──────────────────────────────────────────────────────────────────────────────┘
   Nathan = fleet owner · techs/server = managers · new installs = members
```

The mirror does **not** move behind AllMyStuff names: there is no name→IP
surface for `Invoke-WebRequest`/BITS, and Sites is unfit for bulk. A
Sites-mapped mirror is at most a phase-3 last-resort rung ahead of the Chrome
fallback.

## Pipeline placement + degradation

New **stage 1b "networking"** between windows-prep and BIOS (after the
`lan-drivers/` pnputil step in the offline flow — AllMyStuff needs a NIC, not
internet): stage artifacts (USB → mirror → web, hash-verified) → extract →
`allmystuff service --system install` → start with `ALLMYSTUFF_CLAIMABLE=1` →
state marker. Early placement means the machine reappears on the techs' graph
after every one of the pipeline's reboots. Static binaries, no reboot, runs
under the WU hold, idempotent by version pin.

| Failure | Behavior |
| --- | --- |
| Artifacts nowhere + no internet | log `degraded`, skip 1b, pipeline unchanged; retry at end |
| Installed but never claimed | pipeline unaffected; claimable stops after `claimWindowMinutes` |
| Designated server down | mDNS keeps LAN peers visible; driver pulls use existing vendor fallback |
| Reports endpoint unreachable | queue to `%ProgramData%\firstboot\outbox\`, re-ship next boundary |
| Mesh absent entirely | everything works as today — **no install step gates on the mesh** |

Rehearsal gets a `networking` ledger phase (real: artifact/hash/version
checks, service status, TCP/mDNS probes of the server; emulated: install,
service registration, claimable start).

## Config + enrollment (no secrets on the stick)

`defaults.json` gains `networking.allmystuff` (enabled, installFrom order,
pinnedVersion, minisign key, serviceScope, claimable + claimWindowMinutes,
expected owner fingerprint (public), name prefix), `networking.server`
(lanAddress, signaling, stun), `networking.reports` (url, shipOn, outbox).
USB payload gains `payload/allmystuff/` with the pinned zips + sidecars
(incl. the myownmesh daemon zip — the serve zip doesn't bundle it).

Enrollment = AllMyStuff's own claim flow: device mints identity on first
start; tech adopts from the graph (phase 1, one click per build); phase 2
adds a server-side claim-watcher keyed on a two-channel handshake (LAN claim
rendezvous + `/reports` check-in) — needs a headless claim entry point
(upstream ask). Never `ALLMYSTUFF_PUBLIC_CLAIMS`. A stolen stick exposes no
secrets (URLs, names, public keys, public binaries only).

**Ship disposition (DECIDED, per Nathan 2026-07-23):** shipped machines get
the **CEC Support client** — the consent-gated (Once/ThreeHours/Forever)
hub-topology help-desk client from the upstream `allmystuff-cec-protocol` /
`allmystuff-cec-consent` crates — and do NOT remain in the shop fleet. Key
simplification: the shipped machine likely doesn't need full AllMyStuff at
all, just the support client. So the ship-out step is: un-enroll + remove the
fleet node/identity, install + register the CEC Support client. (Exact
package/binary surface for a standalone support client: confirm during phase
0 — today the crates live in the upstream workspace; if no standalone
distribution exists yet, that becomes the first upstream ask.)

## Phases

- **0 — bench pilot, no code:** hand-stand the mesh (server services + one
  tech node + one adopted test machine); kill internet, confirm LAN-only
  claim/console/`amst`; measure footprint. Resolves the unverified items.
- **1 — minimal autosetup:** stage 1b + config + reports POST/outbox +
  rehearsal phase; manual adoption; mirror untouched.
- **2 — server side:** `/reports` hardening + dashboard over collected
  ledgers; claim-watcher; `Get-LibraryBios` answer joins the mirror index;
  weekly artifact refresh next to the library build.
- **3 — mesh-native niceties:** reports over the mesh files plane (HTTP
  fallback stays), Sites-mapped mirror as last resort, NanoKVM bench
  harness, automated ship-disposition.
- **4 — upstream asks:** headless claim CLI / auto-adopt hook, serve-side
  Sites config, documented minisign key.

## Open questions for Nathan

1. ~~Ship disposition~~ **Answered: CEC Support client ships; fleet node
   removed at ship-out.** Remaining sub-question: does a standalone CEC
   Support client distribution exist yet, or is that an upstream build task?
2. Designated server = the existing Ubuntu mirror host? Bench VLAN fully
   internet-isolated, or public reference servers as fallback?
3. Machine naming: order number, serial, tier, tech initials?
4. Is one manual adopt-click per build OK for phase 1, or is auto-claim
   required day one?
5. Confirm the mirror stays plain HTTP for bulk (recommended).
6. Version policy: pin per USB image + weekly server refresh, or enable
   `allmystuff update` on bench machines?
7. NanoKVM harness in scope? How many bench slots?
8. Reports retention/PII policy for the central log store?
9. OK to open upstream issues/PRs for the headless-claim + Sites gaps?
10. Fleet owner of record: your workstation, or a shop-owned offline key with
    your machines as managers?

**Sources:** mrjeeves/AllMyStuff (README, ARCHITECTURE.md, scripts/install.ps1,
node/src/sites.rs, crates/allmystuff-cec-protocol, docs/INTEGRATION-REPORT-2026-07.md,
releases v0.2.45–47) · mrjeeves/MyOwnMesh (README, docs/SERVICES.md,
docs/NETWORK-TYPES.md) · nathanfraske/cec-support-agent ·
nathanfraske/AllMyStuffEncoderFraske · this repo's README + docs.
