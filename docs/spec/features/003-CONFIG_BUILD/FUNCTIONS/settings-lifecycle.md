[English](settings-lifecycle.md) · [Русский](settings-lifecycle.ru.md)

# Settings lifecycle

| Field | Value |
|------|----------|
| Feature | [003-CONFIG_BUILD](../FEATURE.md) |
| Promises | P10 P11 P12 P13 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Guarantees that a changed setting makes it into the saved config:
marks the config as stale, accumulates edits without extra disk writes and
rebuilds the config at the right moment — on its own, without an "Apply" button.
The state lives in three layers: settings in memory → the settings file → the core
config file; the fourth — the running tunnel — is handled by
[applying to the tunnel](apply-to-running-tunnel.md).

## Parameters

No settings of its own. The `auto_rebuild` setting was removed: the rebuild on
return to the main screen is always automatic.

Two ways screens save:

| Way | Where | Behaviour |
|---|---|---|
| Deferred | VPN Settings (template variables, VPN mode), Routing, DNS, Tunnel apps | Every edit goes into the in-memory settings right away and raises the flag; to disk — in one write on leaving the screen or minimizing the app |
| Immediate | Subscriptions and servers, the rule editor (Save), the node filter (Apply), app settings | Written right away; config-relevant writes raise the flag |

## Inputs / Outputs

**Inputs:** edits on screens, source writes (adding, deleting,
enabling, a fetch with a new composition), Debug API, importing a backup,
loading a set of settings, app launch.
**Outputs:** the "config is stale" flag; the rebuilt and saved config;
the snackbar "Config rebuilt: N nodes" on a build triggered by a user action.

## Rules and invariants

- **The "stale" flag** is raised by editing a config-relevant setting and cleared
  only by a successful build. The build clears it only if the source composition did not
  change under it; if the file was not saved — the flag comes back.
- The flag is not raised by: the fetch attempt mark, a failed fetch, a fetch with the same
  composition, a fetch of a disabled subscription, app settings, service
  writes of the build itself.
- **Staging.** An edit on a screen with a deferred write is visible to any reader
  (rebuild on return, Start, launch) immediately, without waiting for the disk
  write. The write on leaving the screen only awaits the last staging and
  does not light the flag again.
- **Rebuild triggers** (all — one shared rebuild; a repeated trigger
  joins the running one):
  - return to the main screen by any means (back, gesture, leaving a
    nested chain of screens — fires on the last step), if the flag is
    raised; if a fetch or a build is running — the rebuild catches up when they
    finish;
  - a tap on the blue banner;
  - Start: with the flag raised or an unapplied group member selection —
    a rebuild first;
  - cold launch, when there are sources but no config, or the flag is raised —
    a silent rebuild after restoring subscription nodes from the cache;
  - reaction to a subscription update ([001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FEATURE.md)).
- **After the process is killed.** The flag is not written to a file. At launch it is
  derived by comparing the modification times of the settings file and the config file
  (with one-second precision): settings newer or no config — stale.
  A settings write with the flag cleared aligns the config time to the settings
  time, so there is no false "stale".
- A cold launch with the tunnel running but the config unread is not a
  rebuild, but a persistent "Config loading error" banner (tap — stop).
- Loading a set of settings raises the flag, and the config is built from the
  settings of the new set.

## Boundaries

- What the banners show and how changes reach the core —
  [applying to the tunnel](apply-to-running-tunnel.md).
- Atomicity of file writes, backup, import —
  [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md);
  sets of settings — [018-WORKSPACES](../../018-WORKSPACES/FEATURE.md).
- An app killed at the moment of an edit before leaving the screen and before being minimized
  loses that edit — depends on OS capabilities (the moment of the
  minimize notification).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [075](../../../tasks/075-tun-apps-restart-regen-config.md) | Released v1.9.0 | Rebuild before restart after editing Tunnel apps |
| 2 | [076F](../../../tasks/076F-settings-and-config-lifecycle/spec.md) | Released v1.9.0 | Three layers, the "stale" flag, deferred write, rebuild on return, recovery by file times |
| 3 | [101](../../../tasks/101-rehydrate-bootstrap-race.md) | DONE | The rebuild at launch awaits restoring nodes from the cache |
| 4 | [107](../../../tasks/107-lazy-persist-stale-read-race.md) | DONE (v2.0.2) | Staging edits in memory, one rebuild, gate on Start, `auto_rebuild` removed |
| 5 | [113](../../../tasks/113-false-config-changed-banner.md) | Code complete, device-smoke pending | Settings writes themselves raise the flag; aligning the config time |
| 6 | [116](../../../tasks/116-banner-mechanism-and-config-banner-fix.md) | Code-complete, device pending | An unread config with a live tunnel — an error banner, not a rebuild |
| 7 | [331](../../../tasks/331-blue-banner-and-manual-refresh-reaction.md) | Implemented (DEVICE-PENDING) | A fetch without a composition change does not raise the flag |
| 8 | [338](../../../tasks/338-auto-reload-on-settings-change.md) | DEVICE-VERIFIED | The write on leaving does not re-raise the flag after a rebuild |
| 9 | [360](../../../tasks/360-config-dirty-lost-during-rebuild.md) | DEVICE-VERIFIED | A mutation during a build does not lose the flag |
| 10 | [414](../../../tasks/414-config-dirty-check-files-dir.md) | Done | The config is looked up where the native part stores it |
| 11 | [515](../../../tasks/515-workspace-switch-stale-controller-persist.md) | — | Switching the set does not drag in a write of the old set |
