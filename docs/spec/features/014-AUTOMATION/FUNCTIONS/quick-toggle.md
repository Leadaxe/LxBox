[English](quick-toggle.md) · [Русский](quick-toggle.ru.md)

# Quick toggle — one-touch VPN from the Quick Settings tile and icon menu

These entry points work without enabling automation.

| Field | Value |
|-------|-------|
| Feature | [014-AUTOMATION](../FEATURE.md) |
| Promises | P1, P2, P3, P4, P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

One touch turns the tunnel on or off without opening the app: a tile in the
system Quick Settings shade and menu items that appear on a long press of the
app icon on the home screen. The tile and the menu show the current tunnel
state; a long press on the tile opens the app.

## Parameters

| Parameter | Values / behaviour |
|-----------|--------------------|
| App Settings → General → Quick connect → Quick Settings tile → **Add** | system request to add the tile (Android 13+); on older versions the shade is edited manually |
| Offer to add the tile on first run | once; where there is no system request, the step is silently skipped |

No toggles of its own: the tile and the menu always work, regardless of
"Accept automation commands".

## Inputs / Outputs

**Inputs:** a tile touch; a long press on the tile; the "Connect" /
"Disconnect" item in the icon menu; tunnel status; the app language.

**Outputs:** tunnel start or stop; the tile look; the icon menu contents;
one-time messages "Opening L×Box for VPN permission (one-time)" and "VPN
permission denied. Open L×Box to retry.".

| Tunnel status | Tile | Icon menu |
|---------------|------|-----------|
| Stopped | inactive, "Disconnected" | Connect |
| Starting | active, "Connecting…" | Connect + Disconnect |
| Started | active, "Connected" | Disconnect |
| Stopping | inactive, "Stopping…" | Connect + Disconnect |

## Rules and invariants

- A tile touch when Stopped — start, when Started — stop; the tile
  immediately draws the target state, then it is refined by the real status.
  In the Starting and Stopping phases a touch is ignored (the tile is redrawn
  as is).
- In a transitional phase the icon menu offers both items: one can both cancel
  the start and force a stop.
- VPN permission: if the mode requires a system tunnel and there is no
  permission yet, the app opens with an explanation and the system dialog is
  shown; consent → start and the app closes; refusal → a message and closing,
  no repeated request. When the permission already exists — start without the
  UI.
- In Proxy mode the VPN permission is never requested (otherwise the OS tears
  down a foreign VPN).
- A stop from the tile or the menu reports the stop to the app: the running
  node safeguard cycle ends and does not bring the tunnel back up.
- Tile and menu item labels are in the app language; changing the language
  renames the menu items, including copies pinned to the home screen.
- A failure updating the tile or the menu is swallowed: tunnel start and stop
  do not depend on it.

## Boundaries

- There is no choice of node, group or mode from the tile — only the global
  toggle.
- There is no home screen widget.
- Stop / Reconnect buttons in the service notification — 010-VPN_SERVICE.
- Depends on OS capabilities: presence of the Quick Settings shade and the
  dynamic icon menu, the system request to add the tile (Android 13+), the
  tile look in a particular firmware. Live updates of the tile and the menu —
  from Android 11; on Android 7–10 the tile updates only when the shade opens,
  and there is no icon menu.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [032F](../../../tasks/032F-quick-connect/spec.md) | Done (v1.6.0) | Tile and shortcut: one touch, one-time VPN consent |
| 2 | [014](../../../tasks/014-quick-connect-tile-shortcut.md) | Done | First delivery of the tile and shortcut with the permission explanation |
| 3 | [015](../../../tasks/015-android-9-11-quickconnect-regression.md) | Done | Android 9–11: a failure of the quick toggles does not bring down the tunnel start |
| 4 | [019](../../../tasks/019-quick-connect-polish.md) | Done | State-aware menu (Connect/Disconnect), instant tile redraw, start from a fresh process |
| 5 | [139](../../../tasks/139-qs-tile-icon-manifest-rebrand.md) | Done | Tile icon instead of a white square |
| 6 | [155](../../../tasks/155-audit-2026-06-quick-wins.md) | In progress | The permission message from the tile does not crash the process |
| 7 | [192](../../../tasks/192-proxy-mode-prepare-revokes-foreign-vpn.md) | ✅ device-verified | Proxy mode does not ask for the VPN permission and does not tear down a foreign VPN |
| 8 | [212](../../../tasks/212-tile-longpress-open-app.md) | Implementation | A long press on the tile opens the app |
| 9 | [126F](../../../tasks/126F-first-run-wizard/spec.md) | — | Offer to add the tile on first run (Android 13+) |
| 10 | [233](../../../tasks/233-minsdk-24.md) | — | The tile is available from Android 7, live updates — from Android 11 |
| 11 | [279F](../../../tasks/279F-localization/spec.md) | phases 0–7 done | Tile and menu labels in the app language, renaming on language change |
| 12 | [510](../../../tasks/510-review-findings-after-v2251.md) | Released v2.25.2 | A stop from the tile shuts down the node safeguard cycle |
