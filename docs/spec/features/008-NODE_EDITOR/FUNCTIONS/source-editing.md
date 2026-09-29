[English](source-editing.md) · [Русский](source-editing.ru.md)

# Source editing

| Field | Value |
|------|----------|
| Feature | [008-NODE_EDITOR](../FEATURE.md) |
| Promises | P5 P6 P7 P8 P9 P10 P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Lets the user change the very text a custom node is derived from — a link, a
WireGuard INI or a sing-box body — and save it so that exactly what was
written goes into the config. The node's truth is the source; the body the
core sees is derived from it and is not stored.

## Parameters

| Source kind (by text) | Caption on the Source tab | What Save does |
|---|---|---|
| JSON (starts with `{` or `[`) | "sing-box JSON: sent to the core as is. The core checks it on save." | node body only, tag from Tag into `tag`, core check, write |
| link (one line with `://`) | "Link: the tag goes into its fragment on save." | tag into the `#…` fragment, write |
| WireGuard INI | "WireGuard config: saved as is. The tag is stored separately." | text as is, tag as a record field |

The **Edit JSON** button is on the JSON tab.

## Inputs / Outputs

**Input:** the Source tab text, the Tag field, the core's `CheckConfig`
answer.
**Output:** the record's new source, the re-read node, a message.

| Situation | Message |
|---|---|
| empty | "Source is empty" |
| invalid JSON | "Invalid JSON: …" |
| object without `type`, without `outbounds`/`endpoints` | "JSON must be an outbound object with "type" or a document with "endpoints"/"outbounds"" |
| the document has no node | "The document has no node to save." |
| the core rejected it | "The core rejected the node: <core text>" |
| the input had extra content | "Only the node is saved. The rest of the input is not kept." |
| there were comments | "Comments were removed." |
| folder member, the text yielded no node | "Could not parse server config — keeping current" |
| success | "Saved" |

## Rules and invariants

- **Node body only.** A document (`endpoints`/`outbounds` at the root) is an
  input form, not a storage form: the first element that is not a service
  one (`direct`, `block`, `dns`) and not a group (`selector`, `urltest`) is
  taken, first from `endpoints`, then from `outbounds`. An array — the first
  element. `dns`, `route` and the rest of the document are not saved (P5).
- **Byte for byte.** A bare body with an unchanged tag is written as typed;
  one extracted from a document or an array — JSON with a 2-space indent
  (P6).
- **Core check** — for JSON only: the core is given a config of one node
  without `detour` (a reference to another tag is unknown to the core),
  WireGuard under `endpoints`, the rest under `outbounds`. Exactly what will
  go into the config is checked: for a sing-box body — the body itself, for
  an Xray object — the model's body. The bridge to the core is unavailable —
  saving is not blocked (P7).
- **Verbatim.** A custom sing-box body (a custom server or a folder member)
  goes into the config as written: keys outside the model survive, the
  application's gates do not edit the body, the registry only reports; the
  body's `detour` is removed — the detour is decided by the record (P8).
  Build rules — [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md).
- **Edit JSON.** For a JSON source — navigation to Source. For a link and INI
  — the warning "Edit JSON?" (the application stops checking the node, only
  the core checks on Save, "There is no way back to a link"); Continue
  replaces the source with the model's body and goes to Source ("Source
  replaced with JSON").
- **The core's verdict** is cleared only if the node body really changed; the
  node is re-enabled then. Editing the name and whitespace does not touch
  the verdict. A node disabled by the person is not enabled by an edit (P9).
- **A folder member** — transactionally: text without a node is not written
  (P10). **A standalone server** has no such protection: a link without a
  node is saved, the record stays empty (a discrepancy, no witness).
- **Comments** `//` and `/* */` are stripped before parsing; a custom body
  type unknown to the application is accepted with a warning; a body without
  `type` — refusal (P12).
- After writing, the screen re-reads the node: Source — the written text,
  JSON — the new body, notifications — fresh.

## Boundaries

- Parsing a link, INI and an Xray object — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md).
- A subscription node does not edit its source — [subscription-node.md](subscription-node.md).
- There are no field hints, autocompletion or error underlining on the Source
  tab — [json-and-schema.md](json-and-schema.md).
- The meaning of a core refusal and auto-disabling — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [017F](../../../tasks/017F-custom-nodes-and-node-settings/spec.md) | Spec | Node JSON editor; autosave (in the code — Save) |
| 2 | [094](../../../tasks/094-emoji-tags-node-settings-tabs.md) | DONE | JSON in a tab, editable (later — Source) |
| 3 | [455](../../../tasks/455-node-editor-source-json-tabs.md) | Released v2.24.3 | Source is the truth, JSON read-only, Edit JSON, core check, verbatim |
| 4 | [456](../../../tasks/456-wg-ini-as-source-tag-in-record.md) | Released v2.24.3 | INI is stored as is, the tag as a record field |
| 5 | [575](../../../tasks/575-remove-node-sections.md) | Implemented | Document sections are not written into the record |
| 6 | [576](../../../tasks/576-node-source-is-bare-body.md) | Implemented | After an edit the source holds only the node body |
| 7 | [577](../../../tasks/577-authored-json-registry-reports-only.md) | Done | Author body: the registry reports, does not edit |
| 8 | [585](../../../tasks/585-unknown-node-type-accepted.md) | Implemented | Comments stripped, unknown type accepted |
| 9 | [478F](../../../tasks/478F-core-rejected-node-auto-disable/spec.md) | Released in v2.25.0 | Editing the body clears the core's verdict |
| 10 | [237](../../../tasks/237-folder-member-node-settings.md) | Implemented | Editing a folder member is transactional |
