[English](operating-modes.md) · [Русский](operating-modes.ru.md)

# Operating modes: VPN / Proxy / VPN+Proxy

| Field | Value |
|-------|-------|
| Feature | [010-VPN_SERVICE](../FEATURE.md) |
| Promises | P5, P6 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Chooses how the core receives traffic: a system tunnel for the whole device, a
local proxy port that apps use by explicit configuration, or both at once. For
the port it sets the protocol, address, number and authentication. For the
tunnel — whether apps are allowed to bypass it.

## Parameters

| Setting | Values | Default |
|---------|--------|---------|
| VPN mode | `vpn` — system tunnel; `proxy` — port only; `vpn_proxy` — both | `vpn` |
| Local proxy protocol | `mixed` (HTTP+SOCKS5 on one port), `http`, `socks` | `mixed` |
| Listen address | any IPv4; in the list `127.0.0.1` (this device only), `0.0.0.0` (LAN) | `127.0.0.1` |
| Listen port | 1024..65535 | 2080 |
| Require authentication | on/off; outside `127.x` — forced on | on |
| Username / Password | string / password with the "Show", "Regenerate" buttons | `user` / generated 32 hex |
| Allow VPN bypass | on — apps may explicitly go around the tunnel | off |

Port settings are visible only in modes with a port; "Keep VPN on exit" and
"Allow VPN bypass" — only in modes with a tunnel.

## Inputs / Outputs

**Input:** the user's choice (mode screen, Debug API).
**Output to the core config:** `inbounds[]` —
`{type: tun, tag: tun-in, …}` in `vpn`/`vpn_proxy`;
`{type: mixed|http|socks, tag: mixed-in, listen, listen_port, users?}` in
`proxy`/`vpn_proxy`. The `mixed-in` tag does not depend on the protocol.
`users` is written only with effective authentication and a non-empty
password. `route.final` does not depend on the mode.

## Rules and invariants

- The `vpn` mode gives the same config as before modes existed; a missing
  setting = `vpn`.
- Traffic parsing rules (resolve, sniff) apply to the port input the same way
  as to the tunnel one: in `proxy` they move to the port, in `vpn_proxy` they
  apply to both; a disabled sniff appears on neither. DNS hijack applies to all
  inputs.
- An address outside `127.x` makes authentication mandatory, the toggle is
  locked; enabling authentication, choosing such an address or a mode with a
  port while the password is empty generates a password. The screen and the
  Debug API hold the same invariant.
- An invalid port (outside 1024..65535) or an invalid IPv4 — an error under the
  field, the value is not saved. The Debug API rejects an invalid port and
  protocol.
- A numeric password stays a string in the config (no conversion to a number).
- A mode change sets the "has tunnel" flag, which decides whether the system
  VPN permission request is needed (see [foreign-vpn](foreign-vpn.md)).
- Any change of the mode or port settings marks "restart needed".
- "Allow VPN bypass" takes effect from the next time the tunnel comes up; the
  value applied in the current session is reported separately from the saved
  one.

## Boundaries

- Registering the port as the system proxy — not done.
- Two protocols on two ports at once — not done.
- Address, MTU, stack, IPv6 of the tunnel interface — template variables,
  003-CONFIG_BUILD.
- Which apps go through the tunnel — 011-SPLIT_TUNNELING.
- Depends on OS capabilities: the single system VPN slot, the mechanism for
  apps to bypass the tunnel.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [119F](../../../tasks/119F-vpn-mode/spec.md) | Implemented | Three modes, local port, authentication, password generation |
| 2 | [120F](../../../tasks/120F-template-engine-typed-vars-and-if/spec.md) | Implemented | Core inputs per mode are declared in the template |
| 3 | [069](../../../tasks/069-current-session-allow-bypass.md) | Released v1.9.0 | The bypass value effective in the session is separate from the saved one |
| 4 | [188](../../../tasks/188-tun-toggles-to-mode-tab.md) | ✅ DEVICE-VERIFIED | Tunnel toggles on the mode screen; keep-alive on by default |
| 5 | [292](../../../tasks/292-quick-invariant-holes.md) | implemented (device-pending) | Port and protocol validation at the inputs |
| 6 | [293](../../../tasks/293-vpn-settings-facade.md) | dedup implemented; facade pending | A single point of applying the mode for the screen and the Debug API |
