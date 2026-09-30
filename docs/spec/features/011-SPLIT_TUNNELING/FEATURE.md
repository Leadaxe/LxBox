[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Split tunneling — choosing which Android apps use the VPN

LxBox lets you choose which Android apps go through the VPN tunnel and which
bypass it, with Off, Allow-list and Deny-list modes. Android applies the list
when the tunnel is created, and the sing-box core config stores it as
`include_package` or `exclude_package`.

| Field | Value |
|-------|-------|
| Feature | 011-SPLIT_TUNNELING |
| Type | Product feature |
| Absorbed | `§046F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The user decides at the OS level which apps enter the tunnel in the first
place: the bank and games — around the VPN directly over Wi-Fi/mobile data, or
the other way round — "only Telegram through the VPN". This is a boundary
**before** the core: packets of an app left outside the tunnel do not reach
the core, routing rules do not see them. The setting lives on the "Tunnel
apps" tab of the routing screen.

The feature protects two principles:

- **The user's choice is visible in the config.** The app list is written to
  the saved core config explicitly and is diagnosed from it; the app's
  automatic tweaks (its own app in allow mode) do not get into the saved
  config.
- **A label must be the truth.** "App uninstalled" is said only when the OS
  has confirmed it; a check failure does not turn into a false diagnosis.

## Promises

- **P1. Off does not touch the tunnel.** In Off mode nothing is written to the
  tunnel input, even if the list is not empty. **Witness**: units "mode=off →
  no changes", "mode=off + non-empty packages → no changes (mode wins)".
  **Mutation**: writing the list without checking the mode.
- **P2. The mode unambiguously sets the core field.** Allow-list →
  `include_package` = the list; Deny-list → `exclude_package` = the list; the
  two fields are never present together. **Witness**: units "mode=allow + 2
  pkgs → include_package", "mode=deny + 1 pkg → exclude_package".
  **Mutation**: the fields swapped.
- **P3. An empty list breaks nothing.** Allow or Deny with an empty list does
  not change the config — all traffic goes into the tunnel, not "nobody".
  **Witness**: unit "mode=allow + empty packages → no changes". **Mutation**:
  an empty `include_package`.
- **P4. No tunnel — quietly nothing.** No tunnel input (Proxy mode) — the list
  is not applied and there is no error; with several tunnel inputs only the
  first is touched; in VPN+Proxy the list goes to the tunnel, not the port.
  **Witness**: units "no tun-inbound → silent no-op", "inbounds key missing →
  no throw", "multiple tun inbounds — only first", "mode=vpn_proxy → both
  inbounds (tun first)". **Mutation**: looking up the input by tag instead of
  type.
- **P5. The list survives a mode change and an app restart.** Switching
  Off/Allow/Deny does not erase the list; "Clear all" does not change the mode;
  the setting survives leaving the screen, a restart and the backup.
  **Witness**: units "staged tun_apps + flushToDisk → round-trip from disk",
  "round-trip: export → reset → import → bytewise equal", "смена mode не
  стирает packages (P5)". **Mutation**: a mode change resets the list.
- **P6. A list edit is carried through to the core.** Any change of the mode or
  the list marks the config "rebuild needed"; with the tunnel up — a banner or
  an auto-restart per 003. **Witness**: unit "config-significant savers raise
  configDirty". **Mutation**: saving without the mark (§075: restart on the
  old config).
- **P7. Our own app does not drop out of allow mode.** In Allow-list the app
  appends itself to the tunnel channel on every bring-up, without touching the
  saved config; in Deny and Off it does not (otherwise the OS would reject a
  tunnel with a mixed list). **Witness**: device smoke §124 (Android 15);
  mirror units "own package appended to the end of include_package", "deny →
  own package NOT appended". **Mutation**: self-appending in Deny too.
- **P8. The picker selection is not lost on the back gesture.** The system
  "back" returns the selection just like the arrow. **Witness**: widget "system
  back returns the current selection (§108)". **Mutation**: returning without a
  result.
- **P9. Scrolling does not clear checkmarks.** The selection changes only by
  tapping the checkbox, not the row. **Witness**: widgets "a tap on the row
  title does not change the selection", "a tap on the checkbox toggles".
  **Mutation**: toggling by the row.
- **P10. "Uninstalled" — only confirmed.** The "uninstalled" label appears only
  when the OS answered "no such package"; a timeout or failure — a retry, no
  label. **Witness**: units "does NOT mark not-found and retries until
  success", "after retries are exhausted stays unknown". **Mutation**: a
  failure is cached as "absent".
- **P11. A missing package does not prevent the start.** A package from the
  list that is not on the device is skipped, the tunnel comes up.
  `no witness`.

## Controlled parameters

| Setting | Values | Default | When it takes effect |
|---------|--------|---------|----------------------|
| Mode (Tunnel apps → Mode) | `off` / `allow` (Allow-list) / `deny` (Deny-list) | `off` | next tunnel bring-up |
| App list | package identifiers | empty | next tunnel bring-up |

Stored as the pair `{mode, packages}`; the list is normalized on write (no
empties, no duplicates, alphabetical). Part of the backup. Debug API: `GET|PUT
/settings/tun_apps`, body `{"mode":"off|allow|deny","packages":[…]}`; an
invalid mode or package name — 400; the reply carries `rebuild_needed: true`.

Core config keys (contract):

| Key | When |
|-----|------|
| `inbounds[type=tun]`.`include_package` | mode `allow`, list not empty, first tunnel input |
| `inbounds[type=tun]`.`exclude_package` | mode `deny`, list not empty, first tunnel input |

Self-appending of our own package goes through the core start parameters
(`includePackage` in the override options), not through the config.

## Inputs / Outputs

**Inputs:** the user's choice (mode, picker, deleting a row, "Clear all"),
Debug API, backup restore; the list of installed apps and the OS replies
"package present / absent".

**Outputs:** the `include_package` / `exclude_package` field in the config;
the "rebuild needed" flag; on tunnel bring-up — allowed/disallowed apps in the
system VPN; in the core's verbose log mode — one line
`per-app: mode=… allow_bypass=… applied=N […] not_installed=M […]`.

## Data flow

```
user choice / Debug API / backup
  → list normalization → save {mode, packages} → "rebuild needed"
  → config build: the last step edits the first tun input (include | exclude)
  → tunnel bring-up: core + own package (allow only) → the OS builds the tunnel
    with allowed/disallowed apps; missing ones — skipped
```

## Rules and guarantees

- Off mode is the OS default behaviour: all apps are in the tunnel.
- Allow and Deny are mutually exclusive within one tunnel: the OS rejects a
  mixed list.
- The OS applies the list only when the tunnel is created; a live tunnel does
  not change it — a new bring-up is needed (start or core restart).
- The "installed" state is cached per session; a check failure — up to three
  retries (2, 5, 15 s), then "unknown" and a new attempt the next time the
  screen is opened.
- A per-package rule inside the core ([004-ROUTING](../004-ROUTING/FEATURE.md))
  sees only traffic that already got into the tunnel; an app outside the
  tunnel is not subject to such a rule. The tab says so in the hint and help.

## Boundaries

- Proxy mode: split tunneling does not apply — there is no tunnel, and an app
  goes to the local port by its own proxy setting. The tab's help text says
  so; there is no mode-aware banner.
- "Allow VPN bypass" is a different mechanism (the app itself decides to go
  around the tunnel), owner — [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md),
  function "Operating modes".
- Per-package routing inside the core — 004-ROUTING; per-app traffic —
  012-LIVE_STATE; banner and auto-restart — 003-CONFIG_BUILD.
- Split by domains/IP at the OS level — not done (those are core rules).
- Not planned (owner decision 2026-09-29, audit [591](../../tasks/591-spec-kit-revision-audit.md)) from `046F`: a snackbar when adding
  LxBox to the Deny list, a "Config is locked" banner on the tab, a checkbox
  toggle on a listed app (removal by the cross stays), "Show system apps" in the
  tab menu (it is in the picker).
- Depends on OS capabilities: the mechanism of allowed/disallowed VPN apps
  itself, visibility of the list of installed apps, the reaction to an
  uninstalled package (on some OS versions it is accepted silently), the moment
  of application — only when the tunnel is created.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Mode and app list | Stores the Off / Allow-list / Deny-list mode and the package list, writes them into the core config and carries every edit to the core. | P1–P6, P11 | [mode-and-list.md](FUNCTIONS/mode-and-list.md) |
| App selection | Picker for the app list: search, system apps, bulk actions, clipboard import and export; the selection survives the back gesture. | P8, P9 | [app-picker.md](FUNCTIONS/app-picker.md) |
| App status | Shows the app name and icon for each package and marks it "uninstalled" only when the OS confirms it. | P10 | [app-status.md](FUNCTIONS/app-status.md) |
| Own app in the Allow-list | In Allow-list mode, adds LxBox itself to the tunnel on every bring-up without writing it to the saved config. | P7 | [self-in-allowlist.md](FUNCTIONS/self-in-allowlist.md) |

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — the "rebuild needed"
  mark, the restart banner and auto-restart that carry a list edit to a live
  tunnel.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — per-package rules inside the core
  see only traffic already in the tunnel; the same app picker serves the "by
  app" rule condition.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — owns the tunnel whose
  creation applies the list, the VPN/Proxy modes (no list in Proxy) and "Allow
  VPN bypass".
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — per-app traffic view.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the Debug API `GET|PUT
  /settings/tun_apps` that reads and writes the mode and the list.

## Maintenance notes

- The step that writes the list must be the **last** editor of the tunnel
  input: any later step that recreates the input will silently erase the
  user's choice.
- The app recognizes allow mode by the presence of `include_package` on the
  first tunnel input. Change the form of the entry (another field, another
  input) — and self-appending and the "core config is stale" comparison will
  drift apart.
- The comparison with the running core repeats self-appending as an append
  without sorting and deduplication; normalization on this side would give an
  eternal banner.
- A list edit without a config rebuild = a restart on the old config
  (§075) — the choice "doesn't work", although it is in the settings.
