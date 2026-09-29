[English](first-run.md) · [Русский](first-run.ru.md)

# First launch — permission and consent prompts one at a time

On the first opening of the home screen LxBox asks, one question at a time, for
notification permission, background activity, the Quick Settings tile and
consent to the update check.

| Field | Value |
|-------|-------|
| Feature | [020-APP_SHELL](../FEATURE.md) |
| Promises | P11, P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

When the home screen opens for the first time, the app asks, one by one, the
questions without which the tunnel works poorly in the background or without
which the app has no right to go to the network: notification permission,
background activity, the Quick Settings tile, consent to the update check.

## Parameters

No settings of its own. Steps (from "needed to work" to "nice to have"):

| # | Step | When shown | What it offers |
|---|------|------------|----------------|
| 1 | Allow notifications | no notification permission and not asked yet | an explanation, then the system request; Skip / Allow |
| 2 | Allow background activity | the app is not exempt from battery optimization and not asked yet | Later / Allow → system settings → advice on vendor restrictors (Open Settings) |
| 3 | Quick Settings tile | not asked yet | the system add-tile dialog (Android 13+); on older versions — silently skipped |
| 4 | Check for updates? | not asked yet, not a dev build | Skip / Enable update auto-check |

## Inputs / Outputs

**Inputs:** the home screen opening; the state of permissions and battery
optimization; the install channel.
**Outputs:** system requests; the "Check for updates on launch" value;
"already asked" flags.

## Rules and invariants

- The next step comes only after the previous one is closed; dialogs do not
  overlap.
- Each step is shown once: the flag is set before showing, so an app killed in
  the middle of a question will not ask again.
- Steps 1 and 4 are not dismissed by a tap outside the window; step 2 is.
- Step 4: Enable — auto-check on, Skip — off; closing with the system "back" —
  by channel: installed from a store — off, otherwise on.
- Until step 4 is answered the app requests neither releases nor the support
  feed (the auto-check default is off).
- The "already asked" flags are a device property: a full settings
  replacement from a backup that lacks them keeps the current ones — the
  questions do not pop up again after a restore.
- The same can be done manually in App Settings: Diagnostics → System setup
  (notifications, battery optimization — straight to system settings, without
  an explanation) and General → Quick connect → Add (tile, with the add
  result).
- New version notices and the support feed are not part of onboarding.

## Boundaries

- There is no wizard for network setup, preset choice or adding the first
  server here: the empty home screen with a prompt to add a server — 007 / 008.
- The VPN permission is requested on the first connection — 010.
- A notification permission revoked later is not asked again.
- Depends on OS capabilities: the notification request (Android 13+), battery
  optimization exemption, third-party vendor restrictors (OnePlus / OPPO /
  Realme, MIUI, MagicOS), the system tile dialog (Android 13+).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [126F](../../../tasks/126F-first-run-wizard/spec.md) | In implementation | One sequential engine for first-launch questions, the tile as the third step |
| 2 | [395](../../../tasks/395-update-check-consent.md) | — | The update check question; off by default; "back" — by channel |
| 3 | [422](../../../tasks/422-support-feed-gated-by-update-consent.md) | implemented | The same consent opens the network to the support feed |
