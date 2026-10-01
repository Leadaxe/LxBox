[English](support-feed.md) · [Русский](support-feed.ru.md)

# Support feed — the author's messages for active VPN users

LxBox shows the author's full-screen messages (support requests, news, tips) one
at a time and only to people who actively use the VPN; the author changes them
without an app release.

| Field | Value |
|-------|-------|
| Feature | [020-APP_SHELL](../FEATURE.md) |
| Promises | P12, P18, P19, P20, P21 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Shows the author's messages ("support the project", news, tips) to those who
actually use the VPN: full screen, no more often than configured, one by one.
The author changes texts, links, thresholds and the queue without an app
release.

## Parameters

The user has no settings. The parameters are set by the feed:

| Field | Meaning | Default |
|-------|---------|---------|
| `snooze_active_hours` | for how many hours of uptime "Later" silences the whole feed | 10 |
| `messages[].id` | the persistent "read" key | — (without it the message is dropped) |
| `since_version` | from which app version it is visible; raising it above the read one — shown again | `0.0.0` |
| `skip` | take out of rotation | false |
| `min_active_hours` | tunnel uptime since the baseline | 3 |
| `min_session_minutes` | duration of the current tunnel session | 5 |
| `read_delay_seconds` | how many seconds "Got it" stays inactive | 10 |
| `i18n.<language>` | `title`, `message`, `links[]` (`label`, `url`, `mark_read`) | the English block is required |

## Inputs / Outputs

**Inputs:** the feed from the project repository (only with consent to the
update check), its last successful snapshot, the copy built into the app;
tunnel uptime; the current session duration; the interface language; the app
version.
**Outputs:** a full-screen message; navigation to an app screen; the Servers
input field with the link filled in; the system "Share"; an external browser.

## Rules and invariants

- Source: network (if there is consent) → last successful snapshot → built-in
  copy. The feed is read once per process.
- When shown — while the app is on screen, home is open and the tunnel is
  connected: on opening, on returning, or at the moment during work when the
  session and uptime reach the thresholds. Not without the tunnel and not in
  the background. At most one message per app launch.
- Uptime is the tunnel's running time, including while the interface is
  closed; a tunnel restart begins a new session, with no double counting.
- The queue is strict: the first visible unread message is taken; if it has
  not passed its thresholds, the feed stays silent and the next one does not
  jump ahead.
- The uptime baseline moves on "Got it" and on an app version change; "Later"
  does not touch it but raises the common silence threshold.
- The message language is the interface language at the moment of showing,
  otherwise English. Placeholders (`@guideLink`, `@appVersion` and others) are
  substituted at display time.
- Buttons:

  | Button | What it does | Closes the message | Marks as read |
  |--------|--------------|--------------------|---------------|
  | https link | opens the browser | no | no |
  | `lxbox://route:<screen>[/<tab>]` | opens an app screen | yes (replaced by the screen) | yes, unless `"mark_read": false` |
  | `lxbox://add:<link>` | opens Servers with the field filled in; the user adds it themselves | yes | as above |
  | `lxbox://share:<text>` | system "Share" | no | no |
  | Got it (N) | active after `read_delay_seconds` | yes | yes |
  | Later | snooze of the whole feed | yes | no |
  | X | close; comes again on the next app launch | yes | no |

- `route:` screens — servers, routing, dns, vpn-settings, app-settings,
  speedtest, stats, config, debug, about, profiler. An unknown action or
  screen — the button is hidden (a feed newer than the app does not break it).
- A message without an English block, broken links and a broken feed are
  dropped silently, without a failure.
- For the developer: Debug API `GET /support/state`, `POST /support/reset`,
  `POST /support/preview` (showing outside the gates, `dry` — without writing
  state).

## Boundaries

- The feed cannot be turned off entirely; without update consent it is not
  refreshed from the network, but the built-in copy is shown.
- There is no automatic node adding from a feed link — intentionally.
- Donation methods — a separate list in About ([navigation](navigation.md)).
- Depends on OS capabilities: the system "Share", the browser.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [105F](../../../tasks/105F-support-message/spec.md) | SUPERSEDED §356 | "Support the author" dialog from GitHub after 3 h of uptime with an active session |
| 2 | [356](../../../tasks/356-support-message-feed.md) | implemented, device-verified | Queue, languages, re-showing by version, baseline, native uptime |
| 3 | [357](../../../tasks/357-support-deeplinks.md) | implemented, device-verified | Full-screen display, `lxbox://`, "Got it" timer, Debug API |
| 4 | [362](../../../tasks/362-project-links-share.md) | implemented | Link placeholders and the `share:` action |
| 5 | [422](../../../tasks/422-support-feed-gated-by-update-consent.md) | implemented | Network only with consent; a single source; built-in copy |
