[English](add-server-wizard.md) · [Русский](add-server-wizard.ru.md)

# Add server wizard — a SOCKS5, HTTP or Tailscale node from a form or pasted text

The wizard creates one custom server from a SOCKS5, HTTP or Tailscale form,
or from a pasted link or sing-box JSON.

| Field | Value |
|------|----------|
| Feature | [008-NODE_EDITOR](../FEATURE.md) |
| Promises | P1 P2 P13 P15 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Creates one custom server from a structured form or from pasted text — for
those who do not remember the `socks5://…` link format or want to enter a
Tailscale node field by field. It opens on the sources screen by a long press
on "+" or via the "Add server…" menu item. Full-screen, five tabs with
horizontal scrolling; Cancel and Add — in the header.

## Parameters

| Tab | Fields | Defaults |
|---|---|---|
| SOCKS5 | Tag (optional), Host, Port, Username (optional), Password (optional) | empty → `local-socks5-out`; `127.0.0.1`; `1080` |
| HTTP | the same + "HTTPS (TLS to proxy)" | empty → `local-http-out`; `127.0.0.1`; `8080`; off |
| Paste URI | multiline text of links | hint: vless / vmess / trojan / ss / hy2 / tuic / socks5 / proxy-http(s) / wireguard |
| Paste JSON | a sing-box outbound, an array or a document; JSON highlighting | — |
| Tailscale | Tag (optional), Auth key, Control URL, Hostname, Ephemeral, Accept routes, Exit node | empty → `tailscale`; required; empty; `LxBox-<device model>`; off; off; empty |

The Tag fields have an emoji palette; Auth key is hidden with a Show/Hide
button.

## Inputs / Outputs

**Input:** form fields or text.
**Output:** a new "custom server" record with one node at the end of the
source list, a config rebuild, the message "Added: <tag>" (forms) or "Added"
(paste), return to the sources screen.

| Tab | What results |
|---|---|
| SOCKS5 | `socks` outbound: `server`, `server_port`, `username`, `password`, `tag` |
| HTTP | `http` outbound: the same; with HTTPS — `tls.enabled: true`, `tls.server_name` = Host |
| Tailscale | `tailscale` endpoint: `auth_key` + only the filled fields; booleans only `true` |
| Paste URI / JSON | the same path as pasting on the sources screen (parsing — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)) |

The forms store the node **as a sing-box body with `tag`**, not as a link: a
link carries the name in the fragment, and the tag would be different after
re-reading (P1).

## Rules and invariants

- Host non-empty, Port an integer 1..65535; otherwise Add is not performed,
  under the field "Host required" / "Port 1..65535" (P15, no witness).
- An empty Auth key — "Auth key required", the node is not created.
- The Hostname field opens prefilled; erased — no `hostname` key in the body,
  Tailscale chooses the name itself.
- Without Exit node a Tailscale node gives access to the tailnet but does not
  become a Direction candidate; the tailnet route and DNS are provided by the
  template preset, not by the node
  ([030-TAILSCALE](../../030-TAILSCALE/FUNCTIONS/tailnet-dns-and-routes.md)).
- A tag without an emoji gets an emoji by node kind ([name-is-tag.md](name-is-tag.md)).
- Tag uniqueness is not checked: the build suffixes a colliding tag with
  `-1`, `-2`; the message shows the entered tag, not the final one.
- Paste error (not recognized, zero nodes) — a message with the reason, the
  wizard stays open.
- JSON with comments is accepted; the message "Comments were removed."
  instead of "Added".
- Switching tabs does not reset what was entered in other tabs.
- There is no separate "Display name" field: the record title is the tag.

## Boundaries

- Adding by a link in the input field, from the clipboard, QR, file, public
  test servers — "Adding a source" in
  [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FUNCTIONS/add-source.md).
- There are no forms for VLESS, Trojan, WireGuard and others — paste only.
- The wizard does not build a chain and does not set a detour — that is
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- Cloudflare WARP — a separate wizard ([015-WARP](../../015-WARP/FEATURE.md)).
- Editing the created node — [node-settings.md](node-settings.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [017F](../../../tasks/017F-custom-nodes-and-node-settings/spec.md) | Spec | Custom node from a link or JSON |
| 2 | [074F](../../../tasks/074F-add-server-wizard/spec.md) | Released in v1.9.0 | Wizard: SOCKS5, Paste URI, Paste JSON; the tag is stored in the JSON body |
| 3 | [094](../../../tasks/094-emoji-tags-node-settings-tabs.md) | DONE | Emoji palette in the wizard's Tag field |
| 4 | [222](../../../tasks/222-http-proxy-protocol.md) | Implementation | HTTP(S) proxy tab |
| 5 | [226](../../../tasks/226-scrollable-wizard-tabs.md) | Implementation | Horizontal tab scrolling |
| 6 | [243](../../../tasks/243-wg-import-filename-tag.md) | Implemented | Display name field removed, Tag optional with a default |
| 7 | [333](../../../tasks/333-large-text-virtualization.md) | ✅ Implemented | Line-based editor for large pastes |
| 8 | [435](../../../tasks/435-node-sections-tailscale.md) | Cancelled, replaced by §575/§578 | Tailscale form (the form remained, node sections abolished) |
| 9 | [449](../../../tasks/449-tailscale-default-hostname.md) | Implemented | Default Hostname `LxBox-<model>` |
| 10 | [554F](../../../tasks/554F-schema-driven-node-editor/spec.md) | Idea, phase 1 partial | JSON highlighting in the Paste JSON tab |
| 11 | [585](../../../tasks/585-unknown-node-type-accepted.md) | Implemented | JSON with comments and an unknown type is accepted |
