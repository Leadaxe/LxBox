[English](coded-notifications.md) · [Русский](coded-notifications.ru.md)

# Coded notifications

| Field | Value |
|-------|-------|
| Feature | [013-DIAGNOSTICS](../FEATURE.md) |
| Promises | P22, P23 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows the user notifications that carry a stable code from the contract
registry: what happened, why and what to do — so that a dozen same-kind
entries read as one. Separately, it shows system notifications sent by the
core itself (for example, "sign in via the link" for a Tailscale node) and
opens their link on tap.

## Parameters

No settings of its own. Notification levels: `error` → "Errors", `warning` →
"Warnings", `info` → "Info"; ordered from the highest.

## Inputs / Outputs

**Inputs:** node notifications with a code, field path, value and parameters
(which codes a node gets and when — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md));
core notifications: channel, title, text, subtitle, link, number.

**Outputs:**
- one component on three surfaces: the Notifications section of the node's
  Diagnostics tab, the "Notifications" sheet from the node list, the input
  rejection sheet;
- a line under the node in the list: the title of the highest-level code,
  "+N more" for error and warning; info only — a dimmed icon without a line;
- a **Details** link to the code's page in the contract documentation
  (`…/docs/contract/warnings.ru.md#<code>`);
- Debug API: `GET /core_reject/notifications[?tag=]`, `GET
  /subs/{id}?warnings=true` — `{code, severity, path, value, params, title_en,
  text_en}`, texts always in English;
- a core system notification with an "open link" action; the line
  `platform notification: <title> (<link>)` in the core log.

## Rules and invariants

- The header shows counters per level (no zero ones); they count entries, not
  groups. A level subheading — only when there is more than one level.
- Within a level, entries of one code (2 or more) form one group tile: the
  code title, the number of entries, a line per entry (path, otherwise
  "Entry: <entry>", otherwise text; value after ` = `), the explanation and
  Details — once per group.
- Substitution into group texts (`path`, `value`, each parameter) — the value
  if it is the same for all entries, otherwise `…`: the explanation is not
  attributed to one random field.
- An entry without a code and a code seen once — a regular tile. The order of
  groups and tiles — by first occurrence of the code. Different levels are not
  merged into a group.
- A code without texts in the registry — the title from the entry text, without
  explanation blocks.
- Secret values are masked both in the entry line and in the group texts.
- A single tile is expanded right away; several are collapsed, a tap expands.
- Core notification: the channel is created by its identifier (without one —
  the shared core channel), high importance, dismissed on tap; a repeat with
  the same number replaces the previous one; cancellation by the core removes
  it. Without a link — a notification with no action.

## Boundaries

- There is no "code → list of nodes" summary across the whole subscription —
  the owner's decision.
- Which notifications a node gets, node checks, auto-disabling of nodes
  rejected by the core — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- Without the notification permission the system notification is not
  visible; the link is still available in the core log.
- Depends on OS capabilities: notification channels and permission, opening
  the link in an external app.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [036](../../../tasks/036-send-notification-clickable-url.md) | ✅ Implemented | Core notification with a link, duplicated into the core log |
| 2 | [479](../../../tasks/479-notifications-levels-like-launcher.md) | Released v2.25.0 | Node notification levels as in the launcher |
| 3 | [497](../../../tasks/497-node-notifications-tab.md) | Released v2.25.0 | Notifications in node details |
| 4 | [501](../../../tasks/501-diagnostics-notifications-merge.md) | Released v2.25.0 | Notifications inside the node's Diagnostics tab |
| 5 | [520](../../../tasks/520-debug-api-warnings-keyed-by-unique-tag.md) | Released v2.25.3 | Warnings of same-named nodes are not lost in the API |
| 6 | [572](../../../tasks/572-notifications-group-by-code.md) | Released v2.25.7 | Grouping by code, `…` for differing substitutions |
