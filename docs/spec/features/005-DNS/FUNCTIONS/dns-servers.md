[English](dns-servers.md) · [Русский](dns-servers.ru.md)

# DNS server catalog — template, preset and custom DNS servers over UDP, DoT, DoH and DoQ

All DNS servers that can reach the config are in one list, where the user enables them, picks their
channel, adds custom servers by form or JSON and overrides template ones.

| Field | Value |
|------|----------|
| Feature | [005-DNS](../FEATURE.md) |
| Promises | P1 P2 P3 P4 P10 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows every DNS server that may get into the config in one list and lets the
user manage them: enable and disable, choose the channel (`detour`) and the
address from the template's options, add custom servers via a form or JSON,
override template servers, rename without breaking references.

## Parameters

| Kind | Source | What the user edits |
|---|---|---|
| Template ("Template" badge) | template catalog | on/off, description, server variables (`outbound`, IP from the list, name resolver) |
| Preset ("Preset") | active preset | nothing here; parameters live in the preset's rule |
| Custom ("User") | user | everything: tag, description, on/off, form and JSON |
| Override ("Overridden") | custom with the tag of a template/preset server | everything + "Reset to default" |

Custom server form — type: `udp` (53), `tls` (853), `https` (443),
`quic` (853), `h3` (443), `group`, `tailscale`. Fields: address, port (empty —
the type's default port, the key is not written), path (`https`/`h3`), SNI,
name resolver (for a hostname address), the "Outbound (detour)" channel —
Direct or an active Direction. Other core types (`local`, `tcp`, `fakeip`,
`hosts`, …) — JSON tab only; no form is drawn for them.

Template catalog: `local_dns_resolver` (System DNS), `google_udp`,
`google_dot` (via `vpn-1`), `google_doh`, `cloudflare_udp`,
`cloudflare_dot` (via `vpn-1`), `safe_dns_dot` (off; Quad9 / AdGuard /
AdGuard Family), `opendns_udp`, `opendns_doh`, `quad9_doh` (via `vpn-1`),
`yandex_dot`, the `dns_shield` group.

## Inputs / Outputs

**Inputs:** server records, the template catalog, servers of active presets,
active Directions, Tailscale nodes, references from routing rules.
**Outputs:** `dns.servers[]` with a synthesized `tag`, without service fields
(`description`, `enabled`); build warnings.

## Rules and invariants

- Completion: a new template server appears with the template's `enabled`, a
  new preset server — enabled; a record whose template or preset vanished is
  deleted; custom ones — never. The user's order is kept; on screen —
  template servers, then preset, then custom.
- Variables: the user's value (after trimming whitespace) →
  `default_value` → the key is dropped. A name declared neither by the server
  nor by the template — the key is dropped with a warning. An address-type
  server with no address after substitution is not emitted.
- `detour`: Direct / `direct-out` / empty — no key. A channel absent from the
  config — the server is not emitted, warning "dropped: its detour … is not
  in the config", references are healed by the refusal policy (P2). On
  `group` and `tailscale`, `detour` is always removed.
- A hostname address in the form automatically gets a name resolver
  (`google_udp`, otherwise the first available); an IP address loses it.
  Pasting `https://host/path` is split into address, path and DoH mode (DoH3
  is preserved).
- A server referenced by an active preset or by a routing rule with a DNS
  option is emitted regardless of the toggle; in the UI — a "used by …" lock,
  no deletion (P3). A disabled preset gives no servers (P4).
- Saving: empty tag, invalid JSON, empty address (except group and
  `tailscale`), `tailscale` without a node — snackbar, no save. Renaming to an
  occupied tag — forbidden; a new server with an occupied tag — a "Replace?"
  dialog.
- Renaming cascades the tag into references (P10). Deletion — with
  confirmation.
- An override is reset to the original form with the same `enabled`.
- `tailscale`: a dangling `endpoint` or a second server on the same node —
  the server drops out with a warning.
- The JSON tab of a template/preset server is view-only: the resulting body
  and the storage record.

## Boundaries

- Preset server variables and the preset itself — [004-ROUTING](../../004-ROUTING/FEATURE.md).
- Tailscale nodes — outside the feature ([030-TAILSCALE](../../030-TAILSCALE/FEATURE.md)); only the server type is here.
- `tls` fields other than SNI (ALPN, certificates, `insecure`) — JSON only;
  SNI from the form overwrites the whole `tls` (defect §530).
- There is no one-off server latency test (§365).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [014F](../../../tasks/014F-dns-settings/spec.md) | Spec | DNS Settings screen: server list, on/off, JSON editor |
| 2 | [039](../../../tasks/039-empty-template-dns-rules.md) | Implemented | Renaming `direct_dns_resolver` → `google_udp` |
| 3 | [042](../../../tasks/042-dns-servers-merge-and-cleanup.md) | Superseded | Three-level list merge and field cleanup |
| 4 | [043](../../../tasks/043-dns-servers-refs-by-kind.md) | Released | Servers as references by kind, completion and orphan cleanup |
| 5 | [044](../../../tasks/044-dns-servers-clean-schema.md) | Released | The tag is the single source, meta separate from the body |
| 6 | [117F](../../../tasks/117F-dns-rework/spec.md) | Released | Server variables, server channel, full-screen editor, locks |
| 7 | [121](../../../tasks/121-preset-routing-king-dns-orphans.md) | Released | A disabled preset leaves no servers |
| 8 | [128](../../../tasks/128-force-direct-out-detour.md) | Won't-fix | Forced direct-out in detour is not done |
| 9 | [294](../../../tasks/294-dns-typed-model.md) | — | Typed model of servers and rules |
| 10 | [295](../../../tasks/295-dns-dual-write-fix.md) | — | A single deferred write of the screen |
| 11 | [300](../../../tasks/300-dns-controller-facade.md) | — | A single snapshot of the screen state |
| 12 | [411](../../../tasks/411-dns-doq-doh3-form.md) | Done | DoQ and DoH3 types in the form |
| 13 | [435](../../../tasks/435-node-sections-tailscale.md) | Cancelled | `tailscale` type in the form (node sections replaced by §575/§578) |
| 14 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released | Variable values in the server record; an undeclared name is dropped |
| 15 | [443](../../../tasks/443-contract-1-0-2-spec129.md) | Released | Dangling detour → server dropped, refusal policy |
| 16 | [458](../../../tasks/458-dns-server-json-tab-storage-record.md) | Ready for release | JSON tab of a template/preset server does not crash |
| 17 | [530](../../../tasks/530-dns-server-raw-json-tls-preserved.md) | Spec | SNI from the form must not wipe the rest of `tls` |
| 18 | [555](../../../tasks/555-template-lang-spec143-parity.md) | Done | Template server bodies see template variables; without an address — dropped |
| 19 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec | Preset servers per node (`for_each`) without the preset namespace |
