[English](import-rules.md) · [Русский](import-rules.ru.md)

# Subscription import rules

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Gives a subscription a set of "if the node is like this — disable / enable / replace a
field" rules, applied to **every parse of its body**. The rules work on the
canonical JSON of the node, not on the body text, so one rule acts
the same on URI lists, Xray JSON and INI.

## Parameters

Subscription → Filters tab:

| Parameter | Values | Default |
|---|---|---|
| Enable import rules | master toggle of the set | on |
| Rule on/off | on each rule | on |
| Conditions | path in the node JSON (`tag`, `server_port`, `tls.utls.fingerprint`; empty = search everywhere) · `contains` / `equals` / `matches` (regex) · negation · case sensitivity | `contains`, case-insensitive |
| Combining conditions | AND / OR | AND |
| Action | **Disable** · **Enable** · **Replace** | Replace |
| Replace | Target path (empty = across the whole node) · Set whole value / Substitute part · Find inside the value · New value with groups `$1…$9`, `$$` = `$` | Set whole value |

## Inputs / Outputs

**Input:** the parsed subscription nodes and its rules.
**Output:** a per-node outcome — "disable", "force enable" or nothing;
the patched node JSON (goes into the config); traces of replacements "path: was → became"
(visible when viewing the node; the node is marked "Modified by import rules").

## Rules and invariants

- Rules run top to bottom; Replace changes the JSON, the next rule sees
  the changed form.
- Enable/Disable: **the last matching one wins** — "disable everything" +
  targeted Enables give an allowlist, and vice versa.
- A Disable outcome sets a mark ([node-disable.md](node-disable.md)), an Enable outcome
  clears it — including a manual one; applied after TTL cleanup, i.e. the rule
  is stronger than cleanup and manual choice.
- Every application starts from a clean node: repetition does not accumulate replacements.
- Replace does not change the mark key (node name), even if it changes the server or keys.
- A non-existent path: the condition is false (with negation — true), a replacement on it
  is not written. The value type is preserved (a port stays a number). A path
  pointing to a non-leaf is compared as compact JSON.
- An unusable rule (no conditions, empty pattern, broken regex, "Set whole
  value" without a path, "across the whole node" without a search pattern) is skipped and
  marked "invalid pattern — skipped"; the editor does not let it be saved.
- Changing rules does not recompute existing nodes: shown is
  "Rules changed. Refresh the subscription to apply them." with an Apply button
  that updates the subscription over the network; the result — how many nodes came and how many
  were disabled.
- Rehydration at start applies Replace to nodes from the cache; the
  Disable/Enable marks are recomputed only on a successful network update.
- The editor's "Matches" tab previews matches on the current nodes.

## Boundaries

- Not applied to folders and single servers.
- Parsing the body before the rules — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [302](../../../tasks/302-subscription-import-rewrite-rules.md) | implemented (device-verified) | Replace/Disable rules over the node JSON, per-subscription |
| 2 | [307](../../../tasks/307-import-rules-prefix-accumulation.md) | implemented, device-pending | Application from a clean node, replacement across the whole node |
| 3 | [332](../../../tasks/332-import-rules-enable-and-bulk-toggle.md) | ✅ device-pending | Enable action, "the last one wins" |
| 4 | [400](../../../tasks/400-identity-tag-mirror.md) | Implemented, DEVICE-PENDING | Replace no longer breaks the mark |
| 5 | [346](../../../tasks/346-subs-full-crud-debug-api.md) | — | CRUD of rules via the Debug API |
