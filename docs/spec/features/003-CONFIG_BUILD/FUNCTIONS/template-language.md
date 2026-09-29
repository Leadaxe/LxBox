[English](template-language.md) · [Русский](template-language.ru.md)

# Template language — typed variables, conditions and per-node repetition

The template language turns variables, `#if` conditions and `for_each` repetition over nodes into
concrete sing-box JSON; the declared type decides how each value is written.

| Field | Value |
|------|----------|
| Feature | [003-CONFIG_BUILD](../FEATURE.md) |
| Promises | P1 P2 P3 P5 P6 P7 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Turns a declarative template with variables and conditions into concrete
JSON. There is one markup rule: `#` is an engine keyword, `@` is a reference to a
variable, everything else is data. The language standard is shared with the launcher
(`contract/docs/TEMPLATE_LANG.md`, corpus `contract/corpus/template/`).

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

**Constructs:**

| Construct | Meaning |
|---|---|
| `"@name"` (the whole string) | substitution of the typed value; inside a string `@` is a literal |
| `{"#tpl": "@{node}-dns"}` | a composite string; empty or unknown → the node is removed |
| `"#if…": {"#and"\|"#or": […], "#value": …, "#else": …}` | as an object key — the branch's fields merge into the object; as the only key of an array element — the element is replaced by the branch or drops out |
| `"#enable": <condition>` | the node exists only if the condition is true; the contents are not evaluated |
| `"#on_change": {"#set": {"@x": …}}` | when the variable is toggled, write derived values once |
| `{"ref": "<global>"}` in a preset's `vars` | a variable by reference to a global one |
| `for_each: {node_type, as, filter}` on a preset | the body is repeated for each matching node; `@node`, `@node.skip_presets`, `@node.body.<path>` |

Predicates: `"@v"` (bool), `{"@v": "literal"}`, `{"@v": "#notEmpty"|"#isEmpty"}`,
`{"@v": {"#in"|"#notIn": […]}}`, `{"@v": {"#matches": "re"}}`,
`{"#not": …}`; conditions nest to any depth. Legacy spellings without `#`
(`and`, `value`, `enabled: "@var"`) are read indefinitely.

## Inputs / Outputs

**Inputs:** a template fragment (the skeleton, a preset body, a template DNS
server body), variable values, for `for_each` — the nodes of the final config.
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
- `for_each` serves only nodes that got into the final config, in config
  order; the tags of such presets have no preset prefix (`<node>-dns`).
- `@runtime.platform/arch/target` are declared without a value on the phone: the key
  or element drops out, in a condition — false.

## Boundaries

- What exactly is gated by variables in presets and DNS —
  [004-ROUTING](../../004-ROUTING/FEATURE.md), [005-DNS](../../005-DNS/FEATURE.md).
- The UI for multi-select and free input for `options_open` — not finished (§555 follow-up).

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
| 12 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | Spec. Implementation started | `for_each`, `@node`, `#tpl` |
| 13 | [580](../../../tasks/580-dns-cache-settings.md) | Done | Bounds of an `int` variable, out of bounds → default |
