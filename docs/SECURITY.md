# Security — what we protect against, and how

This document describes the L×Box threat model and the concrete protection mechanisms: what we close off, how exactly, and why. The traffic-leak section is covered in the most detail, because it's the least obvious part.

Related specs: [`020 — Security & DPI Bypass`](spec/features/020%20security%20and%20dpi%20bypass/spec.md), [`119 — VPN Mode`](spec/features/119%20vpn-mode/spec.md), [`124 — per-app allowlist`](spec/tasks/124-allowlist-self-package-investigation.md).

---

## Table of contents

1. [Threat model](#1-threat-model)
2. [Traffic leaks out of the tunnel](#2-traffic-leaks-out-of-the-tunnel) — the main part
   - 2.1 [Two matching axes: WHERE vs WHO](#21-two-matching-axes-where-vs-who)
   - 2.2 [`0.0.0.0/0 → reject` — destination-address filter](#22-00000--reject--destination-address-filter)
   - 2.3 [Ownerless traffic: why `curl --interface tun0` bypasses attribution](#23-ownerless-traffic-why-curl---interface-tun0-bypasses-attribution)
   - 2.4 [The "Unknown traffic" rule — socket-owner filter](#24-the-unknown-traffic-rule--socket-owner-filter)
   - 2.5 [Layers: route engine vs connection tracker](#25-layers-route-engine-vs-connection-tracker)
3. [Local attack surface](#3-local-attack-surface)
4. [Secrets on the device](#4-secrets-on-the-device)
5. [Summary table](#5-summary-table)

---

## 1. Threat model

L×Box is a VPN client: it accepts other apps' traffic, wraps it in a tunnel, and sends it to a remote node. Three classes of threat follow from that, and we defend against each:

| Class | Threat | Covered in |
|-------|--------|------------|
| **Traffic leak** | Traffic escapes the tunnel or the routing policy — deanonymization, bypass simply doesn't work | [§2](#2-traffic-leaks-out-of-the-tunnel) |
| **Local surface** | An open local proxy/API that another app on the device could abuse | [§3](#3-local-attack-surface) |
| **Secret theft** | Private keys, API secret, subscription credentials leak out of the app | [§4](#4-secrets-on-the-device) |

---

## 2. Traffic leaks out of the tunnel

### 2.1 Two matching axes: WHERE vs WHO

Every routing rule matches traffic on one of two independent axes:

- **WHERE** (destination) — by the packet's destination: `ip_cidr`, domain, port. The sender doesn't matter.
- **WHO** (source / owner) — by **which app owns the socket**: UID → package_name.

These are different sets, and they must not be conflated. Leak protection is built on both axes, but with different rules.

### 2.2 `0.0.0.0/0 → reject` — destination-address filter

`0.0.0.0/0` is the IP-CIDR for "**any IPv4 destination address**". A rule using it matches traffic on the **WHERE** axis:

```json
{ "ip_cidr": ["0.0.0.0/0"], "action": "reject" }
```

- Matches **all** IPv4 traffic indiscriminately — apps and background processes alike, regardless of owner.
- `reject` = the core drops the packet (RST / ICMP-unreachable, or a silent drop).
- Practically equivalent to `final = reject`, **if** the rule is last and nothing above it matched. The difference:
  - `final` — the fallback for traffic that **matched no rule at all**.
  - `0.0.0.0/0` — an **active** rule: it matches literally everything and short-circuits the chain, preventing rules placed below it from running.

**Purpose:** a kill-switch. "If nothing in the allowlist matched, don't let anything out." Closes leaks on the address axis.

### 2.3 Ownerless traffic: why `curl --interface tun0` bypasses attribution

The normal path for an app's traffic:

```
app socket → VpnService intercept → tun0 → core sees UID → resolves package → rules
```

The core knows the socket's UID → maps it to the `package_name` of an installed app. The traffic is "signed" by its owner.

But a process that binds **directly to the tun0 interface** (`curl --interface tun0`, termux, low-level network tools) bypasses the VpnService interception layer:

```
curl bind(tun0) → writes into tun "from the side" → core: UID = INVALID_UID → package = "" (empty)
```

Why such traffic is called **ownerless**:

- It didn't go through the normal entry point (the VpnService intercept) → the **socket owner can't be resolved** → `INVALID_UID`.
- With an empty UID, the core **can't map** the traffic to any installed app → `package` is the empty string.
- The result is traffic inside the tunnel that is **attributed to nothing**: not the system, not an app from the list — a process that crawled into tun on its own.

**Why it's dangerous:** such traffic can escape the routing policy (e.g. bypass your allowlist / detour) — it's a potential leak channel. It reproduces trivially (`curl --interface tun0 ...`), so this is a real hole, not a theoretical one.

### 2.4 The "Unknown traffic" rule — socket-owner filter

It catches the ownerless traffic from [§2.3](#23-ownerless-traffic-why-curl---interface-tun0-bypasses-attribution) — on the **WHO** axis. The `block_unknown` preset definition ([`wizard_template.json`](../app/assets/wizard_template.json)):

```json
{ "invert": true, "package_name_regex": "^" }
```

How to read it:

- `package_name_regex: "^"` — the `^` regex matches **any** string (including the empty one): "there is some package".
- `invert: true` — flips the condition → the rule catches traffic whose **package is NOT defined** (empty / `INVALID_UID`).

So the rule isolates exactly the traffic that enters the tunnel without attribution to an installed app.

**What to do with it** (the `outbound` var in the preset):

| Value | Behavior |
|-------|----------|
| `reject` (default) | drop — ownerless traffic isn't let out at all |
| `direct` | send it outside the VPN (direct egress, bypassing the tunnel) |

**Why it's needed:**

1. **Close the leak.** A process crawling into tun behind VpnService's back can't exfiltrate traffic past the routing policy.
2. **Tunnel hygiene.** Only legitimate apps' traffic goes through the proxy; everything unattributed is brought under control (drop or direct).
3. **Different axis than §2.2.** A legitimate app with a valid UID and destination `1.2.3.4` is caught by `0.0.0.0/0`, but **not** by "Unknown traffic" — the sets barely overlap.

### 2.5 Layers: route engine vs connection tracker

An important diagnostic caveat. Ownerless `tun0`-bind traffic is matched at the **route layer** (the routing engine sees the packet and its empty attribution), but it is **not visible in the Clash API `/connections`** — that's a different layer (the connection tracker).

Consequences:

- "The rule fired" and "the connection shows up in `/connections`" are **not the same thing**. Don't look for `tun0`-bind traffic in the connection list — it won't be there, neither as `termux` nor as `unknown`.
- To reproduce something visible in `/connections`, you need an **ordinary long-lived curl without binding to tun0**.

More on diagnostic layers — [`DIAGNOSTICS.md`](DIAGNOSTICS.md).

---

## 3. Local attack surface

Threat: another app on the same device abuses our local proxy or API (the class of vulnerabilities seen in mobile VLESS clients).

| Measure | How we defend | Why |
|---------|---------------|-----|
| **TUN-only inbound** | No SOCKS5/HTTP proxy on localhost by default — traffic enters only through TUN | An open local proxy with no auth = any app silently routes through the VPN |
| **Local proxy — auth when non-localhost** | If `proxy_listen` ≠ `127.x` (reachable from the network), auth is forced on | A LAN-reachable proxy with no password is an open relay |
| **Clash API on a random port** | Port from the 49152–65535 range | Makes scanning/brute-forcing a fixed port harder |
| **Clash API secret** | 32 hex, `Random.secure()`, validated on every request | Without a secret any local app could control the core |
| **Clash API localhost-only** | Bound to 127.0.0.1 | Not reachable from the network |
| **Authorization header everywhere** | Every Clash API request carries the secret | No "forgotten" unauthenticated endpoints |
| **VpnService / BootReceiver not exported** | `android:exported="false"` | Third-party apps can't invoke our components |

Source and roadmap — [`020 — Security & DPI Bypass`](spec/features/020%20security%20and%20dpi%20bypass/spec.md).

---

## 4. Secrets on the device

| Secret | How we protect it |
|--------|-------------------|
| **WARP private key** | The X25519 key is generated **on the device** and never leaves it — only the public key is sent to Cloudflare. We don't use third-party generator workers (they hand out a server-generated private key). See [§025 WARP](spec/features/025%20warp%20integration/spec.md). |
| **Clash API secret** | `Random.secure()`, in process memory; never printed to logs. |
| **Subscription credentials** | Roadmap: encrypted storage (Android Keystore), URL masking in the UI — see the roadmap in spec 020. |

---

## 5. Summary table

| Mechanism | Axis / layer | What it catches | Apps affected? |
|-----------|--------------|-----------------|----------------|
| `0.0.0.0/0 → reject` | WHERE (destination IP) | all IPv4 traffic indiscriminately | yes, all |
| `final = reject` | fallback | everything that matched no rule above | yes, unless explicitly described |
| **Unknown traffic** (`block_unknown`) | WHO (socket owner) | traffic with an empty package (`INVALID_UID`) | **no** — ownerless only |
| Random port + secret on Clash API | local surface | unauthorized access to the core | — |
| TUN-only / auth-on-LAN | local surface | other apps using the local proxy | — |
| On-device key gen (WARP) | secrets | private-key leakage | — |

**Key takeaway:** ownerless traffic = entered tun bypassing the VpnService intercept (`curl --interface tun0`, termux bind), the UID doesn't resolve → the package is empty → it's caught **only** by the "Unknown traffic" rule, not by destination rules like `0.0.0.0/0`. So full leak protection needs both axes.
