[English](update-check.md) · [Русский](update-check.ru.md)

# Update check — a daily release check with consent and a link to the install source

With the user's consent LxBox checks GitHub for a new release at most once a day
and announces it on the next launch with a link to where the app was installed
from.

| Field | Value |
|-------|-------|
| Feature | [020-APP_SHELL](../FEATURE.md) |
| Promises | P12, P13, P14, P15, P16, P17 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Once a day (with consent) asks GitHub for the latest release number and, on the
next launch, unobtrusively announces a new version with a link to where the app
was installed from. There is no in-app installation.

## Parameters

| Setting | Where | Values | Default |
|---------|-------|--------|---------|
| Check for updates on launch | App Settings → General → Updates | on/off | off until the first-launch question is answered |
| Check now | same place (the "Last check: …" line) and About | button | — |

Fixed: the first auto-attempt — 5 s after home opens; at most once per 24 h
since the last successful check; request timeout 10 s; the popup stays for
6 s.

Sources: the GitHub releases API (the latest stable release); on any failure
of it — the project's own manifest (`tag`, `name`, `html_url`,
`published_at`), published with every release. The request is signed with a
generic client name without the exact version.

## Inputs / Outputs

**Inputs:** consent; the app version; the install channel (GitHub, Google Play,
F-Droid; an unknown installer — GitHub); the sources' responses.
**Outputs:** the "vX available" popup on home; the block in About (the known
new version, the release date or "(cached info)", the "View release" / "Open
in <store>" button); the result line under "Check now"; the
`UPDATE_AVAILABLE` automation event (if enabled in 014).

## Rules and invariants

- The auto-check is skipped silently: turned off; a dev build; less than a day
  since the last successful one; both sources unreachable (a failure does not
  move the threshold).
- "Check now" always works, even on a dev build; one check runs at a time.
  Result: "%s available", "You're up to date" or "Check failed: …" — "Couldn't
  reach GitHub — check network or try later".
- A successful check remembers the time and the latest known version,
  regardless of whether it is newer.
- Comparison: `vX.Y.Z`, `X.Y.Z` or `X.Y`, a `v` prefix of any case, the tail
  after the digits (`-rc1`, `-dirty`) is dropped; an unrecognized string —
  "not newer"; equal — "not newer".
- The popup is shown only at launch and only from the remembered version: a
  network response in the same session does not raise it — the version pops
  up on the next launch.
- Popup actions:

  | Action | Effect |
  |--------|--------|
  | Tap on the text | open the update page of its channel; nothing is remembered |
  | Later | hide; remind on the next launch |
  | Ignore | do not remind about this version; a newer one will be shown again |

- Address by channel: GitHub — this version's release page; Google Play — the
  store listing with a web fallback address; F-Droid — the package page.
- On a narrow screen (up to 320 dp) the popup buttons move below the text
  instead of being cut off.
- An ignored version is still visible in About.

## Boundaries

- There is no APK download or installation; there is no forced update.
- There is no beta channel — stable releases only.
- There is no background check while the app is minimized.
- For stores, updates are managed by their client; the app only leads to the
  page.
- Depends on OS capabilities: opening a store or browser link.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [036F](../../../tasks/036F-update-check/spec.md) | Released (v1.5.0) | Polling GitHub once a day, popup, About block, own manifest when the API refuses |
| 2 | [092](../../../tasks/092-update-dismiss-wire.md) | DONE | The user can dismiss a release (remembered version) |
| 3 | [390](../../../tasks/390-install-source-aware-update-notice.md) | Done | The link leads to the install channel; Later without remembering, Ignore per version; shown only from the cache at launch |
| 4 | [395](../../../tasks/395-update-check-consent.md) | — | Auto-check off until explicit consent |
| 5 | [426](../../../tasks/426-install-sources-always-in-about.md) | Done | Install channels always visible in About |
