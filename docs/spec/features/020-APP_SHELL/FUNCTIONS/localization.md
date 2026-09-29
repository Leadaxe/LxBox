[English](localization.md) · [Русский](localization.ru.md)

# Localization — English, Russian and Chinese interface without a restart

LxBox shows its interface, notification, tile and shortcuts in English, Russian
or Simplified Chinese and switches language on the fly without stopping the
tunnel.

| Field | Value |
|-------|-------|
| Feature | [020-APP_SHELL](../FEATURE.md) |
| Promises | P5, P6, P7, P8, P9, P10 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows the app in the user's language: the interface, template texts (preset
names, hints, rule descriptions), the system notification, the tile and
shortcuts. The language changes on the fly, without a restart and without
stopping the tunnel.

## Parameters

| Setting | Where | Values | Default |
|---------|-------|--------|---------|
| Language | App Settings → Appearance | System default · English · Русский · 中文（简体） | System default |

Language names are endonyms: each in its own language, whatever the current
one is. The same choice is available in the app's system language settings
(Android 13+) and through the Debug API (`app_language`: `system` \| `en` \|
`ru` \| `zh`).

## Inputs / Outputs

**Inputs:** the in-app choice; the device language; the app language in system
settings; a value from a backup, a settings set or the Debug API.
**Outputs:** interface and template text, date format, system surfaces in the
chosen language.

## Rules and invariants

- System default is the device language if it is among the supported ones,
  otherwise English. A device language change under System default is picked
  up on the fly.
- An unknown stored value is read as System default.
- The first frame after launch is already in the saved language.
- English is the base: the source text itself is the translation key; there is
  no separate English dictionary.
- No translation for a string — English text; no plural form — the English
  string with the number; a missing value — an empty spot, not a format code.
  A dictionary load failure — everything in English, and the language still
  switches.
- Plurals follow the language's rules: Russian one/few/many, Chinese — a single
  form.
- System surfaces (notification, tile, shortcuts, automation windows) are
  translated even when the interface is not running, and are renamed
  immediately on a language change.
- Reconciliation with the system choice (Android 13+) at startup: the system
  changed since our last choice — the system wins; only storage changed — the
  storage choice is sent to the system; System default clears the system
  choice.
- The language is part of the backup and of settings sets; loading a set
  applies its language immediately.
- Always English: logs, Debug API responses, automation events, machine-form
  config warnings, config values and tags, file names, user data (subscription,
  node, rule names), OS, library and core messages, the name "L×Box", network
  names in the donations list.
- Previously saved text snapshots (channel labels, fallback rule names from
  presets) are not translated retroactively.
- CI does not let an interface string bypass the translator, and rejects an
  untranslated or orphaned key and mismatched placeholders in a translation.

## Boundaries

- RTL languages are not supported.
- Theme option labels and the update check status lines in About are not
  translated (see the discrepancy report).
- Support feed texts are translated by its author inside the feed itself
  ([support-feed](support-feed.md)).
- Depends on OS capabilities: the app language in system settings (Android
  13+).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [154](../../../tasks/154-conn-app-icon-and-i18n.md) | Done | Connections screen in English |
| 2 | [156](../../../tasks/156-ui-english-only-cyrillic-cleanup.md) | Done | Interface and API in English only, Cyrillic cleaned out |
| 3 | [279F](../../../tasks/279F-localization/spec.md) | — | Localization: en + ru, switching without restart, English machine surfaces |
| 4 | [280](../../../tasks/280-l10n-first-version.md) | — | First cycle: interface, template, system surfaces, reconciliation with Android 13+ |
| 5 | [285](../../../tasks/285-getlocaltext-migration.md) | — | English text as the translation key, strict CI checks |
| 6 | [452](../../../tasks/452-zh-localization.md) | Implemented | Simplified Chinese as the third language |
| 7 | [541](../../../tasks/541-appearance-tab-two-columns-toggle.md) | Done | Language choice moved to the Appearance tab |
