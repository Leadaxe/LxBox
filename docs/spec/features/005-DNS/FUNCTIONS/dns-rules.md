[English](dns-rules.md) · [Русский](dns-rules.ru.md)

# DNS rules — which server resolves which domains

DNS rules send specific queries to specific servers before `dns.final`; custom, template and rule
set rules and mirrors of routing rules form one ordered list.

| Field | Value |
|------|----------|
| Feature | [005-DNS](../FEATURE.md) |
| Promises | P4 P9 P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Decides which server resolves a particular query — before `dns.final`.
Assembles `dns.rules` from four sources into one ordered list and shows the
DNS trace of routing rules and presets as a separate group, where it can be
switched off without touching the route.

## Parameters

| Kind | Source | What can be done |
|---|---|---|
| Custom rule | user: name + sing-box DNS rule body (JSON) | add, edit, on/off, move, delete (with confirmation) |
| Template | the template's `dns_options.rules` (`name`, `enabled_default`) | on/off, move |
| By rule-set (`.srs`) | record from import / Debug API (the UI does not create them) | on/off, move |
| Preset mirror | `dns_rules` of an active preset | the preset's DNS toggle (`dns_enable`) |
| Routing rule mirror | the rule's DNS option: server and/or Force IPv4 | DNS and Force IPv4 toggles |

Currently the template carries no DNS rules of its own (`rules: []`):
everything that did not match goes to `dns.final`.

## Inputs / Outputs

**Inputs:** rule records, template rules, `dns_rules` of active presets,
routing rules with a DNS option, paths of downloaded `.srs`, the list of
actually emitted servers.
**Outputs:** `dns.rules[]`; for rule-set rules — local sets
(`type: local`, `format: binary`) in `route.rule_set`.

## Rules and invariants

- The order of `dns.rules` = the list order. New preset mirrors are inserted
  before the template block, new template rules — at the end; the user's
  saved order does not change.
- Mirrors of presets and rules are one atomic group ("From routing rules ·
  ordered as in Routing") in routing rule order. Custom rules are placed
  above or below the group as a whole, not inside it. The group's anchor is
  the position of the first preset record; without one — before the template
  rules; otherwise — at the end.
- A routing rule mirror is built only if the rule is enabled and contains no
  ports, protocols or `network` (they do not exist at DNS query time). The
  chosen server is given by tag; Force IPv4 produces a separate rule
  `{ip_version: 6, action: predefined, rcode: NOERROR}` and goes first. For
  an inline rule the match moves into a shared headless rule-set, for `.srs`
  — a reference to the same set.
- A mirror pointing to a server absent from the built list is silently not
  emitted (no warning). A server dropped because of its channel — the
  opposite: a rule pointing to it becomes `action: reject`.
- A disabled preset (routing off) gives no DNS rules; the preset's record in
  the list is only the group's position anchor and has no on/off of its own
  (a preset's DNS is switched by its DNS toggle).
- A rule-set rule without a downloaded file or without `server` is skipped
  silently.
- Custom rule: empty name — "Name is required"; body is not a JSON object —
  "Invalid JSON: …"; the client does not check the body's contents.
- If the config contains `query_type` or `ip_version`, the legacy `strategy`
  is removed from all DNS rules (P11).
- Orphans (a template rule without a template, a preset rule without an
  active preset) are removed on screen load and at build time.

## Boundaries

- The routing rule editor with the DNS option and the "DNS" badge on rules —
  [004-ROUTING](../../004-ROUTING/FEATURE.md).
- Import/export and merging of rules in a backup —
  [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).
- A custom rule's reference to a non-existent server is not caught by the
  client.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [014F](../../../tasks/014F-dns-settings/spec.md) | Spec | DNS rules on the screen (back then — one JSON array) |
| 2 | [032](../../../tasks/032-dns-rules-schema-symmetry.md) | Implemented | Rule record kind `kind` + `presetId` |
| 3 | [039](../../../tasks/039-empty-template-dns-rules.md) | Implemented | Template without a catch-all rule, the rest goes to `dns.final` |
| 4 | [061](../../../tasks/061-dns-rules-refactor/spec.md) | Done | Named toggleable rules from several sources |
| 5 | [098](../../../tasks/098-reorder-subscriptions-and-unify-dns.md) | DONE | Unified drag-and-drop of DNS rules |
| 6 | [117F](../../../tasks/117F-dns-rework/spec.md) | Released | DNS option on a rule, atomic mirror group |
| 7 | [121](../../../tasks/121-preset-routing-king-dns-orphans.md) | Released | A disabled preset leaves no DNS rules |
| 8 | [231](../../../tasks/231-dns-badge-on-rules.md) | — | "DNS" chip on rules that affect DNS |
| 9 | [246](../../../tasks/246-preset-rule-array.md) | — | Legacy `strategy` is removed with `query_type`/`ip_version` |
| 10 | [253](../../../tasks/253-preset-dns-rules-array.md) | — | Preset DNS rule array, actions without a server |
| 11 | [256](../../../tasks/256-rule-force-ipv4-dns.md) | — | Force IPv4 on a user rule |
| 12 | [257](../../../tasks/257-dns-enable-unify-and-force-ipv4-visibility.md) | — | Preset DNS toggle — `dns_enable`, Force IPv4 on the DNS screen |
| 13 | [294](../../../tasks/294-dns-typed-model.md) | — | Typed rule model |
| 14 | [306](../../../tasks/306-dns-rule-delete-confirm.md) | ✅ | Confirmation for deleting a custom rule |
| 15 | [434](../../../tasks/434-srs-rule-multiple-rule-sets.md) | Done | Several `.srs` sets in one rule |
