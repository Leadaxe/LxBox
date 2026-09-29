[English](json-and-schema.md) · [Русский](json-and-schema.ru.md)

# JSON and protocol schema — viewing and hand-editing the sing-box body

The JSON tab shows the sing-box body the core will receive; hand edits go
through the Source tab, and the schema-aware editor is only partly built.

| Field | Value |
|------|----------|
| Feature | [008-NODE_EDITOR](../FEATURE.md) |
| Promises | P6 P8 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows the node body in sing-box form and lets the user write it by hand.
Knowledge about protocol fields (which exist, of what type, what is allowed)
lives in the contract registry with the core; today the editor **does not
use** this knowledge — it only highlights JSON syntax. What is written is
checked by the core on save ([source-editing.md](source-editing.md)) and by
parse warnings ([002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)).

## Parameters

| Place | What there is |
|---|---|
| Node → JSON | read-only body, JSON highlighting, Copy JSON, Edit JSON |
| Subscription node → JSON / Source | read-only, highlighting; Source — Compact/Extended |
| Wizard → Paste JSON | an editable field with JSON highlighting |
| Node → Source | an editable monospace field **without** highlighting |

The function has no settings of its own.

## Inputs / Outputs

**Input:** the node body (a custom one — verbatim from the source, otherwise
— the model's body).
**Output:** text for viewing and copying; editing — only via Source.

## Rules and invariants

- The JSON tab of a custom node shows what the core will receive: for a
  sing-box source — its object verbatim, for a link, INI and an Xray object —
  the model's body. Without the tag prefix, detour and build steps.
- Fields absent from the application's model are preserved in a custom JSON
  body and go to the core (P8).
- **TLS/SNI are edited only as text.** A node has no separate TLS form, so a
  custom node's `tls` object changes exactly as the person wrote it. The
  HTTP wizard with HTTPS on writes `tls: {enabled: true, server_name:
  <Host>}`; ALPN, `insecure`, certificates and the rest — by editing the
  body.
- **The "replace the whole `tls` object" trap.** A form that sets one field of
  `tls` (SNI) and, on editing it, rebuilds `tls` from two keys silently loses
  the rest (`alpn`, `certificate`, …). This is how the DNS server form works
  (a known limitation, task 530, feature [005-DNS](../../005-DNS/FEATURE.md)).
  Any future schema-based node form must merge the field into the existing
  `tls`, not replace the object.
- A node from a link, rebuilt by the model, carries over as is the TLS fields
  the model does not reason about (parsing — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)).

## What is not done (the §554F direction)

The accepted direction is a JSON editor aware of the registry schema; a
schema-based form is postponed. Of phase 1 only syntax highlighting is done.
Missing:

- error underlining by sanitizer codes with paths to fields;
- a bottom sheet describing the field under the cursor (`desc_ru`/`desc_en`,
  type, `required`, `default`, `values`, `format`);
- autocompletion of keys and values by the schema;
- highlighting on the Source tab, where the editing actually happens;
- a schema-based form (hiding fields by `conflicts`/`requires`/`when`,
  masking `secret`).

The place of the schema-based editor in navigation is not decided.

## Boundaries

- The field schema, warning codes and texts — the contract registry
  ([021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.md), parsing —
  [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)).
- The whole resulting config — [019-CONFIG_EDITOR](../../019-CONFIG_EDITOR/FEATURE.md).
- DPI bypass settings (fragmentation, ECH) — [016-DPI_HARDENING](../../016-DPI_HARDENING/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [017F](../../../tasks/017F-custom-nodes-and-node-settings/spec.md) | Spec | Node JSON editor |
| 2 | [455](../../../tasks/455-node-editor-source-json-tabs.md) | Released v2.24.3 | JSON read-only; custom body verbatim, TLS fields are not lost |
| 3 | [530](../../../tasks/530-dns-server-raw-json-tls-preserved.md) | Spec (no code written) | Replacing the whole `tls` in the DNS server form — a precedent for schema-based forms |
| 4 | [554F](../../../tasks/554F-schema-driven-node-editor/spec.md) | Idea, phase 1: only highlighting done | Editor driven by the registry schema |
| 5 | [577](../../../tasks/577-authored-json-registry-reports-only.md) | Done | The registry on an author body reports, does not edit |
