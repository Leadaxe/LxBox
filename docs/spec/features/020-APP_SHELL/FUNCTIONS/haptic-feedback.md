[English](haptic-feedback.md) · [Русский](haptic-feedback.ru.md)

# Haptic feedback

| Field | Value |
|-------|-------|
| Feature | [020-APP_SHELL](../FEATURE.md) |
| Promises | P4 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Confirms significant events with vibration so the user does not have to look
at the screen: tap "connect" and put the phone away — the feedback tells
whether the tunnel came up.

## Parameters

| Setting | Where | Values | Default | When it takes effect |
|---------|-------|--------|---------|----------------------|
| Haptic feedback | App Settings → General → Feedback | on/off | on | immediately |

Turning the toggle on gives a short test pulse by itself.

## Inputs / Outputs

**Inputs:** tunnel events, taps on the main buttons, the result of a manual
subscription update.
**Outputs:** vibration of one of three strengths.

| Event | Strength |
|-------|----------|
| Tap on Start/Stop, "Tap to connect", Reload and its menu item | selection click |
| Tunnel came up | medium |
| Tunnel stopped from the "connected" state | light |
| Tunnel revoked by the system or another VPN from "connected" | heavy |
| Tunnel stopped responding (liveness check failed) | heavy, once |
| Manual subscription update: success | light |
| Manual subscription update: error | medium |

## Rules and invariants

- A disabled toggle silences all events; the change takes effect from the next
  event without a restart.
- At most one pulse per 100 ms: a burst of events gives one.
- The stop pulse fires only if the tunnel was up; a connection dropped halfway
  does not vibrate.
- Automatic subscription updates do not vibrate — only manual ones.
- System "Touch feedback" off or no vibration motor — no feedback, and no
  errors either.
- The setting value is part of the backup and of settings sets.

## Boundaries

- There is no vibration on every tap, scroll and toggle — intentionally.
- There are no custom vibration patterns or per-event strengths.
- Selecting a node and applying a preset give no feedback.
- Depends on OS capabilities: the vibration motor, the system touch feedback
  setting.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [029F](../../../tasks/029F-haptic-feedback/spec.md) | Implemented and in production | Feedback on connect, disconnect and failures; toggle; throttling |
| 2 | [022F](../../../tasks/022F-app-settings/spec.md) | Implemented (v1.4.0) | Toggle in the Feedback section |
