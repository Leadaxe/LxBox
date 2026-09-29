[English](translation-workflow.md) · [Русский](translation-workflow.ru.md)

# Translation workflow — adding a string or a language and the four CI checks

Adding a language to LxBox means one interface dictionary, one template overlay,
one native strings file and a few declarations; adding a string means one
English literal in the code and one entry per language. Four checks run in
strict mode on every push and fail the build on anything incomplete.

| Field | Value |
|-------|-------|
| Feature | [029-LOCALIZATION](../FEATURE.md) |
| Promises | P13, P14, P15 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Keeps the code and every language's files complete against each other. The
developer's procedure is fixed (`docs/l10n.md`), and the checks discover
languages by their directories, so a new language is under the gates from the
moment its files exist.

## Parameters

No user settings. Check modes: default (warnings) and `--strict` (CI: every
warning fails). The hardcoded-string baseline is empty; `--write-baseline`
rewrites it for a same-file hotfix.

| Check | Looks at | Fails on |
|-------|----------|----------|
| interface dictionary | every localizer call in the code vs `ui.json` of each language | missing key, orphan key, unused special form (strict); a key called both plain and plural, a wrong value shape, an incomplete plural set, a special index absent from the dictionary, a placeholder set that differs between key and translation or between plural forms (always) |
| template overlay | display texts extracted from `wizard_template.json` vs `template.json` of each language | an unknown key, an empty value, a value starting with `@` or containing `{` (always); an untranslated text (strict) |
| hardcoded strings | string literals in display positions: text widgets, tooltips, labels, hints, registered snackbar and dialog helpers, including every branch of a ternary or switch | any display literal not exempted (the baseline is empty); a text-only literal with no letters is ignored |
| native strings | notification, toast, shortcut, tile and stop-alert calls and manifest labels in native code; `strings.xml` of every language directory vs the English one | a literal in a native display call, a label without a resource, a missing or orphan key, a `%n$s` placeholder set that differs |

## Inputs / Outputs

**Inputs:** the code, `wizard_template.json`, the dictionaries and overlays of
every language directory, the native strings of every language directory, the
helper registry and the machine-surface allowlist.
**Outputs:** a pass or a list of findings by kind; a red build on a finding in
strict mode.

## Rules and invariants

- A new interface string: write the English literal at the display site, then
  add an entry with the same placeholders under that text to every language's
  `ui.json`. A missing entry falls back to English at runtime and fails CI for
  that language.
- Editing an English text renames the key: the old entry becomes an orphan and
  the new one is missing in every language until the dictionaries follow.
  Template display texts work the same way; there is no regeneration step, the
  check extracts keys from the template on every run.
- A new language, end to end: (1) the interface dictionary with every key the
  check lists as missing, plurals in the language's forms, (2) the template
  overlay with every extracted display text, (3) the native strings file with
  every translatable key, (4) the language in the Android 13+ locale
  declaration, in the supported list and in the three validators that would
  otherwise reset the setting to System default, plus the plural-form table of
  the check, (5) the endonym in the language picker marked exempt, (6) the
  asset directory declared so the files reach the bundle, then the four checks
  in strict mode and the localization tests. A plural rule for a new language
  is added in one place for the runtime and mirrored in the check.
- Every dictionary the app declares must load and parse; a test loads each
  template overlay from the bundle, and the interface dictionaries are loaded
  whole by tests.
- Machine surfaces: the English render is allowed only in model types and in
  the listed machine-surface modules (automation, Debug API, config build,
  home and subscription controllers); elsewhere it fails the check. A screen
  that fetches template texts once at creation fails the check too — texts are
  fetched on every language change.
- A snackbar or dialog helper with a display parameter is registered for the
  hardcoded check; an unregistered helper is a hole.
- A dynamic key (a variable, an interpolation) is counted but cannot be
  validated.
- Hotfix path: rewording an existing literal keeps a file's site count; the
  baseline forbids growth, not changes.

Checklist before a push: the English literal is at the display site · every
language's `ui.json` has the entry with the same placeholders · a plural has
every form of every language · a context variant uses a special index and the
dictionary has it · template display text is in every `template.json` · native
text is in every `strings.xml` · exemptions carry a reason · the four checks
pass in strict mode · the localization tests pass.

## Boundaries

- No translation memory, machine translation or external translation service;
  translations are edited by hand in the repository.
- The checks read the code statically: a string that reaches a widget through
  a variable, a helper the registry does not know or a native call outside the
  listed patterns is not seen (the known cases are in the feature's
  Maintenance notes).
- The CI job itself — [023-BUILD_CI_RELEASE](../../023-BUILD_CI_RELEASE/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [156](../../../tasks/156-ui-english-only-cyrillic-cleanup.md) | Done | Interface and API in English only, Cyrillic cleaned out |
| 2 | [279F](../../../tasks/279F-localization/spec.md) | — | Ratchet on hardcoded strings, native string parity, machine-surface locality |
| 3 | [285](../../../tasks/285-getlocaltext-migration.md) | — | Dictionary check on natural keys, strict CI, empty baseline |
| 4 | [452](../../../tasks/452-zh-localization.md) | Implemented | Checks discover languages by directory; per-language plural forms |
| 5 | [591](../../../tasks/591-spec-kit-revision-audit.md) | Open | Audit: untranslated spots that pass the checks |
