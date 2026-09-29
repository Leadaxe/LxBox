[English](english-as-key.md) · [Русский](english-as-key.ru.md)

# English as key — dictionaries, placeholders, plurals and the English fallback

LxBox has no string identifiers: the English text written in the code is the
translation key, each other language is a `ui.json` dictionary keyed by that
text, and anything the dictionary lacks is shown in English.

| Field | Value |
|-------|-------|
| Feature | [029-LOCALIZATION](../FEATURE.md) |
| Promises | P7, P8, P9, P10, P11 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Turns an English text plus arguments into the text of the active language:
looks the English text up in the language's dictionary, picks the plural or
special form, substitutes the placeholders, and if any step fails prints the
English text with the same substitution. The same model covers the display
texts of the config template through a per-language overlay.

## Parameters

No user settings. Contracts:

| File | Shape | Notes |
|------|-------|-------|
| `assets/l10n/<tag>/ui.json` | flat map: English text → `{"value": …, "special": {"N": {"value": …}}}` | `value` is a string or a plural object with the language's forms |
| `assets/l10n/<tag>/template.json` | flat map: English display text → `{"value": "…"}` | plain strings only; `@…` and `{` are refused |
| `<tag>` | `ru`, `zh` | there is no `en` file: English lives in the code and in the template |

Plural forms: Russian `one`/`few`/`many`/`other` (CLDR), English `one`/`other`,
Chinese `other` only. Today: 1703 interface keys per language, of them 81
plurals and 8 special forms; 219 template keys.

## Inputs / Outputs

**Inputs:** the English text, the optional special-form index, the arguments
(the count first for a plural); the active language's dictionary; the decoded
template and its overlay.
**Outputs:** the display text; the localized template before it is parsed; the
English render of the same object for machine surfaces.

## Rules and invariants

- Lookup: dictionary → entry for the English text → form 0 is the root
  `value`, form N ≥ 1 is `special["N"].value`. No dictionary (English or a
  missing file), no entry, no form — the English text itself is the template.
- A plain call that meets a plural object, or a plural call that meets a plain
  string, falls back to the English text; raw JSON never reaches the screen.
- Placeholders: `%s` and `%d` in order of appearance, `%1$s` / `%2$d` by
  explicit position, `%%` a literal percent; `%d` truncates a fraction. A
  missing argument prints an empty spot, never the placeholder. A stray `%` is
  printed as is.
- A plural takes the count as the first substitution argument and picks the
  form by the language's rules; a fraction goes to `other` in Russian; an
  incomplete plural object degrades to any present form rather than throwing.
- Special forms exist for one English text that must read differently in two
  places ("OK" as a translated word in a dialog and as the Latin term
  elsewhere): the code
  names the index, the dictionary carries the variant; an index the dictionary
  lacks falls back to the English text.
- Two objects, two renders: a stored error or warning renders in the active
  language on screen and in English for the log, the Debug API and automation;
  the English render never changes with the language.
- Template overlay: applied to the decoded template before parsing, only to
  display fields (preset names, hints, option labels, rule descriptions), keyed
  by the English text itself; machine fields (config, tags, values, identity
  names) are not visited, so the emitted config is byte-identical. An overlay
  value that starts with `@` or contains `{` is ignored (it would become a
  variable reference or a substitution). Repeated English text is one key.
  Preset bodies inside conditional and template branches are visited too.
- Template-derived live labels (rule names from presets) are re-derived on a
  language change without a config rebuild; inline rule conditions are text
  the user wrote and are not touched.
- Date and time formatting follows the active language.
- Writing a string in the code: call the localizer with the English literal at
  the display site — no screen context is needed, so services and parsers can
  do it; a count goes through the plural call with `%d`; reorderable arguments
  use positional placeholders; a text stored for later goes through a typed
  message rendered at display time; adjacent literals form one key; a text that
  must not be translated (wire tag, unit, endonym, protocol term) carries
  `// l10n-exempt: <reason>` on its line or the line above — "later" is not a
  reason. A key built from a variable cannot be checked and should be avoided.

## Boundaries

- The dictionary is read-only at runtime: no in-app editing, no remote update.
- Which strings are native or core, not dictionary —
  [native-and-core-strings](native-and-core-strings.md); how a key gets into
  every dictionary — [translation-workflow](translation-workflow.md).
- The template language itself (`#if`, `for_each`, variables) —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md).
- Grammatical gender and case agreement beyond plural forms are not modelled.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [279F](../../../tasks/279F-localization/spec.md) | — | Typed messages with two renders; template overlay of display fields |
| 2 | [285](../../../tasks/285-getlocaltext-migration.md) | — | English text as the key, `ui.json` dictionaries, plurals and special forms, ARB removed |
| 3 | [452](../../../tasks/452-zh-localization.md) | Implemented | Chinese single plural form; endonym labels |
| 4 | [578](../../../tasks/578-tailscale-preset-template-for-each.md) | — | Overlay visits preset servers inside conditional and template branches |
| 5 | [588](../../../tasks/588-spec-kit-revision-audit.md) | Open | Audit: plain-string dictionary entries are invisible to the check and English at runtime |
