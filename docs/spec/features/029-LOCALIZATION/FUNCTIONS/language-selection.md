[English](language-selection.md) · [Русский](language-selection.ru.md)

# Language selection — the setting, the device language and Android 13+ per-app language

LxBox picks its interface language from the in-app setting, the device language
or the app language in Android system settings, applies it without a restart
and keeps all three sources in agreement.

| Field | Value |
|-------|-------|
| Feature | [029-LOCALIZATION](../FEATURE.md) |
| Promises | P1, P2, P3, P4, P5, P6 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Decides which of the three languages the app speaks right now and applies it
everywhere at once: the interface, the template texts, date formats, the
notification, the tile, the shortcuts and the automation windows. The choice
comes from the setting, and under System default from the device; on Android
13+ the same choice can be made in the system's per-app language settings.

## Parameters

| Setting | Where | Values | Default |
|---------|-------|--------|---------|
| Language | App Settings → Appearance | System default · English · Русский · 中文（简体） | System default |

Language names are endonyms — each in its own language whatever the current
one is. The same setting is exposed as `app_language` in the Debug API
(`system` \| `en` \| `ru` \| `zh`), in the backup and in settings sets.

## Inputs / Outputs

**Inputs:** the in-app choice; the device language and its change event; the
app language from system settings (Android 13+); a value from a backup, a
settings set or the Debug API.
**Outputs:** the effective language tag; the redrawn interface; renamed system
surfaces; the per-app language pushed to the system (Android 13+); the user
guide link in About.

## Rules and invariants

- System default is the device language if it is among the supported ones,
  otherwise English. An unknown stored value is read as System default; the
  Debug API rejects an unknown value.
- Applying a language, in order: save the setting; set the date and time
  locale; load the language's dictionary; warm the template cache; re-derive
  template-derived labels; flush pending settings; redraw the interface. The
  dictionary and the template are ready before the first redraw, so no frame
  mixes languages. A dictionary or template load failure does not block the
  switch: the interface stays English and still redraws.
- The first frame after launch is already in the saved language: the
  dictionary is loaded before the interface starts.
- Under System default, a device language change redraws the interface and
  renames the system surfaces on the fly; under an explicit choice a device
  language change is ignored.
- What stays English on a switch: every machine surface, user data, previously
  saved text snapshots, the support feed languages it does not have, and the
  known untranslated spots listed in the feature's Maintenance notes.
- Android 13+ per-app language: an explicit choice is pushed to the system;
  System default pushes an empty list (otherwise the system would keep
  returning the last explicit choice and System default would be dead). At
  startup the three sides are reconciled: the system choice differs from what
  the app last pushed — the user changed it in system settings, the system
  wins and the setting is rewritten; the system matches the last push but the
  stored setting differs — storage changed underneath (restore, Debug API,
  hand edit), the stored value is pushed again; all equal — nothing happens.
  On the first start after an upgrade a non-empty system choice wins, an empty
  one is aligned to storage. A region suffix from the system (`ru-RU`) is read
  as the bare language.
- Below Android 13 the per-app part does nothing; the setting alone decides.
- Restoring a backup or loading a settings set re-reads the language and runs
  the same pipeline; nothing happens if the value did not change.
- The user guide link in About opens the Russian guide for Russian and the
  English guide for any other language.
- Screens that hold template-derived texts refetch them on a language change
  without losing the user's input.

## Boundaries

- RTL languages are not supported.
- Only three languages ship; adding one is a developer task
  ([translation-workflow](translation-workflow.md)).
- The text lookup and fallback rules — [english-as-key](english-as-key.md);
  what the native side renames — [native-and-core-strings](native-and-core-strings.md).
- The row's place on the settings screen —
  [020-APP_SHELL](../../020-APP_SHELL/FEATURE.md).
- Depends on OS capabilities: the app language in system settings and the
  per-app locale (Android 13+); the device language change broadcast.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [154](../../../tasks/154-conn-app-icon-and-i18n.md) | Done | Connections screen in English |
| 2 | [156](../../../tasks/156-ui-english-only-cyrillic-cleanup.md) | Done | Interface and API in English only, Cyrillic cleaned out |
| 3 | [279F](../../../tasks/279F-localization/spec.md) | — | Localization: en + ru, switching without restart, English machine surfaces |
| 4 | [280](../../../tasks/280-l10n-first-version.md) | — | First cycle: interface, template, system surfaces, reconciliation with Android 13+ |
| 5 | [452](../../../tasks/452-zh-localization.md) | Implemented | Simplified Chinese as the third language |
| 6 | [541](../../../tasks/541-appearance-tab-two-columns-toggle.md) | Done | Language choice moved to the Appearance tab |
| 7 | [591](../../../tasks/591-spec-kit-revision-audit.md) | Open | Audit: core locale from the device, Debug API error text without `zh` |
