[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Config template — the shipped template, its language, presets and how the client grows through it

LxBox ships one config template, `wizard_template.json`, that declares every VPN setting, the
sing-box config skeleton, the preset catalog and the DNS catalog; the app is extended by editing
this template, not only by writing code. The template language — typed variables, `@var`
substitution, `#if` conditions, `for_each` over nodes — is shared with the desktop launcher and
has a normative description and a test corpus. This feature owns the template as an entity: its
schema, its language, the preset language, what happens to user overrides when a new template
arrives with an app update, and the procedure for adding a capability through the template.

| Field | Value |
|------|----------|
| Feature | 024-TEMPLATE |
| Type | Product feature with a process part (extending the client through the template) |
| Absorbed | `§120F` (template engine: typed variables, `#if`, ref variables — moved from 003), `§033F` (preset bundles: the preset language and catalog; the rule-list part stays in 004) |
| State | ✅ written from code, 2026-09-29 |

## Purpose

The template is the single source of structure and defaults: which settings
exist, what type they are and on which screen they appear, what the core
config skeleton looks like, which presets and DNS servers can be enabled.
Settings screens and the build read the same file, so the default on the
screen and in the config match by construction. The template is a
self-contained entity: a large part of new product capabilities — a preset, a
DNS server, a variable with a field on a screen, a rule set inside a preset —
is added by editing the template alone, and the code changes only when the
language itself gains a construct.

Principles the feature protects:

1. **The template is data, not code.** `#` is an engine keyword, `@` is a
   reference to a variable, everything else is sing-box JSON; the language is
   the same on the phone and in the launcher.
2. **A malformed shipped template is a defect of the shipment.** It is rejected
   at load, not at build; user data never makes the template invalid.
3. **Storage keeps only overrides.** The user's value that equals the template
   default is not stored; a new template default therefore reaches everyone
   who did not change it, and a user's change survives a template update.
4. **A preset is a reference, not a copy.** An app update changes preset
   behaviour for everyone; the user keeps only the preset id, the values that
   differ from the defaults and the target override.

## Promises

- **P1. A variable value is coerced by its declared type, not by its appearance.**
  `bool`/`int` are coerced, `text`/`secret`/`enum`/`outbound`/`dns_servers`
  go as a string verbatim: the password `1234` stays a string, `urltest_tolerance`
  goes as a number. **Witness:** unit tests "secret/text: NOT coerced even if they
  look like a number/bool", "urltest_tolerance is substituted as a number, not
  a string". **Mutation:** guess the type from the string contents.
- **P2. No value the core would reject goes into the config.** `int`
  is clamped to 0..65535; for a variable with bounds (`dns_cache_capacity`
  1024..65535) an out-of-bounds value is replaced with the default; an empty
  required one — with the default (except `secret` and optional ones). **Witness:**
  unit tests "int is clamped to 0..65535", "an out-of-bounds cache size does not get into the
  config — 4000 applies", "empty required int → default",
  "an empty optional one is not replaced with the default". **Mutation:**
  substitute the saved string as is.
- **P3. A condition is evaluated lazily; a false one without `#else` removes the node.**
  The discarded branch is not walked; an array element drops out, a key is removed.
  **Witness:** unit tests "outer condition false — a nested one in the discarded branch
  has no effect", "false without else — the element drops out", the contract corpus
  for the template engine. **Mutation:** walk both branches.
- **P4. A malformed shipped template is rejected at load, not at
  build.** Exception: a preset with an incomplete `for_each` is removed alone, the template
  lives. **Witness:** unit tests "the real bundled wizard_template.json passes
  validation", "a broken #enable of the shipped template is rejected at load",
  "for_each without as — only this preset is removed", "the live tailscale
  preset passes validation". **Mutation:** validation only at build.
- **P5. Something unknown at runtime does not break the build, but is visible.** An undeclared
  `@name` stays a literal, an unknown `#` directive is removed — both with
  a warning code; template warnings go first in the build report
  and do not block saving. **Witness:** unit tests "unknown @name →
  the placeholder stays", "an unknown #-key neighbour is removed", widget test
  "N warnings — a snackbar, the button opens a sheet". **Mutation:** a silent drop.
- **P6. A preset's ref variable reads the global value.** Its own value
  in the preset record is ignored. **Witness:** unit tests "ref variable: value
  from globals → enabled", "no global value, only in the preset
  record → disabled". **Mutation:** read the ref from the preset record.
- **P7. `for_each` yields one body per node that actually made it into the
  config.** Zero nodes — the preset is empty; `filter` (for example `skip_presets`)
  excludes a node. **Witness:** unit tests "zero nodes — the preset is empty", "two nodes —
  repetitions in a row in node order, tags without a namespace", "filter false
  (skip_presets)". **Mutation:** serve a disabled node or one removed by a gate.
- **P8. A preset is a reference to the template:** it is expanded on every build;
  variable defaults are not stored; the user's target replaces the template's
  decision entirely, intermediate `resolve`/`sniff` are not touched. **Witness:**
  unit tests "outbound override == vpn-tag", "override vpn-1 → the #if gate drops
  resolve; route gets the override", "all template presets: defaults in vars
  ≡ empty vars". **Mutation:** a copy of the preset body in the rule.
- **P9. A broken preset does not break the build:** missing from the template — skipped and "Preset
  not found — tap to fix"; a rule without condition fields drops out. **Witness:**
  unit tests "broken preset (presetId not found) → warning + skip", "§571:
  a rule without registry condition fields drops out with a code". **Mutation:** a rule
  without conditions matches all traffic.
- **P10. A default preset is seeded once.** On a clean install the presets with
  `default: true` are added once; a preset that became default in a later
  template is added once to a user with saved state and is not brought back
  after the user deletes it. **Witness:** unit tests "defaults seeded earlier:
  the preset is added once", "the preset is already there — no duplicate",
  "a fresh install is not touched; the first seed closes the step".
  **Mutation:** re-seed on every start.
- **P11. Only overrides are stored.** In preset and template DNS server
  records a value equal to the template default is not written, choosing the
  default in the editor removes the key, and a name the template does not
  declare is dropped at the next write (`outbound` is allowed on any preset).
  **Witness:** unit tests "default, empty and undeclared are dropped, the value
  is trimmed", "editor: choosing the default removes the key", "outbound is
  legitimate on a preset without a declaration". **Mutation:** store a full
  copy of the variables.
- **P12. Preset tags live in the preset's namespace.** A DNS server or rule
  set declared inside a preset gets the tag `<preset_id>:<tag>` in the config,
  and references to it inside the preset follow; a foreign tag (a shared rule
  set, a Direction, `direct-out`) is untouched; a `for_each` preset's tags have
  no namespace. A record from the 2.23.2 form is read into the same namespace.
  **Witness:** unit tests "build tags are in the preset namespace", "record:
  ref without a repeated namespace", "an early 2.23.3 record with a repeated
  namespace is read tolerantly", "two nodes — tags without a namespace".
  **Mutation:** two presets with the same local tag — the second silently
  loses its server.
- **P13. A backup carries overrides, not the template.** Variables are
  accepted only for names declared by this build's template plus the app
  flags; unknown ones are dropped and counted; transfer to the desktop moves
  only variables marked portable in the contract registry. **Witness:** unit
  tests "replaceRaw drops a foreign vars sub-key, keeps known ones",
  "allowlist ⊆ export"; [017-BACKUP_AND_STORAGE · P5, P15](../017-BACKUP_AND_STORAGE/FEATURE.md#promises).
  **Mutation:** accept any key from the file.
- **P14. A language overlay changes only display texts.** The overlay for the
  active language rewrites `name`, `description`, `title`, `tooltip` and
  option labels; the `config` subtree and every data field stay as in the
  English template; every declared overlay loads. **Witness:** unit tests "ru
  overlay localizes display fields, config subtree untouched", "every declared
  template overlay asset loads and parses". **Mutation:** translate a
  `default_value`.

## Documentation and examples

Three documents describe the template; this feature is their index, not their
copy:

- [`docs/TEMPLATE.md`](../../../TEMPLATE.md) — the full schema of the shipped
  file: every section, variable, preset, DNS catalogue entry, the formatting
  style and the "what breaks when" list.
- `contract/docs/TEMPLATE_LANG.md` in the launcher repository
  ([Leadaxe/singbox-launcher](https://github.com/Leadaxe/singbox-launcher)) —
  the normative description of the language: keywords, variable types,
  coercion, the semantics of `#if`, `for_each`, `#tpl`, warning codes. The app
  pulls a copy into `app/contract/` with `app/tool/sync_contract.sh`; the copy
  is not committed, so there is no in-repo link.
- The shared corpus `contract/corpus/template/` in the same repository —
  fixtures the engine tests run on both sides; a new construct is added
  together with a fixture.

Syntax, verbatim from `wizard_template.json`:

**A variable with a type and options** — declared in a section; the screen
renders a field, the build coerces the value by `type`:

```json
"name": "tun_stack",
"type": "enum",
"wizard_ui": "edit",
"title": "Stack",
"tooltip": "system (default), gvisor (userspace), mixed",
"default_value": "system",
"options": [
  "system",
  "gvisor",
  "mixed"
]
```

**`@var` substitution** — a whole-string `@name` is replaced by the typed
value; `timestamp` is data and stays as is:

```json
"log": {
  "level": "@log_level",
  "timestamp": true
}
```

**`#if` as the only key of an array element** — the IPv6 address is an element
that exists only when the condition holds, otherwise it drops out:

```json
"address": [
  "@tun_address",
  {
    "#if": {
      "#and": [
        "@ipv6_enabled"
      ],
      "#value": "@tun_address6"
    }
  }
]
```

**`for_each` on a preset** — the body is repeated for each node of the type;
`filter` reads a field of the node record:

```json
"for_each": {
  "node_type": "tailscale",
  "as": "node",
  "filter": {
    "#not": "@node.skip_presets"
  }
}
```

**`#tpl` composite string** — a tag built from the node tag; an empty or
unknown value removes the node:

```json
"server": {
  "#tpl": "@{node}-dns"
}
```

**A preset declaration with `on_change`** — the `ui` object is the catalog
entry; the hidden pseudo-variable `rule_enable` recomputes a global when the
preset is toggled:

```json
"preset_id": "fakeip",
"ui": {
  "label": "FakeIP",
  "default": false,
  "num": 1130,
  "isSortable": true
},
```

```json
"#on_change": {
  "#set": {
    "@resolve_enabled": {
      "#if": {
        "#and": [
          "@rule_enable",
          "@dns_enable"
        ],
        "#value": "false",
        "#else": "true"
      }
    }
  }
}
```

**A `dns_options` entry** — a catalog server; `server` is the sing-box body,
`description` and `enabled` are catalog fields:

```json
{
  "description": "System DNS",
  "enabled": true,
  "server": {
    "type": "local",
    "tag": "local_dns_resolver"
  }
}
```

**A ref variable** — a preset shows a global variable in its editor instead of
declaring its own; the value lives in the global:

```json
{
  "ref": "resolve_enabled"
},
{
  "ref": "resolve_strategy"
}
```

## Controlled parameters

| Knob | Values | Default |
|---|---|---|
| Variable value (per section, on VPN Settings / Routing / DNS) | by the declaration: `bool`, `int` (0..65535, bounded ones — their bounds), `text`, `text_list`, `secret`, `enum` with `options`, `outbound`, `dns_servers` | `default_value` |
| Preset: on/off, variables, target | catalog `selectable_rules`; a variable per declaration; the target — `direct`, a Direction, `block`, Reject | `ui.default`, `default_value`, the template's target |
| Template DNS server: on/off, variables | catalog `dns_options.servers`; `outbound`, IP from the list | the catalog's `enabled`, `default_value` |
| Language | the overlay for the app language | English (the template itself) |

The template itself has no user knobs: there is no user template, and it
changes only with an app update. Core config keys emitted by the template
belong to the owning features (see Boundaries).

## Inputs / Outputs

**Inputs:** the shipped template file; the display-text overlay for the
active language; the user's variable values; preset and DNS server records
(id, overrides, target); nodes of the final config for `for_each`; the
contract registry of variables (portable flags).

**Outputs:** the loaded template model for screens and the build; the
skeleton, preset and DNS fragments with substituted values; engine warnings
with a code; a load error for a malformed shipment; seeded presets and
Directions on a clean install; the list of variable names the backup accepts.

## Data flow

```
app update ─► new template ─► load: overlay → construct check → model (once per language)
                                   │
   clean install ─► seed: default presets, default Directions, DNS defaults
   saved state  ─► late default presets once; records keep only overrides
                                   ▼
 variables (value ← default, type, bounds) ─► SKELETON @var/#if ─► PRESETS (expand, namespace,
                                              for_each, on_change) ─► DNS catalog ─► build (003)
                                   ▼
 backup / transfer: vars filtered by this build's template ∪ app flags; records with ref + overrides
```

## Rules and guarantees

- The template is loaded once per language; the overlay changes display
  fields only; an unreadable overlay gives the English template and a log
  error instead of a crash.
- All conditional constructs (`#if`, `#enable`, `#on_change`, `for_each.filter`,
  DNS server body placeholders) are checked at load against the declared
  variables; a violation rejects the template, except an incomplete
  `for_each`, which removes only its preset.
- Variable metadata (type, default, options) comes only from the template;
  the bounds of an `int` variable (today `dns_cache_capacity`) are set by the
  app; storage holds only the value. The `internal` section is not
  rendered, its variables are reachable by `ref` from presets.
- The template has no version of its own: its version is the app build. The
  `parser_config.version` field (5) is read into the model, but no migration
  keys on it — a breaking change of the template shape is handled by the
  storage form ([017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md)),
  not by a template version.
- `on_change` is a one-time effect at the moment of toggling, not a lock.

## Boundaries

- The build pipeline that consumes the template fragments, the final check
  and the settings lifecycle — [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md).
- What the presets do to traffic, rule order and the Routing screen —
  [004-ROUTING](../004-ROUTING/FEATURE.md); the DNS catalog's behaviour,
  groups, FakeIP — [005-DNS](../005-DNS/FEATURE.md); group templates and
  default Directions — [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md).
- The storage form, migrations of the document and backup mechanics —
  [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md); the
  overlay files and language switching — [020-APP_SHELL](../020-APP_SHELL/FEATURE.md).
- The launcher's normative documents and the corpus are pulled by the
  contract sync — [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md).
- There is no user template and no preset created by the user.
- The UI for multi-select and free input for `options_open` is not finished
  (§555 follow-up).
- Not planned (owner decision 2026-09-29, audit [591](../../tasks/591-spec-kit-revision-audit.md)): migrations by `parser_config.version`
  (the template's version is the app build); moving the bounds of `int`
  variables into the template declaration; bringing back the one-off remap of
  old `preset_id`s (§229) — such records show "Preset not found — tap to fix".

## Functions

| Function | What it does | Promises | File |
|---|---|---|---|
| Config template | Declares variable sections, the config skeleton, the preset and DNS catalogs; loaded and checked once per language with localized display texts. | P4 P14 | [config-template.md](FUNCTIONS/config-template.md) |
| Template language | Coerces variables by declared type and evaluates `@var`, `#if`/`#enable`, predicates, `for_each`/`#tpl`, ref variables and `on_change`. | P1 P2 P3 P5 P6 P7 | [template-language.md](FUNCTIONS/template-language.md) |
| Preset language and catalog | Defines how a preset is declared — `ui`, `vars`, `on_change`, `@outbound`, `for_each`, tag namespace — and lists the shipped presets. | P8 P9 P12 | [preset-bundles.md](FUNCTIONS/preset-bundles.md) |
| Template lifecycle | Describes what an app update with a new template does to saved state: seeding, late defaults, tag migration, which overrides survive, and how overrides travel in a backup. | P10 P11 P13 | [template-lifecycle.md](FUNCTIONS/template-lifecycle.md) |
| Extending the client | The procedure for a new capability through the template: what needs no code, what needs code, the checklist and the documents to update. | — | [extending-the-client.md](FUNCTIONS/extending-the-client.md) |

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — consumes the template
  fragments in its pipeline; template warnings go first in its build report.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — presets in the rule list, order
  axis, the pinned Traffic Processing preset
  ([004-ROUTING · P2](../004-ROUTING/FEATURE.md#promises)).
- [005-DNS](../005-DNS/FEATURE.md) — the DNS catalog's behaviour; defaults
  come from the template ([005-DNS · P8](../005-DNS/FEATURE.md#promises)).
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — group
  templates and the default Directions seeded from the template.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — the
  storage form, the import allowlist built from this build's template, the
  2.23.2 migration of preset DNS server references.
- [020-APP_SHELL](../020-APP_SHELL/FEATURE.md) — the language overlay files.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) — the contract sync
  that brings `TEMPLATE_LANG.md`, the registry and the corpus.

## Maintenance notes

- **Two documents to keep in step with the template.** `docs/TEMPLATE.md`
  (schema of the shipped file) and the language norm `TEMPLATE_LANG.md` in
  the launcher repository; a template change that touches either is not done
  until they match (audit 591 lists the current drift: 8 vs 11 presets, old
  `#if` keys).
- A `#if` key with a suffix (`#if1`, `#if tun-only`) is the only way to
  attach two conditions to one object: a second JSON key with the same name
  silently overwrites the first.
- A preset pseudo-variable with `#on_change` needs `default_value` and
  `required: false`, otherwise the preset silently emits nothing.
- A preset that becomes `default: true` after users already have saved state
  reaches them only through the late-defaults list; `default: true` alone is
  not enough.
- A new state key that stores a template override must be classified for the
  backup allowlist and for the Workspaces slot, otherwise it is silently
  dropped on import or shared by all sets.
