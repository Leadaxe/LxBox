[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Node editor — adding and editing custom VPN servers: SOCKS5, HTTP, Tailscale, links and JSON

LxBox adds VPN servers that are not in any subscription (SOCKS5, HTTP,
Tailscale, a link, a WireGuard INI or sing-box JSON) and lets you edit them
later. The node is stored as the text you entered, so a hand-written
sing-box body reaches the core unchanged once the core has checked it.
Subscription nodes are shown read-only; they change only through the
subscription's import rules.

| Field | Value |
|------|----------|
| Feature | 008-NODE_EDITOR |
| Type | Product feature |
| Absorbed | `§017F` `§074F` `§554F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The user creates **a custom node** — a server that is not in any
subscription: a local SOCKS5/HTTP proxy, a Tailscale node, a link or a
sing-box JSON from a friend — and then edits it themselves. The feature is
responsible for the add wizard, the node settings screen and editing the
node's **source** — the text the node is derived from.

Principles the feature protects:

1. **The node's truth is its source.** What the person entered is stored (a
   link, a WireGuard INI or a sing-box body), not a copy assembled by the
   model. Only the source is edited; the JSON tab shows what will go to the
   core, read-only.
2. **What is written by hand goes to the core as written.** A custom JSON
   body is not rewritten by the application's gates; the core checks it on
   save. Keys unknown to the application are not lost.
3. **The name is the tag.** The title of a custom server in the list is the
   tag of its node; there is no separate "display name". Renaming rewrites
   all references to the node.
4. **A subscription node belongs to someone else.** It is not edited
   individually: the next update would replace it anyway. Subscription nodes
   can be changed only via the subscription's import rules
   ([001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md)).

Parsing links and formats — [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md);
detour and chains — [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md);
the node list, folders and order — [007-NODE_LIST](../007-NODE_LIST/FEATURE.md).

## Promises

- **P1. The tag from the wizard form survives a restart.** SOCKS5, HTTP and
  Tailscale are stored as a sing-box body with a `tag` field, so after the
  record is re-read the tag is the same as the person entered.
  **Witness:** units "wizard SOCKS5 node → JSON body → the re-read record
  keeps the tag", "HTTP node with login and TLS → the round trip keeps login,
  password, tls", widget "the entered tag survives a persist round-trip".
  **Mutation:** store SOCKS5 as a `socks5://…#label` link.
- **P2. An empty form tag — a default with an emoji.** Empty →
  `local-socks5-out`, `local-http-out`, `tailscale`; a created node without an
  emoji in the tag gets an emoji by node kind. **Witness:** widgets "empty Tag
  field → default tag", "empty Tag → "tailscale" with the default emoji".
  **Mutation:** require Tag.
- **P3. A custom server's title is the node tag.** The record name is neither
  written nor shown, even if left over from an old version; re-saving erases
  it. **Witness:** widget "filled Tag → node tag = what was entered, name
  empty", unit "legacy v2.11.0 record with a non-empty name: displayName
  ignores name". **Mutation:** show the record name first.
- **P4. The emoji is set once.** A tag without an emoji gets an emoji by node
  kind on creation (local → 🔁, WARP → 🔥☁️, WireGuard → 🏠, Tailscale → 🕸️,
  MASQUE → 🎭, Hysteria2/TUIC → 🚀, others → ⚡); a tag with an emoji is not
  touched; a repeat does not duplicate. **Witness:** units of the groups
  "defaultEmojiFor" and "withDefaultEmoji — round-trip through the parser".
  **Mutation:** check for an emoji only at the start of the tag.
- **P5. Only the node body is written into the source.** A document
  (`outbounds`/`endpoints` at the root) → the first node that is not a service
  type and not a group, `endpoints` before `outbounds`; an array → the first
  element; everything else is not saved, the user sees one message.
  **Witness:** units of the groups "document" and "array of bodies".
  **Mutation:** write the whole text into the source.
- **P6. Untouched JSON is saved byte for byte.** If the tag did not change,
  the body text goes into the source as typed; an empty Tag field does not
  touch the body's tag. **Witness:** units "tag unchanged → original text byte
  for byte", "empty Tag → the body's tag is not touched". **Mutation:** always
  re-encode the JSON.
- **P7. The core checks a custom JSON body before writing.** The core is
  given a config of one node without `detour`, WireGuard under `endpoints`;
  core refusal — the source does not change, the error text is in the core's
  words. **Witness:** units "bare body → outbounds without detour", "wireguard
  → endpoints"; core refusal — manual check: add a key unknown to the core
  `"foo": 1` to the body, Save → "The core rejected the node: …", the source
  is unchanged. **Mutation:** write before the core's answer.
- **P8. A custom JSON body goes into the config verbatim.** Keys outside the
  model survive; the body's `detour` key is removed, the detour is decided by
  the record ([006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md)).
  A subscription node and a link go through the model. **Witness:** units
  "standalone server from JSON: body verbatim, keys outside the model
  survive", "JSON source → object without detour", "a member's personal detour
  is applied on top of the verbatim body", "container: a subscription node
  goes through the model". **Mutation:** emit the model for all.
- **P9. Editing the body clears the core's verdict.** A node disabled because
  of a core refusal is re-enabled after its body changes; re-saving without
  changes keeps the verdict; a node disabled by the person is not revived by
  an edit. **Witness:** units "body changed → verdict cleared…", "re-saving
  without an edit…", "a server disabled by the person (no verdict) is not
  revived by an edit". **Mutation:** clear the verdict on any Save.
- **P10. A broken source of a folder member is not written.** "Could not parse
  server config — keeping current", the member is untouched. **Witness:** unit
  "updateMemberAt: broken raw → rollback with an error, member untouched".
  **Mutation:** write, then parse. (A standalone server has no such
  protection — see the maintenance notes.)
- **P11. Renaming rewrites references.** The node's new tag is picked up by
  other nodes' detour, group members and chain positions. **Witness:** units
  "renaming a root node rewrites root references", "editing a member's body
  (renaming) rewrites storage". **Mutation:** match nodes before and after by
  tag rather than by position in the body.
- **P12. Comments and an unknown type do not get in the way.** JSON with `//`
  and `/* */` is accepted, it goes into the source without comments with the
  message "Comments were removed."; a custom body of a type unknown to the
  application is accepted with a warning; a body without `type` — refusal.
  **Witness:** units "input with comments is accepted, source without
  comments", "pasting a body of an unknown type…", "a body without type is
  still rejected". **Mutation:** strict JSON parsing before stripping
  comments.
- **P13. The Tailscale form writes only what is filled in.** Auth key is
  required; empty fields do not get into the body, booleans — only `true`;
  Hostname is prefilled with `LxBox-<model>`, erased — no key. **Witness:**
  widgets "empty Auth key → the validator does not let it through", "optional
  fields and toggles get into the body as is", "§449 Hostname with the LxBox…
  default". **Mutation:** write `false` and empty strings. In detail —
  [030-TAILSCALE](../030-TAILSCALE/FEATURE.md).
- **P14. A subscription node is not edited individually.** The subscription
  node screen is inspection only: no Save, no Edit JSON, Tailscale has no
  Save choice. **Witness** — manual check: subscription → node → "Inspect
  node": the JSON/Source tabs are read-only, there are no write buttons.
  **Mutation:** open the custom node screen for a subscription node.
- **P15. Proxy forms do not accept an invalid address.** Host non-empty, Port
  1..65535, otherwise Add does not work. `no witness` (there are no tests for
  the SOCKS5/HTTP validator).

## Controlled parameters

| Parameter | Where | Values | Default |
|---|---|---|---|
| Tag · Host · Port · Username · Password | Wizard → SOCKS5 | strings; Port 1..65535 | empty→`local-socks5-out` · `127.0.0.1` · `1080` |
| Tag · Host · Port · Username · Password · HTTPS | Wizard → HTTP | same + TLS on/off | `local-http-out` · `127.0.0.1` · `8080` · off |
| Tag · Auth key · Control URL · Hostname · Ephemeral · Accept routes · Exit node | Wizard → Tailscale | strings, toggles | `tailscale` · required · empty · `LxBox-<model>` · off · off · empty |
| Paste URI / Paste JSON | Wizard | text | — |
| Tag | Node → Settings | string + a palette of 14 emoji | node tag |
| Detour server | Node → Settings | see [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) | None (direct) |
| Skip presets | Node → Settings; visible if the template has a `for_each` preset for the node type | on/off | off |
| Source | Node → Source | source text | as saved |
| Exit node | Tailscale node → Network → Save choice | tailnet node / None | from the body |

Core config keys the feature creates: the `socks` outbound (`server`,
`server_port`, `username`, `password`), the `http` outbound (same +
`tls.enabled`, `tls.server_name` = Host), the `tailscale` endpoint
(`auth_key`, `control_url`, `hostname`, `ephemeral`, `accept_routes`,
`exit_node`), `tag`. A custom JSON body is handed to the core whole, except
`detour`.

## Inputs / Outputs

**Inputs:** wizard form fields; a link or JSON in the wizard tabs; the source
text on the Source tab; the emoji choice; the core's `CheckConfig` answer on
saving a JSON body.

**Outputs:** a new "custom server" record (standalone) with one node; the
changed source of a custom server or a folder member; a config rebuild;
messages "Added: <tag>", "Saved", "Only the node is saved. The rest of the
input is not kept.", "Comments were removed.", "The core rejected the node:
…".

## Data flow

```
wizard: form ─► sing-box body with tag ──┐
        link/JSON ─► parsing (002) ──────┼─► auto emoji ─► "custom server" record ─► rebuild
node screen: Source ─► text kind?
   JSON  ─► body only + tag from Tag ─► core CheckConfig ─► write
   link  ─► tag into the fragment ──────────────────────► write
   INI   ─► as is, tag as a record field ───────────────► write
   write ─► re-read: model for the form, list, diagnostics
          ─► core verdict cleared if the body changed; references rewritten
build: custom JSON source ─► body verbatim (without detour) ; otherwise ─► model
```

## Rules and guarantees

- The source kind is derived from the text: a JSON object → `json`, a
  WireGuard INI → `wg_ini`, anything else → a link. There is no mode flag.
- Tag and Source are applied only with the Save button; Edit JSON —
  immediately after confirmation; Detour and Skip presets are written
  immediately on selection.
- "Edit JSON" on a link or INI, after a warning, replaces the source with the
  model's body — irreversibly, there is no way back to the link; on a JSON
  source it opens Source.
- The tag in the wizard is not checked for uniqueness: on a collision the
  build gives the node a suffix `-1`, `-2`…; the message shows the entered
  tag.
- The emoji is set only when the record is created; it is not substituted
  when the tag is edited.
- An auto-select node (group) has no Detour block.

## Boundaries

- Parsing links, JSON forms, INI and `vpn://` —
  [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md); adding by link, QR, file,
  public test servers — the "Adding a source" function in
  [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md).
- Detour selection, folder policy, chains —
  [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md); here only
  the place on the screen.
- Folders, moving to a folder, order, the main screen —
  [007-NODE_LIST](../007-NODE_LIST/FEATURE.md).
- Node diagnostics and notifications — [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md);
  Cloudflare WARP — [015-WARP](../015-WARP/FEATURE.md); the Tailscale preset —
  [004-ROUTING](../004-ROUTING/FEATURE.md); the Tailscale node itself, its
  identity and the Network tab — [030-TAILSCALE](../030-TAILSCALE/FEATURE.md).
- Does not do: overrides of a subscription node, node duplication, a form by
  protocol schema, a separate WireGuard/AmneziaWG form, a TLS form.
- Camera and file picking — depend on OS capabilities
  ([001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md)).

## Functions

| Function | What it does | Promises | File |
|---|---|---|---|
| Add server wizard | Creates a custom SOCKS5, HTTP or Tailscale node from a form, or any node from a pasted link or sing-box JSON. | P1 P2 P13 P15 | [add-server-wizard.md](FUNCTIONS/add-server-wizard.md) |
| Node settings | Shows the tabs of a custom node and lets you change its tag with an emoji, its detour server and the Skip presets switch. | P3 P4 | [node-settings.md](FUNCTIONS/node-settings.md) |
| Source editing | Saves the source by its kind (link, INI or JSON), keeps only the node body, checks JSON with the core and converts a link to JSON on request. | P5 P6 P7 P8 P9 P10 P12 | [source-editing.md](FUNCTIONS/source-editing.md) |
| The name is the tag | Makes the node tag the only name of a custom server, with defaults, an automatic emoji, collision suffixes and reference rewriting on rename. | P2 P3 P4 P11 | [name-is-tag.md](FUNCTIONS/name-is-tag.md) |
| JSON and protocol schema | Shows the node's sing-box JSON with highlighting, keeps fields unknown to the app and records what the schema-aware editor still lacks, including the "replace the whole `tls`" trap. | P6 P8 | [json-and-schema.md](FUNCTIONS/json-and-schema.md) |
| WireGuard / AmneziaWG editing | Edits WireGuard and AmneziaWG nodes through their INI, link or JSON source, with AWG obfuscation fields as plain text. | P9 | [wireguard-awg-editing.md](FUNCTIONS/wireguard-awg-editing.md) |
| Subscription node | Shows a subscription node read-only, without individual overrides, and lists what survives a subscription update. | P14 | [subscription-node.md](FUNCTIONS/subscription-node.md) |
| Node deletion and duplication | Deletes a custom server, clears detour, group and chain references to it and counts the affected ones; there is no duplication. | P11 | [delete-and-duplicate.md](FUNCTIONS/delete-and-duplicate.md) |

## Related features

- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md) — subscription nodes are changed only by its import rules; adding a source by link, QR, file.
- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — parsing the links, JSON, INI and `vpn://` a custom node is derived from.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — the build rules under which a custom JSON body goes into the config verbatim.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — the Tailscale preset that provides the tailnet route and DNS.
- [005-DNS](../005-DNS/FEATURE.md) — the DNS server form as the precedent of the "replace the whole `tls`" trap.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — detour selection, folder and subscription policy, chains, the fate of references after the target is deleted.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — the node list, folders, moving to a folder, order, copying a link.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — the Diagnostics tab, node notifications, core refusal and auto-disabling.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — WireGuard endpoint state (handshake, asleep).
- [015-WARP](../015-WARP/FEATURE.md) — the separate Cloudflare WARP wizard with its own obfuscation fields.
- [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.md) — DPI bypass settings (fragmentation, ECH).
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — record storage and the reference registry.
- [019-CONFIG_EDITOR](../019-CONFIG_EDITOR/FEATURE.md) — the whole resulting config.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) — the contract registry: field schema, warning codes and texts.
- [030-TAILSCALE](../030-TAILSCALE/FEATURE.md) — the Tailscale node created by the wizard form: device identity, the Network tab with the exit node switch, tailnet DNS and routes.

## Maintenance notes

- **A broken source of a standalone server is written.** A folder member has
  a rollback (P10), a standalone server does not: a link that did not yield a
  node is saved, the record stays without a node. Any new write point must
  decide this explicitly.
- **Save writes the text of the Source tab.** Editing just the Tag re-saves
  the source; for a link the tag goes into the `#…` fragment, for JSON — into
  `tag`, for INI — into a record field. Leaving the screen without Save
  silently loses the edit.
- **The core check is for JSON only.** Links and INI go through the model and
  its gates; if the bridge to the core is unavailable, saving is not
  blocked.
- **The HTTP proxy's SNI = Host.** The HTTPS switch puts the Host value into
  `tls.server_name`; fine-tuning TLS — only via the body text.
- **A subscription node is edited only via import rules**
  ([001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md)): an individual edit
  would be wiped by the next update — that is why there is none.
