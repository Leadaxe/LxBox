[English](tls-fragmentation.md) · [Русский](tls-fragmentation.ru.md)

# TLS fragmentation — splitting the ClientHello so DPI cannot read the SNI

LxBox can split the TLS ClientHello of first-hop VPN nodes into several TCP
segments or TLS records, so that DPI does not see the SNI in one packet.

| Field | Value |
|-------|-------|
| Feature | [016-DPI_HARDENING](../FEATURE.md) |
| Promises | P1 P2 P3 P4 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Cuts the ClientHello into pieces so that DPI does not see the SNI in one
packet. Two sources of flags: the global checkboxes of the "TLS
Fragmentation" section (for all direct nodes at once) and fragmentation that
the provider built into an Xray subscription (for a specific node). Under
`detour` the decision is left to the core: it enables `record_fragment`
itself when there are no explicit flags.

## Parameters

| Knob | Values | Default | Core key |
|---|---|---|---|
| TLS Fragment — "Split TLS ClientHello into small TCP segments" | on/off | off | `tls.fragment` |
| TLS Record Fragment — "Split handshake into multiple TLS records (try this first)" | on/off | off | `tls.record_fragment` |
| Fallback delay | duration string | `500ms` | `tls.fragment_fallback_delay` |

| Core mode | What it does |
|---|---|
| `fragment` | ClientHello pieces — as separate TCP segments, waiting for ACK |
| `record_fragment` | pieces — as separate TLS records in one `Write`, without delays |
| both | each record — in its own segment, waiting for ACK |

The `fragment_fallback_delay` pause applies where the ACK cannot be tracked
(in particular under `detour`).

Levels (§636). The four options (both checkboxes, the delay, Mixed-case SNI)
are set on three levels:

| Level | Where | Applies to |
|---|---|---|
| node | node screen, TLS section (standalone server, folder member) | this node and its own chain |
| source | subscription or folder settings tab, TLS section | every node of the source |
| global | VPN Settings → Core → TLS Fragmentation | everything else and whatever is not set above |

Each field resolves on its own: node → source → global, the first one set
wins; `Default` means "inherit". `Off` below beats `On` above. Outbounds that
do not come from a source (template, Directions, WARP) follow the global level
only. A subscription node has no level of its own.

## Inputs / Outputs

**Inputs:** the checkboxes and the delay; node bodies after `detour` is set;
the node's Xray JSON (`streamSettings.sockopt.dialerProxy` → `freedom` with
`settings.fragment`; `streamSettings.finalmask.tcp[]` with `type: fragment`).
**Outputs:** flags in outbounds' `tls`; the code `detour_with_tls_fragment` in
the node's notifications; a build warning line.

## Rules and invariants

- The global checkboxes write flags only to outbounds without `detour` and
  with `tls.enabled: true`. The delay is written when any checkbox is on; a
  value the core cannot parse as a duration (`500`, `fast`) is replaced with
  `500ms`.
- Whether the field suits the node is asked of the registry by the body:
  naive — forbidden (the core fails with "fragment is not supported on naive
  outbound"); hysteria, hysteria2, tuic — forbidden, QUIC is not fragmented
  (`tls_not_applicable_quic`, contract 1.1.118); MASQUE `vhttp: h3` — a
  conflict, skipped silently; MASQUE
  `h2`/unset — a `tls{}` block is created if there was none, the SNI is not
  lost.
- Flags with `tls.engine` = `apple`/`windows` are removed with the code
  `tls_fragment_system_engine` (the core would reject startup).
- The node's `tls.fragment` under a `detour` assigned by the build (a chain,
  the source's "Add detour") is removed with the code
  `detour_with_tls_fragment` (info); the delay is removed if
  `record_fragment` is not set. An explicit `record_fragment` under `detour`
  stays. A `detour` written inside the input sing-box JSON does not trigger
  the relation.
- On an authored JSON body `tls.fragment` is not removed: the code is marked
  "(not applied)".
- Xray `dialerProxy` → `freedom` with `fragment` and `finalmask.tcp` with
  `type: fragment` yield `tls.fragment: true` (not `record_fragment`), if TLS
  is enabled and the node does not go through a proxy hop; `freedom` is not
  counted as a hop. `packets`, `length`, `delay`, `maxSplit` are dropped
  without a code; both forms at once — one flag. On hysteria/hysteria2 the
  entry has no effect. Other `type` values in `finalmask.tcp[]` —
  `json_field_unknown`.
- REALITY and fragmentation (§627, §636): the global and the
  subscription/folder checkboxes skip a REALITY node — a bulk setting cannot
  know whether the server accepts a split ClientHello; a checkbox set on the
  node itself applies. Mixed-case SNI never applies to REALITY, on any level.
- `Off` on any level does not remove flags that came in the node body (Xray
  `dialerProxy`, `finalmask.tcp`, authored JSON) — it only stops adding them.

- All settings are portable: the global ones go into the cross-platform
  backup as `vars`, the node and source policy as the record field `tls`
  (contract 1.1.117, LxBox side; the launcher silently ignores it). On merge
  the matched source and node keep their own policy.

## Boundaries

- Node ping and probe build their own config, but apply the same checkboxes
  and the same delay per level as the tunnel, so the ping checks the path the
  traffic takes; the node's `tls.fragment` under the probe's `detour` is
  removed the same way, but without a code.

- Skipping chain links and `strip_evasion` —
  [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FEATURE.md).
- QUIC Initial fragmentation in WARP — [015-WARP](../../015-WARP/FEATURE.md).
- Fragmentation under `detour` cannot be turned off entirely: the core does
  not distinguish an explicit `record_fragment: false` from "not set".
- Xray size and delay parameters are not emulated: the core chooses the cut
  points itself by the SNI labels.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [020F](../../../tasks/020F-security-and-dpi-bypass/spec.md) | Closed | fragment/record_fragment checkboxes, first hop only |
| 2 | [270](../../../tasks/270-naive-tls-fragment-incompatible.md) | — | naive does not get the fragmentation flags |
| 3 | [393](../../../tasks/393-masque-config-schema-migration.md) | — | MASQUE: fragmentation on h2, skipping h3 |
| 4 | [488](../../../tasks/488-xray-dialer-proxy-freedom-fragment.md) | Released v2.25.0 | `dialerProxy` → `freedom` with fragment → `tls.fragment` |
| 5 | [573](../../../tasks/573-xray-finalmask-tcp-fragment.md) | Released v2.25.7 | `finalmask.tcp` fragment → `tls.fragment` |
| 6 | [574](../../../tasks/574-tls-fragment-yields-to-detour.md) | Released v2.25.7 | `tls.fragment` yields to the build's `detour` and to the system engine |
| 7 | [606](../../../tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md) | Done | An invalid fallback delay is replaced with `500ms` |
| 8 | [606](../../../tasks/606-audit-591-export-list-tun-warp-dpi-bugs.md) | Done | Ping and probe apply the global fragmentation like the tunnel |
| 9 | [636](../../../tasks/636-tls-settings-per-node-folder-subscription.md) | Implemented | Options on node, folder and subscription; REALITY is fragmented only by the node-level flag |
| 10 | [642](../../../tasks/642-contract-1-1-118-sync.md) | Done | QUIC protocols (hysteria, hysteria2, tuic) do not get the flags |
