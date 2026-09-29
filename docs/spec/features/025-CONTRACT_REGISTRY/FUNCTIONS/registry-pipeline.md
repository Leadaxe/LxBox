[English](registry-pipeline.md) · [Русский](registry-pipeline.ru.md)

# Registry-driven parse pipeline — one path from any input to a validated node

Every input goes through the same mapper → sanitizer → model stages driven by the contract registry,
so the app and the launcher produce the same node from the same link.

| Field | Value |
|------|----------|
| Feature | [025-CONTRACT_REGISTRY](../FEATURE.md) |
| Promises | P1 P2 P3 P4 P6 P7 P17 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Gives all inputs — a link, a `.conf`, an Xray object, a sing-box object — one
path to a node and one set of value rules. The rules come from the contract registry
that the app ships in its build and shares with the launcher: the same link in
both apps yields the same body and the same codes.

## Parameters

| Registry part | What it sets |
|---------------|-----------|
| protocols (`scheme`, `aliases`, `kind`, `sources`) | scheme spellings, body type, outbound or endpoint, allowed inputs |
| `mappers.<input>` (`uri`, `conf`, `xray`, `singbox`) | entry forms, how to build a core body from it, defaults, name fallback |
| `body` + `tls` / `transports` / `multiplex` / `dialer` | body schema: fields, types, allowed values, `on_invalid`, `secret`, `min_core` |
| `emit` | building a share link ([export](../../002-NODE_IMPORT/FUNCTIONS/share-link-export.md)) |
| `source_kinds` | document kinds ([body recognition](../../002-NODE_IMPORT/FUNCTIONS/body-recognition.md)) |
| `warnings` | texts and severity of codes ([warnings](parse-warnings.md), [dictionary](warning-codes.md)) |
| `limits` | length, depth, chain limits |

Registry version — `1.1.99`; the registry arrives with a sync and is not edited by hand
([sync and guards](registry-sync-and-guards.md)).

## Inputs / Outputs

**Input:** an entry of one kind (a line, INI, an object) and the mapper name.
**Output:** a node with a model, body, source and codes — or a "no
node" verdict with a code.

## Rules and invariants

- **Stage order:** mapper → raw map in core form → sanitizer by
  body schema → typed model → a second sanitizer pass over the
  final body → rejects by verdict → dedup within the body.
- **The sanitizer is the only judge of values.** The model is built from an already
  cleaned map; there are no hand-written value rules in parsing.
- **Registry rule verdicts:** remove the node (`drop_node`, severity `error`),
  remove the field with a code, replace the value with a code, keep it with an info code.
- **The input names itself.** Rules of the form "except a body written in core
  form" (`except_sources`) distinguish a link, INI, Xray and authored
  sing-box JSON.
- **Core gates (`min_core`, platform) are off at parse time** — a node does not
  depend on which core is running; the [build gate](registry-gate.md) judges them.
- **Registry not loaded — links are not parsed.** There is no fallback to a hand-written copy
  of the rules; the only fallback number is the AmneziaWG MTU ceiling.
- **The protocol set is the bundle's.** Schemas are loaded from the manifest of the
  shipped mirror; a protocol added by a sync loads with no code change.
- **Dedup within one body** — by signature: the node emission without `tag` and
  `detour` plus the dial path signature. The first entry survives, a repeat goes to
  the rejects with code `duplicate` and the survivor's name. Groups are not deduplicated
  ([002-NODE_IMPORT · P8](../../002-NODE_IMPORT/FEATURE.md#promises)).
- **A node's identity is its tag.** Changing the engine changes neither the hash, nor the tag,
  nor the body of any corpus case ([002-NODE_IMPORT · P10](../../002-NODE_IMPORT/FEATURE.md#promises)).
- **A node is stored as the source text** and re-parsed on every
  load; the model, the body delta and codes are derived.
- **Body fields the model does not hold** are returned into the body from the cleaned
  map: every field of the registry schema survives the "body → model → body" round trip.
- Parsing 2000 nodes fits into a reasonable time (parse cost tests).

## Boundaries

- Link schemes, body forms, JSON walks and `.conf` reading — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md);
  subscription import rules after parsing — [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md).
- The registry gate at build, gates by build tags and core version — [registry-gate.md](registry-gate.md).
- Registry sync, contract version, conformance corpus — [registry-sync-and-guards.md](registry-sync-and-guards.md).

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [026F](../../../tasks/026F-parser-v2/spec.md) | Implemented | Typed node model, three-layer parsing |
| 2 | [400](../../../tasks/400-identity-tag-mirror.md) | DEVICE-VERIFIED | Node identity = tag |
| 3 | [454](../../../tasks/454-tls-certificate-round-trip.md) | Released v2.24.3 | The node source is the original text |
| 4 | [460F](../../../tasks/460F-contract-registry-bundle/spec.md) | Released v2.25.0 | Registry in the app, sanitizer by body schema |
| 5 | [472F](../../../tasks/472F-unified-parse-pipeline/spec.md) | Released v2.25.0 | A single mapper → sanitizer → model pipeline |
| 6 | [476](../../../tasks/476-body-fields-roundtrip-guard.md) | Released v2.25.0 | Every registry field survives the round trip |
| 7 | [477](../../../tasks/477-vless-encryption-grammar.md) | Released v2.25.0 | The "remove node" verdict — at parse time |
| 8 | [480F](../../../tasks/480F-registry-driven-mapper/spec.md) | Released v2.25.0 | The mapper is an engine, sections in the registry |
| 9 | [512](../../../tasks/512-registry-scheme-set-contract-1149.md) | Released v2.25.2 | The scheme set comes from the registry |
| 10 | [532](../../../tasks/532-registry-engine-primitives-parity.md) | Done | Primitive semantics aligned with the launcher |
| 11 | [533](../../../tasks/533-contract-1-1-53-sync-overlays-body-runner.md) | Done | Draft overlays removed, body checks |
| 12 | [538](../../../tasks/538-subscription-dedup-by-identity.md) | Done | Dedup within a body |
| 13 | [545](../../../tasks/545-singbox-json-entries-through-registry-sanitizer.md) | Done | sing-box JSON entries built from the sanitizer map |
| 14 | [546](../../../tasks/546-emitters-drop-registry-rule-copies.md) | Done | Emitters without copies of registry rules |
| 15 | [547](../../../tasks/547-last-registry-rule-copies.md) | Done | The last copies of rules in code removed |
| 16 | [551](../../../tasks/551-parse-route-cache.md) | Done | The scheme route is computed once per registry composition |
| 17 | [553](../../../tasks/553-registry-expand-refs.md) | Done | Registry references are expanded on load |
| 18 | [556](../../../tasks/556-registry-debt-1157-1170.md) | Partial | Registry debt 1.1.57–1.1.70 |
| 19 | [562](../../../tasks/562-uri-scheme-dispatch-from-registry.md) | Done | Scheme dispatch read from the registry |
| 20 | [566](../../../tasks/566-scheme-literals-outside-dispatcher.md) | Done | No scheme names outside the dispatcher; protocol set from the manifest |
| 21 | [577](../../../tasks/577-authored-json-registry-reports-only.md) | Done | Authored body: codes without edits |
| 22 | [586](../../../tasks/586-endpoint-types-from-registry.md) | Implemented | Endpoint types from the registry; `openvpn-client` known without a field schema |
