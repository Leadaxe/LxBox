[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Node import — share links, Xray and sing-box JSON, WireGuard and AmneziaWG configs in one node model

LxBox parses proxy share links, Xray and sing-box JSON, WireGuard and AmneziaWG configs and Amnezia
`vpn://` profiles into sing-box nodes. Supported link schemes include VLESS with REALITY, VMess,
Trojan, Shadowsocks, Hysteria2, TUIC, AnyTLS, SOCKS, HTTP, SSH, NaiveProxy, WireGuard and MASQUE.
Every entry that does not become a node is reported with a reason code, and any node can be exported
back to a share link. The parsing rules come from a contract registry shared with the launcher, so
both apps turn the same input into the same node.

| Field | Value |
|------|----------|
| Feature | 002-NODE_IMPORT |
| Type | Product feature |
| Absorbed | `§019F` `§026F` `§037F` `§097F` `§321F` `§368F` `§460F` `§472F` `§480F` `§584F` |
| Contract | contract registry `1.1.99` (protocols, source kinds, warnings, limits) — [025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.md) |
| State | ✅ written from code, 2026-09-28 |

## Purpose

Nodes reach L×Box in a dozen forms: a share link of any protocol, a subscription
body (a list of links, base64, JSON), a whole Xray or sing-box config,
a WireGuard/AmneziaWG `.conf` file, an Amnezia profile link `vpn://`. The feature
turns any of them into **one** node form — a body in the sing-box core form
(outbound or endpoint) with a name, a source and a list of warnings — and
can do the reverse: build a share link from a node.

Principles the feature protects:

- **One rule — one place.** What counts as an allowed field value,
  which link schemes exist and how they are spelled, what text a warning has —
  is decided by the contract registry, shared with the launcher. The app executes it rather than
  keeping its own copy.
- **No silent losses.** An entry that did not become a node is named by
  a code with a reason; one broken entry does not bring down its neighbours.
- **A node the core will not accept does not survive until start.** It is removed at
  parse time instead of bringing down the whole config later.

## Promises

- **P1. Any supported link scheme yields a node.** The set of schemes and their
  spellings (`vless`, `vmess`, `trojan`, `ss`, `hysteria2`/`hy2`, `tuic`,
  `anytls`, `socks`/`socks5`/`socks4`/`socks4a`, `proxy-http(s)`/`proxy+http(s)`,
  `ssh`, `naive+https`/`naive+quic`, `wireguard`/`wg`/`awg`/`amneziawg`,
  `masque`, `vpn://`) is taken from the registry. **Witness:** unit test "`$proto/$name` parses
  + emits + round-trips" over fixtures of all schemes; unit test "contract 1.1.48/49 —
  `amneziawg` in the set WITHOUT a code change". **Mutation:** a scheme declared by the registry
  but not accepted by the dispatcher.
- **P2. The link → node → link → node round trip does not lose the node.** **Witness:** unit test
  "`$scheme`: the body survives building the link and parsing it back"; unit tests
  "the whole `<scheme>` corpus survives the round trip" (vmess, shadowsocks and others). **Mutation:** link
  emit skips a parameter that parsing reads.
- **P3. The body form is recognized unambiguously.** Every document falls into exactly
  one source kind; the base64 wrapper is unwrapped no deeper than two layers, the third is
  a rejection without an exception. **Witness:** unit test "every document is recognized UNAMBIGUOUSLY
  (exactly one winner by priority)"; unit test "3× — silent rejection, no nodes, no
  exception". **Mutation:** two source-kind branches with equal priority
  match on the same text.
- **P4. A broken entry does not bring down its neighbours.** **Witness:** unit tests "a broken outbound
  form does not bring down neighbours", "valid neighbours survive next to garbage",
  "malformed links never throw an exception" (malformed URIs). **Mutation:** a parse exception on one
  entry aborts the loop over the body.
- **P5. A loss is named.** An unknown scheme — `scheme_unsupported` with the scheme,
  an unknown entry type — `protocol_unsupported`, an unreadable wrapper —
  `form_unrecognized`, a link that is too long — `uri_too_long`, an unrecognized
  body — `core_rejected` with the decoder's reason. Exception: a line with no
  `://` at all is dropped silently. **Witness:** unit tests of the group "§506 item 2 — a reason instead
  of silence". **Mutation:** a rejection branch returns "no node" without a code.
- **P6.** moved to [025-CONTRACT_REGISTRY · P2](../025-CONTRACT_REGISTRY/FEATURE.md#promises).
- **P7.** moved to [025-CONTRACT_REGISTRY · P3](../025-CONTRACT_REGISTRY/FEATURE.md#promises).
- **P8. A repeat within one body collapses; across sources it does not.**
  The key is the node content without the tag and `detour`, plus the dial path. **Witness:** unit test
  "`amneziawg://` and `vpn://` of one node — one node and `duplicate`"; unit test "dedup
  does not cross subscription boundaries"; unit test "D-086: different SNI → TWO nodes". **Mutation:**
  a dedup key by the "scheme+host+port+credentials" quadruple.
- **P9. Order and names of multi-node configs are the author's.** Nodes go in file
  order; the server name goes to a single element, not to a pool. **Witness:** unit tests
  "list order is the author's, not sorted", "a pool first in the file
  stays first in the list, names from singles". **Mutation:** sorting elements
  by node count remains in the output.
- **P10. Changing the parser does not change node identity.** The hash, tag and body
  of every corpus case match the snapshot taken before the move to the registry engine.
  **Witness:** unit test "`$scheme`: hash, tag and body of every case in place"; unit test
  "wireguard: INI cases give the same hash, tag and body". **Mutation:** the tag fallback
  of a nameless link changed.
- **P11.** moved to [025-CONTRACT_REGISTRY · P4](../025-CONTRACT_REGISTRY/FEATURE.md#promises).
- **P12.** moved to [025-CONTRACT_REGISTRY · P5](../025-CONTRACT_REGISTRY/FEATURE.md#promises).
- **P13. A link with a private key is copied only after confirmation.**
  **Witness:** widget test "private_key role" and the `copyNodeUri` group (dialog
  "Link contains a private key", cancel does not touch the clipboard). **Mutation:** detecting a
  private key by the node class rather than by the field's role in the registry.
- **P14. AmneziaWG gets an MTU ceiling of 1280.** A link/INI without MTU → 1280, above
  → 1280 with code `awg_mtu_clamped`; plain WireGuard is not touched; an authored
  sing-box body keeps the value with an info code. **Witness:** unit tests "AWG
  mtu=1420 → clamp to 1280", "plain WG is not touched", "sing-box body with mtu=1420:
  value intact, info code". **Mutation:** clamping by the `wireguard` protocol without
  the AWG marker.
- **P15. A provider banner does not become a node.** A link to `0.0.0.0`,
  loopback or `localhost` is dropped with code `provider_banner_link`, the remark
  after `#` travels as a message. **Witness:** unit tests "a banner as the ONLY entry of
  the body: no nodes, the reason is named", "the PORT is NOT a marker". **Mutation:**
  checking by port `1`.
- **P16. An OpenVPN `.ovpn` profile is accepted.** `no witness` — the format is not
  implemented (owner's decision: postponed); only a ready core body
  `openvpn-client` is accepted (see the sing-box JSON function).

## Controlled parameters

The feature has no user settings: behaviour is set by the contract registry and
limits.

| Parameter | Value | Source |
|----------|----------|----------|
| Contract registry version | `1.1.99`, shipped in the app build | [025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.md) |
| Length of one link | ≤ 65536 characters, otherwise `uri_too_long` | registry limit |
| Length of a `vpn://` link | ≤ 524288 characters | registry limit |
| Amnezia profile decompression | ≤ 4 MiB (anti-bomb) | registry limit |
| Depth of base64 wrapper removal | 2 | `max_unwrap_depth` of source kinds |
| `detour` chain length at import | ≤ 8 links, beyond that truncated with a code | registry limit |
| AmneziaWG MTU ceiling | 1280 | registry rule `wireguard.mtu` |
| Comments in a link list | lines with `#`, `//`, `;` | `line_comment_prefixes` |
| Banner targets | `0.0.0.0`, `127.0.0.1`, `::`, `::1`, `localhost` | `banner_targets` |
| Service schemes | `incy`, `happ` with path `routing/…` → info code | `service_schemes` |

Core keys the feature emits: the node body `outbounds[]` (types `vless`,
`vmess`, `trojan`, `shadowsocks`, `hysteria2`, `tuic`, `anytls`, `socks`,
`http`, `ssh`, `naive`, `masque`, groups `selector`/`urltest`) and `endpoints[]`
(`wireguard` with AmneziaWG fields, `tailscale`, `openvpn-client`); the fields
`tls`, `transport` (`ws`, `grpc`, `http`, `httpupgrade`, `xhttp`),
`multiplex`, `detour`, TCP keep-alive dial fields — per the registry body schema.

## Inputs / Outputs

**Inputs:** the text of one link; a subscription or file body (a list of links, base64
of it, Xray/sing-box JSON in any of its forms, `.conf`); a `vpn://` profile
link; a name hint (the `.conf` file name); an "own source" flag
(own server or folder member — this decides whether the body is authored).

**Outputs:** a list of nodes — each with a body in core form, a name (tag), the source
text, warnings `{code, path, value}`; the reject list `dropped[]` —
entries that did not become nodes, with a code and an owner (the entry tag, the link line
or the container number); a node's share link on request.

## Data flow

```
text ─► source-kind recognition (registry, up to 2 base64 layers)
          │
          ├─ link list ─► per line: scheme dispatcher ─► link mapper ────────┐
          ├─ vpn:// ─► profile unpacking ─► INI per container ─► conf mapper ┤
          ├─ .conf ─► conf mapper ───────────────────────────────────────────┤
          └─ JSON ─► walk elements along the registry path ─► xray/singbox mapper ┤
                                                                             ▼
                               raw map in core form ─► sanitizer by body schema
                                                        │ (remove node / remove field / code)
                                                        ▼
                                                 typed node model
                                                        ▼
             rejects by verdict ─► dedup within the body ─► codes on the final body
                                                        ▼
                                              nodes + dropped[]
node ─► emit by the registry emit section ─► share link (or rejection)
```

## Rules and guarantees

- The registry is the only source of schemes, fields and texts. Registry not loaded —
  links are not parsed at all (body-form recognition works without it too,
  in a fallback order). There is no silent fallback to hand-written rules.
- The sanitizer is the only judge of values; the model is fed an already clean map.
- Node name: the `#…` remark / `remarks` / `tag` / a comment under `[Peer]` / the file
  name; none of these — `<type>-<host>-<port>`. The name is also the node's identity.
- The node's source text is stored as it came: a link byte for byte, an
  outbound object, INI text. The model and warnings are restored from it.
- An authored body (own server/folder member, kind `singbox_outbound`): the registry
  only reports, it does not change values.
- Service outbounds (`direct`, `block`, `dns`, `freedom`, `blackhole`)
  do not become nodes. From a whole config only nodes and groups are taken;
  `route`, `dns`, `inbounds` are dropped.

## Boundaries

- Where the text comes from (URL, file, paste, QR) and where it is put
  (own server or subscription) — [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md).
- Building the final config, core gates by build tags and version —
  [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md).
- The meaning of groups and chains after import — [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md).
- Showing warnings in the node list — [007-NODE_LIST](../007-NODE_LIST/FEATURE.md);
  editing a node by schema — [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md).
- The registry itself, the sanitizer, the build gate and the warning-code dictionary —
  [025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.md); the core pin —
  [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md).
- Does not do: `.ovpn`, Clash YAML (recognized, yields no nodes), hysteria v1
  as a node, Amnezia containers other than WG/AWG, network checks of a node.

## Functions

| Function | What it does | Promises | File |
|---------|-----------|----------|------|
| Share link parsing | Turns one link of any supported scheme into a node or names the reason it was rejected. | P1 P4 P5 P10 P15 | [share-link-parse.md](FUNCTIONS/share-link-parse.md) |
| Body recognition | Classifies a body as exactly one source kind, removes base64 wrappers and splits it into entries. | P3 P5 | [body-recognition.md](FUNCTIONS/body-recognition.md) |
| Xray JSON import | Turns Xray configs in any of four JSON forms into sing-box nodes, auto-select groups and chains. | P4 P8 P9 | [xray-json-import.md](FUNCTIONS/xray-json-import.md) |
| sing-box JSON import | Takes nodes, groups and `detour` chains from a sing-box outbound, array or config, including types outside the registry. | P4 P8 P9 P16 | [singbox-json-import.md](FUNCTIONS/singbox-json-import.md) |
| WireGuard / AmneziaWG import | Turns a wg-quick `.conf`, a `wg://`/`awg://` link or an Amnezia `vpn://` profile into a `wireguard` endpoint. | P8 P14 | [wireguard-amnezia-import.md](FUNCTIONS/wireguard-amnezia-import.md) |
| Export to a share link | Builds a share link from a node by the registry and asks for confirmation before copying a private key. | P2 P13 | [share-link-export.md](FUNCTIONS/share-link-export.md) |

Registry-driven parse pipeline and Parse warnings moved to [025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.md).

## Related features

- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md) — supplies the text (URL, file, paste, QR)
  and decides where the nodes go.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — builds the final config and judges core gates
  (build tags, `min_core`) that are off at parse time.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — gives meaning to the groups and
  chains that import produces.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — shows node warnings and rejects in the list.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — edits a node by the same registry body schema.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — core rejections and toggling/probing WireGuard nodes on the fly.
- [015-WARP](../015-WARP/FEATURE.md) — generates WARP nodes; `masque` links are WARP nodes.
- [016-DPI_HARDENING](../016-DPI_HARDENING/FEATURE.md) — details of TLS obfuscation and XHTTP carried by imported nodes.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — the node storage form (own link /
  source text) and backup.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) — the core pin whose version and build tags the build gate judges.
- [025-CONTRACT_REGISTRY](../025-CONTRACT_REGISTRY/FEATURE.md) — the registry pipeline, sanitizer, build gate and
  warning codes the feature executes.
- [030-TAILSCALE](../030-TAILSCALE/FEATURE.md) — what the `tailscale` endpoint parsed here becomes:
  the node, its identity, the tailnet DNS and routes.

## Maintenance notes

- **A scheme = data.** A new scheme or alias arrives with a registry sync; changing
  parse code for a scheme is a sign of a mistake (a guard forbids scheme names in the engine).
- **Identity = tag.** Any change to the name fallback or to label normalization
  (for example, the flag `🇪🇳` → `🇬🇧`) changes the identity of live nodes: it resets
  selection, disabling and rules. The corpus snapshot catches this first.
- **Dedup by content, not by address.** One server under two SNIs, or direct
  and via a relay — different nodes; coarsening the key silently eats entries.
- **Two sanitizer passes.** Over the verbatim map (sees the provider's garbage) and
  over the final body (sees values set by parsing). The order matters:
  on a matching `(code, path)` the verbatim one stays.
- **Registry notes about Dart go stale.** `emit.note` describes the behaviour of both
  sides in text and is not checked by tests — trust the tests, not the note.
