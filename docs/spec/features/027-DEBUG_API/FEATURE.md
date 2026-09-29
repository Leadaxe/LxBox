[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Debug API — local HTTP control surface for automation and diagnostics

LxBox runs a token-protected HTTP server on the device's own address through
which a developer, a test script or an AI agent reads the whole app state and
changes it without the screen: sing-box config, subscriptions, routing rules,
Directions, hop chains, DNS, logs and crash reports. It is off by default and
reachable from a host only over `adb forward`.

| Field | Value |
|-------|-------|
| Feature | 027-DEBUG_API |
| Type | Product feature (developer surface) |
| Absorbed | `§031F` (the Debug API part of `§043F`) |
| State | ✅ written from code, 2026-09-29 |

## Purpose

Reproducing a complaint, running an autotest or trying a config the app cannot
build by itself all need full access to the app state from a host machine,
with no taps. The Debug API gives that as plain HTTP on `127.0.0.1:<port>`:
every domain the UI edits — sources, rules, Directions, chains, folders, DNS,
VPN mode, tunnel apps — has routes that go through the same owners as the
screens; on top sit read-only evidence routes (logs, dump, crash reports,
memory snapshots, pprof) and triggers (start, stop, URLTest, rebuild, network
reset).

The feature protects three principles:

- **Root access by design, behind an explicit gate.** Behind the token the API
  sees and changes everything, secrets included; masking is a convenience, not
  a boundary. The gate itself — off by default, loopback only, a 128-bit token,
  host-name check — is what an audit verifies.
- **The map does not lie.** `/help` lists every mounted prefix, error codes are
  a fixed contract, and a route is not considered done until it is in `/help`
  and in the reference.
- **Writes are the UI's writes.** A route mutates through the owning service,
  the same validation gate as the form applies, a rejected write changes
  nothing, and `?rebuild=true` turns any write into "change + rebuild config"
  in one call.

## Promises

- **P1. The Debug API is closed by default.** Off until explicitly enabled;
  listens only on the device's own address; the token is 32 hex characters
  (128 bits), generated on first enable; with an empty token the server does
  not start and every protected route is 401. **Witness:** units "yields 32
  hex characters", "different tokens on consecutive calls", "an empty token →
  Unauthorized even with Bearer"; loopback — manual check (a request to the
  device's LAN address does not connect). **Mutation:** an empty token allows
  startup.
- **P2. Without a token — only /ping and /help.** Everything else without the
  exact `Authorization: Bearer <token>` header returns 401. **Witness:** units
  "GET /state without a token → 401", "/ping passes without auth", "the scheme
  must be exactly `Bearer `, not `bearer`". **Mutation:** a case-insensitive
  scheme.
- **P3. A foreign host name is rejected first.** A request whose Host is not
  `127.0.0.1` / `localhost` gets 403 even with the correct token and even on
  `/ping`; the port in the header and letter case are ignored. **Witness:**
  units "evil.com → InvalidHost", "GET /ping with Host: evil.com → 403",
  "drops the port from the header", "ignores case". **Mutation:** the host
  check after authorisation, only for protected paths.
- **P4. Access cannot be lost through the API itself or a backup import.** The
  enable, port and token keys cannot be written through `/settings/vars`
  (409); a replace import that lacks them keeps the current ones. **Witness:**
  units "replaceRaw merge=false keeps device Debug API keys absent in
  snapshot", "Debug API keys from snapshot win"; the ban in `/settings/vars` —
  `no witness`. **Mutation:** a replace import rewrites `vars` entirely.
- **P5. File routes do not leave their directories.** Names with path
  traversal and names outside the whitelist are rejected (404/400).
  **Witness:** units "traversal in &file= is rejected", "a non-whitelisted
  name → 404 even if the file exists", "traversal on /files/local is rejected
  too". **Mutation:** the file name is joined to the directory without a check.
- **P6. A hung handler does not hang the server.** After 30 s the client gets
  504 `timeout`. **Witness:** unit "long handler → RequestTimeout".
  **Mutation:** waiting without a deadline.
- **P7. The secret does not leak into copyable snapshots.** The token in the
  storage snapshot is `***`; subscription addresses and node bodies are masked
  until `?reveal=true`; sensitive request parameters are masked in the request
  log. **Witness:** units "debug_token is masked, other vars pass through",
  "an empty debug_token stays an empty string", "without reveal — uri is not
  returned"; the request log — `no witness`. **Mutation:** a storage snapshot
  without the scrubber.
- **P8. Stopping the server closes the port.** After stop (toggle off, port or
  token change) a new connection is refused; the server comes back on the new
  values. **Witness:** unit "stop() interrupts listen — connect refused
  afterwards"; restart on a changed port — manual check. **Mutation:** the
  old listener kept alive after a port change.
- **P9. Routing is by longest prefix, never by substring.** `/subs/{id}/rules`
  reaches the subscription handler, `/statex` does not reach `/state`; an
  unmounted prefix is 404 `not_found`. **Witness:** units "longest-prefix
  wins", "does not match by substring", "404 NotFound when the prefix is not
  mounted", "GET /unknown/path → 404 not_found". **Mutation:** first match
  wins.
- **P10. The map does not lie and is machine-readable.** Every mounted prefix
  appears in `/help?format=json`, every path listed there resolves to a
  mounted route, JSON always serialises (every nested key is a string) and
  text is markdown. **Witness:** units "every mounted router prefix is in
  /help?format=json", "/help json and text contain real paths", "all keys of
  nested maps are String", "/help?format=text → markdown, works".
  **Mutation:** a route without an entry in `/help`.
- **P11. Error codes are a fixed contract; an unknown failure is 500 without
  details.** The envelope is `{"error":{"code","message"}}`; 400
  `bad_request`, 401 `unauthorized`, 403 `invalid_host`, 404 `not_found`, 409
  `conflict`, 413 `payload_too_large`, 502 `upstream_error`, 504 `timeout`;
  an unclassified exception is 500 `internal` with the stack in the app log,
  not in the response. **Witness:** units "the shape is {error: {code,
  message}}", "codes are stable (API contract)", "an ordinary exception →
  InternalError (500)". **Mutation:** a renamed code; the stack in the
  response.
- **P12. Input is validated uniformly.** A missing or empty required query
  parameter, a non-integer where an integer is expected, a body that is not a
  JSON object, an unsupported method — 400. **Witness:** units "requiredQuery
  throws BadRequest when absent", "qInt invalid → BadRequest", "jsonBodyAsMap —
  an array (not an object) → BadRequest", "an unsupported method → 400".
  **Mutation:** a missing parameter read as an empty string.
- **P13. A rejected write changes nothing.** Validation runs before the
  write; on 400 the storage is as it was. **Witness:** units "POST with one
  position → 400 AND NOTHING WRITTEN", "→ 400 with a sample record, storage
  untouched", "PATCH member: a broken raw → 400 keeps the old one".
  **Mutation:** write first, validate after.
- **P14. A missing precondition is 409, not a silent no-op.** A tunnel that is
  not up, a guard run in flight, a protected Direction: the write is refused
  with a machine-readable message. **Witness:** units "group scope, tunnel
  down → Conflict", "a run in flight → 409, the phase is not reset", "vpn-1
  cannot be disabled → 409". **Mutation:** 200 with nothing done.
- **P15. `?rebuild=true` rebuilds after the write, and a failed rebuild does
  not undo it.** The write status stays 200/201; the outcome is reported as
  `rebuilt` + `config_bytes` or `rebuild_error`. **Witness:** units
  "?rebuild=true — the write reaches storage", "?rebuild=false / no flag — a
  plain response"; `rebuild_error` under its own key — `no witness`.
  **Mutation:** a failed rebuild rolls the write back.
- **P16. A write is the UI's write.** Changes through the API are visible to
  the live screens immediately and survive a controller reload. **Witness:**
  units "PATCH /directions/{tag}: flag-unset is mirrored in entries", "DELETE
  /directions/{tag}: heal is mirrored in entries", "rules and identity survive
  a controller reload (persist)". **Mutation:** a write to storage that the
  screen sees only after a restart.
- **P17. Headless start does not need the UI.** `POST /action/start-vpn`
  works before the subscription controller exists (200, the tunnel starts),
  not 409. **Witness:** unit "without the subscription controller → 200 and
  startVPN, not 409". **Mutation:** the start refused until the home screen
  is opened.

## Controlled parameters

| Setting | Where | Values | Default | When it applies |
|---------|-------|--------|---------|-----------------|
| Debug API | App Settings → Diagnostics → Developer | on/off | off | immediately |
| Port | same place | 1024..49151, otherwise an error under the field | 9269 | immediately (the server restarts) |
| Token | same place, Copy / Regenerate | 32 hex | generated on first enable | immediately; the old one gets 401 |
| Lock config (debug) | same place, visible only while the Debug API is on | on/off | off; cleared by turning the Debug API off | immediately |

Fixed values (contract): address `127.0.0.1`; request handling deadline 30 s;
request body up to 1 MiB; paths without a token — `/ping`, `/help`;
response type `application/json; charset=utf-8` (text or a file where the
route says so).

The feature emits no core config keys: it reads and writes the same settings
the screens do.

## Inputs / Outputs

**Inputs:** HTTP requests to `127.0.0.1:<port>` with `Authorization: Bearer
<token>`; the toggle, port and token from App Settings; the home screen
opening (the server comes up).

**Outputs:** JSON responses; text (`/help`) and files (SRS, reports,
snapshots, pprof); lines in the app log — one per request (method, path,
query, status, time) and the server lifecycle (listening, stopped, bind
failed); side effects in the app — the same as the corresponding UI action.

## Data flow

```
App Settings → enable / port / token → (re)start the server on 127.0.0.1:<port>
HTTP → error mapper → request log → Host check (403) → token (401)
     → 30 s deadline (504) → longest-prefix route (404) → handler
handler → owning service (the same as the screen) → storage
        → [?rebuild=true] → build config → save → rebuilt / rebuild_error
        → JSON {"ok":true,"action":…} | {"error":{"code","message"}}
```

## Rules and guarantees

- Order of checks: host name → token → deadline → route. A rejected request
  is logged with its final status; 5xx as a warning, everything else as debug.
- The server starts when the home screen opens and on every change of the
  toggle, port or token; a busy port is an error in the app log, not an app
  failure; enabling without a token creates one.
- Turning the API off clears Lock config, so a pinned config can never be
  left without a way to unpin it (019-CONFIG_EDITOR · P7).
- Keys with `token`, `secret`, `auth` or `key` in the name are masked in the
  request log; `/config`, `/backup/export` and `?reveal=true` return secrets
  as they are — by design.
- Any write accepts `?rebuild=true`; several writes are cheaper as writes
  without the flag plus one `POST /action/rebuild-config`.
- A config-significant write without a rebuild leaves the app with a stale
  config: the home screen shows the "config changed" banner as after the same
  edit in the UI, and the next rebuild picks the change up.

## Boundaries

- No access from the network: only the device address and `adb forward`; the
  loopback is shared by all apps on the device, so the token is the only
  protection there. Depends on OS capabilities: the lifetime of the app
  process.
- The semantics of each domain — what a rule, a Direction, a chain or a
  subscription means — belong to the owning features
  ([route-map.md](FUNCTIONS/route-map.md)); this feature owns the transport,
  the gate, the error contract and the map.
- Logs, crash reports, the dump, live events and notifications —
  [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md); here only their routes.
- Config pinning (`PUT /config` + Lock config) —
  [019-CONFIG_EDITOR](../019-CONFIG_EDITOR/FUNCTIONS/config-pin.md).
- External control from automation apps and the quick tile —
  [014-AUTOMATION](../014-AUTOMATION/FEATURE.md); the Debug API is not an
  end-user surface.
- An MCP wrapper over the API (`§035F`) — cancelled, not implemented. Clash
  API routes (`/clash/*`, `/state/clash`) — removed (§122), 404. No log
  streaming; the only stream is `/profiler/live/stream`.
- The full route reference is
  [`docs/api/debug-api-reference.md`](../../../api/debug-api-reference.md);
  the feature does not duplicate it.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Access and security | Gates the server: default-off, loopback bind, port, token, host check, request deadline, masking of secrets and locking the configuration keys. | P1–P8 | [access-and-security.md](FUNCTIONS/access-and-security.md) |
| Route map | Maps the 23 mounted prefixes to what they give and to the feature that owns the semantics; longest-prefix routing. | P9 | [route-map.md](FUNCTIONS/route-map.md) |
| Self-documentation | Serves the capability map at `/help` as text and JSON and keeps it in step with the router, the reference and the tests. | P10 | [self-documentation.md](FUNCTIONS/self-documentation.md) |
| Write operations | Changes settings, rules, sources and the config through the owning services with uniform validation, atomic rejection, stable error codes and `?rebuild=true`. | P11–P16 | [write-operations.md](FUNCTIONS/write-operations.md) |
| Automation recipes | Shows how a developer or an agent drives the app from a host: `adb forward`, `curl`, typical scenarios. | P17 | [automation-recipes.md](FUNCTIONS/automation-recipes.md) |

## Related features

- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — logs, crash reports,
  memory snapshots and the dump that the `/logs`, `/files`, `/diag` and
  `/profiler` routes read; the request log lives in its app log.
- [019-CONFIG_EDITOR](../019-CONFIG_EDITOR/FEATURE.md) — `PUT /config` and
  Lock config are its config pinning (019-CONFIG_EDITOR · P6, P7,
  [promises](../019-CONFIG_EDITOR/FEATURE.md#promises)).
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — the
  `/backup` routes; the export strips the Debug API keys by default
  (017-BACKUP_AND_STORAGE · P1,
  [promises](../017-BACKUP_AND_STORAGE/FEATURE.md#promises)).
- [014-AUTOMATION](../014-AUTOMATION/FEATURE.md) — the end-user control
  surface (Intent API, tile); the Debug API is the developer one.
- [004-ROUTING](../004-ROUTING/FEATURE.md), [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md),
  [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md),
  [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — own the semantics behind
  the CRUD routes (see the route map for the full list).

## Maintenance notes

- The capability map in `/help` is written by hand; there is no generator
  from the router. Rule: a new route = an entry in `/help` (text and JSON) + a
  line in the reference. Known gaps are collected in task 589.
- The scrubber in `/state/storage` is a denylist: a new sensitive key must be
  added to it and to the test, otherwise it is returned as is.
- The API is root access by design: an audit checks the boundary (token, bind,
  default-off, host), not the masking of secrets behind it. Masking
  `warp_account` / `masque_account` "as a security fix" is a false boundary —
  the same data is raw in `/backup/export`.
- Handler deadline is 30 s: folder probes and chain probes are sequential, so
  lower `timeout_ms` on large inputs instead of raising the deadline.
