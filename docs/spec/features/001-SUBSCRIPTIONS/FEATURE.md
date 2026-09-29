[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Subscriptions — VPN node sources, auto-update and per-node control

LxBox imports VPN nodes from subscription URLs, files, QR codes and pasted links, keeps them updated
and lets you disable single nodes. Subscriptions refresh on a schedule and on app events without
flooding the provider with requests, and a failed update never replaces a working node list. The
request identifies itself to provider panels such as Remnawave and Marzban with a branded User-Agent
and optional HWID headers.

| Field | Value |
|------|----------|
| Feature | 001-SUBSCRIPTIONS |
| Type | Product feature |
| Absorbed | `§006F` `§010F` `§027F` `§118F` `§129F` `§283F` (`§123F` — the core channel model, assigned to 012-LIVE_STATE) |
| State | ✅ written from code, 2026-09-28 |

## Purpose

Nodes enter the app from **sources**: a subscription by provider URL, a file
with a list of nodes, text from the clipboard or a QR code. The feature is
responsible for getting a source added, **keeping it fresh on its own**, and
never leaving the user without nodes while doing so.

Three principles the feature protects:

1. **Never end up without nodes.** Any failure — network, HTTP error, empty or
   garbage response, a failed address change — keeps the last working list.
   Nodes survive a restart and a start without network.
2. **Do not spam the provider.** Every automatic request is justified by an
   interval, every series of failures has a cap, parallel requests for one
   subscription collapse into one.
3. **Identify itself to the panel correctly.** The request carries a
   recognizable User-Agent and, if the user wants, HWID headers — this decides
   which format and how many "devices" the panel hands out.

How a subscription body turns into nodes is the
[002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) feature; here the body is a black
box that either yielded ≥1 node or did not. How nodes are shown and selected
on the main screen — [007-NODE_LIST](../007-NODE_LIST/FEATURE.md).

## Promises

- **P1. A failed update does not touch the working list.** A network error,
  HTTP 4xx/5xx or a 200 response parsed into 0 nodes keep the previous nodes,
  the previous body cache and the last success time; only the "error" status,
  the attempt time and the consecutive-failure counter change.
  **Witness:** unit tests "200 with a garbage body → nodes/cache/counter kept, failed",
  "HTTP 500 → nodes kept, failed". **Mutation:** write the parse result
  without checking it for emptiness.
- **P2. Changing the source is transactional.** A new URL or file is applied
  only if it yielded ≥1 node; otherwise the subscription stays on the old
  source with the old nodes, and the user sees "Couldn't load new source — keeping current".
  **Witness:** unit tests "online → online (fetch fail): full rollback", "file → online
  (success): commit + old cache cleanup". **Mutation:** swap the address before loading.
- **P3. Auto-update no more often than allowed.** An automatic trigger updates
  a subscription only if its interval has passed since the last success, ≥ 15 min
  have passed since the last attempt, and there were < 5 consecutive failures
  in this session. A manual update bypasses all three limits.
  **Witness:** unit tests of the "shouldUpdate" group (min-retry, fail-cap, interval, force).
  **Mutation:** remove the check of the last attempt time.
- **P4. The server cannot override the "Don't auto-update" interval.** With `-1`
  the `profile-update-interval` header is ignored; with `0` and `N>0` it is accepted.
  A file subscription is created with `-1`.
  **Witness:** unit tests "interval=-1 → ignores server profile-update-interval",
  "interval ≤ 0 → never auto (but force works)". **Mutation:** apply the server
  interval unconditionally.
- **P5. One pass at a time, a pause between subscriptions.** Automatic and
  "update all" passes do not run in parallel; subscriptions within a pass are
  requested sequentially with a 10 s ± 2 s pause. **Witness** — manual
  check: two subscriptions, "Update all", the "Fetching
  subscription" lines in the app log are ≥ 8 s apart. **Mutation:** run requests in parallel.
- **P6. A disabled subscription stays out of the way.** Without the "Update disabled
  subscriptions" setting it is updated neither automatically nor via "update all";
  with the setting it is updated, but its new composition does not mark the
  config as changed and does not trigger a reaction. **Witness:** unit tests "disabled: without the checkbox
  skip, with the checkbox updates", "force does NOT unfreeze a disabled one WITHOUT the checkbox",
  "disabled subscription with a new composition → dirty stays false". **Mutation:**
  place the disabled gate below `force`.
- **P7. The panel recognizes the request.** By default User-Agent =
  `LxBox-android/<version>` and contains no `singbox` substring; HWID headers
  are sent only with "Send HWID" enabled and a non-empty HWID; in Custom mode
  the subscription sends only its own snapshot, global values are ignored.
  **Witness:** unit tests "never contains singbox", "sendHwid=false → empty",
  "Custom → the snapshot goes into headers, the global one is ignored". **Mutation:**
  add `singbox` to the UA.
- **P8. Offline start.** After a restart, subscription nodes are restored from
  the cache of the last successful response without network (marked
  "(cached)"); for a file subscription — from its snapshot.
  **Witness:** unit tests "init → restores nodes from cache", "start: nodes empty →
  raised from cache by file:url". **Mutation:** do not read the cache at start.
- **P9. The "node disabled" mark follows the node name.** A disabled subscription
  node is visible in the list but does not get into the config; the mark survives
  an update and a restart, survives the provider changing the address under the
  same name, is lost on rename; namesakes are disabled separately.
  **Witness:** unit tests "the mark survives address ROTATION", "RENAME loses
  the mark", "namesakes X / X-2 are disabled SEPARATELY", "a disabled node is not emitted".
  **Mutation:** make the content hash the mark key again.
- **P10. Dormant marks expire by TTL.** The mark of a node that has been absent
  from the subscription longer than `clamp(3 × interval, 24 h, 30 days)` is
  removed — but only on a successful network update. **Witness:** unit tests "threshold
  table", "absent longer than the threshold → removed", "threshold not expired → kept". The
  "only on a successful network update" part is `no witness` (failure, rehydration and file
  subscription are not checked). **Mutation:** clean marks on rehydration from cache.
- **P11. A reaction only to a real change.** A rebuild/reload of the core
  after an update happens only if the node composition of an enabled subscription
  changed; one reaction per pass, `reload` beats `rebuild`.
  A failed update does not mark the config as changed.
  **Witness:** unit tests "same composition again → dirty stays false", "three
  reload subscriptions → one reload, not three", "network error → the flag stays
  false". **Mutation:** react to every successful request.
- **P12. Import rules are deterministic.** A subscription's rules are applied
  top to bottom to every parse, starting from a clean node; the last matching
  Enable/Disable wins; Enable also clears a manual mark.
  **Witness:** unit tests "the last matching rule wins", "re-application
  starts from a clean node", "enable clears the mark — including a manual
  one". **Mutation:** apply rules to an already patched node.
- **P13. Metadata is read tolerantly.** An unparsable `expire` = "no expiry",
  not the year 1970; the name is `profile-title`, otherwise the file name from
  `Content-Disposition`; when HTTP headers are absent, `# key: value` lines from
  the beginning of the body are used.
  **Witness:** unit tests "unparsable expire → null", "profile-title takes priority
  over content-disposition", "inline profile-title from body comments".
  **Mutation:** parse `expire` with a default of 0.
- **P14. Switching the workspace aborts the update.** A running pass stops
  between subscriptions; a response arriving after the switch is not written into
  the new workspace. **Witness:** unit tests "halt aborts a running
  pass between subscriptions", "a deferred fetch of the old controller does not touch the
  new slot". **Mutation:** do not check cancellation in the pause between subscriptions.
- **P15. A stuck "updating" does not block a subscription forever.** If the process
  is killed during a request, on the next start the status becomes "error", and
  the 15 min window counts from that attempt. Pressing "update" again while
  the request is running does not make a second request. `no witness`.

## Controlled parameters

| Parameter | Where | Values | Default |
|---|---|---|---|
| Auto-update subscriptions | Settings → Subscriptions; duplicated in the sources screen menu | on/off | on |
| Update disabled subscriptions | same place; active only with auto-update enabled | on/off | off |
| Custom User-Agent (global) | Settings → Subscriptions | string; empty = `LxBox-android/<version>` | empty |
| Send HWID | Settings → Subscriptions | on/off | off |
| HWID · `x-hwid` | same place, Regenerate button | UUIDv4, generated on first display | — |
| `x-device-os` / `x-ver-os` / `x-device-model` | same place | string; empty = the device value | `android` / OS version / model |
| Update interval (per subscription) | Subscription → Settings | `-1` Don't auto-update · `0` Never (respect server) · 1/3/6/12/24/48/72/168 h | 24 h (online), `-1` (file) |
| On update (per subscription) | Subscription → Settings; hidden with "Auto-restart VPN on settings change" | Rebuild · Reload · Do nothing | Rebuild |
| Custom identity (per subscription) | Subscription → Settings → Fetch identity | Default / Custom (own UA, HWID, device-meta) | Default |
| Import rules (per subscription) | Subscription → Filters | list of rules + a master toggle | empty, toggle on |
| Node on/off | Subscription → Nodes | switch on the node, "enable/disable all" | on |

Fixed constants: pause between subscriptions 10 s ± 2 s; min-retry 15 min;
failure cap per session 5; periodic tick 1 h; delay after the VPN
connects 2 min; 3 request attempts with pauses of 1 s and 3 s, attempt timeout
9 s; 4xx is not retried.

The feature emits no core config keys: a disabled subscription or a disabled node
is left out of the build ([003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md)).

## Inputs / Outputs

**Inputs:** URL `http(s)://…`; text from the clipboard, a QR code or a file (the format
is determined by [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md)); the HTTP response —
body and the headers `subscription-userinfo`, `profile-title`,
`profile-update-interval`, `profile-web-page-url`, `support-url`,
`Content-Disposition`; events: app start, return from background, VPN
connected/stopped, hourly tick, manual "update".

**Outputs:** the list of sources with nodes, status, update time,
failure counter; metadata (traffic, expiry, support links); marks of
disabled nodes; a "composition changed" signal → rebuild / reload of the core
per "On update"; automation events "subscription updated / failed to update"
([014-AUTOMATION](../014-AUTOMATION/FEATURE.md)).

## Data flow

```
input (URL | clipboard | QR | file)
  → classification: subscription URL / single node / file >1 node → file subscription
  → request (identity: Default | Custom) ── 3 attempts ──┐
  → body parse (002) → ≥1 node?                           │ no/error
        yes: import rules → marks (migration, TTL, rules)       → status failed,
            → body cache to disk → status ok → "composition changed?" old nodes and cache
                 → yes and subscription enabled: On update reaction
app start: read sources → "updating" → failed
           → rehydrate nodes from cache → auto-update pass (appStart)
```

## Rules and guarantees

- The last success time changes only on success; the attempt time — on
  every attempt; the consecutive-failure counter is reset by any success.
- A file subscription does not re-read the file: automatic and manual "update"
  are a no-op for it; freshness comes only via "Edit source".
- The server `profile-update-interval` is accepted with interval `0` and `N>0`.
- The subscription name is taken from `profile-title` only on the first success, when the name
  is empty; after that it is the user's. Without a name the URL host is shown.
- Metadata is replaced entirely on every successful response.
- The failure cap lives in memory and is reset by a restart, the "Reset
  fail count & retry" item, a manual update of the subscription and "update all".
- A URL goes to the log only as `scheme://host/***`, a file one — as `file:<local>`.
- A config rebuild by itself never makes HTTP requests.

## Boundaries

- No background update of an unloaded app: the timer ticks while the
  process is alive; the moment of return from background is a separate trigger. How long the process
  lives minimized depends on OS capabilities.
- Parsing body formats, node dedup, rejecting entries — 002-NODE_IMPORT.
- Node availability checks and mass disabling based on their results (buttons on
  the subscription screen) — [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md); here
  only the shared map of marks.
- Auto-disabling nodes rejected by the core — 009-NODE_HEALTH; the verdict is stored
  next to the mark and cleared when the user enables the node.
- Tag prefix, detour settings and folding a subscription into a group —
  [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) and 007.
- Folders of manual servers and single servers — 007/008; only
  creating them from a paste/file belongs here.
- Storage and backup of subscription records —
  [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md).
- File picking and the camera for QR depend on OS capabilities (on a TV without
  a file manager — a hint instead of a picker).
- Not planned (owner decision 2026-09-29, audit [588](../../tasks/588-spec-kit-revision-audit.md)): the "Get Free VPN" Quick Start and refreshing
  subscriptions by interval on pressing Start (`§010F`) — subscriptions are
  refreshed by the auto-update triggers.

## Functions

| Function | What it does | Promises | File |
|---|---|---|---|
| Adding a source | Turns a URL, pasted text, a QR code or a file into a subscription, a single server, a folder or a file subscription. | — | [add-source.md](FUNCTIONS/add-source.md) |
| File subscription and source change | Keeps a multi-node file as a subscription and changes a subscription's URL or online/file mode only when the new source yields nodes. | P2, P4, P8 | [file-subscription.md](FUNCTIONS/file-subscription.md) |
| Subscription request identity | Sets the User-Agent, HWID and device headers of the subscription request, globally (Default) or per subscription (Custom). | P7 | [fetch-identity.md](FUNCTIONS/fetch-identity.md) |
| Subscription auto-update | Refreshes subscriptions on a schedule and on app and VPN events within intervals and anti-spam limits; a manual update bypasses the limits. | P3, P4, P5, P6, P14, P15 | [auto-update.md](FUNCTIONS/auto-update.md) |
| Request, cache and offline start | Retries the request, keeps the previous nodes on a failed or empty response and caches the last good response for an offline start. | P1, P8, P15 | [fetch-cache-offline.md](FUNCTIONS/fetch-cache-offline.md) |
| Action on update | Rebuilds the config, reloads the core or waits when the node composition of an enabled subscription changes. | P6, P11 | [on-update-action.md](FUNCTIONS/on-update-action.md) |
| Disabling subscription nodes | Switches single subscription nodes off by name; the mark survives updates and restarts and expires by TTL once the node is gone. | P9, P10 | [node-disable.md](FUNCTIONS/node-disable.md) |
| Subscription import rules | Disables, enables or edits subscription nodes with rules applied to every parse of the subscription body. | P12 | [import-rules.md](FUNCTIONS/import-rules.md) |
| Subscription metadata | Shows traffic, expiry, name, support links and the recommended interval from the provider's headers or body comments. | P4, P13 | [subscription-meta.md](FUNCTIONS/subscription-meta.md) |

## Related features

- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — turns a subscription body, a paste or a file
  into nodes; recognizes the input format.
- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — disabled subscriptions and nodes are left out
  of the build; "On update" triggers a rebuild.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — tag prefix, detour settings and
  folding a subscription into a group.
- [007-NODE_LIST](../007-NODE_LIST/FEATURE.md) — shows and selects subscription nodes; manual server folders.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — single servers created here from a paste/file are edited there.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — availability checks, bulk disabling and
  auto-disabling core-rejected nodes on top of the shared mark map.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — reloads the core when "On update" = Reload.
- [012-LIVE_STATE](../012-LIVE_STATE/FEATURE.md) — took over the core channel model (`§123F`).
- [014-AUTOMATION](../014-AUTOMATION/FEATURE.md) — receives "subscription updated / failed to update" events.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — storage and backup of subscription records.
- [018-WORKSPACES](../018-WORKSPACES/FEATURE.md) — a workspace switch halts the updater (P14).

## Maintenance notes

- **A 200 response ≠ success.** An HTML stub, a DDoS challenge, a foreign format yield
  0 nodes — that is a failure, the cache is not overwritten. Any new path that writes the
  result must keep this check.
- **Mark = node name within the source**; namesakes are numbered `X`, `X-2`, `X-3`
  in parse order. Compute the identity map only from the full list of the
  source: a subset yields different numbers. Old hash marks (64 hex)
  move to the name on the first parse.
- **"Composition" = ordered nodes + the set of marks.** Subscription metadata is
  not part of it; otherwise the blue "Settings changed" banner would appear once an hour.
- **The attempt mark is written before the network** — without it, app restarts would
  hit the provider on every start.
- **A UA without the brand token** breaks some panels (they return a format that
  parses worse); this warning is shown next to the field but does not block.
- **Switching the workspace** (Workspaces) must stop the updater before
  the scene changes: the pause between subscriptions is interrupted within ~¼ s.
