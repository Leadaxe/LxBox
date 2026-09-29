[English](auto-update.md) · [Русский](auto-update.ru.md)

# Subscription auto-update

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | P3, P4, P5, P6, P14, P15 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Keeps subscriptions fresh without user involvement and **does not spam the provider**.
All triggers converge into one pass, which decides for each subscription by a single
"is it time" rule. A manual update takes the same path, but bypasses the limits.

## Parameters

| Parameter | Values | Default |
|---|---|---|
| Auto-update subscriptions | on/off (Settings → Subscriptions and the sources screen menu) | on |
| Update disabled subscriptions | on/off; available only with auto-update enabled | off |
| Update interval (subscription) | `-1` Don't auto-update · `0` Never (respect server) · 1, 3, 6, 12, 24, 48, 72, 168 h | 24 h; file `-1` |

Constants: min-retry 15 min · failure cap 5 per session · pause between
subscriptions 10 s ± 2 s · periodic tick 1 h · delay after VPN 2 min.

## Inputs / Outputs

**Triggers:**

| Trigger | When | Limits |
|---|---|---|
| appStart | after sources load at start | all |
| resumed | the app returned from background | all |
| periodic | once an hour while the process is alive | all |
| vpnConnected | 2 min after the tunnel connects | all |
| vpnStopped | immediately when the tunnel leaves "connected" | all |
| "Update all" | button on the sources screen | bypasses everything except the disabled gate |
| "Update" / "Refresh now" / "Reset fail count & retry" | one subscription | bypasses everything |

**Output:** updated subscriptions ([request and cache](fetch-cache-offline.md)),
one aggregated [reaction](on-update-action.md) per pass.

## Rules and invariants

The "is it time" decision for an automatic trigger, in order:

1. Auto-update is off → the pass does not start.
2. The subscription is disabled and "Update disabled subscriptions" is off → no
   (this gate also applies to "Update all").
3. ≥ 5 consecutive failures in this session → no (except manual).
4. Manual → yes.
5. Interval ≤ 0 → no.
6. < 15 min since the last attempt → no.
7. No success yet → yes; otherwise — yes if ≥ interval has passed since the success.

- Passes do not run in parallel: a new trigger during a pass is skipped.
  Within a pass subscriptions go sequentially. Two entries with the same URL
  are both requested, one after the other.
- The server `profile-update-interval` changes the subscription interval with `0` and
  `N>0`; with `-1` it is ignored.
- The failure cap lives in memory: it is reset by a restart, a manual
  update of the subscription, "Reset fail count & retry" and "Update all".
  The consecutive-failure count for display ("(N fails)") is stored separately and
  reset by the first success.
- A subscription request is running → a repeated request of the same subscription does not start.
  An "updating" status left over from a killed process turns into
  "error" at start.
- Switching the workspace aborts the pass: between subscriptions and in the pause
  (reaction ≈ ¼ s); no new passes start after that.
- Haptic feedback and snackbars — only for manual updates; automatic ones are
  silent.
- After "Update all" the config is rebuilt and saved, snackbar "Config
  generated: N nodes".

## Boundaries

- No update of an unloaded app; how long the process lives minimized
  depends on OS capabilities. Return from background closes this gap.
- There is no exponential backoff between passes — the cap of 5 plays that role.
- A file subscription is not requested in a pass.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [010F](../../../tasks/010F-quick-start-and-offline/spec.md) | Implemented | Update by interval on pressing Start (replaced by triggers) |
| 2 | [027F](../../../tasks/027F-subscription-auto-update/spec.md) | Implemented | Six triggers, min-retry/fail-cap/interval gates, pause, global toggle |
| 3 | [129F](../../../tasks/129F-file-subscription/spec.md) | Spec (implemented) | Intervals `-1` and `0`, the server interval is ignored with `-1` |
| 4 | [291](../../../tasks/291-subscription-refresh-on-resume.md) | ✅ implemented | "Return from background" trigger |
| 5 | [337](../../../tasks/337-auto-update-disabled-subscriptions.md) | ✅ DEVICE-PENDING | "Update disabled" checkbox, gate above force |
| 6 | [515](../../../tasks/515-workspace-switch-stale-controller-persist.md) | Released v2.25.2 | Stopping the pass on a workspace switch |
| 7 | [219](../../../tasks/219-deep-audit-2026-07.md) | Done / findings in progress | Audit: closing the HTTP client, index order on reorder |
