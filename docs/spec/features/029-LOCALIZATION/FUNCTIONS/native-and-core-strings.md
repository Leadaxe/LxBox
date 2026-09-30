[English](native-and-core-strings.md) · [Русский](native-and-core-strings.ru.md)

# Native and core strings — notification, tile, automation plugin, core warnings and what stays English

LxBox translates the texts that live outside the Flutter interface — the VPN
service notification, the Quick Settings tile, shortcuts, the automation plugin
windows and the core's warning registry — and deliberately leaves every
machine-facing string in English.

| Field | Value |
|-------|-------|
| Feature | [029-LOCALIZATION](../FEATURE.md) |
| Promises | P6, P11, P12 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Renders the native Android surfaces in the chosen language even when the
interface is not running, renames them on a language change, hands the core
its message language, and keeps a fixed English render for logs, the Debug
API and automation payloads.

## Parameters

No settings of its own: it follows the language from
[language-selection](language-selection.md). Contract: native strings are one
file per language with the same keys as the English file; a payload-carrying
text uses `%1$s` and passes the payload verbatim.

Native texts by surface:

| Surface | Texts |
|---------|-------|
| Service notification | channel name and description, "Starting…", "Connected", Stop, Reconnect, error title, core notification channel name |
| Stop alerts | unknown error, core init failed, empty configuration, command server not initialized, failed to start service, "VPN stopped" after a restart storm |
| Quick Settings tile | Connecting…, Stopping…, Disconnected |
| Quick connect shortcuts | Connect, Disconnect, one-time permission prompt, permission denied |
| Automation plugin | four plugin labels, Start / Stop / Toggle blurbs, command and condition prompts, command names, condition names, value labels, Save |

## Inputs / Outputs

**Inputs:** the stored language mirror on the native side; the device language
change event; the language change from the interface; the core's warning
registry with English and Russian texts.
**Outputs:** native surfaces in the chosen language; the core's locale; the
English render of stored errors and warnings for machine surfaces.

## Rules and invariants

- Native surfaces resolve their strings at render time under the chosen
  language: an explicit choice wraps the context in that language, System
  default takes the system's own resolution (including the per-app choice on
  Android 13+). Nothing is cached, so every redraw is in the current language.
- The native side keeps a mirror of the language setting so it can render
  without the interface; the mirror is written only through the language
  change path, and an unknown mirror value is System default.
- A language change refreshes, in order: the notification channel (an
  idempotent re-submit renames it), the notification text of a running
  service (a stopped service has nothing to rename), both shortcuts including
  pinned copies, the tile, and the core locale. Each step is best-effort: a
  failure is logged and the next step still runs.
- With System default a device language change runs the same refresh even
  when the interface is not running; with an explicit choice it is a no-op.
- The core's message language: set from the device at process start (a
  language-and-region tag, falling back to the bare language, then to the
  core default — a rejected tag never blocks startup), and from the app
  choice inside the refresh above.
- Core warning texts (title, text, cause, fix) exist in English and Russian in
  the registry; Russian reads Russian, every other language reads English.
- Always English: logs, Debug API responses, automation events and plugin
  command strings, machine-form config warnings, config values and tags, file
  names, user data, passthrough OS, library and core payloads, the name
  "L×Box", units and duration suffixes, network names in the donations list. A
  stored error or warning has two renders — the active language for the
  screen and English for the machine surfaces — and the English one never
  changes with the language.
- The "L×Box" name is marked untranslatable in the native strings; the
  `alert:` wire prefix of stop alerts is not a display string.

## Boundaries

- The service itself, its states and stop alerts —
  [010-VPN_SERVICE](../../010-VPN_SERVICE/FEATURE.md); the tile, shortcuts and
  plugin behavior — [014-AUTOMATION](../../014-AUTOMATION/FEATURE.md); the
  registry contents — [021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.md).
- Core log lines and passthrough error payloads are not translated by the app;
  only the core's own locale call affects them.
- Depends on OS capabilities: per-app locale and the device language change
  broadcast; shortcut relabeling may be rate-limited by the system when the
  app is in the background.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [279F](../../../tasks/279F-localization/spec.md) | — | Native strings by language, refresh of channel, notification, shortcuts, tile and core locale |
| 2 | [280](../../../tasks/280-l10n-first-version.md) | — | First cycle: system surfaces, mirror on the native side, device language receiver |
| 3 | [452](../../../tasks/452-zh-localization.md) | Implemented | Chinese native strings; parity check finds languages by directory |
| 4 | [460F](../../../tasks/460F-contract-registry-bundle/spec.md) | — | Warning registry bundled with English and Russian texts |
| 5 | [591](../../../tasks/591-spec-kit-revision-audit.md) | Open | Audit: core locale follows the device until the first language change |
| 6 | [607](../../../tasks/607-l10n-backup-shell-bugs-from-591.md) | Done; device check pending | The core locale at process start comes from the saved app language |
