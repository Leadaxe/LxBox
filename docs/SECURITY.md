# Security: threats and defences

This document lists the threats L×Box defends against and, for each, names the defence, its defaults and the reason behind it. Traffic leaks (§2) get the most detail: their mechanics are the least obvious.

> Русская версия: [SECURITY.ru.md](SECURITY.ru.md)

Related specs: [`020 — Security & DPI Bypass`](spec/tasks/020F-security-and-dpi-bypass/spec.md), [`119 — VPN Mode`](spec/tasks/119F-vpn-mode/spec.md), [`124 — per-app allowlist`](spec/tasks/124-allowlist-self-package-investigation.md).

---

## Table of contents

1. [Threat model](#1-threat-model)
2. [Traffic leaks out of the tunnel](#2-traffic-leaks-out-of-the-tunnel)
   - 2.1 [Two matching axes: WHERE vs WHO](#21-two-matching-axes-where-vs-who)
   - 2.2 [`0.0.0.0/0 → reject` — destination-address filter](#22-00000--reject--destination-address-filter)
   - 2.3 [Ownerless traffic: why `curl --interface tun0` bypasses attribution](#23-ownerless-traffic-why-curl---interface-tun0-bypasses-attribution)
   - 2.4 [The "Unknown traffic" rule — socket-owner filter](#24-the-unknown-traffic-rule--socket-owner-filter)
   - 2.5 [Layers: route engine vs connection journal](#25-layers-route-engine-vs-connection-journal)
3. [Local attack surface](#3-local-attack-surface)
4. [Inbound connections from client tunnels](#4-inbound-connections-from-client-tunnels)
5. [Secrets on the device](#5-secrets-on-the-device)
6. [Summary table](#6-summary-table)

---

## 1. Threat model

L×Box is a VPN client: it accepts other apps' traffic, wraps it in a tunnel and sends it to a remote node. Four classes of threat follow from that:

| Class | Threat | Covered in |
|-------|--------|------------|
| **Traffic leak** | Traffic escapes the tunnel or the routing rules: the destination sees the user's IP, the rules do not apply | [§2](#2-traffic-leaks-out-of-the-tunnel) |
| **Local surface** | Another app on the device uses the client's open local proxy or API | [§3](#3-local-attack-surface) |
| **Tunnel ingress** | The server or a peer of a client tunnel (WireGuard, OpenVPN, OpenConnect) opens a connection inward: to the device, into the LAN, or out to the internet from the user's IP | [§4](#4-inbound-connections-from-client-tunnels) |
| **Secret theft** | Private keys, device tokens, subscription credentials leak out of the app or out of a backup | [§5](#5-secrets-on-the-device) |

---

## 2. Traffic leaks out of the tunnel

### 2.1 Two matching axes: WHERE vs WHO

A routing rule matches traffic on one of two independent axes:

- **WHERE** (destination) — by destination: `ip_cidr`, domain, port. The sender does not matter.
- **WHO** (source / owner) — by the app that owns the socket: UID → `package_name`.

One axis does not replace the other: a destination rule does not see the owner, an owner rule does not see the destination. Leak protection needs both.

### 2.2 `0.0.0.0/0 → reject` — destination-address filter

`0.0.0.0/0` is the CIDR that matches any IPv4 destination. A rule with it works on the WHERE axis:

```json
{ "ip_cidr": ["0.0.0.0/0"], "action": "reject" }
```

- It matches all IPv4 traffic: apps and background processes, whoever the owner.
- `reject` — the core answers with RST or ICMP unreachable; `drop` — it discards the packet silently.

How it differs from `final = reject`:

| | When it fires | Rules below |
|---|---|---|
| `final = reject` | traffic matched no rule | all checked before it |
| `0.0.0.0/0 → reject` | at its place in the list, for any IPv4 | never fire |

Placed last, such a rule is a kill-switch: traffic that matched no rule above does not go out. That closes leaks on the WHERE axis.

### 2.3 Ownerless traffic: why `curl --interface tun0` bypasses attribution

An app's traffic normally goes like this:

```
app socket → VpnService intercept → tun0 → kernel sees the UID → finds the package → rules
```

The kernel knows the socket's UID and maps it to an installed app's `package_name`.

A process that binds its socket to the `tun0` interface itself (`curl --interface tun0`, Termux, network utilities) skips the VpnService intercept:

```
curl bind(tun0) → writes straight into tun → kernel: UID = INVALID_UID → package = "" (empty)
```

Such traffic is called ownerless:

- it did not pass the VpnService intercept, so the socket owner is not resolved: `INVALID_UID`;
- without a UID the kernel maps the traffic to no installed app: `package` is an empty string;
- the tunnel carries traffic attributed neither to the system nor to any listed app.

The threat: an app excluded from the VPN binds a socket to `tun0`, and its traffic goes through the tunnel. That way it learns the VPN server's address and sees that the VPN is on. The allowlist and detour do not apply to this traffic: it has no owner for them to compare. One command reproduces it: `curl --interface tun0 …`.

### 2.4 The "Unknown traffic" rule — socket-owner filter

The rule catches the ownerless traffic from [§2.3](#23-ownerless-traffic-why-curl---interface-tun0-bypasses-attribution) on the WHO axis. The `block_unknown` preset definition ([`wizard_template.json`](../app/assets/wizard_template.json)):

```json
{ "invert": true, "package_name_regex": "^" }
```

How it reads:

- `package_name_regex: "^"` — the regex `^` matches any string, the empty one included: "there is a package";
- `invert: true` — flips the condition: the rule catches traffic whose package is not resolved (empty, `INVALID_UID`).

The rule carries `inbound: ["tun-in"]`, so it applies to the tunnel only:

- it leaves connections on the local proxy inbound (`mixed-in`) alone;
- in pure Proxy mode the app is not the active VPN, `getConnectionOwnerUid` attributes nothing, and the rule stays idle instead of rejecting every connection.

The preset is on by default. The `outbound` variable sets the action:

| Value | Behaviour |
|-------|----------|
| `direct` (default) | Ownerless traffic goes out directly, outside the tunnel. The process sees the ISP's address, not the server's. An attribution failure does not cut the flow off |
| `reject` | Ownerless traffic does not go out. Strict mode: on an attribution failure (system UIDs, a `find_process` miss) the flow has no network |

What the rule gives:

1. **The server address stays hidden.** A process that bound a socket to `tun0` around VpnService does not exit through the tunnel.
2. **Only attributed traffic uses the tunnel.** Everything without an owner goes direct or is dropped.
3. **A different axis from §2.2.** An app with a valid UID heading to `1.2.3.4` is caught by `0.0.0.0/0` but not by "Unknown traffic". Ownerless traffic is the reverse.

**How to check on a device.** Exclude Termux from the VPN (per-app mode) and run from Termux:

```bash
curl --interface tun0 https://ifconfig.me/ip
```

Expected answer:

| "Unknown traffic" rule | Answer |
|---|---|
| on, `direct` (default) | the ISP's address: the connection went outside the tunnel |
| on, `reject` | timeout |
| off | the server's address — a leak |

📖 The same check, the Android kernel mechanics behind it (`SO_BINDTODEVICE` on Linux 5.7+) and how other clients treat `INVALID_UID` are covered in a two-part series on Habr: [part 1, overview](https://habr.com/ru/articles/1088980/), [part 2, the fix](https://habr.com/ru/articles/1089082/). The authors require reject for an unknown owner in any per-app mode. Here that is the `reject` value; the default is `direct`, so an attribution failure gives a direct connection rather than no network.

**Leak summary.** Ownerless traffic enters tun bypassing the VpnService intercept (`curl --interface tun0`, a bind from Termux). Its UID does not resolve, so the package is empty. Destination rules like `0.0.0.0/0` cannot tell it from ordinary traffic; only "Unknown traffic" can. So leak protection rests on both axes: WHERE (§2.2) and WHO (§2.4).

### 2.5 Layers: route engine vs connection journal

Ownerless traffic passes through two independent layers:

- **the routing layer** — the engine sees a packet with empty attribution and applies the `block_unknown` preset's action to it;
- **the connection journal** — the Live/Profiler stream, fed by the libbox CommandClient. The app has no Clash API `/connections` (§122).

"The rule fired" and "the connection shows in the journal" belong to different layers. An ownerless connection from a bind on `tun0` shows in Live/Profiler as a short open+close event (the profiler works with `FilterState(All)`, §176). The preset's action is still applied to it.

More on the diagnostic layers — [`DIAGNOSTICS.md`](DIAGNOSTICS.md).

---

## 3. Local attack surface

The threat: another app on the same device uses the client's local proxy or API. This class of vulnerability has been found in mobile VLESS clients.

| Measure | How it works | Why |
|---------|---------------|-----|
| **TUN-only inbound** | By default there is no SOCKS5/HTTP proxy on localhost: traffic enters only through TUN | Through an open proxy without auth any app quietly uses the VPN |
| **Proxy auth off localhost** | If `proxy_listen` is not a loopback address, auth is forced on and cannot be turned off | A proxy visible on the LAN without a password is an open relay |
| **No Clash HTTP API** | The core is built without `with_clash_api`; an `experimental.clash_api` block in the config stops the start with an error (§122). The core is controlled through the libbox CommandClient — an in-process channel with no network socket | An open localhost API is a known vulnerability of mobile VLESS clients. No HTTP surface — nothing to scan or brute-force |
| **Debug API off by default** | The local HTTP Debug API (subscriptions, rules, settings, `PUT /config`) does not start until it is turned on (`debug_enabled` defaults to `false`). With an empty Bearer token the server does not start either | A default install has no local HTTP server |
| **Debug API: loopback, Bearer, Host check** | Listens on `127.0.0.1` only, default port `9269`. Every endpoint except `/ping` and `/help` requires `Authorization: Bearer <token>`; an empty token is refused. The Host header is accepted only as `127.0.0.1` or `localhost` (DNS-rebinding defence): a request via a rebound `evil.com` gets `403` even with a leaked token | The Debug API controls the whole config; access from the LAN or via CSRF would hand it to someone else. See [`debug-api-reference.md`](api/debug-api-reference.md) and spec §031 |
| **pprof — on demand, loopback only** | Goroutine and CPU capture (§207) brings up the libbox `PProfServer` on `127.0.0.1` (ports 6060–6065) for the duration of a user-started capture, then shuts it down. There is no auth. `network_security_config` allows cleartext HTTP only on loopback (`127.0.0.1`, `localhost`, `::1`) | Diagnostics do not keep an open port without auth, and cleartext stays within loopback. See spec §207 |
| **Automation receivers off** | The automation receiver and the Locale-plugin components (§047, §157) are declared `android:exported="true"` and `android:enabled="false"`: they do not work until the user turns on the automation master switch | Without that switch no third-party app controls the client |
| **VpnService and BootReceiver not exported** | `android:exported="false"` | Third-party apps cannot call the core's service components |

Source — [`020 — Security & DPI Bypass`](spec/tasks/020F-security-and-dpi-bypass/spec.md).

> ⚠️ With the automation master switch on (§157), the receiver accepts commands from any sender on the device. A broadcast carries no caller identity, so there is no per-app check (`android:permission` is deliberately unset). The commands are control-only: start, stop, switch node, set group, rebuild, refresh, reset, urltest; there is no channel for pulling out secrets. Outgoing events carry status labels only. See the "Security" section of [`AUTOMATION.md`](AUTOMATION.md).

---

## 4. Inbound connections from client tunnels

Threat: a client endpoint (WireGuard/AWG, OpenVPN, OpenConnect) is a two-way channel. The server, or any peer on the far side, can open a connection inward on its own, and the gVisor stack accepts a connection to any address. Without a dedicated rule such a connection follows the general routing. With `final = direct` the peer reaches the device itself (`127.0.0.1`), the user's local network, and the internet from the user's IP.

The defence is the **Tunnel ingress** preset (`tunnel-ingress`, §656, contract 1.1.126–1.1.129):

- **On by default.** Existing installs get it once on update (late default). A preset the user deleted does not come back.
- **Coverage.** Every node of type `wireguard`, `openvpn-client` or `openconnect`: own servers, folder members and subscription nodes. Rules match on the inbound: `inbound` = the endpoint tag.
- **Node switches.** The "Incoming connections from this tunnel" block on the node screen: access to this device (`allow_local`), to the local network (`allow_lan`), using this device as a gateway (`allow_gateway`). All off by default. A subscription node has no switches and is always closed.

Preset rules, top to bottom:

| Condition | Destinations | Goes to |
|---|---|---|
| `allow_local` | `127.0.0.0/8`, `::1/128` | `allowed_out` (default `direct-out`) |
| `allow_lan` | private addresses (`ip_is_private`) | `allowed_out` |
| `allow_gateway` | any | `gateway_out` (default `vpn-1`, same as `route.final`) |
| everything else from these endpoints | any | `closed_out` (default `reject`; `drop` or an outbound also allowed) |

DNS queries from nodes without `allow_gateway` are rejected by a rule in `dns.rules` when `closed_out` is `reject` or `drop`. That rule does not depend on the preset's `dns_enable`. A peer allowed only the device or the LAN does not get to use the client's resolver.

---

## 5. Secrets on the device

All secrets sit in the app's private storage as plain text. There is no storage encryption and none is planned: protection comes from the Android sandbox.

Backups come in two formats:
- **native** — a settings snapshot with categories on the Backup screen;
- **LX Backup** — the portable contract format shared with the launcher.

The core config is built from this data on every start. Anything in it is also visible wherever the whole config is shown.

| Secret | In the core config | In the backup | How we protect it |
|--------|--------------------|---------------|-------------------|
| **WARP (WireGuard): private key, Cloudflare token, license** | the private key only (`wireguard` endpoint) | yes, both formats: native — `warp_account` (App settings category), LX Backup — `warp[]` (`private_key`, `token`, `license`) | The X25519 key is generated **on the device**; only the public key goes to Cloudflare. No third-party generator workers: they hand out a server-generated key. The backup carries the whole registration, otherwise "Add WARP" on a new machine would create an extra Cloudflare device. See [§025 WARP](spec/tasks/025F-warp-integration/spec.md), §393. |
| **MASQUE: ECDSA P-256 key, device token** | the private key only (`masque` endpoint) | yes, both formats: native — `masque_account`, LX Backup — `warp[]` with `type: masque` (`private_key_der`, `token`) | A separate keypair is generated on the device; only the public part is enrolled with Cloudflare (PATCH enroll). The key and the token are marked never-log. See [§130 MASQUE](spec/tasks/130F-masque-warp-transport/spec.md). |
| **Subscriptions: URL (often carrying an access token)** | no | yes, both formats (`sources[]` records) | — |
| **Node credentials** (uuid, passwords, REALITY/WireGuard keys of own servers) | yes, in the node's outbound/endpoint | own servers — yes, both formats (the node body); subscription nodes — no, they come again from the URL | — |
| **File subscription body** (§129) | its nodes — yes | no: kept as an `HttpCache` snapshot (key `file:<uuid>`) on the device only | — |
| **Subscription HWID** (`x-hwid`) | no | the global one — native only (App settings category); a subscription's own HWID (§289) — both formats, in `identity` | Not a secret but a stable install identifier for panels with device limits (Remnawave). Since §658 it is sent by default together with `x-device-os` / `x-ver-os` / `x-device-model`; the "Send HWID" switch turns it off. In the backup **on purpose**: a backup restored on another device carries the same HWID, the panel sees one device, and the move does not use up a slot. Regenerate after the restore makes the panel count it as a separate device. |
| **Debug API Bearer token** | no | native only, as the separate "Debug API config" category, off by default; not in LX Backup | The Debug API is off by default and bound to loopback only (see §3). |

---

## 6. Summary table

| Mechanism | Axis / layer | What it catches | Apps affected? |
|-----------|--------------|-----------------|----------------|
| `0.0.0.0/0 → reject` | WHERE (destination IP) | all IPv4 traffic indiscriminately | yes, all |
| `final = reject` | fallback | everything that matched no rule above | yes, unless explicitly described |
| **Unknown traffic** (`block_unknown`) | WHO (socket owner) | traffic with an empty package (`INVALID_UID`) | **no** — ownerless only |
| No Clash HTTP API (CommandClient) | local surface | in-process control, no network socket to attack | — |
| Debug API off by default; loopback + Bearer + Host check | local surface | unauthorized config control (opt-in only) | — |
| TUN-only / auth-on-LAN | local surface | other apps using the local proxy | — |
| On-device key gen (WARP X25519, MASQUE P-256) | secrets | private-key leakage | — |
| **Tunnel ingress** preset (`tunnel-ingress`) | tunnel inbound (`inbound`) | peer connections inward: to the device, into the LAN, out through us | no — endpoint inbound only |
