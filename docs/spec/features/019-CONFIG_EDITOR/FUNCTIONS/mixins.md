[English](mixins.md) · [Русский](mixins.ru.md)

# Mixins — stored edits of the final config that survive rebuilds

A mixin is a stored operation on the built sing-box config: a target path, an
action and a JSON value. It adds what the template does not offer (an extra
inbound, a rule, a field on a group of outbounds) without pinning the config.

| Field | Value |
|-------|-------|
| Feature | [019-CONFIG_EDITOR](../FEATURE.md) |
| Promises | P12 |
| User reference | [docs/MIXINS.md](../../../../MIXINS.md) |
| State | ✅ written from code, 2026-11-01 |

## What it does

- **Where.** Config screen (≡ → Config Editor), the **Mixins** tab next to
  **Config**. The Config tab shows the config with mixins already applied.
- **When.** Last step of every build: after presets, after the guards and the
  automatic removal of broken nodes, before the final validation. Enabled
  mixins run top to bottom; each one sees the result of the ones above it.
- **Lifetime.** Mixins are settings: a rebuild applies them again, they are
  saved in LX Backup (`mixins` section) and are available through the Debug
  API at `/mixins`.

## The mixins list

Each row: drag handle (order = apply order), name, `target → action` below it,
toggle on the right. If the last build failed because of a mixin, its row gets
a `⚠ <reason>` line. Long tap — Duplicate, Delete. The (+) button opens an
empty form. Toggle, reorder and delete are saved at once and trigger a
rebuild.

## Mixin record

| Form field | Record key | Meaning |
|------------|------------|---------|
| Name | `name` | Free text, may be empty; an empty name is shown as `target → action` |
| — (toggle in the list) | `enabled` | A disabled mixin is skipped by the build |
| Target | `target` | Path in the config, see "Path language" |
| Action | `op` | `append`, `prepend`, `before`, `after`, `set`, `merge`, `remove` |
| Value | `value` | Any JSON; JSON5 is accepted in the form (comments, trailing commas). For `remove`: `true` or a list of keys |

In the Debug API and in LX Backup a mixin is the object
`{"target": "...", "op": "...", "value": <json>, "name": "...", "enabled": true}`.
Import from a backup appends to the end of the list; a mixin with the same
`target` + `op` + `value` is skipped, not duplicated.

## Path language

The app's own syntax, not JSONPath.

```
path      = "" | segment ("." segment)*
segment   = name | name "[" N "]" | name "[" conditions "]"
conditions = condition ("," condition)*
condition = field "=" value
field     = name ("." name)*
```

- Segments are joined by `.`: `route.rules`, `dns.servers`, `log.level`.
- An empty path is the root of the config.
- `name[0]` — list element by index. `name.0` means the same.
- `name[k=v]` — every element of list `name` whose field `k` equals `v`.
  Several conditions are joined by commas and must all hold:
  `route.rules[action=resolve,strategy=prefer_ipv4]`.
- The field in a condition can go deeper into the element: `outbounds[tls.enabled=true]`.
- Comparison: a number with a number, `true`/`false` with a bool, everything
  else as strings, case-sensitive. If the element's field is a list, `=` means
  "contains": `route.rules[rule_set=Ads]` matches a rule with
  `"rule_set": ["Ads", "Trackers"]`.
- The value runs up to `,` or `]`; spaces inside are allowed:
  `outbounds[tag=S2 Fastest]`. A value cannot contain `,` or `]`.
- No regular expressions, no `!=`, no `or`. A path starting with `$` is
  reserved and is a syntax error.

A path denotes a set of nodes: `outbounds[type=vless]` is every VLESS
outbound, not the first one.

## Actions

| Action | Target | Effect |
|--------|--------|--------|
| `append` | one list | Value at the end; if the value is a list, each element in turn |
| `prepend` | one list | Same at the start; the order of the value is kept |
| `before` | list elements | Value (or each element of a list value, in order) at the same level before the **first** match |
| `after` | list elements | Same after the **last** match |
| `set` | any node | Replaces the node whole: scalar, list or object. At the root — an object only |
| `merge` | object(s) | Deep merge: keys of the value are added or replace their own, other keys stay; object into object recursively; a list inside the value replaces the target's list whole. The value must be an object |
| `remove`, value `true` | any node | Removes the node: a list element drops out, an object key disappears. The root cannot be removed |
| `remove`, value `["key", "a.b"]` | object(s) | Removes only the named keys; a dotted key goes inside the element; a missing key is not an error |

By the number of matches:

| Action | 0 | 1 | several |
|--------|---|---|---------|
| `set`, `merge`, `remove` | error | applied | applied to each, same value |
| `before` | error | before it | before the first |
| `after` | error | after it | after the last |
| `append`, `prepend` | error | into this list | error |

## Form

- **Target** — text field with suggestions by cursor position: object keys
  after the start or `.`; fields and indexes after `[`; values of the field
  after `=`; unused fields after `,`; `.` after `]`. The light bulb icon in
  the field (tooltip Suggestions) turns suggestions on and off; the choice is
  remembered between openings and does not trigger a rebuild. Below the field —
  live status: `✓ 1 match`, `✓ N matches → before first` / `→ after last`,
  `✗ no match`, `✗ syntax: <message>`, `✗ needs a single list`,
  `✗ not a list element`.
- **Action** — the seven actions. For `remove` there is a Whole node / Keys
  switch; with Keys the Value field is replaced by a comma-separated key list.
- **Value** — JSON editor with Format.
- **Preview** — the target's parent after applying: one line per element,
  `+` inserted, `~` changed, `-` removed; tap a line for the element's full
  JSON. A scalar target shows one line `old → new`.

Suggestions, status and preview come from the current built config as it was
before this mixin, with the enabled mixins above it applied. Save is inactive
while the status shows ✗ or Value does not parse.

## Examples

A DNS listener for another app (Rethink and the like) — two mixins in this
order:

```json
{"name": "DNS listener", "target": "inbounds", "op": "append",
 "value": {"type": "direct", "tag": "dns-in", "listen": "127.0.0.1",
           "listen_port": 5354, "override_address": "1.1.1.1", "override_port": 53}}
{"name": "Hijack DNS from dns-in", "target": "route.rules[action=hijack-dns]", "op": "before",
 "value": {"inbound": ["dns-in"], "action": "hijack-dns"}}
```

Port 5353 on Android may be held by the system mDNS service, so the example
uses 5354; any free port works.

Other actions:

```json
{"target": "route.rules[action=resolve,strategy=prefer_ipv4]", "op": "after",
 "value": {"domain_suffix": [".nas.home"], "outbound": "direct-out"}}
{"target": "outbounds[type=vless]", "op": "merge", "value": {"tcp_fast_open": true}}
{"target": "outbounds[tag=PR DE-1]", "op": "remove", "value": ["tcp_fast_open", "tls.utls"]}
{"target": "route.rules[rule_set=Ads]", "op": "remove", "value": true}
{"target": "log.level", "op": "set", "value": "warn"}
{"target": "", "op": "merge", "value": {"services": []}}
```

## Errors

A mixin that cannot be applied stops the build: the config is not built, the
error appears as a fatal build error, and the mixin's row in the list gets a
`⚠` line. Error text:

- `Mixin "<name>": <target>: no match`
- `Mixin "<name>": <target>: needs a single list` — `append`/`prepend` on a
  non-list or on several matches;
- `Mixin "<name>": <target>: not a list element` — `before`/`after` on a key
  of an object (`inbounds`, `log.level`);
- `Mixin "<name>": <target>: not an object` — `merge` or `remove` with keys on
  a non-object; `merge needs an object value` — the value is not an object;
- `Mixin "<name>": duplicate tag "x" in outbounds` — after all mixins, tags
  are checked for uniqueness in `inbounds`, in `outbounds` + `endpoints` (one
  name space) and in `dns.servers`.

An empty path is shown as `(root)`. The mixin stays enabled: fix it or turn it
off.

## Rules and invariants

- Mixins work on the raw config: the automatic removal of broken nodes and the
  outbound sanitizer do not see them. A value the core rejects (unknown field,
  wrong type) is reported by the core at start; for a tagged element the error
  is tied to its tag, for a rule — only to its index.
- `prepend` on `route.rules` puts the rule before Traffic Processing (sniff,
  hijack-dns). This is allowed; the target is the user's choice.
- `merge` adds new keys at the end of the object; the core ignores key order.
- A manual edit in the Config tab and mixins are independent: the next
  rebuild discards the manual edit and applies the mixins again.
- Lock config stops rebuilds altogether; mixins keep the rebuilds and change
  only their own nodes.

## Boundaries

- After the app restarts and before the first build, the form shows
  `No config built yet` under Target: no match count, no suggestions, no
  preview. Save checks only the path syntax and Value; matches are checked by
  the next build.
- No grouping of mixins and no shared toggle.
- The launcher's backup schema does not declare the `mixins` section yet; the
  launcher warns about an unknown field when importing such a backup.
- Debug API endpoints (list, create, `PATCH`, delete, reorder, preview of one
  mixin) — [Debug API reference](../../../../api/debug-api-reference.md#mixins-crud--mixins).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [704](../../../tasks/704-config-mixins.md) | In progress | Mixins: path language, seven actions, Mixins tab, LX Backup, Debug API |
