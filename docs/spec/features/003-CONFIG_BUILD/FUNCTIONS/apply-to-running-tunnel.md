[English](apply-to-running-tunnel.md) · [Русский](apply-to-running-tunnel.ru.md)

# Applying to a running tunnel — honest restart banners, auto-restart and live changes

The app compares the saved config with the one the core is running, shows a restart banner only when
they differ, can restart the tunnel automatically and applies group selections live.

| Field | Value |
|------|----------|
| Feature | [003-CONFIG_BUILD](../FEATURE.md) |
| Promises | P14 P15 P16 P17 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Answers the question "is the core already running on my settings?" and carries the
change through to the core: shows an honest banner, optionally restarts the
tunnel by itself, and whatever the core can change on the fly it changes without a drop.

## Parameters

| Setting | Values | Default |
|---|---|---|
| Auto-restart VPN on settings change | on/off | off |

The caption in settings warns: every apply drops the tunnel for
about 3 s and closes open connections. The enabled checkbox
overrides the reaction choice of each subscription — everything is applied.

**What is applied how:**

| Change | Application |
|---|---|
| Settings that are part of the config (template variables, rules, DNS, Tunnel apps, nodes and sources) | Rebuild ([lifecycle](settings-lifecycle.md)); with the tunnel up — the "restart" banner or auto-restart |
| VPN mode, proxy address, port, authorization | Rebuild + immediately the "restart needed" flag with the tunnel up |
| Allow bypass, Keep on exit, Background mode | Not part of the config; taken on the next tunnel bring-up; with the tunnel up — the "restart needed" flag, with it down — nothing |
| Selecting a member of an own manual group (a folder node, a subscription group) | Immediately in the core, without a drop and without a banner; remembered and gets into the config on the next Start |
| Selecting a node in a Direction | Immediately in the core ([007-NODE_LIST](../../007-NODE_LIST/FEATURE.md)) |
| App settings (language, haptic feedback…) | Outside the config, require nothing |

## Inputs / Outputs

**Inputs:** the result of saving the config; tunnel state; a snapshot of the
running config from the core (`GetRunningConfig`) and the canonical form of the
saved one (`FormatConfig`); the auto-restart checkbox.
**Outputs:** main screen banners, an in-place core reload, the rebuild snackbar
text: "Config rebuilt: N nodes" / "… — reloading VPN" / "… — restart
VPN to apply".

## Rules and invariants

- **The blue banner** "Settings changed — tap to rebuild config": the "stale"
  flag is raised and no build is running. Tap — rebuild.
- **The "Config changed — restart VPN to apply" banner**: the tunnel is up, the "stale"
  flag is cleared, the "restart needed" flag is set, no auto-apply is running.
  Tap — stop the VPN (with >3 active connections — with the confirmation
  "Stop VPN?"); the banner disappears when the tunnel state actually changes.
- These two banners are never shown at the same time.
- **The "restart needed" flag** is set by saving the config if the tunnel is
  up and the config changed in canonical form; it is cleared by saving a
  config that matched the previous one, any tunnel bring-up/stop and a
  successful core reload.
- **Comparison with the running one.** With the tunnel up, the saved config (with
  the native tweaks applied: the own package in `include_package` in
  allow mode, `auto_redirect`) is brought to the core's canonical form and
  compared with the snapshot of the running one: a match — the flag is cleared. No
  snapshot, an old core, a failure — "unknown", the flag stays.
- **Auto-restart** — after any successful rebuild, if the checkbox is on,
  the tunnel is up and the "restart needed" flag is set. It is done by an in-place core
  reload; the "restart" banner is suppressed for the duration of the apply. The reload
  cooldown (3 s) skips the apply — the banner returns as the
  fallback path, the reason is written to the log.
- **The ⟳ button next to the status:** tunnel down — rebuild + start;
  up with changes — rebuild + reconnect; up without
  changes — in-place core reload. A long press — a menu of explicit
  actions.
- A tunnel that is down does not show the "restart" banner: the config will be picked up
  on Start.

## Boundaries

- The core reload itself, its cooldown and reconnection —
  [010-VPN_SERVICE](../../010-VPN_SERVICE/FEATURE.md).
- Reaction to a subscription auto-update (rebuild/reload per subscription) —
  [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md).
- Applying native tunnel settings depends on OS capabilities: they
  take effect only when the tunnel is established.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [030](../../../tasks/030-vpn-reload-button.md) | Implemented | The ⟳ button: in-place core reload instead of a full reconnect |
| 2 | [076F](../../../tasks/076F-settings-and-config-lifecycle/spec.md) | Released v1.9.0 | Two mutually exclusive banners; the "restart needed" flag from native toggles |
| 3 | [113](../../../tasks/113-false-config-changed-banner.md) | Code complete, device-smoke pending | A false banner after the app is killed |
| 4 | [116](../../../tasks/116-banner-mechanism-and-config-banner-fix.md) | Code-complete, device pending | A single banner mechanism; diff of the saved against the current |
| 5 | [323](../../../tasks/323-subscription-on-update-action.md) | Implemented (DEVICE-PENDING) | Saving a matching config clears the flag |
| 6 | [324](../../../tasks/324-saved-vs-running-canonical-diff.md) | Implemented (DEVICE-PENDING) | Comparison with the running core in canonical form |
| 7 | [338](../../../tasks/338-auto-reload-on-settings-change.md) | DEVICE-VERIFIED | Auto-restart on settings change, banner suppressed during the apply |
| 8 | [565F](../../../tasks/565F-selector-group-genus/spec.md) | Phases A, B | Manual live selection of a group member |
| 9 | [570](../../../tasks/570-close-open-tails.md) | Done | The live selection is remembered, Start rebuilds |
