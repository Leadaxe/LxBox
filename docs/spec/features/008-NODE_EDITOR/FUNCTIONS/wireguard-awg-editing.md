[English](wireguard-awg-editing.md) · [Русский](wireguard-awg-editing.ru.md)

# WireGuard / AmneziaWG editing — fixing keys, endpoint and obfuscation in the source text

A custom WireGuard or AmneziaWG node is fixed by editing its INI, link or
JSON source; the only form is the Masquerade section (`ip`/`id`/`ib`).

| Field | Value |
|------|----------|
| Feature | [008-NODE_EDITOR](../FEATURE.md) |
| Promises | P9 P16 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Lets you fix a custom WireGuard or AmneziaWG node — the key, the
address, `Endpoint`, obfuscation parameters — by editing its source. There is
no separate form with WireGuard fields: the text in which the node arrived is
edited. The exception is masquerade: the Masquerade section on Settings writes
`ip`/`id`/`ib` into that same text.

## Parameters

| Node source | Where it is edited | How the tag is stored |
|---|---|---|
| `.conf` (wg-quick INI) | Source, as INI text | as a record field; INI byte for byte |
| link `wireguard://`, `wg://`, `awg://`, `amneziawg://` | Source, as link text | in the `#…` fragment |
| sing-box body `type: wireguard` | Source, as JSON text | in `tag` |

AmneziaWG obfuscation fields are edited only as text — as INI/link keys or as
JSON keys of the `wireguard` endpoint:

| Level | Fields |
|---|---|
| 1.0 | `jc`, `jmin`, `jmax`, `s1`, `s2`, `h1`–`h4` (number) |
| 1.5 | `i1`–`i5`; masquerade `ip`/`id`/`ib` |
| 2.0 | `h1`–`h4` as a range `"N-M"`, `s3`, `s4` |
| 3.x | `header_protection_key`, `content_padding_addition`, `rekey_after_time`, `rekey_timeout`, `reject_after_time`, `keepalive_timeout`, `max_handshake_attempts`, `random_trailers`, `disable_cookies` |

Meaning and value rules — [002, WireGuard / AmneziaWG import](../../002-NODE_IMPORT/FUNCTIONS/wireguard-amnezia-import.md).

### The Masquerade section (P16)

Settings tab, below Protocol / Server / Tag, for any WireGuard node — plain
WireGuard and AmneziaWG alike. Enabling masquerade on a plain WireGuard node
makes it AmneziaWG (Protocol caption, the `awg1.5+` level).

| Field | Key | Values | Visible |
|---|---|---|---|
| Masquerade protocol | `ip` | Off · `quic` · `dns` · `stun` · `sip` | always |
| Masquerade domain | `id` | LDH name ≤ 253 bytes (registry `id.pattern`), a die picks a random domain from the WARP wizard pool | with `quic`, `dns`, `sip` |
| Browser | `ib` | Default · `chrome` · `firefox` · `curl` | with `quic` only |

| `ip` | The domain | Required |
|---|---|---|
| `quic` | SNI of the decoy QUIC ClientHello | yes |
| `dns` | the DNS query name, visible on the wire | no: empty → the core makes up a name |
| `sip` | the SIP request host, visible on the wire | no: empty → the core makes up a name |
| `stun` | not used, the field is hidden | — |

Save of the section (its own button) writes into the source text and then
goes the Source Save path (tag from the Tag field, core check for JSON, the
transactional write, re-reading the screen):

| Source | How the keys are written |
|---|---|
| link | query edited as a string: existing pairs replaced in place, new ones appended, others byte for byte (raw `+` kept), fragment untouched |
| INI | `[Interface]` only: old `Ip`/`Id`/`Ib` lines (any case) removed, new ones after the last key line of the section; the rest byte for byte, `\r\n` kept |
| sing-box body | keys at the body root; the JSON is re-indented by 2, like Source Save |

Keys the form does not show are removed (`ib` without `quic`, `id` with
`stun`). Save is disabled while QUIC has no domain, the domain is invalid, or
the Source tab has an unsaved edit ("Source has unsaved changes.").

The section is disabled, with the reason, when:
- the node sets `i1` explicitly — `i1` wins (parsing takes `ip`/`id`/`ib`
  only without `i1`); if the source also carries masquerade keys, the text
  says they are ignored;
- the source is a packed link (`awg://` base64 `.conf`, Amnezia `vpn://`) —
  available after Edit JSON;
- the source is an Xray config or another form the section cannot write.

With `i2` set, `sip` is disabled in the list: `sip` occupies `i2`.

The WARP wizard (Advanced) uses the same fields with the same hints and
domain check, without Off.

## Inputs / Outputs

**Input:** the source text. **Output:** a new source; the node is re-read; on
Settings — Protocol "AmneziaWG (wireguard)" if the node has obfuscation
fields, otherwise `wireguard`. The AWG level (`awg`, `awg1.5`, `awg2`, the `+`
suffix for masquerade) is visible in the node row on the main screen
([007-NODE_LIST](../../007-NODE_LIST/FEATURE.md)).

## Rules and invariants

- The INI is saved as is; the `DNS` line from `[Interface]` does not go into
  the body ([002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)). The tag on
  Save — as a record field, not into the text.
- A link is saved with the tag in the fragment; parameters the link does not
  carry are lost in the link → model transition
  ([002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)).
- A sing-box body is checked by the core on save and goes into the config
  verbatim: the AmneziaWG MTU cap of 1280 is not applied to it — only a
  message ([002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md), P14 there).
- "Edit JSON" on an INI or a link replaces the source with the model's
  endpoint body — irreversibly; from then on the node is edited as JSON.
- Changing the body clears the core's verdict and enables a node disabled
  because of a core refusal (P9).
- For the core check a WireGuard body is placed under `endpoints`.
- The editor keeps no validator of its own for AWG fields (ranges) as text:
  parsing ([002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)) and the core
  judge. The Masquerade section checks only its own fields (QUIC domain
  required, domain pattern) and steps aside when `i1` is set explicitly.

## Boundaries

- Parsing INI, links, `vpn://`, the MTU clamp, codes —
  [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md).
- Cloudflare WARP with its own obfuscation fields — [015-WARP](../../015-WARP/FEATURE.md).
- Endpoint state (handshake, asleep) —
  [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md) /
  [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- AWG on top of WireGuard in a detour is allowed —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- A separate WireGuard/AmneziaWG form with dedicated fields (`097F` Phase 2b)
  is not planned (owner decision 2026-09-29, audit [591](../../../tasks/591-spec-kit-revision-audit.md)),
  except the Masquerade section ([623](../../../tasks/623-node-masquerade-section.md)).
- Packed links are not unpacked for masquerade; masquerade overrides for
  subscription nodes do not exist.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [097F](../../../tasks/097F-awg2-amneziawg2/spec.md) | In progress | AWG2; dedicated fields in the UI — an optional follow-up, not done |
| 2 | [106](../../../tasks/106-wireguard-slash-key-and-bare-cidr.md) | DONE | `/` in the key, bare IP → CIDR (parsing) |
| 3 | [110](../../../tasks/110-amnezia-vpn-link-import.md) | Done | Amnezia `vpn://` profile (parsing) |
| 4 | [112](../../../tasks/112-awg-ranged-magic-headers.md) | Done | `h1`–`h4` number or range |
| 5 | [130](../../../tasks/130-awg-detour-exclude-wireguard.md) | SUPERSEDED | "AmneziaWG (wireguard)" caption; AWG-over-WG prohibition lifted |
| 6 | [148](../../../tasks/148-awg-version-labels.md) | Implemented | Level labels `awg` / `awg1.5` / `awg2` and `+` |
| 7 | [243](../../../tasks/243-wg-import-filename-tag.md) | Implemented, partially replaced by §456 | The `.conf` file name is the tag; a tag edit is visible in the list |
| 8 | [421](../../../tasks/421-awg3-header-protection-timings.md) | Implemented, device-verified | AmneziaWG 3.0/3.1 fields |
| 9 | [450](../../../tasks/450-awg-conf-base64-link.md) | Implemented | `awg://<base64 .conf>` |
| 10 | [456](../../../tasks/456-wg-ini-as-source-tag-in-record.md) | Released v2.24.3 | INI is the source as is, the tag as a record field |
| 11 | [623](../../../tasks/623-node-masquerade-section.md) | Implemented | Masquerade section on Settings: `ip`/`id`/`ib` written to the source, explicit `i1` wins |
