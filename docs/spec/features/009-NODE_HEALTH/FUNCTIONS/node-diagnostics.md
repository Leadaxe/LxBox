[English](node-diagnostics.md) · [Русский](node-diagnostics.ru.md)

# Node diagnostics — an HTTP request through one node to see what sites see

The Diagnostics tab sends one HTTP request through a chosen node and shows
the raw reply, which explains cases like "ping works but sites don't open"
or a wrong exit country.

| Field | Value |
|------|----------|
| Feature | [009-NODE_HEALTH](../FEATURE.md) |
| Promises | P13 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Answers the questions ping cannot: "ping works but sites don't open",
"services think I'm in another country", "WARP is connected but
`warp=off`". The Diagnostics tab in the node details sends one HTTP request
through this node to the chosen service and shows the reply as is — without
switching the active node and without touching live connections.

## Parameters

| Check | Address |
|-------|---------|
| Cloudflare trace (default) | `https://1.1.1.1/cdn-cgi/trace` |
| Cloudflare trace (hostname) | `https://cloudflare.com/cdn-cgi/trace` |
| IP & location | `https://api.ip2location.io/` |
| IP info | `https://ipinfo.io/json` |

Exchange timeout — 10 s; the body is limited to 64 KiB. Entering one's own
address is deliberately impossible: the tab must not become an HTTP client
through other people's tunnels.

## Inputs / Outputs

**Inputs:** the node (a parsed node of a subscription, folder or server; from
the built-config view screen — only the tag); VPN state; the core's
`getURLViaOutbound` reply — status, body, truncation flag, destination
address, exchange time or error text.

**Outputs:**

| What is visible | When |
|-----------------|------|
| `<status> · <N>ms`, monospace body, copy button | the exchange happened (any HTTP status; 2xx highlighted) |
| "Response was longer and got cut off." | the body was truncated by the core |
| "Connected to %s from inside the tunnel" | the core reported the destination address |
| Source caption: "Through this node in the running core — not through your current route" / "Through this node in a temporary core session" | always with a result |
| Core error text in red | the exchange did not happen |
| An explanation instead of a result | a run is impossible (reasons below) |

## Rules and invariants

- **The branch is chosen by itself** from the VPN state, there is no switch:

  | VPN | Through what |
  |-----|--------------|
  | on | the live core, the node addressed by its tag in the config (with the list prefix) |
  | off | a temporary core session of just this node and its own chain; shut down right after the reply |

- **Reasons a run is impossible:**

  | Reason | What the user sees |
  |--------|--------------------|
  | `group` — an auto-select node | "This is an auto-select node — it has no connection of its own. Open a member to diagnose it." |
  | `no_node` — only the tag is known, VPN off | "Start the VPN to check this node from here, or open it from its subscription to check it with the VPN off." |
  | the node does not build into a config | the build reason |
  | the temporary session did not come up | the session error text |
  | `cancelled` | the run was removed by a stop or by backgrounding |

- A non-2xx (for example, 429 from a rate-limited service) is an ordinary
  result, not a sign of a dead node.
- The body is not parsed: the user reads what the service sent; a change of
  the service's format does not break the tab.
- Runs only on the Run button: opening the tab sends nothing.
- For a Tailscale node without an effective exit node the external check is
  hidden with the explanation "This node has no exit. Check devices on the
  Network tab.".
- Cancellation — as with the server test: a tunnel stop and backgrounding
  remove the run.
- Below the check — the Notifications section with the node's warnings (if
  any); the dot on the tab label is yellow, red at the error level.

## Boundaries

- Does not answer "what am I going through right now": the live route with
  rules and group selection is checked by an ordinary request from the device.
- Layered chain probe (the block above the check on the chain screen) —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- Notification texts and grouping — [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FEATURE.md).

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [392F](../../../tasks/392F-node-diagnostics/spec.md) | DEVICE-PENDING | Diagnostics tab: request through a node, two branches by VPN, raw reply |
| 2 | [497](../../../tasks/497-node-notifications-tab.md) | Released v2.25.0 | Node notifications in the details |
| 3 | [501](../../../tasks/501-diagnostics-notifications-merge.md) | Released v2.25.0 | Notifications inside the Diagnostics tab, dot on the label |
| 4 | [546](../../../tasks/546-emitters-drop-registry-rule-copies.md) | — | Registry check in the session — by the core version of the live build |
