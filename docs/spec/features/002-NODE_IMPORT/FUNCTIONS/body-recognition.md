[English](body-recognition.md) · [Русский](body-recognition.ru.md)

# Body recognition

| Field | Value |
|------|----------|
| Feature | [002-NODE_IMPORT](../FEATURE.md) |
| Promises | P3 P5 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Looks at the text as a whole (a subscription body, a file, a paste) and decides what it is:
a list of links, base64 of something, JSON of which dialect, `.conf` or an Amnezia
profile. Then it slices it into entries and hands each one to its parser.

## Parameters

Source kinds are a registry table; they are tried by priority, the lower one wins.

| Priority | Kind | Marker | Entries |
|-----------|-----|---------|--------|
| 10 | `amnezia_link` | starts with `vpn://`, the following lines are not links | INI per WG/AWG container |
| 20 | `base64_wrapped` | ≥ 16 characters, base64 alphabet (std or url-safe) | the unpacked text is judged anew |
| 30 | `singbox_config_array` | array of configs, outbounds have `type`, no `protocol` | `[].outbounds[]` |
| 31 | `xray_config_array` | array of configs with `outbounds` | `[].outbounds[]` |
| 32 | `singbox_outbound_array` | array of objects with `type` | `[]` |
| 33 | `xray_outbound_array` | array of objects with `protocol` | `[]` |
| 34 | `xray_outbound` | object with `protocol` | the object itself |
| 35 | `xray_config` | object, `outbounds` contain `protocol` | `outbounds[]` |
| 40 | `singbox_outbound` | object with `type` | the object itself |
| 50 | `singbox_config` | object with `outbounds`/`endpoints` | `outbounds[]` + `endpoints[]` |
| 60 | `wireguard_conf` | the first non-comment section is `[Interface]` | the text itself |
| 100 | `uri_lines` | everything else | non-empty non-comment lines |

Base64 removal depth — 2 layers. List comments — `#`, `//`, `;`.

## Inputs / Outputs

**Input:** text. **Output:** one of the forms — link lines, INI texts, JSON
with a declared path to entries, or "not decoded" with a reason.

## Rules and invariants

- Every text is recognized as exactly one kind; `uri_lines` is the default
  branch and never competes with a real marker.
- The base64 branch wins only if the unpacked text looks like a document
  (`://`, `{`, `[`, `[Interface]`); otherwise it stays a list of lines. A third
  base64 layer is not removed — no nodes, no exception.
- A BOM at the start of the text, `\r\n` and the url-safe alphabet without padding do not interfere.
- An ambiguous array of configs (both `type` and `protocol`, or neither)
  stays with Xray.
- A single object with `type` is an outbound, even if it has `outbounds`
  (a single `selector`).
- JSON with comments is accepted; it is saved into the node source without them.
- JSON with `proxies` (Clash) is recognized but yields no nodes.
- A `.conf` without `[Peer]` is a legitimate text without nodes, not an error.
- An empty body, only comments, only whitespace → "not decoded";
  the decoder's reason goes to the rejects with code `core_rejected`.
- Without a loaded registry, a fallback order with the same content works;
  the fallback branches matching the registry is checked by a test.

## Boundaries

- Loading the body by URL, the response size limit — [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md).
- Format by file extension (needed for `.ovpn`) is not applied: recognition
  goes by text only.
- Clash YAML is not parsed.

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [026F](../../../tasks/026F-parser-v2/spec.md) | Implemented | Body decoder: list / base64 / JSON / INI |
| 2 | [368F](../../../tasks/368F-singbox-config-import/spec.md) | Implemented | Four sing-box JSON forms, one gate instead of three |
| 3 | [480F](../../../tasks/480F-registry-driven-mapper/spec.md) | Released v2.25.0 | The source kind is recognized by the registry table (W6) |
| 4 | [483](../../../tasks/483-remove-json-flavor.md) | Released v2.25.0 | The hand-written enumeration of JSON forms removed |
| 5 | [506](../../../tasks/506-silent-parse-loss-reasons.md) | Released v2.25.2 | The decoder's reason instead of "0 nodes" |
| 6 | [492](../../../tasks/492-engine-findings-from-launcher-review.md) | Released v2.25.0 | BOM does not interfere; base64 is removed up to two layers, the third is a silent rejection |
| 7 | [532](../../../tasks/532-registry-engine-primitives-parity.md) | Done | Recognition predicates aligned with the launcher's semantics |
| 8 | [570](../../../tasks/570-close-open-tails.md) | Wave B done | `vpn://` as the first line of a list — a list, not a profile |
| 9 | [585](../../../tasks/585-unknown-node-type-accepted.md) | Implemented | JSON with comments is accepted |
