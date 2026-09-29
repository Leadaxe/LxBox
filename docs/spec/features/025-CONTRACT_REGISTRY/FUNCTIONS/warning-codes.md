[English](warning-codes.md) · [Русский](warning-codes.ru.md)

# Warning codes — one dictionary of reasons shared with the launcher

Every degradation of a node — a removed field, a replaced value, a dropped entry, a core refusal —
is a code from one dictionary, with a title, a text, a reason, a fix and a "Learn more" page.

| Field | Value |
|------|----------|
| Feature | [025-CONTRACT_REGISTRY](../FEATURE.md) |
| Promises | P11 P12 P13 P14 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Gives every event a stable name that both apps use, and turns that name into what the user sees:
a short title on the node row, a card with "What happened / Why it happens / What you can do", a
"Details" button that opens the page for the code, and a machine form in the Debug API. The
dictionary is `docs/contract/warnings.md` — a byte-for-byte mirror of the launcher's generated
page; it is never edited here.

## Parameters

| Level | Colour and place | Meaning |
|---|---|---|
| `error` | red; in the source's rejects, the core-reject sheet, build report | the entry is not a node or is out of the config |
| `warning` | yellow; text on the node row | the node lives, a field was removed or replaced |
| `info` | muted icon; on the row only as an icon, text in the card | a note: superfluous removed, a service line, a substitution |

| Where codes are shown | What is shown |
|---|---|
| Node row (list, subscription, main screen) | the top level: title of the highest code, `+N more` over error and warning only; info-only — an icon before the protocol |
| Notifications sheet and the Notifications section of the node screen | counters per level, subsections Errors → Warnings → Info, entries of one code grouped, each expands into the card |
| Card of a code | title; "What happened" with `path` and `value`; "Why it happens"; "What you can do" as steps; "Details" → `docs/contract/warnings.md#<code>` on branch `main` |
| Paste and single-input dialogs | the reject reason with the owner line (entry, link line, container) |
| Debug API `GET /subs/{id}?warnings=true` | per node: `code, severity, path, value, params, applied, title_en, text_en` — pinned English; nodes without codes give `[]` |
| Debug API `GET /core_reject/notifications[?tag=]` | stored core-reject codes as the row and card would render them |

Dictionary size at contract `1.1.99`: 108 codes — 24 `error`, 54 `warning`, 30 `info`.
Texts: `title_en/ru`, `text_en/ru`, optional `cause_*`, `fix_*[]`, `params[]`; `path` and
`value` are implicit substitutions.

## Inputs / Outputs

**Inputs:** a code with `path`, `value`, params and an owner tag, from the parse pipeline, the
build gate, the core-reject machine or an app class; the active locale.
**Outputs:** row text, card blocks, the link, the Debug API map.

## Rules and invariants

- **Codes are stable names.** A code is a conformance identifier shared with the launcher
  corpus; it never changes meaning, and a retired code is retired in the registry, not renamed in
  code. A new event gets a new code on the launcher side first.
- **Severity comes from the registry**, not from the app; a code missing from the registry is
  `warning`.
- **An unknown code is shown as the code itself**; a card without registry texts has no
  blocks and no "Details" link. An unfilled `{placeholder}` stays visible on purpose.
- **Secrets stay masked** in the card and in the Debug API: `value` of a `secret` field is `***`
  even when the code came from outside the sanitizer.
- **`applied: false`** replaces "What happened" with "the node is written by hand, so the app
  changed nothing in it"; reason and fix still come from the registry.
- **Counters count entries, not groups**, so the number matches the icons in the lists.
- **The Debug API is locale-free**: `title_en` and `text_en` always, regardless of the device.
- **App-only codes** (`unknown_node_type`) have their texts in the app and no
  `path`/`value`/`title_en`; `text_en` is always present.
- Language: `ru` locale reads `*_ru`, every other locale reads `*_en`.

## Boundaries

- How a code is produced — [parse-warnings.md](parse-warnings.md), [registry-gate.md](registry-gate.md);
  core rejections after start — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- Row layout and the tap targets in the lists — [007-NODE_LIST](../../007-NODE_LIST/FEATURE.md);
  the node screen — [008-NODE_EDITOR](../../008-NODE_EDITOR/FEATURE.md).
- Template and build-degradation lines (not per node) — [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md).
- Backup codes are a separate dictionary (`backup_warnings.json`) — [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).
- Dictionary vs. app divergence (audit [591](../../../tasks/591-spec-kit-revision-audit.md)):
  `unknown_node_type` is app-only by design; repeats of a server are reported with the
  dictionary code `duplicates_collapsed` on the surviving node (contract 1.1.102, task 589); `amnezia_container_choice` and
  `max_nodes_exceeded` are in the dictionary with no producer in the app.

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [460F](../../../tasks/460F-contract-registry-bundle/spec.md) | Released v2.25.0 | W2b: the card (Why / What to do / Learn more) and the documentation mirror |
| 2 | [467](../../../tasks/467-contract-111-sync.md) | Released v2.25.0 | `cause_*` and `fix_*` in the registry (contract 1.1.1) |
| 3 | [471](../../../tasks/471-warning-severity-display.md) | Released v2.25.0 | Separate info / warning / error |
| 4 | [474](../../../tasks/474-contract-116-conflicts-declarant-advisory-bool-dialer.md) | Released v2.25.0 | Text guard: every code has all texts in en and ru |
| 5 | [479](../../../tasks/479-notifications-levels-like-launcher.md) | Released v2.25.0 | Levels in the row and the sheet as in the launcher |
| 6 | [482](../../../tasks/482-warnings-text-from-registry.md) | Released v2.25.0 | Texts of app classes replaced by registry texts |
| 7 | [500](../../../tasks/500-direct-link-reject-reason.md) | Released v2.25.0 | Secrets masked in the sheet and the Debug API |
| 8 | [501](../../../tasks/501-diagnostics-notifications-merge.md) | Released v2.25.0 | Notifications inside the Diagnostics tab of the node |
| 9 | [520](../../../tasks/520-debug-api-warnings-keyed-by-unique-tag.md) | Released v2.25.3 | Debug API warnings keyed by unique tag |
| 10 | [572](../../../tasks/572-notifications-group-by-code.md) | Released v2.25.7 | Entries of one code grouped in the sheet |
| 11 | [577](../../../tasks/577-authored-json-registry-reports-only.md) | Done | `applied: false` in the card and the API |
| 12 | [585](../../../tasks/585-unknown-node-type-accepted.md) | Implemented | App-only code `unknown_node_type` |
