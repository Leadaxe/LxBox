[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Localization — UI languages, translation files and the English-as-key model

LxBox shows its interface, notification, tile and shortcuts in English, Russian
or Simplified Chinese and switches language on the fly without stopping the
VPN tunnel. English is the base language: the English text in the code is the
translation key, every other language is a dictionary file. Logs, the Debug
API, automation events and the sing-box config stay English in any language.

| Field | Value |
|-------|-------|
| Feature | 029-LOCALIZATION |
| Type | Product feature |
| Absorbed | `§279F` |
| State | ✅ written from code, 2026-09-29 |

## Purpose

A user reads the app in their own language, while everything a machine or
another person reads — logs, API responses, automation payloads, config values —
stays English so that a bug report from Russia and one from China look the same.
The feature covers how the language is chosen and applied, how the translation
files are shaped, how a developer adds a string or a language, and which native
and core strings follow the choice.

Principles: **English is the key** — no separate English dictionary, no
artificial identifiers, a dictionary miss degrades to the English text.
**Language is for humans, English is for machines** — interface, template
texts and system surfaces are translated, machine surfaces are pinned to
English. **A change never stops the tunnel** — a switch redraws the interface,
renames the system surfaces and re-derives template labels without a restart or
a config rebuild. **Nothing untranslated reaches a release unnoticed** — CI
rejects a hardcoded display string, an untranslated or orphaned key, a
mismatched placeholder set and a native string missing in one language.

## Promises

- **P1. The language is chosen from System default / English / Русский / 中文;
  an unknown value is System default.** System default takes the device
  language, else English. **Witness:** units "set() with unknown value falls
  back to system", "invalid stored value resolves to system". **Mutation:** an
  unknown device language gives an empty locale.
- **P2. Changing the language — without a restart; the first frame after launch
  is already in the saved language.** **Witness:** units "set() persists, warms
  the template cache, updates the localizer and notifies", "bootstrap() warms
  the dictionary — a cold start is localized". **Mutation:** the dictionary is
  loaded after the first frame.
- **P3. The language from Android system settings and the in-app language do not
  conflict.** A change in the app's system settings wins; a change in storage
  (backup restore, Debug API) also wins if the system did not change; System
  default clears the per-app choice. **Witness:** reconciliation units "system
  Settings changed the language → the system wins", "restore/Debug API changed
  storage → storage wins", "storage became system with ru pushed → an empty
  list is re-pushed". **Mutation:** a one-sided "the system is always right".
- **P4. The language survives a backup and a settings set.** **Witness:** units
  "app_language export → import round-trip preserves value", "reloadFromStorage
  applies the restored value and is idempotent". **Mutation:** the language key
  dropped from the import allowlist.
- **P5. The user guide link in About follows the interface language; an
  unsupported language opens the English guide.** **Witness:** units "ru →
  Russian guide, en → English", "unknown language → English (fallback, not
  404)". **Mutation:** the link always points to the Russian guide.
- **P6. System surfaces are renamed on a language change even when the
  interface is not running.** Notification channel and text, the tile, the
  shortcuts and their pinned copies, automation windows; with System default a
  device language change does the same. **Witness:** manual check — tunnel up,
  switch to Russian: the notification and the tile are Russian without a
  reconnect. **Mutation:** the notification text is cached at service start.
- **P7. Untranslated means English, not empty and not a format code.** No
  dictionary, no key, no form, a wrong form kind — the English text is shown
  with the values substituted; a missing argument is an empty spot, not `%s`.
  **Witness:** units "missing key → key itself substituted", "missing arg →
  empty placeholder", ".s never throws on plural-object value → key fallback",
  "dict null → English key substituted with %d". **Mutation:** a missing
  argument prints `%s`.
- **P8. Plurals follow the language's rules.** Russian one/few/many by CLDR,
  fractions fall into `other`; English one/other; Chinese a single form.
  **Witness:** units "one: 1, 21", "few: 2, 3, 4, 22", "many: 5, 11, 12, 13, 14,
  25", "non-integer 1.5 → other", widget "ru: the sing-box card counters
  decline"; for the Chinese single form — `no witness`. **Mutation:** 21 → many.
- **P9. Template display texts are translated, the config the template emits is
  byte-identical.** Preset names, hints, option labels and rule descriptions
  come from the language overlay; a value that starts with `@` or contains `{`
  is ignored. **Witness:** units "ru overlay localizes display fields, config
  subtree untouched", "localizes display fields, leaves machine subtrees
  byte-identical", "skips values starting with @ or containing {", "unknown
  English keys are a silent no-op". **Mutation:** the overlay applied to the
  config subtree.
- **P10. Template-derived labels change language without a config rebuild.**
  Live rule names from presets are re-derived on a switch; inline rule
  conditions are not touched. **Witness:** units "relocalize: a label change in
  the template is reflected in the resolver output", "relocalize does not touch
  inline rule conditions (titles only)". **Mutation:** a build-time snapshot.
- **P11. Machine surfaces are English in any language.** A stored error or
  warning renders in the interface language on screen and in English for the
  log, the Debug API and automation — the same object, two renders.
  **Witness:** unit "renderWith(ru) turns Russian, renderEn() is unchanged".
  **Mutation:** the log writes a message in the interface language.
- **P12. Core warning texts exist in English and Russian; any other language
  reads the English one.** **Witness:** widget "zh gets the English text of the
  registry". **Mutation:** zh falls back to Russian.
- **P13. Every shipped dictionary loads and parses.** A translation file that
  is declared but broken does not reach a release. **Witness:** unit "every
  declared template overlay asset loads and parses"; the ru and zh interface
  dictionaries are loaded whole by unit "the “Info” subheading is its own
  dictionary form, not “Information”". **Mutation:** a comment key in a dictionary.
- **P14. CI rejects a hardcoded display string, an untranslated or orphaned key,
  a mismatched placeholder set and an unused special form.** **Witness:**
  checker self-tests "Text positional literal is a site", "both ternary
  branches in Text are sites", "key used in code but absent from dict =
  missing", "dict key never referenced = orphan", "arity mismatch (key vs
  value) fails", "special defined but never used with that index =
  orphan-special". **Mutation:** the hardcoded baseline allowed to grow.
- **P15. Native strings are complete in every language.** The sets of keys and
  of `%n$s` placeholders in each language's Android strings match the English
  set. **Witness:** manual check — remove one key from the Russian strings, run
  the native check in strict mode: it fails. **Mutation:** a missing key falls
  back to English silently.

## Controlled parameters

| Setting | Where | Values | Default | When it takes effect |
|---------|-------|--------|---------|----------------------|
| Language | App Settings → Appearance | System default / English / Русский / 中文（简体） | System default | immediately |

Language names are endonyms. The same choice is available in the app's system
language settings (Android 13+) and in the Debug API (`app_language`: `system`
\| `en` \| `ru` \| `zh`).

The feature emits no core config keys.

Formats (contracts): the interface dictionary `assets/l10n/<tag>/ui.json`
(English text → `{"value": …}`, a plural object or a `special` variant;
placeholders `%s`, `%d`, `%1$s`, `%%`); the template overlay
`assets/l10n/<tag>/template.json`; native Android strings, one file per
language; the exemption mark `// l10n-exempt: <reason>`.

## Inputs / Outputs

**Inputs:** the in-app choice; the device language; the app language from
system settings (Android 13+); a value from a backup, a settings set or the
Debug API; the dictionaries and the template shipped with the app.

**Outputs:** interface text, template display texts, date and time formats,
the notification, tile, shortcuts and automation windows in the chosen
language; the core's message language; English on machine surfaces.

## Data flow

```
setting | device language | system settings (13+) → reconciliation → language tag
language tag → interface dictionary → every string call → text or English fallback
             → template overlay → presets, hints, rule names
             → native strings → notification · tile · shortcuts · automation windows
             → core locale (on a change)
stored error / warning → screen: interface language · log, Debug API, automation: English
CI: code + dictionaries + native strings → four checks in strict mode → build
```

## Rules and guarantees

- System default is the device language if supported, otherwise English; a
  device language change under System default is picked up on the fly.
- An unknown stored value is read as System default; the Debug API rejects it.
- The dictionary of the new language is loaded and the template cache is warmed
  before the interface is redrawn; a dictionary load failure leaves everything
  in English, and the language still switches.
- Date and time formats follow the chosen language.
- Reconciliation with the per-app choice (Android 13+) at startup: the system
  changed since our last push — the system wins; only storage changed — the
  stored choice is pushed to the system; System default clears the system
  choice; on the first start after an upgrade a non-empty system choice wins.
- The language is part of the backup and of settings sets; loading a set
  applies its language immediately.
- Always English: logs, Debug API responses, automation events, config values
  and tags, file names, user data, passthrough OS and core payloads, the name
  "L×Box", units (full list — [native-and-core-strings](FUNCTIONS/native-and-core-strings.md)).
- Previously saved text snapshots (channel labels, fallback rule names from
  presets) are not translated retroactively.

## Boundaries

- The Language row's place on the settings screen and the support feed with
  its own per-language texts — [020-APP_SHELL](../020-APP_SHELL/FEATURE.md);
  this feature owns the mechanism.
- RTL languages are not supported; no in-app translation editing, no
  downloadable language packs — languages ship with the app; the user guide
  exists in English and Russian only.
- The core's own message language is set once from the device at process start
  and follows the app choice only after a language change (see Maintenance
  notes).
- Depends on OS capabilities: the app language in system settings and the
  per-app locale (Android 13+); the device language change broadcast.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Language selection | Chooses the interface language from the setting, the device or Android 13+ system settings and applies it on the fly. | P1–P6 | [language-selection.md](FUNCTIONS/language-selection.md) |
| English as key | Uses the English text as the translation key, resolves plurals and special forms and falls back to English. | P7–P11 | [english-as-key.md](FUNCTIONS/english-as-key.md) |
| Translation workflow | Adds a string or a language and keeps the dictionaries complete through four CI checks. | P13–P15 | [translation-workflow.md](FUNCTIONS/translation-workflow.md) |
| Native and core strings | Translates the notification, tile, shortcuts, automation windows and core warnings and pins machine surfaces to English. | P6, P11, P12 | [native-and-core-strings.md](FUNCTIONS/native-and-core-strings.md) |

## Related features

- [020-APP_SHELL](../020-APP_SHELL/FEATURE.md) — the Language row on the
  Appearance tab; the support feed carries its own per-language texts.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — the config template
  whose display texts the overlay translates; the emitted config is English.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — preset rule names are re-derived
  in the new language on a switch.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md),
  [014-AUTOMATION](../014-AUTOMATION/FEATURE.md) — the service notification,
  stop alerts, tile, shortcuts and plugin windows are native strings; command
  strings and events stay English.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — logs and the Debug API
  are English machine surfaces; `app_language` is a Debug API setting.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md),
  [018-WORKSPACES](../018-WORKSPACES/FEATURE.md) — the language is part of the
  backup and of a settings set; a restore or a load applies it.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) — the warning registry
  carries English and Russian texts; the core's locale call.
- [023-BUILD_CI_RELEASE](../023-BUILD_CI_RELEASE/FEATURE.md) — the four
  localization checks run in strict mode on every push.

## Maintenance notes

- Known untranslated spots (audit
  [588](../../tasks/588-spec-kit-revision-audit.md)): theme option labels
  System/Light/Dark, update check result lines in About, "Add tile" messages,
  Tunnel apps mode labels and hint, rule editor JSON error strings and the APPS
  section, "Copy server + detour(s)" / "Server copied" / "Detour copied" in the
  config editor, restore summary lines. They pass CI because the text reaches
  the widget through a variable or an unregistered helper.
- Seventeen Russian entries (DNS group strings such as "Error TTL", "Win TTL",
  "Selection mode") are written as plain strings instead of `{"value": …}`
  objects: the runtime treats them as absent and prints English, and the
  dictionary check counts them as present. A shape check for flat entries is
  missing (→ 588).
- The Debug API error text for `app_language` still lists only `system`, `en`
  and `ru`; `zh` is accepted (→ 588).
- The core's message language is set from the device at process start and from
  the app choice only on a language change: a saved Russian on an English
  device gives English core errors until the user touches the language (→ 588).
- A new snackbar or dialog helper with a display parameter must be registered
  for the hardcoded check, otherwise its literals slip past.
- The supported-language list is mirrored in four places plus the Android
  locale declaration and the checker's plural-form table; a language missing in
  one of them silently resets the setting to System default (`docs/l10n.md`).
