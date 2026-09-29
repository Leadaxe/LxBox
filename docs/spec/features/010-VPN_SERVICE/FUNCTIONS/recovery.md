[English](recovery.md) · [Русский](recovery.ru.md)

# Tunnel recovery — coming back after process death and core crashes

The tunnel restarts after the app process dies, the next start clears caches
after a core crash, and the app stops showing "Connected" when the core no
longer answers.

| Field | Value |
|------|----------|
| Feature | [010-VPN_SERVICE](../FEATURE.md) |
| Promises | P12, P13, P14 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Three passive mechanisms, each against its own trouble: the tunnel comes up by
itself after the app process dies; after an abnormal core crash the next start
clears the caches that might have brought it down; the open app notices that
the core has stopped responding and does not show "Connected" over a dead
tunnel. There is no active watchdog with probes and automatic network reset — it
was rejected for the sake of the battery.

## Parameters

No settings of its own. Fixed values:

| What | Value |
|------|-------|
| Worst-case auto-restart time after process death | ~3.5 min (earlier — on screen wake) |
| Auto-restart limit | 2 within a 5 min window; the third is not made |
| Core liveness check (app on screen) | every 5 s, "silence" > 8 s, 2 in a row → loss |

## Inputs / Outputs

**Inputs:** process death with the tunnel up; a non-empty core crash report
from the previous run; the core status stream.
**Outputs:** an automatic tunnel start; the notification "VPN stopped — VPN
was restarted too many times after the app was killed. Start it manually.";
cleared core caches; the status "Connection lost — VPN tunnel is not
responding".

## Rules and invariants

- The tunnel is considered "wanted" from the moment of a confirmed start until
  any confirmed stop (manual stop, stop on error, slot takeover). Auto-restart
  works only for a wanted tunnel — a manual stop is not resurrected.
- A live service regularly postpones the safety alarm, so in a healthy state
  there are no extra wake-ups. The alarm does not wake a sleeping device — it
  fires on the first wake-up.
- A successful start resets the auto-restart counter. When the limit is
  exhausted, the "want" is cleared, a notification is shown, the tunnel stays
  off.
- If a notification from a dead service is left in the shade, opening the app
  removes it.
- A core crash on the previous run → before the core starts, the core cache
  (FakeIP addresses, DNS cache, group selections) and temporary files are
  deleted. The config, geo databases, rule-sets, crash reports and user data
  are not touched. Fires once per crash.
- The liveness check works only while the app is on screen; in the background
  it is off, and the tunnel's death is reported by a service event. The first
  check after returning from the background is not penalized; one vibration
  per series of failures.
- Liveness loss: node probes stop, session data is cleared, a regular stop is
  attempted. This does not count as a slot takeover.

## Boundaries

- An active watchdog based on URL tests and absence of traffic (§042F) —
  rejected, won't-fix; escalating "healing after sleep" (§088) — postponed.
- The "core crashed" banner and the crash report —
  [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FEATURE.md).
- Depends on OS capabilities: the system restarting the service, delivery of
  the postponed alarm, aggressive background cleanup by the firmware.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [042F](../../../tasks/042F-health-watchdog/spec.md) | 🚫 Won't-fix | Active health watchdog with automatic network reset — rejected for the battery |
| 2 | [088](../../../tasks/088-wake-heal-escalation.md) | ⏸️ On hold | Escalating recovery after sleep — design only |
| 3 | [122F](../../../tasks/122F-commandclient-migration/spec.md) | Implemented | Core liveness — by silence of the status stream, not by HTTP polling |
| 4 | [164](../../../tasks/164-cc-clients-energy-model.md) | Implemented (device-verified) | In the background the status stream and the liveness check sleep |
| 5 | [216](../../../tasks/216-heartbeat-resume-grace.md) | IN PROGRESS | The first check after the background is not penalized |
| 6 | [334](../../../tasks/334-on-launch-after-crash-cache-reset.md) | ✅ DEVICE-PENDING | Core cache reset after a crash |
| 7 | [428](../../../tasks/428-vpn-service-start-sticky.md) | Done, DEVICE-VERIFIED | Coming up after process death + a storm guard |
| 8 | [430](../../../tasks/430-stale-fgs-notification-cleanup.md) | Done, DEVICE-VERIFIED | Removing a dead service's notification |
| 9 | [128](../../../tasks/128-jni-callback-crash-android10.md) | In Progress | Callbacks from the core must not crash the process |
