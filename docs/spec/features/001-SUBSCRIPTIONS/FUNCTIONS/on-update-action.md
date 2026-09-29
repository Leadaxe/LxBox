[English](on-update-action.md) · [Русский](on-update-action.ru.md)

# Action on update

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | P6, P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Decides what to do with the config when a subscription has updated and **its composition
has changed**: only rebuild, rebuild and have the core re-read it on the fly, or
do nothing until the next regular rebuild. Needed so that a subscription with
an hourly interval does not raise the "restart to apply" banner every hour for
a user who has not touched anything.

## Parameters

| Parameter | Values | Default |
|---|---|---|
| On update (subscription → Settings) | **Rebuild config — apply manually** · **Rebuild and reload core — brief connection drop** · **Do nothing — apply on next rebuild** | Rebuild |
| Auto-restart VPN on settings change (global, owned elsewhere) | on → Reload applies to all subscriptions, the "On update" row is hidden | off |

The subscription's choice is not erased while the global checkbox is on — turning the
checkbox off brings it back.

## Inputs / Outputs

**Input:** the subscription update outcome — "composition changed" yes/no.
**Output:** a config rebuild without a snackbar; with Reload and the tunnel up —
the core re-reads the config on the fly (drop ≈ 3 s, open TCP connections break).

## Rules and invariants

- **Composition** = the subscription nodes in order (by content fingerprint)
  plus the set of marks of disabled nodes. Name, time, metadata, status are not
  part of the composition. The same composition → no reaction and the config is not marked
  as changed, though the update time is saved.
- Only an **enabled** subscription reacts: a disabled one is not in the config.
- An automatic pass accumulates reactions and applies **one** at the end:
  at least one Reload → Reload, otherwise at least one Rebuild → Rebuild.
- A manual update of one subscription applies its reaction immediately, under the same
  conditions (the composition changed, the subscription is enabled).
- Reload runs only if the tunnel is up and the rebuilt config
  differs from the running one; within the reload cooldown — skipped,
  the banner stays.
- A rebuild in flight is awaited, then our own runs — so as not to
  apply a config built before the new nodes were written.
- Do nothing: nodes are updated, the config is marked as changed; it applies on
  returning to the main screen, Start or a manual Apply.
- A reaction error does not break the updater pass.

## Boundaries

- The rebuild itself and the comparison with the running config —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md); the core reload —
  [010-VPN_SERVICE](../../010-VPN_SERVICE/FEATURE.md).
- "Update all" always rebuilds and saves the config after the pass.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [323](../../../tasks/323-subscription-on-update-action.md) | ✅ DEVICE-PENDING | Three reaction modes, one reaction per pass, "config is the same" gate |
| 2 | [331](../../../tasks/331-blue-banner-and-manual-refresh-reaction.md) | ✅ DEVICE-PENDING | Reaction and change flag only on a changed composition; a manual ⟳ reacts too |
| 3 | [338](../../../tasks/338-auto-reload-on-settings-change.md) | ✅ DEVICE-VERIFIED | Global auto-restart overrides the subscription's choice |
| 4 | [349](../../../tasks/349-two-month-revision-services-fixes.md) | ✅ Released v2.19.3 | A disabled subscription does not raise the flag and does not trigger a reaction |
| 5 | [346](../../../tasks/346-subs-full-crud-debug-api.md) | — | The reaction mode is configurable via the Debug API |
