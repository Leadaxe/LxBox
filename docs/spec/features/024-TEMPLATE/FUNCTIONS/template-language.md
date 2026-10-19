[English](template-language.md) · [Русский](template-language.ru.md)

# Template language — typed variables, conditions and node loops

The template language turns variables, `#if` conditions and node loops (`for_each_node`,
`for_each_node_do`) into concrete sing-box JSON; the declared type decides how each value is written.

| Field | Value |
|------|----------|
| Feature | [024-TEMPLATE](../FEATURE.md) |
| Promises | P1 P2 P3 P5 P6 P7 P15 |
| State | ✅ written from code, 2026-09-28; contract 1.1.119 ([643](../../../tasks/643-contract-1-1-119-node-loops.md)), 2026-10-14 |

## What it does

Turns a declarative template with variables and conditions into concrete
JSON. There is one markup rule: `#` is an engine keyword, `@` is a reference to a
variable, everything else is data. The language standard is shared with the launcher
(see Documentation below).

## Parameters

**Variable types and coercion:**

| `type` | Into the config | Note |
|---|---|---|
| `bool` | `true` if the value after trim, case-insensitive, = `true`, otherwise `false` | |
| `int` | a number clamped to 0..65535; not a number — as a string + `template_int_invalid` | outside 0..65535 — `template_int_clamped` |
| `text_list` | an array of strings: line by line, trimmed, empty ones dropped | |
| `text`, `secret`, `enum`, `outbound`, `dns_servers` | a string verbatim | `options` do not affect coercion |
| undeclared | a string verbatim | legacy values |

A variable's value: the user's record, otherwise `default_value`. Empty
with `required` and a non-empty default → the default (not for `secret`).
A variable with bounds (`dns_cache_capacity` 1024..65535): out of bounds —
the default.

**Declaration fields that change how a value is kept:**

| Field | Effect |
|---|---|
| `unique: true` | only on `text_list` (on another type — a load error); the value never holds duplicates, first occurrence wins: the editor removes them on save, a stored value is normalized on read, the same applies to `default_value` and to a list collected by `#do` |
| `wizard_ui: "internal"` | a build-only variable: no row in any form; the stored and backup values are ignored, the base is `default_value`; never written to the state, never exported; an import drops it with `backup_var_skipped` (`reason: internal`). Unlike `hidden`, whose value stays the user's data. Outside a preset with `#do` it is a constant `default_value` without a form row |

**Constructs:**

| Construct | Meaning |
|---|---|
| `"@name"` (the whole string) | substitution of the typed value; inside a string `@` is a literal |
| `{"#tpl": "@{node}-dns"}` | a composite string; empty or unknown → the node is removed |
| `"#if…": {"#and"\|"#or": […], "#value": …, "#else": …}` | as an object key — the branch's fields merge into the object; as the only key of an array element — the element is replaced by the branch or drops out |
| `"#enable": <condition>` | the node exists only if the condition is true; the contents are not evaluated |
| `"#on_change": {"#set": {"@x": …}}` | when the variable is toggled, write derived values once |
| `{"ref": "<global>"}` in a preset's `vars` | a variable by reference to a global one |
| `for_each_node: {"#filter": …}` on a preset | the body is repeated for each node that passes; `@node`, `@node.skip_tailscale_presets`, `@node.body.<path>` in scope |
| `for_each_node_do: {"#filter": …, "#do": …, "#final": …}` on a preset | the walk collects values into the preset's own `text_list` variables; the body is expanded once after the walk, without `@node` |

Predicates: `"@v"` (bool), `{"@v": "literal"}`, `{"@v": "#notEmpty"|"#isEmpty"}`,
`{"@v": {"#in"|"#notIn": […]}}`, `{"@v": {"#matches": "re"}}`,
`{"#not": …}`; conditions nest to any depth. Legacy spellings without `#`
(`and`, `value`, `enabled: "@var"`) are read indefinitely.

**Node loops** (`TEMPLATE_LANG.md` §6.5–§6.7). A preset has at most one loop
key. Inside it the keys are a closed list, all marked with `#`, with no
unmarked aliases:

| Key | `for_each_node` | `for_each_node_do` | Meaning |
|---|---|---|---|
| `#filter` | optional | optional | a full `#if` condition without the `#if`/`#value` wrapper; no key — every node passes; the node type is a condition on `@node.body.type` |
| `#do` | load error | required | `{"@name": {"#append": <reference or #tpl>}}`: the name is a `text_list` declared in this preset's `vars`; an empty value skips the node; no dedup |
| `#final` | load error | optional | `{"@name": {"#unique": true, "#sort": true, "#limit": N}}` once after the walk; applied as unique → sort (byte order) → limit whatever the key order |

A `for_each_node_do` build goes: base value (the user's value or
`default_value`) → walk → `#do` → `#final` → `unique` of the declaration →
body once. The collected list exists only in the build and is never stored;
an empty result is `[]`, and a rule left with no condition is dropped with
`template_fragment_dropped`.

**Node access** (`TEMPLATE_LANG.md` §6.6). The name is fixed:

| Reference | Value |
|---|---|
| `@node` | the node's final tag in the config |
| `@node.<field>` | a field of the node's storage record: `skip_tailscale_presets`, `allow_local`, `allow_lan`, `allow_gateway` (contract 1.1.126) |
| `@node.body.<path>` | a field of the node body, a dot path |

A missing field is the empty value: false in a condition, the key or element
drops out of the body. A subscription node has no record, so
all four fields are false for it.

## Inputs / Outputs

**Inputs:** a template fragment (the skeleton, a preset body, a template DNS
server body), variable values, for the node loops — the nodes of the final config.
**Outputs:** a JSON fragment; engine warnings with a code and parameters
(`template_var_undeclared`, `template_unknown_directive`,
`template_int_clamped`, `template_int_invalid`, `template_fragment_dropped`),
without duplicates by the "code + parameters" pair.

## Rules and invariants

- The branch is chosen before the walk; the discarded branch is not evaluated and yields no
  warnings. Several `#if` on one object are distinguished by a suffix
  (`#if1`, `#if tun-only`) and applied in sorted order.
- An `#if` branch of an array element that is itself an array is merged into the
  parent one level up.
- At runtime an undeclared `@name` stays a literal, an unknown
  neighbouring `#` directive is removed — both with a warning. At load the same
  errors in the shipped template reject the template.
- Template warnings go first in the build report, are shown as a snackbar
  with an expandable list and do not block saving the config.
- A ref variable has no metadata or value of its own: the type, options and
  value are taken from the global one; in the rule editor it is shown with the
  global's metadata, an edit writes to the global. A copy in the preset
  record is ignored and cleaned out.
- In records of template DNS servers and presets a value equal to the default
  is not stored; an undeclared name is removed (`outbound` is legitimate on any
  preset as a universal target override).
- `on_change` is a one-time effect at the moment of toggling, not a lock: the target can
  be overridden by hand. Example: `ipv6_enabled` sets `dns_strategy` and
  `resolve_strategy` to `prefer_ipv4` / `ipv4_only`. The preset pseudo-variables
  `@rule_enable` / `@dns_enable` recompute global targets when
  the preset and its DNS part are enabled (FakeIP turns off `resolve_enabled`).
- A loop walks only nodes that are enabled and got into the final config
  (not dropped by the registry gate, the core gate or a degradation), in
  config order; the container does not matter (own server, folder member,
  subscription node). The tags of a `for_each_node` preset have no preset
  prefix (`<node>-dns`); a `for_each_node_do` body has no node, so its tags
  are prefixed as in a plain preset. The node probe does not expand loop
  presets.
- Structural errors of a loop fail the load of the whole template: the
  removed `for_each` (with `node_type` / `as`), both loop keys in one preset,
  any other key inside a loop including unmarked `filter` / `do` / `final`,
  `#do` or `#final` in `for_each_node`, `#do` on a name outside this preset's
  `text_list` variables, `@node` inside a `for_each_node_do` body, a variable
  named `node` or `node.*`. A preset is never dropped alone: the former soft
  drop (§83) is gone together with `for_each`.
- `@runtime.platform/arch/target` are declared without a value on the phone: the key
  or element drops out, in a condition — false.

## Boundaries

- How a preset is declared with these constructs — [preset language and
  catalog](preset-bundles.md); what exactly is gated by variables in presets
  and DNS — [004-ROUTING](../../004-ROUTING/FEATURE.md), [005-DNS](../../005-DNS/FEATURE.md).
- The UI for multi-select and free input for `options_open` — not finished (§555 follow-up).

## Documentation

- The normative description of the template language (keywords, variable
  types and declaration fields in §2.1, coercion rules, keyword marking in
  §4.5.1, `#if`, the node loops in §6.5–§6.7, `#tpl`) is
  `contract/docs/TEMPLATE_LANG.md` in the launcher repository
  ([Leadaxe/singbox-launcher](https://github.com/Leadaxe/singbox-launcher)),
  together with the shared corpus `contract/corpus/template/`. The app pulls a
  copy into `app/contract/` with `app/tool/sync_contract.sh`; that copy is not
  committed, so there is no in-repo link.
- The full schema of the shipped template (`wizard_template.json`: sections,
  presets, variables, DNS catalogue) is [`docs/TEMPLATE.md`](../../../../TEMPLATE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [026F](../../../tasks/026F-parser-v2/spec.md) | Implemented | `@var` substitution in the build |
| 2 | [120F](../../../tasks/120F-template-engine-typed-vars-and-if/spec.md) | Implemented | Coercion by declared type, `#if`, absorbing `enabled:"@var"` |
| 3 | [161](../../../tasks/161-urltest-tolerance-uint16.md) | Done | `int` is clamped to uint16, empty required → default |
| 4 | [232](../../../tasks/232-ipv6-opt-in-and-reactive-onchange.md) | Implemented, device-verify pending | A variable's `on_change`, IPv6 and routes behind checkboxes |
| 5 | [265](../../../tasks/265-ref-vars.md) | DEVICE-VERIFIED | Preset ref variables |
| 6 | [266](../../../tasks/266-preset-on-change.md) | DEVICE-VERIFIED | Preset `on_change` via `@rule_enable`/`@dns_enable` |
| 7 | [297](../../../tasks/297-onchange-single-dispatch.md) | Dedup implemented | A single `on_change` dispatch |
| 8 | [298](../../../tasks/298-unify-substitution-engines.md) | Implemented (§120) | One substitution engine for the skeleton and presets |
| 9 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Value norms in records: the default is not stored |
| 10 | [555](../../../tasks/555-template-lang-spec143-parity.md) | Done (items 1–6) | Array merging, `runtime.*`, warning codes with dedup |
| 11 | [570](../../../tasks/570-close-open-tails.md) | Done (waves A, B) | Tails of the template language campaign |
| 12 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Released v2.25.8, superseded by 643 | `for_each`, `@node`, `#tpl` |
| 13 | [580](../../../tasks/580-dns-cache-settings.md) | Done | Bounds of an `int` variable, out of bounds → default |
| 14 | [643](../../../tasks/643-contract-1-1-119-node-loops.md) | Released v2.25.14 | Contract 1.1.119: `for_each_node` / `for_each_node_do` with `#filter` / `#do` / `#final`, the fixed name `@node`, `unique` and `internal`, a loop error fails the whole template |
