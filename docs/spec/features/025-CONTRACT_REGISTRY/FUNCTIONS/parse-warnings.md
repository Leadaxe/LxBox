[English](parse-warnings.md) · [Русский](parse-warnings.ru.md)

# Parse warnings — reason codes for removed fields and dropped entries

Every field that parsing removed or replaced and every entry it dropped gets a code with a text from
the registry, shared with the launcher.

| Field | Value |
|------|----------|
| Feature | [025-CONTRACT_REGISTRY](../FEATURE.md) |
| Promises | P2 P4 P5 P14 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Explains to the user what parsing did with their data: which field was removed
or replaced, which node was dropped and why. Codes and texts are shared with the launcher —
one event is named the same in both apps. The dictionary itself, its levels and where the
codes are shown are described in [warning-codes.md](warning-codes.md).

## Parameters

| Level | Where it lives | Meaning |
|---------|-----------|-------|
| `error` | in the source's rejects `dropped[]` | the entry did not become a node |
| `warning` | on the node | the node is alive, a field was removed or replaced |
| `info` | on the node or in the rejects | a note: something superfluous removed, a service line, a banner |

A code has: `code`, `path` (field path in the body), `value` (what was written),
substitution parameters, an owner (entry tag, link line, container
number). The text comes from the registry: a short title, an expanded text,
"why", "what to do", a "Learn more" link to the contract documentation
mirror. Languages — `en`, `ru`; other locales get `en`.

## Inputs / Outputs

**Input:** verdicts of the sanitizer, mappers, dedup, decoder.
**Output:** a list of codes on the node; the source's reject list.

## Rules and invariants

- **Two sanitizer passes.** Over the verbatim map of a JSON entry — it sees the
  provider's garbage (a key outside the schema, a forbidden `flow`, a foreign TLS field); over the
  final body — it sees values set by parsing, and the whole body of a
  link/INI. On a matching `(code, path)` pair the verbatim entry stays.
- **One `(code, path)` pair — one entry**; a hand-written code and a registry code
  are not duplicated.
- **The reject code is the first `error` in body field order**; if there is none —
  `type_invalid` with the tag.
- **Rejects live only in the source's `dropped[]`**; they are not moved onto a neighbouring
  working node.
- **Secrets:** the `value` of a field with the `secret` flag is `***` in the text, in the
  rejects and in the log.
- **An unknown code** is shown as the code itself with severity `warning`;
  an unfilled text placeholder stays as is.
- **Codes are recomputed on every load**, not stored.
- Reasons are shown to the user when a paste or a body yielded not a single
  node; with live nodes the rejects are visible in the source summary
  ([001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md)).

Typical parse codes: `scheme_unsupported`, `protocol_unsupported`,
`form_unrecognized`, `field_missing`, `type_invalid`, `uri_too_long`,
`core_rejected`, `duplicates_collapsed`, `provider_banner_link`, `unknown_key`,
`flow_deprecated`, `tls_not_applicable_quic`, `obfs_unknown`, `awg_mtu_clamped`,
`awg_mtu_high`, `wgconf_dns_ignored`, `detour_*`, `dialer_proxy_unusable`,
`unknown_node_type`. The full dictionary — `docs/contract/warnings.md`;
`unknown_node_type` is the one app-own code, it is not in the shared dictionary
(the former app-own `duplicate` became the dictionary code `duplicates_collapsed`,
contract 1.1.102, task 589).

## Boundaries

- Which code a given link, body or `.conf` defect produces — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)
  (its promise [002-NODE_IMPORT · P5](../../002-NODE_IMPORT/FEATURE.md#promises) names the loss).
- Showing codes on the node row and the "Why / What to do / Learn more" card —
  [warning-codes.md](warning-codes.md), [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md).
- Build gate codes — [registry-gate.md](registry-gate.md); core rejections after start —
  [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- The code dictionary is edited on the launcher side and arrives with a sync.

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [321F](../../../tasks/321F-xray-json-parsing/spec.md) | Implemented | An unsupported protocol is not lost silently |
| 2 | [460F](../../../tasks/460F-contract-registry-bundle/spec.md) | Released v2.25.0 | W2a: registry codes on the node with `path`/`value`; W2b: the card and the documentation mirror |
| 3 | [469](../../../tasks/469-contract-114-quic-tls-not-applicable.md) | Released v2.25.0 | Stripping uTLS/REALITY on QUIC, `tls_not_applicable_quic` |
| 4 | [470](../../../tasks/470-corpus-body-runner-warnings.md) | Released v2.25.0 | The corpus checks `warnings[]` |
| 5 | [471](../../../tasks/471-warning-severity-display.md) | Released v2.25.0 | Separate info / warning / error |
| 6 | [472F](../../../tasks/472F-unified-parse-pipeline/spec.md) | Released v2.25.0 | A pass over the verbatim map of a JSON node |
| 7 | [482](../../../tasks/482-warnings-text-from-registry.md) | Released v2.25.0 | Warning texts from the registry |
| 8 | [485](../../../tasks/485-warnings-without-producers.md) | Released v2.25.0 | Codes without producers |
| 9 | [500](../../../tasks/500-direct-link-reject-reason.md) | Released v2.25.0 | Rejection reason of a single input, masking secrets |
| 10 | [506](../../../tasks/506-silent-parse-loss-reasons.md) | Released v2.25.2 | Reasons instead of a silent loss |
| 11 | [561](../../../tasks/561-dropped-only-in-source-summary.md) | Done | Rejects — only in the source summary |
