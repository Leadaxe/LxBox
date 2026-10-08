[English](write-operations.md) · [Русский](write-operations.ru.md)

# Write operations — changing the app through the same owners as the UI

Every domain the screens edit can be written over HTTP; a write goes through
the owning service, is validated before it lands and can rebuild the config
in the same call.

| Field | Value |
|-------|-------|
| Feature | [027-DEBUG_API](../FEATURE.md) |
| Promises | P11–P16 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Lets a script or an agent change what a user would change by hand: settings
(`/settings/*`), custom rules (`/rules`), sources and their import rules
(`/subs`, `/folders`), Directions and chains (`/directions`, `/chains`), Wi-Fi
history, the support feed state, backup import, and the config itself (`PUT
/config`). Writes answer with a uniform envelope and a fixed set of error
codes, so a caller can branch on the code without parsing the message.

## Parameters

| Parameter | Where | Values | Effect |
|-----------|-------|--------|--------|
| `?rebuild=true` | any write | `true`/`1`/`yes` | rebuild the config from settings after the write; the response gains `rebuilt` and `config_bytes` or `rebuild_error` |
| `?reveal=true` | writes that return a snapshot (`/subs`, `/folders`) | bool | the returned snapshot carries secrets (URLs, node bodies) |
| `merge`, `rebuild` | `POST /backup/import` | bool, default `false` | upsert instead of replace; rebuild after restore |
| `keep_servers` | `DELETE /folders/{id}` | bool | members become standalone servers instead of being deleted |
| Body | `PUT`/`POST`/`PATCH` | a JSON object (`Content-Type: application/json`); `PUT /config` — the raw config object; `PUT /settings/vars/{key}` — `{"value":"…"}` | a non-object body, wrong field type or unknown enum value — 400 |

Every `bool` parameter reads `true`, `1` or `yes` (case-insensitive) as true; any
other value, `on` included, is false.

Limits: body up to 1 MiB (413); handler deadline 30 s (504).

## Inputs / Outputs

**Inputs:** `POST`/`PUT`/`PATCH`/`DELETE` requests with a JSON body and the
query flags above.

**Outputs:** `{"ok":true,"action":"<name>",…}` with the domain's own fields
(the created id or tag, the fresh snapshot, `healed` counters,
`dangling_refs`, `rebuild_needed`) and, with `?rebuild=true`, `rebuilt:true,
config_bytes:N` or `rebuilt:false, rebuild_error:"…"`; creations answer 201.
Errors: `{"error":{"code","message"}}`; a rejected `POST /subs` adds a
top-level `dropped[]` with the parse reasons.

| Status | Code | When |
|--------|------|------|
| 400 | `bad_request` | missing or wrong query, malformed JSON, wrong field type, a validation finding (chain `tooFewHops`, an immutable Direction `tag`, a chain `tagEmpty`/`tagTaken`, a bad regex), unsupported method |
| 404 | `not_found` | unknown sub-path, id, tag or index |
| 409 | `conflict` | a precondition is missing: tunnel down, a guard run in flight, `vpn-1` disable or delete, a taken or reserved tag, a protected `debug_*` var, rebuild while Lock config is on |
| 413 | `payload_too_large` | body over 1 MiB |
| 502 | `upstream_error` | the core, the native side or the config save refused |
| 504 | `timeout` | the handler did not finish in 30 s |
| 500 | `internal` | unclassified failure; details in the app log |

## Rules and invariants

- **Validation before the write; a rejection changes nothing.** The same gate
  as the form: a chain with one position, a self-reference or a forward
  reference is 400 and the list is unchanged; a DNS record in the old form is
  400 and storage is untouched; a folder member whose new `raw` does not parse
  keeps the old one.
- **A chain rename rewrites references.** PATCH `/chains/{tag}` with `tag`
  keeps the chain's place in the source list and moves references to the old
  tag (other chains' positions, rules, `route_final`, detours, DNS) to the new
  one in the same write.
- **Writes go through the owners.** Sources through the subscription owner
  (fetch state machine, UI notify), Directions and chains through the
  Directions owner (live entries are re-synced, `healed` reports reset
  references), `app_language` through the locale owner. A generic
  `/settings/vars/{key}` write is a plain variable write, except the
  protected `debug_*` keys (409).
- **Config-significant writes mark the config stale.** Writing a template
  variable, `vpn_mode`, `tun_apps`, `dns_options`, rules or sources without
  `?rebuild=true` raises the same "config changed" banner on the home screen
  as the UI edit would; `tun_apps` also answers `rebuild_needed:true` because
  the tunnel must be re-established. `?rebuild=true` clears it in the same
  call; several writes are cheaper as writes without the flag plus one
  `POST /action/rebuild-config`.
- **`?rebuild=true` never undoes a write.** The write returns 200/201 even if
  the rebuild fails; the failure is `rebuild_error` under its own key. With
  Lock config on, the explicit rebuild route answers 409 and the flag's
  rebuild silently returns `rebuilt:false`.
- **`PUT /config` is temporary unless pinned.** It replaces the saved config
  byte for byte (validated only as a JSON object; the core reports semantic
  errors on reload) and the next rebuild from any source wipes it; `PUT
  /settings/config_locked {"locked":true}` pins it —
  [019-CONFIG_EDITOR](../../019-CONFIG_EDITOR/FUNCTIONS/config-pin.md).
- **Positional collections return a fresh snapshot.** Folder members and
  import rules have no ids; every write answers with the whole collection and
  the next call must take indexes from it.
- **Full permutations only.** `reorder` routes require exactly the current
  set of ids, tags or indexes; a partial list is 400.

## Boundaries

- No transactions across routes: two writes are two independent commits;
  atomicity holds within one request.
- No optimistic locking or versioning: the last write wins, including against
  a concurrent UI edit.
- Node bodies of subscriptions are not editable through the API (they come
  from the fetch); a standalone server's body is edited through
  `PATCH /folders/{id}/members/{idx}` or by replacing the source.
- What a specific field means is the owning feature's contract
  ([route-map.md](route-map.md)).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [031F](../../../tasks/031F-debug-api/spec.md) | ✅ Done → §043 | CRUD of rules and sources, scoped settings writes, `?rebuild=true` |
| 2 | [037](../../../tasks/037-debug-api-write-config-and-lock-rebuild.md) | ✅ Implemented | `PUT /config` and the rebuild lock |
| 3 | [341](../../../tasks/341-quic-knobs-debug-api.md) | Released v2.19.2 | QUIC knobs for field A/B diagnostics |
| 4 | [370](../../../tasks/370-rule-order-num-axis.md) | SPEC (implemented in the same task) | `POST /rules/move` on the sparse `num` axis |
| 5 | [494](../../../tasks/494-debug-api-debts.md) | Released v2.25.0 | Headless start through the guard, run reset, config body check |
| 6 | [500](../../../tasks/500-direct-link-reject-reason.md) | Released v2.25.0 | `dropped[]` with parse reasons on a rejected `POST /subs` |
| 7 | [520](../../../tasks/520-debug-api-warnings-keyed-by-unique-tag.md) | Released v2.25.3 | Warnings of same-named nodes are not lost |
| 8 | [577](../../../tasks/577-authored-json-registry-reports-only.md) | Done | `warnings[].applied` — the registry reports, it does not rewrite |
