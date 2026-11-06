[English](MIXINS.md) · [Русский](MIXINS.ru.md)

# L×Box — Mixins reference

A mixin is a stored edit of the built sing-box config: a target path, an
action and a JSON value. This page is the reference: the record format, the
path language, the actions, examples, error texts and limits. How to work
with the Mixins tab and the form, step by step, is in the
[Advanced user guide → Mixins](ADVANCED_USER_GUIDE.md#mixins). The formal
description of the function is
[spec/features/019-CONFIG_EDITOR/FUNCTIONS/mixins.md](spec/features/019-CONFIG_EDITOR/FUNCTIONS/mixins.md).

## Contents

- [What a mixin is](#what-a-mixin-is)
- [Record format](#record-format)
- [Path language](#path-language)
  - [Grammar](#grammar)
  - [Matching rules](#matching-rules)
  - [Path examples](#path-examples)
- [Actions](#actions)
  - [What each action does](#what-each-action-does)
  - [Number of matches](#number-of-matches)
  - [Target type errors](#target-type-errors)
- [Examples](#examples)
- [Errors](#errors)
- [Limits and interaction](#limits-and-interaction)
- [Debug API](#debug-api)

---

## What a mixin is

The app builds the sing-box config from the template and the settings. A
manual edit in Config Editor lasts only until the next rebuild. A mixin is
applied as the last step of every build, so it survives rebuilds and Lock
config is not needed.

Order of the build: presets, then the guards and the automatic removal of
broken nodes, then mixins, then the final validation. Mixins therefore see
the finished config with all tags in place.

One mixin is one operation on one path. A change that needs two operations —
an inbound plus a rule for it — is two mixins.

Enabled mixins are applied in list order, top to bottom; each one sees the
result of the ones above it. A disabled mixin is skipped. A mixin may target
a node that a mixin above it created.

---

## Record format

The Debug API and LX Backup store a mixin as a JSON object:

```json
{"id": "…", "name": "DNS listener", "enabled": true,
 "target": "inbounds", "op": "append", "value": {"type": "direct", "tag": "dns-in"}}
```

| Field | Type | Meaning | In the form |
|---|---|---|---|
| `id` | string | Assigned by the app, cannot be changed | — |
| `name` | string | Free text; may be empty, then the list shows `target → op` | Name |
| `enabled` | bool | A disabled mixin is skipped by the build | Toggle in the list |
| `target` | string | Path in the [path language](#path-language) | Target |
| `op` | string | One of `append`, `prepend`, `before`, `after`, `set`, `merge`, `remove` | Action |
| `value` | JSON | The value for the action; `remove` takes `true` or a list of keys | Value, or Keys for `remove` |

LX Backup saves mixins in the `mixins` section without `id`. Import appends
them to the end of the list and assigns new `id`s; a mixin with the same
`target`, `op` and `value` as an existing one is skipped.

The form's Value field accepts JSON5 (comments, trailing commas); on Save the
value is stored as plain JSON.

---

## Path language

The path syntax is the app's own, not JSONPath. A path denotes a set of nodes,
not the first match: `outbounds[type=vless]` is every VLESS outbound.

### Grammar

```
path       = "" | segment ("." segment)*
segment    = name | name "[" N "]" | name "[" conditions "]"
conditions = condition ("," condition)*
condition  = field "=" value
field      = name ("." name)*
```

### Matching rules

- Segments are joined by `.`: `route.rules`, `dns.servers`, `log.level`.
- An empty path is the root of the config. In messages it is shown as
  `(root)`.
- `name[0]` is a list element by index; `name.0` means the same. An index past
  the end of the list matches nothing.
- `name[k=v]` is every element of the list `name` whose field `k` equals `v`.
  Several conditions are joined by commas, and all of them must hold.
- The field in a condition may go deeper into the element:
  `outbounds[tls.enabled=true]`. An element without that field does not
  match.
- Comparison: a number with a number (`5` equals `5.0`), `true`/`false` with a
  bool, a string with a string, case-sensitive. An object or `null` in the
  field matches nothing.
- If the element's field is a list, `=` means "contains":
  `route.rules[rule_set=Ads]` matches a rule with
  `"rule_set": ["Ads", "Trackers"]`.
- The value runs up to `,` or `]`. Spaces inside are kept, so tags with
  spaces are written as they are: `outbounds[tag=S2 Fastest]`. Spaces around
  the field, around `=` and at the ends of the value are dropped.
- A value cannot contain `,`, `]` or `[`. A key name cannot contain spaces or
  any of `. [ ] , =`.
- There are no regular expressions, no `!=` and no `or`.
- A path starting with `$` is reserved and is a syntax error.

### Path examples

The tags below are from a typical config; the tags in your config differ, and
Target suggestions in the form show the real ones.

| Path | What it points at |
|---|---|
| (empty) | The root of the config |
| `log.level` | The log level field |
| `inbounds` | The list of inbounds |
| `inbounds[tag=tun-in]` | The TUN inbound |
| `outbounds[0]`, `outbounds.0` | The first outbound |
| `outbounds[type=vless]` | Every VLESS outbound |
| `outbounds[tag=PR DE-1]` | The outbound tagged `PR DE-1` |
| `outbounds[tag=S2 Fastest]` | The urltest group `S2 Fastest` |
| `outbounds[tls.enabled=true]` | Every outbound with TLS on |
| `route.rules[action=hijack-dns]` | The DNS hijack rule |
| `route.rules[action=resolve,strategy=prefer_ipv4]` | Resolve rules with the `prefer_ipv4` strategy |
| `route.rules[rule_set=Ads]` | Every rule whose `rule_set` is `Ads` or contains it |
| `route.rules[inbound=tun-in]` | Every rule whose `inbound` list contains `tun-in` |
| `dns.servers[tag=google_udp]` | The DNS server `google_udp` |
| `dns.servers[tag=ru-direct:yandex_udp]` | A colon in the value is allowed |

---

## Actions

### What each action does

| Action | Target | Effect |
|---|---|---|
| `append` | One list | Puts the value at the end; a list value adds each element in turn |
| `prepend` | One list | The same at the start; the order of the value is kept |
| `before` | List elements | Puts the value (or each element of a list value, in order) at the same level before the **first** match |
| `after` | List elements | The same after the **last** match |
| `set` | Any node | Replaces the node whole: scalar, list or object. At the root — an object only |
| `merge` | Object(s) | Deep merge: keys of the value are added or replace their own, other keys stay; object into object recursively; a list inside the value replaces the target's list whole. The value must be an object |
| `remove`, Whole node (value `true`) | Any node | Removes the node: a list element drops out, an object key disappears. The root cannot be removed |
| `remove`, Keys (value `["key", "a.b"]`) | Object(s) | Removes only the named keys; a dotted key goes inside the element; a missing key is not an error |

`merge` adds new keys at the end of the object; the core ignores key order.

### Number of matches

| Action | 0 matches | 1 match | Several matches |
|---|---|---|---|
| `set`, `merge`, `remove` | Error | Applied | Applied to each, with the same value |
| `before` | Error | Before it | Before the first |
| `after` | Error | After it | After the last |
| `append`, `prepend` | Error | Into this list | Error |

### Target type errors

| Action | Target that fails | Reason |
|---|---|---|
| `append`, `prepend` | Not a list, or several matches | `needs a single list` |
| `before`, `after` | An object key, not a list element (`inbounds`, `log.level`) | `not a list element` |
| `merge`, `remove` with Keys | Not an object | `not an object` |
| `merge` | Value is not an object | `merge needs an object value` |
| `set` | Root, value is not an object | `the root can only be set to an object` |
| `remove`, Whole node | Root | `cannot remove the root` |

---

## Examples

In the form `target` is Target, `op` is Action, `value` is Value.

**1. DNS listener for another app.** A third-party firewall such as Rethink
sends DNS queries to a resolver address of your choice, and the sing-box DNS
module answers them with the rules L×Box built. Two mixins, in this order:

```json
{"name": "DNS listener", "target": "inbounds", "op": "append",
 "value": {"type": "direct", "tag": "dns-in", "listen": "127.0.0.1",
           "listen_port": 5354, "override_address": "1.1.1.1", "override_port": 53}}
{"name": "Hijack DNS from dns-in", "target": "route.rules[action=hijack-dns]", "op": "before",
 "value": {"inbound": ["dns-in"], "action": "hijack-dns"}}
```

The first adds the inbound. The second puts a rule before the existing
`hijack-dns` rule: everything that arrives at `dns-in` goes to the DNS
module. Port 5353 on Android is often held by the system mDNS service, so the
example uses 5354; any free port works. In the firewall, the DNS server is
`127.0.0.1`, port `5354`. A check from a computer:

```
adb forward tcp:5354 tcp:5354
dig +tcp @127.0.0.1 -p 5354 example.com
```

Turning the first mixin off removes `dns-in` from the config; the pair is
meant to be turned on and off together.

**2. A local domain goes direct.** The rule goes right after the resolve rule
with the `prefer_ipv4` strategy, ahead of the template's routing rules:

```json
{"name": "NAS direct", "target": "route.rules[action=resolve,strategy=prefer_ipv4]", "op": "after",
 "value": {"domain_suffix": [".nas.home"], "outbound": "direct-out"}}
```

**3. A field on every VLESS outbound:**

```json
{"name": "TFO on VLESS", "target": "outbounds[type=vless]", "op": "merge",
 "value": {"tcp_fast_open": true}}
```

**4. Group settings the form does not offer:**

```json
{"name": "Fastest: check every minute", "target": "outbounds[tag=S2 Fastest]", "op": "merge",
 "value": {"interval": "1m", "tolerance": 100}}
```

**5. Remove keys from one node.** In the form: Action `remove`, Keys,
`tcp_fast_open, tls.utls`:

```json
{"name": "PR DE-1 without uTLS", "target": "outbounds[tag=PR DE-1]", "op": "remove",
 "value": ["tcp_fast_open", "tls.utls"]}
```

**6. Remove a whole rule:**

```json
{"name": "No ad blocking", "target": "route.rules[rule_set=Ads]", "op": "remove", "value": true}
```

**7. Replace a scalar and add a top-level key:**

```json
{"name": "Quiet log", "target": "log.level", "op": "set", "value": "warn"}
{"name": "Empty services", "target": "", "op": "merge", "value": {"services": []}}
```

---

## Errors

A mixin that cannot be applied stops the build: the config is not built, the
build reports a fatal error, and the mixin's row in the list gets a
`⚠ <reason>` line. The previously built config stays in place. The mixin
stays enabled: fix it or turn it off. The mixins below a failed one are still
applied, so one build can report several errors.

Error texts, as the build and the Debug API (`rebuild_error`, `lastError`)
report them; with the Russian interface the prefix reads
`Миксин «<name>»:`, the rest is the same:

| Text | Cause |
|---|---|
| `Mixin "<name>": <target>: syntax: <message>` | The path does not parse |
| `Mixin "<name>": <target>: no match` | Nothing matches the path |
| `Mixin "<name>": <target>: needs a single list` | `append`/`prepend` on a non-list or on several matches |
| `Mixin "<name>": <target>: not a list element` | `before`/`after` on an object key (`inbounds`, `log.level`) |
| `Mixin "<name>": <target>: not an object` | `merge` or `remove` with Keys on a non-object |
| `Mixin "<name>": <target>: merge needs an object value` | The `merge` value is not an object |
| `Mixin "<name>": (root): the root can only be set to an object` | `set` at the root with a non-object value |
| `Mixin "<name>": (root): cannot remove the root` | `remove` Whole node at the root |
| `Mixin "<name>": <target>: remove expects true or a list of keys` | The `remove` value is neither `true` nor a list of strings |
| `Mixin "<name>": duplicate tag "x" in outbounds` | The mixin added an element whose tag is already in the list |

`<name>` is the mixin's name, or `target → op` when the name is empty. An
empty target is shown as `(root)`.

Tags are checked for uniqueness after each mixin, separately in `inbounds`,
in `outbounds` together with `endpoints` (one name space, as in the core) and
in `dns.servers`. The error names the mixin that introduced the duplicate.

A path that matched yesterday can stop matching after a subscription update
renames a node; the build then fails with `no match`.

---

## Limits and interaction

- **Traffic Processing.** `prepend` on `route.rules` puts the rule before
  Traffic Processing (sniff, hijack-dns). This is allowed; such a rule sees
  connections before sniffing.
- **Guards and automatic removal.** Mixins work on the finished config: the
  automatic removal of broken nodes and the outbound sanitizer run before
  them and do not see what they add. A duplicate tag is caught before the
  core; anything else the core does not accept (an unknown field, a wrong
  type) is reported by the core when the VPN starts. For a tagged element the
  error names its tag; for a rule — only its index.
- **Manual edits in Config Editor.** A manual edit on the Config tab and
  mixins are independent. The next rebuild discards the manual edit and
  applies the mixins again. To keep an edit, write it as a mixin.
- **Lock config.** Lock config stops rebuilds altogether: the config stays as
  you saved it, and neither settings nor mixins reach it. Mixins keep the
  rebuilds and change only their own nodes. Lock config remains for testing
  a config pushed through the Debug API.
- **No preview before the first build.** After the app restarts and before
  the first build, the form shows `No config built yet` under Target: no
  match count, no suggestions, no preview. Save checks only the path syntax
  and Value; matches are checked by the next build. The Debug API preview
  answers 409 in the same state.
- **Grouping.** Mixins cannot be grouped and have no shared toggle.
- **Desktop launcher.** The launcher's backup schema does not declare the
  `mixins` section yet; the launcher warns about an unknown field when
  importing such a backup.

---

## Debug API

| Endpoint | Method | What it does |
|---|---|---|
| `/mixins` | GET | List in the order of application |
| `/mixins/{id}` | GET | One mixin |
| `/mixins` | POST | Create; the mixin goes to the end of the list |
| `/mixins/{id}` | PATCH | Change `name`, `enabled`, `target`, `op`, `value`; `id` is fixed |
| `/mixins/{id}` | DELETE | Delete |
| `/mixins/reorder` | POST | New order: `{"order": [id, …]}` with exactly the current ids |
| `/mixins/{id}/preview` | GET | The same match count, issue and fragment the form shows |

Writes accept `?rebuild=true`. A write checks the path syntax and the action
and answers 400 on an error; a match is checked only by the build, since the
target may appear after another mixin. Request bodies, response shapes and
error texts —
[Debug API reference → Mixins](api/debug-api-reference.md#mixins-crud--mixins).
