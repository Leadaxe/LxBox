[English](path-mtu.md) · [Русский](path-mtu.ru.md)

# Path MTU — the largest packet the user's network lets through

Measured on the direct node, past the tunnel and without the core.

| Field | Value |
|-------|-------|
| Feature | [013-DIAGNOSTICS](../FEATURE.md) |
| Promises | P25 |
| State | ✅ written with the code, 2026-11-10 |

## What it does

Answers "everything hangs" on a network that silently drops large packets: an
operator black hole around 1280–1340 bytes kills WireGuard / AWG / MASQUE
tunnels with the default MTU. The **Path MTU** island on the Diagnostics tab of
the `direct` node sends ping packets of different sizes with "do not fragment"
over the physical network and shows the largest IP packet that got an answer,
plus the MTU to set on tunnel nodes.

## Parameters

| Parameter | Value |
|-----------|-------|
| Target | field, default `8.8.8.8`; an IP or a host name (resolved by the physical network's DNS, not the tunnel's) |
| Upper bound | the MTU of the physical interface; 1500 when the system does not report it |
| Lower floor | 576 (IPv4 target) / 1280 (IPv6 target) |
| Reachability probe | 84 bytes |
| Attempts per size | up to 2, 1 s timeout each; "does not fit the interface" is not repeated |

## Inputs / Outputs

**Inputs:** the Target field, the Run / Stop button; the physical network
(interface, transport, MTU).

**Outputs:**

| What is visible | When |
|-----------------|------|
| "Interface  wlan0 (Wi-Fi) · MTU 1500" | at once, before a run |
| "Path MTU N" + "Network drops packets above N" | something below the interface MTU is cut |
| "Path MTU N" + "Nothing is cut on the way" | the interface MTU itself passed |
| "Recommended tunnel MTU": WireGuard / AWG ≤ N − 60 (IPv6 target: − 80), MASQUE ≤ N − 51 | with a result |
| "Path MTU below 576/1280" | even the floor size did not pass |
| "Target does not answer ping" | the small packet got no answer twice; no numbers, no recommendation |
| "No network" | no physical network |
| "Probes (N)", collapsed: "size · ok 38 ms / no reply / does not fit the interface" | after the first probe; filled as probes arrive |
| Copy button | copies the whole report as text, probes included |

Debug API: `POST /action/pathmtu[?target=]` — the same search, JSON answer
([reference](../../../../api/debug-api-reference.md)).

## Rules and invariants

- The result is the size of the **whole IP packet**, not the ping payload.
- Works with the VPN on and off: probes go through an ICMP socket bound to the
  physical network (and protected from the tunnel when the VPN is up); the
  system `ping` is not used.
- The search: the small packet, then the interface MTU (passed — done), then
  the floor, then a binary search to a difference of 1.
- A reply of any length counts (some servers cut the echo).
- Stop takes effect between probes; leaving the screen stops the run.
- Only on the `direct` node: ICMP does not go through proxy nodes.

## Boundaries

- A round trip: a reply of the same size has to come back.
- The path to the target may differ from the path to a node's server — the
  Target field is for that.
- Always-on VPN with "Block connections without VPN" may forbid bypassing the
  tunnel: the result is "Target does not answer ping".
- Measuring through proxy nodes or chain hops — not done.
- The HTTP check above it — [node diagnostics](../../009-NODE_HEALTH/FUNCTIONS/node-diagnostics.md).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [725](../../../tasks/725-path-mtu-direct-diagnostics.md) | In progress | Path MTU island on the direct node, Debug API `/action/pathmtu` |
