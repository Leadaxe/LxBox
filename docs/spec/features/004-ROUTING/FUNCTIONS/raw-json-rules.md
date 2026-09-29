[English](raw-json-rules.md) · [Русский](raw-json-rules.ru.md)

# Raw JSON rule — any sing-box route rule written by hand

A rule body can be written as raw sing-box JSON, which gives access to every condition and action
the Inline form does not expose.

| Field | Value |
|------|----------|
| Feature | [004-ROUTING](../FEATURE.md) |
| Promises | P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Lets the user write a core route rule in full, as in the sing-box documentation:
any conditions (including `invert`, `domain_regex`, logical `and`/`or`) and
any action — `hijack-dns`, `sniff`, `resolve`, `route-options`,
`reject` with options, `route`. This is the way out for everything the Inline form
cannot express, without a separate model for every field.

## Parameters

| Parameter | Value |
|---|---|
| Source | **Raw JSON** (the kind switch in the editor) |
| Body | one JSON object — one `route.rules` rule |

Such a rule has no target, condition sections, Wi-Fi, DNS option or Action & Resolve:
everything is inside the body. The target picker is not shown in the list row.

## Inputs / Outputs

**Inputs:** the body text.
**Outputs:** the body is put into `route.rules` as is, at its place in the list
order.

## Rules and invariants

- **Editor:** an empty body ("Enter a JSON object."), invalid JSON
  ("Invalid JSON."), a scalar and an array are not saved; for an array the hint is
  "One rule holds one JSON object. Add each object of the array as a separate
  rule." The same check applies to the form's Save button, Save in the header and Save from
  the unsaved changes dialog; the typed text stays in the field.
- **Build:** an empty body, broken JSON, a scalar — the rule is skipped with
  a warning, the rest of the config is built. An array of objects (old
  records) is laid out into several rules in a row, non-objects
  are dropped.
- Comment keys `//…` are removed recursively with a warning — the core
  rejects unknown fields; a rule consisting only of comments
  is not emitted. Other unknown fields are not touched — the core will reject them.
- The `outbound` target inside the body is checked before start, like all rules:
  a dangling one — fatal with a reason.
- Rule equality — by JSON content; a change of formatting only
  counts as an edit in the editor.
- A disabled rule is not emitted.

## Boundaries

- The meaning of the body is not checked by the client, except for `//` keys and the target; schema
  errors are caught by the core in the pre-start check.
- A body reference to a rule_set that is not in the config is not healed by the client.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [225](../../../tasks/225-raw-json-routing-rule.md) | ✅ Implemented | The Raw JSON rule kind: an object or an array, skipping a broken one with a warning |
| 2 | [350](../../../tasks/350-comment-keys-gate.md) | ✅ Released v2.19.3 | Removing comment keys `//…` |
| 3 | [447](../../../tasks/447-v2-24-0-avd-findings.md) | Fixed | Save in the editor header — the same check as the form's |
| 4 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | — | A rule record holds one object: an array is not saved in the editor |
