[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# App shell — theme, language, navigation, first launch, update check and support feed

The LxBox app shell covers everything around the VPN tunnel: theme, interface
language, navigation, first-launch prompts, vibration and update notices. The
interface is available in English, Russian and Simplified Chinese and switches
language without a restart, while logs and the Debug API stay in English.
Neither the update check nor the author's support feed contacts GitHub until the
user agrees on first launch.

| Field | Value |
|-------|-------|
| Feature | 020-APP_SHELL |
| Type | Product feature |
| Absorbed | `§009F` `§022F` `§029F` `§034F` `§036F` `§105F` `§126F` `§279F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The shell covers everything that surrounds the VPN but is not the VPN: how the
app looks, which language it speaks, how to navigate it, what it asks on first
launch, how it announces a new version and how it asks to support the author.
Domain settings (tunnel, subscriptions, diagnostics, automation) are not
described here — the feature gives them a home (the App Settings screen, the
side menu) and shared conventions.

The feature protects four principles:

- **No consent — not a single "phone home" request.** The update check and the
  message feed go to the network only after an explicit "yes" on first launch
  or after the toggle is turned on; until then the app lives on built-in data.
- **The shell does not get in the way.** The new version notice appears only at
  launch, the support request — at most once per launch and only to someone who
  has been using the VPN for a long time; vibration — only on significant
  events; an accidental "back" does not throw the user out of the app.
- **Language is for humans, English is for machines.** The interface, system
  surfaces and template texts are translated; logs, the Debug API, automation
  events and config values are always English.
- **A setting applies immediately.** Shell toggles are saved at the moment of
  change and take effect without a restart; there is no "Save" button.

## Promises

- **P1. The theme follows the choice and applies immediately.** System / Light /
  Dark, System by default (follows the device theme); a change repaints the
  whole app without a restart and survives a restart. **Witness:** manual check —
  App Settings → Appearance → Dark, close and reopen the app. **Mutation:** the
  theme is read only at startup.
- **P2. Portrait by default, rotation by consent.** Without "Allow rotation" the
  interface is locked to portrait; turning it on immediately hands the
  orientation to the system auto-rotate (and its lock). **Witness:** manual check
  on a tablet. **Mutation:** rotation allowed by default.
- **P3. Two columns of the node list — from 600 dp and only with the toggle
  on.** Manual sort is always single-column. **Witness:** units "599 dp — one
  column", "600 dp — two columns (non-strict threshold)", "§541 toggle off — one
  column at any width", "manual sort stays single-column". **Mutation:** a
  strict `> 600` threshold.
- **P4. Vibration — only on the listed events and at most once per 100 ms.** A
  disabled toggle silences all events at once, without a restart. **Witness:**
  units "enabled=false → no platform calls", "throttle blocks rapid duplicate
  fires", "toggling enabled mid-flight applies immediately". **Mutation:**
  throttling removed.
- **P5. The language is chosen from System / English / Русский / 中文; an unknown
  value is System.** System takes the device language, and if it is not
  supported — English. **Witness:** units "set() with unknown value falls back to
  system", "invalid stored value resolves to system". **Mutation:** an unknown
  device language gives an empty locale.
- **P6. Changing the language — without a restart; the first frame is already in
  the right language.** **Witness:** units "a language change saves the choice,
  warms up the template, swaps the dictionary and redraws", "a cold start warms
  up the dictionary — the first frame is localized". **Mutation:** the
  dictionary is loaded after the first frame.
- **P7. Untranslated means English, not empty and not a format string.** No
  dictionary, key or form — the English text is shown with the values
  substituted; a missing argument is an empty spot, not `%s`. **Witness:** units
  "missing key → key itself substituted", "missing arg → empty placeholder",
  ".s never throws on plural-object value → key fallback". **Mutation:** a
  missing argument prints `%s`.
- **P8. Machine surfaces are English in any language.** **Witness:** unit
  "renderWith(ru) turns Russian, renderEn() is unchanged". **Mutation:** the log
  writes a message in the interface language.
- **P9. The language from Android system settings and the in-app language do not
  conflict.** A change in the app's system settings wins; a change in storage
  (restoring a backup, Debug API) also wins if the system did not change.
  **Witness:** reconciliation branch units "system Settings changed the language
  → the system wins", "restore/Debug API changed storage → storage wins".
  **Mutation:** a one-sided "the system is always right".
- **P10. The language survives a backup.** **Witness:** unit "app_language
  export → import round-trip preserves value". **Mutation:** the language key
  dropped from the import allowlist.
- **P11. First launch — questions one at a time and once each.** Notification
  permission → background activity → Quick Settings tile → update check; the
  next question appears after the previous one is answered; the answer is
  remembered, including on a full settings replacement from a backup.
  **Witness:** unit "replaceRaw merge=false keeps startup prompt flags"; the
  order — manual check on a clean install. **Mutation:** the questions are
  launched in parallel.
- **P12. Before consent the app does not ask GitHub about releases and the
  feed.** The update check is off by default; without consent the feed is read
  from the cache or the built-in copy. **Witness:** units "§422: without update
  consent — not a single request, the cache is read", "without consent and
  without a cache — the bundled copy, the network is not touched"; for the
  update check — `no witness`. **Mutation:** the update check default is `true`.
- **P13. Auto-check — at most once a day, dev builds stay silent, "Check now"
  always works.** **Witness:** `no witness`. **Mutation:** the daily threshold is
  counted from a failed attempt.
- **P14. The new version notice — only at launch and only from the stored
  result.** The result of a network check appears on the next launch; the
  notice does not pop up over the running app. **Witness:** manual check —
  "Check now" with a new version available does not raise the popup, a restart
  does. **Mutation:** showing on arrival of the network response.
- **P15. "Later" — until the next launch, "Ignore" — forever for this version, a
  tap — to its own store without remembering.** The next version is shown again.
  **Witness:** widget tests "“Later” does not persist", "“Ignore” persists the
  tag", "an already ignored version is not shown", "tap on the body: go to the
  store, but WITHOUT persisting". **Mutation:** "Later" remembers the version.
- **P16. The update link leads to where the app was installed from.** GitHub —
  the release page, Google Play — the store listing, F-Droid — the package page.
  **Witness:** widget tests "the github channel leads to the release page",
  "f-droid leads to the package page"; install channel units ("Obtainium
  installs the APK from GitHub → github"). **Mutation:** all channels → GitHub.
- **P17. Version comparison is strict; garbage does not wake it.** **Witness:**
  units "equal returns false", "malformed input returns false (no
  false-positive notify)". **Mutation:** string comparison.
- **P18. The support request — only to someone who uses the VPN right now and
  has used it for a long time.** Shown with the tunnel connected, with a session
  no shorter than the threshold and accumulated uptime no less than the
  threshold since the last baseline; the queue is strict. **Witness:** units
  "session gate: VPN inactive / short session → null", "baseline: the threshold
  is counted from the baseline", "the queue is strict". **Mutation:** the uptime
  threshold counted from zero.
- **P19. After an app update the feed does not dump everything at once.** A
  version change moves the baseline; the update itself does not mark read
  messages as unread. **Witness:** units "an app version change moves the
  baseline", "an app update does NOT mark messages unread BY ITSELF".
  **Mutation:** counting from the first launch.
- **P20. "Later" silences the whole feed for hours of uptime; "Got it" cannot be
  pressed blindly.** **Witness:** units "snooze raises the threshold from the
  current total", widget test "timer: “Got it (N)” disabled → ticks → active".
  **Mutation:** snooze in calendar hours.
- **P21. Message buttons do nothing dangerous on their own.** An unknown action
  is hidden; `add:` only fills the input field; `share:` does not close the
  message. **Witness:** units "route: unknown screen … → false", "share: a
  non-empty payload resolves and does NOT leave the screen"; widget test
  "buttons: https is visible; a future action is hidden". **Mutation:** `add:`
  adds the node right away.
- **P22. Exit — by a double "back".** On the home screen the first "back" shows
  a hint, the second within 2 s exits; an open menu is closed without a hint.
  **Witness:** widget tests "first press: message, no exit", "second press
  within 2 seconds: exit", "second press after 2 seconds: message again", "side
  menu is open". **Mutation:** a window with no time limit.
- **P23. App Settings toggles are saved immediately.** **Witness:** manual check —
  toggle, kill the process, open. **Mutation:** writing on a button press.

## Controlled parameters

| Setting | Where | Values | Default | When it takes effect |
|---------|-------|--------|---------|----------------------|
| Theme | App Settings → Appearance | System / Light / Dark | System | immediately |
| Allow rotation | same place, Layout | on/off | off (portrait) | immediately |
| Two columns on wide screens | same place, Layout | on/off | on | immediately |
| Language | same place | System default / English / Русский / 中文（简体） | System default | immediately |
| Haptic feedback | App Settings → General → Feedback | on/off | on | immediately |
| Check for updates on launch | App Settings → General → Updates | on/off | off until the first-launch question is answered | from the next launch |
| Check now | same place and About | button | — | immediately |

Fixed values: double "back" window — 2 s; two-column threshold — 600 dp;
vibration throttling — 100 ms; auto-check interval — 24 h, first attempt — 5 s
after the home screen opens; request timeout — 10 s; version popup — 6 s.

The feature emits no core config keys.

Formats: the latest version manifest (`tag`, `name`, `html_url`,
`published_at`); the message feed (`snooze_active_hours`, `messages[]` with `id`,
`since_version`, `skip`, `min_active_hours`, `min_session_minutes`,
`read_delay_seconds`, `i18n.<language>.{title, message, links[]}`); links
`lxbox://route:<screen>[/<tab>]`, `lxbox://add:<link>`,
`lxbox://share:<text>`; translation dictionaries — English text → translation.

## Inputs / Outputs

**Inputs:** touches and "back"; the device language and theme; the app language
from system settings (Android 13+); the install channel; GitHub responses about
the latest release and the message feed; tunnel uptime and the current session
duration; tunnel events and subscription updates (for vibration).

**Outputs:** interface theme and layout; the language of the interface, system
notifications, the tile and shortcuts; vibration; first-launch questions; the
new version popup and the block in About; the full-screen feed message; the
"new version available" automation event (if enabled in 014).

## Data flow

```
language: setting | device language | system settings → reconciliation → dictionary
      → interface · template · system surfaces; machine surfaces → English
first launch: notifications → background activity → tile → update consent
updates: [consent] 5 s after home → releases API ─ failure → own manifest
      → version cache → (next launch) popup Later / Ignore / tap → channel's store
feed: [consent] network → cache → built-in copy → queue → gates (session,
      uptime since baseline, snooze) → full-screen message → Got it / Later / X
tunnel and subscription events → toggle → throttling → vibration
```

## Rules and guarantees

- One consent on first launch controls two network channels: the release
  check and the message feed update.
- Dismissing the update check question with the system "back" is a choice by
  install channel: from a store — off, otherwise — on.
- A dismissed version is shown neither at launch nor from the cache; About
  still shows the known new version.
- The feed is loaded once per process and shows at most one message per
  launch; "X" closes a message without marking it — it will come again on the
  next launch.
- The theme is a device property: it is not part of the backup or of settings
  sets (018). Language, vibration, rotation, columns and update consent are.

## Boundaries

- Tunnel settings, auto-start, modes — [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md);
  tile, shortcuts and Intent API — [014-AUTOMATION](../014-AUTOMATION/FEATURE.md);
  the Diagnostics tab — [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md);
  the Subscriptions tab — [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md);
  usage region — [015-WARP](../015-WARP/FEATURE.md); backup —
  017; settings sets — 018.
- There is no in-app update installation: only a link.
- The message feed cannot be turned off entirely; it can be snoozed or read.
- Donations — About → "Support the project"; the addresses come as a separate
  list on an explicit action (public document `docs/DONATE.md`).
- RTL languages are not supported.
- Depends on OS capabilities: the vibration motor and the system "Touch
  feedback"; choosing the app language in system settings (Android 13+);
  requesting the tile through a system dialog (Android 13+); notification
  permission (Android 13+); battery optimization exemption and third-party
  vendor restrictors; the predictive "back" gesture.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Navigation and exit | Reaches every screen from the home screen and side menu and exits only on a double "back". | P22 | [navigation.md](FUNCTIONS/navigation.md) |
| App settings | Groups the settings outside the core config on one screen and saves each at once. | P23 | [app-settings.md](FUNCTIONS/app-settings.md) |
| Appearance | Sets the theme, rotation, two-column layout, pull-to-refresh and app icon. | P1–P3 | [appearance.md](FUNCTIONS/appearance.md) |
| Haptic feedback | Vibrates on significant tunnel and subscription events. | P4 | [haptic-feedback.md](FUNCTIONS/haptic-feedback.md) |
| Localization | Shows the app in English, Russian or Simplified Chinese and keeps machine surfaces in English. | P5–P10 | [localization.md](FUNCTIONS/localization.md) |
| First launch | Asks the permission and consent questions one at a time, once each. | P11, P12 | [first-run.md](FUNCTIONS/first-run.md) |
| Update check | Checks for a new release with consent, at most daily, and links to the install source. | P12–P17 | [update-check.md](FUNCTIONS/update-check.md) |
| Support feed | Shows the author's messages to active VPN users: source, gates, buttons. | P12, P18–P21 | [support-feed.md](FUNCTIONS/support-feed.md) |

## Related features

- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — tunnel settings, auto-start
  and modes live there; the VPN permission is requested on the first connection;
  tunnel events drive vibration and the support feed gates.
- [014-AUTOMATION](../014-AUTOMATION/FEATURE.md) — the tile, shortcuts and
  Intent API; the "new version available" automation event; the tile step of
  first launch.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — the Diagnostics tab of App
  Settings (System setup, logs, Developer) and the Debug API.
- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md) — the Subscriptions tab
  of App Settings; subscription updates drive vibration.
- [015-WARP](../015-WARP/FEATURE.md) — the Region section on the General tab.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — language,
  vibration, rotation, columns and update consent are part of the backup; the
  theme is not; first-launch prompt flags survive a full replacement.
- [018-WORKSPACES](../018-WORKSPACES/FEATURE.md) — shell settings except the
  theme belong to the set; loading a set applies its language; the set menu sits
  in the home screen header.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — automatic VPN restart on
  settings change in the Behavior section; the build sees an edit already on
  returning home.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — auto-ping after connecting
  in the Feedback section.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md),
  [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — the empty home screen
  prompting to add a server replaces a setup wizard in first launch.

## Maintenance notes

- F-Droid catalogs treat a background request to GitHub without consent as
  tracking (the Tracking anti-feature): any new network channel of the shell
  must sit behind the same consent (§395, §422).
- The anonymous GitHub API limit (60 requests per hour per address) is
  exhausted by the shared VPN exit address: without our own manifest the check
  would silently fail.
- A new language is added with an interface dictionary, a template dictionary
  and system surface strings; the CI translation checks are strict — an
  untranslated or orphaned string breaks the build (procedure — `docs/l10n.md`).
- A string rendered outside the localizer stays English in any language and is
  not caught by the check if it reaches the text through a variable.
