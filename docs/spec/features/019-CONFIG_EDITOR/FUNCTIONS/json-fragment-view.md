[English](json-fragment-view.md) · [Русский](json-fragment-view.ru.md)

# Config JSON fragment view

| Field | Value |
|-------|-------|
| Feature | [019-CONFIG_EDITOR](../FEATURE.md) |
| Promises | P10, P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows a piece of the final config where it is needed: the JSON tab on the node
details screen (with copying of the node and its detour chain) and the View
tab of the custom rule editor (how the rule will land in the config). The view
is read-only, with highlighting and the same selection menu as the editor.

## Parameters

| Place | Action | What is copied |
|-------|--------|----------------|
| Node without detour | "Copy JSON" icon | the node's outbound without the `detour` field |
| Node with detour | "Copy server JSON" | the node's outbound without `detour` |
| — | "Copy detour" | the first detour hop without `detour`; no hop — "No detour for this node" |
| — | "Copy server + detour" / "+ detours(N)" | an array: the node and the whole hop chain, each without `detour` |
| Rule | copy button on each block | the rule entry in storage; the preview for the core |

## Inputs / Outputs

**Inputs:** the node tag from the list; the config model; the rule being
edited.

**Outputs:** JSON on screen; the clipboard; a snackbar about copying or "no
data for the tag".

## Rules and invariants

- **The node comes from what the core is running.** With the tunnel up, the
  JSON and copies are taken from a snapshot of the running config, otherwise
  from the saved one; no tag — a message, not silence.
- **The node's JSON tab** shows the outbound itself, and with a detour — the
  "node + hops" array.
- **Copies are self-contained:** the `detour` field is removed from every
  element so that a paste does not refer to a missing tag.
- **The rule preview does not filter by `enabled`:** a disabled rule shows
  what it will produce when enabled; the config build still skips disabled
  ones. A preset shows only non-empty sections (`dns_options`, `route`); a
  rule-set that has not been downloaded — a path placeholder. A broken preset
  or an error — a comment in the text, not a crash.

## Boundaries

- There is no editing here — a node is edited in [008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.md),
  a rule — in [004-ROUTING](../../004-ROUTING/FEATURE.md).
- The node link (`Copy URI`) is not JSON and lives in the node menu ([002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md)).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [064](../../../tasks/064-view-tab-preview-independent-of-enabled.md) | done (v1.7.4) | The rule preview does not depend on whether it is enabled |
| 2 | [099](../../../tasks/099-copy-json-into-view-json.md) | DONE | JSON copy variants moved from the node menu to the JSON view |
| 3 | [258](../../../tasks/258-outbound-view-tabs-runtime-chain.md) | done | Node screen with Overview and JSON tabs |
| 4 | [311](../../../tasks/311-running-config-from-kernel.md) | implemented | Node JSON from a snapshot of the running core; the editor — from the file |
| 5 | [554F](../../../tasks/554F-schema-driven-node-editor/spec.md) | Idea; only highlighting done | Highlighted JSON view instead of plain text |
