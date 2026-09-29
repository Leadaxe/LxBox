[English](route-map.md) · [Русский](route-map.ru.md)

# Route map — which prefix gives what, and which feature owns the meaning

Twenty-three prefixes are mounted on the server; each one mirrors a domain of
the app whose semantics live in the owning feature, not here.

| Field | Value |
|-------|-------|
| Feature | [027-DEBUG_API](../FEATURE.md) |
| Promises | P9 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Turns a request path into a handler by the longest mounted prefix and tells
the reader where to look for the meaning of what the handler does. This table
is the index; the full route reference with parameters, bodies and examples is
[`docs/api/debug-api-reference.md`](../../../../api/debug-api-reference.md)
and the server's own `GET /help` — neither is duplicated here.

## Parameters

None: the set of prefixes is fixed by the build. Nothing is mounted
conditionally — a route exists whether or not its precondition (a live
tunnel, a loaded UI) is met; the handler answers 409 in that case.

## Inputs / Outputs

**Inputs:** the request path. **Outputs:** the handler, or 404 `not_found`.

| Prefix | What it gives | Owner of the semantics |
|--------|---------------|------------------------|
| `/ping`, `/help` | liveness; the capability map (text, `?format=json`) — no token | this feature — [self-documentation.md](self-documentation.md) |
| `/state` | tunnel and node state; `/subs`, `/rules`, `/vpn`, `/config_locked`; `/storage` — the scrubbed storage snapshot | [012-LIVE_STATE](../../012-LIVE_STATE/FEATURE.md); storage — [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FUNCTIONS/storage-contract.md) |
| `/device` | Android version, model, ABI, app version and build, core version, network, uptime | [021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.md) (versions), [020-APP_SHELL](../../020-APP_SHELL/FEATURE.md) |
| `/config` | the saved config raw or pretty, its path, the running core's snapshot; `PUT` — replace the saved one | [019-CONFIG_EDITOR](../../019-CONFIG_EDITOR/FUNCTIONS/config-editor.md), [config-pin.md](../../019-CONFIG_EDITOR/FUNCTIONS/config-pin.md); `/running` — [012-LIVE_STATE](../../012-LIVE_STATE/FUNCTIONS/running-config.md) |
| `/pool` | a round-robin pool snapshot by group tag | [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FUNCTIONS/balancing.md) |
| `/logs` | app and core log with `limit`, `source`, `q`, `level`; clear | [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/app-log.md), [core-log.md](../../013-DIAGNOSTICS/FUNCTIONS/core-log.md) |
| `/action` | start, headless start, stop, force-stop, reconnect, reload, reset-network, quic-knobs, urltest, switch-node, set-group, rebuild-config, check-config, refresh-subs, download-srs, clear-srs, toast, emulate-error, check-updates, preview-empty-state | [010-VPN_SERVICE](../../010-VPN_SERVICE/FUNCTIONS/tunnel-control.md), [009-NODE_HEALTH](../../009-NODE_HEALTH/FUNCTIONS/urltest-group.md), [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FUNCTIONS/config-validation.md), [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FUNCTIONS/auto-update.md), [004-ROUTING](../../004-ROUTING/FUNCTIONS/remote-rule-sets.md), [020-APP_SHELL](../../020-APP_SHELL/FUNCTIONS/update-check.md) |
| `/files` | cached rule-sets, whitelisted local files, archived crash reports, memory snapshots | [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/crash-reports.md), [004-ROUTING](../../004-ROUTING/FUNCTIONS/remote-rule-sets.md) |
| `/diag` | the dump, exit reasons, system log tail, current crash report, app log by session, pprof | [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/diagnostic-dump.md), [core-profiling.md](../../013-DIAGNOSTICS/FUNCTIONS/core-profiling.md) |
| `/backup` | export a data snapshot, import with merge or replace | [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FUNCTIONS/full-backup-export.md), [full-backup-restore.md](../../017-BACKUP_AND_STORAGE/FUNCTIONS/full-backup-restore.md) |
| `/rules` | CRUD of custom rules, reorder, move | [004-ROUTING](../../004-ROUTING/FUNCTIONS/inline-rules.md), [rule-order.md](../../004-ROUTING/FUNCTIONS/rule-order.md), [024-TEMPLATE](../../024-TEMPLATE/FUNCTIONS/preset-bundles.md) |
| `/subs` | the unified source list, one entry with `reveal` / `warnings`, add by input, meta patch, refresh, reorder, import rules | [001-SUBSCRIPTIONS](../../001-SUBSCRIPTIONS/FUNCTIONS/subscription-meta.md), [import-rules.md](../../001-SUBSCRIPTIONS/FUNCTIONS/import-rules.md), [fetch-identity.md](../../001-SUBSCRIPTIONS/FUNCTIONS/fetch-identity.md); parsing — [025-CONTRACT_REGISTRY](../../025-CONTRACT_REGISTRY/FUNCTIONS/parse-warnings.md) |
| `/nodes` | a node as a share link, exactly what Copy link produces | [002-NODE_IMPORT](../../002-NODE_IMPORT/FUNCTIONS/share-link-export.md) |
| `/directions` | CRUD of Directions, reorder, the `healed` counters | [004-ROUTING](../../026-DIRECTIONS/FUNCTIONS/direction-model.md), [006-DETOUR_AND_BALANCE](../../026-DIRECTIONS/FUNCTIONS/direction-as-detour.md) |
| `/chains` | CRUD of hop chains, layer-by-layer probe | [006-DETOUR_AND_BALANCE](../../006-DETOUR_AND_BALANCE/FUNCTIONS/hop-chains.md), [chain-editor.md](../../006-DETOUR_AND_BALANCE/FUNCTIONS/chain-editor.md) |
| `/folders` | folders and their members by position, ungroup, move, probe | [007-NODE_LIST](../../007-NODE_LIST/FUNCTIONS/server-folders.md), [folder-testing.md](../../007-NODE_LIST/FUNCTIONS/folder-testing.md) |
| `/core_reject` | the auto-disable guard: run state, stored verdicts, banner, prompt, cancel, reset, enable, per-node notifications | [009-NODE_HEALTH](../../009-NODE_HEALTH/FUNCTIONS/core-reject-auto-disable.md), [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/coded-notifications.md) |
| `/warp` | register a WARP node without the UI | [015-WARP](../../015-WARP/FUNCTIONS/one-tap-registration.md) |
| `/settings` | scoped writes: route_final, node_sort, vpn_mode, ping_options, tun_apps, dns_options, vars, config_locked, core_logs_*, vpn/*; rebuild-config alias | [004-ROUTING](../../004-ROUTING/FEATURE.md), [007-NODE_LIST](../../007-NODE_LIST/FUNCTIONS/node-sorting.md), [010-VPN_SERVICE](../../010-VPN_SERVICE/FUNCTIONS/operating-modes.md), [009-NODE_HEALTH](../../009-NODE_HEALTH/FUNCTIONS/ping-settings.md), [011-SPLIT_TUNNELING](../../011-SPLIT_TUNNELING/FUNCTIONS/mode-and-list.md), [005-DNS](../../005-DNS/FEATURE.md), [024-TEMPLATE](../../024-TEMPLATE/FUNCTIONS/template-language.md), [029-LOCALIZATION](../../029-LOCALIZATION/FUNCTIONS/language-selection.md) |
| `/wifi_history` | saved Wi-Fi networks for rule conditions (cap 50) | [004-ROUTING](../../004-ROUTING/FUNCTIONS/wifi-conditions.md) |
| `/profiler` | live event recording: start, stop, state, window snapshot, SSE stream, unattributed ring | [013-DIAGNOSTICS](../../013-DIAGNOSTICS/FUNCTIONS/live-events.md), [028-TRAFFIC_PROFILER](../../028-TRAFFIC_PROFILER/FUNCTIONS/debug-api-access.md) |
| `/support` | the support feed state, reset, preview of one message | [020-APP_SHELL](../../020-APP_SHELL/FUNCTIONS/support-feed.md) |

## Rules and invariants

- **Longest prefix wins, substrings do not match.** `/subs/{id}/rules` is
  the subscription handler, `/statex` is not `/state`; a path under no prefix
  is 404 `not_found`. Inside a prefix the handler decides the sub-path and
  the method; a wrong method is 400, an unknown sub-path 404.
- **Read routes are `GET`; every write is `POST`/`PUT`/`PATCH`/`DELETE`** and
  accepts `?rebuild=true` — [write-operations.md](write-operations.md).
- **Ids and addressing follow the domain.** Sources by `id`, Directions and
  chains by `tag`, folder members and import rules by position (indexes shift
  after a delete or reorder — take the next index from the returned
  snapshot), rules by `id` with a sparse `num` axis.
- **Removed prefixes stay removed.** `/clash/*` and `/state/clash` (§122) —
  404; no alias is kept.

## Boundaries

- The meaning of a field in a domain response (what `healed`, `usable`,
  `strip_evasion`, `warnings[].applied` mean) is the owning feature's
  contract; this map only says where to look.
- Sub-routes, parameters and bodies are not listed here by design: the
  reference and `/help` carry them, and this table would drift.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [031F](../../../tasks/031F-debug-api/spec.md) | ✅ Done → §043 | State, config, logs, actions, rules, subs, settings, files |
| 2 | [122F](../../../tasks/122F-commandclient-migration/spec.md) | — | Clash API routes removed |
| 3 | [035](../../../tasks/035-platform-interface-extras-in-debug-api.md) | ✅ Implemented (in a modified form) | `/diag/*`: exit reasons, system log, dump |
| 4 | [147](../../../tasks/147-debug-api-warp-endpoint.md) | Implemented | `/warp` |
| 5 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | Implemented | `/pool` |
| 6 | [238](../../../tasks/238-debug-api-channels-folders.md) | Implemented | `/directions`, `/folders` |
| 7 | [316](../../../tasks/316-kernel-crash-reports-access.md) | Device-verified | `/files/crash`, `/files/oom` |
| 8 | [346](../../../tasks/346-subs-full-crud-debug-api.md) | DEVICE-VERIFIED | `/subs` meta, identity, import rules |
| 9 | [357](../../../tasks/357-support-deeplinks.md) | DEVICE-VERIFIED | `/support` |
| 10 | [478F](../../../tasks/478F-core-rejected-node-auto-disable/spec.md) | Released v2.25.0 | `/core_reject`, `/nodes/link` |
| 11 | [524](../../../tasks/524-unified-source-entries.md) | Released v2.25.3 | `/subs` as the unified list with chains and `source_key` |
