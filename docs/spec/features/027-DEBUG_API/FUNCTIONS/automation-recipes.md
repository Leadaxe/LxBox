[English](automation-recipes.md) · [Русский](automation-recipes.ru.md)

# Automation recipes — driving the app from a host with adb and curl

A developer, a CI script or an AI agent talks to the device through `adb
forward` and plain `curl`; the same six scenarios cover most of what the
screen would be used for.

| Field | Value |
|-------|-------|
| Feature | [027-DEBUG_API](../FEATURE.md) |
| Promises | P17 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Turns the API into a working method: how a session is set up, how an agent
discovers the surface, and which routes make up the typical flows —
reproducing a complaint, testing nodes, editing rules, trying a hand-made
config, driving the start guard in an autotest. The full catalogue of
examples is the reference
([`docs/api/debug-api-reference.md`](../../../../api/debug-api-reference.md));
the recipes below are the short list an agent should know by heart.

## Parameters

| Item | Value |
|------|-------|
| Forwarding | `adb forward tcp:9269 tcp:9269` (the port from App Settings) |
| Base | `BASE=http://127.0.0.1:9269`, `HDR="Authorization: Bearer <token>"` |
| Token | App Settings → Diagnostics → Developer → Copy; stable until Regenerate |
| Tags with non-ASCII | URL-encode the query value (`python3 -c 'import urllib.parse;print(urllib.parse.quote("…"))'`) |

## Inputs / Outputs

**Inputs:** shell commands on the host; the app running on the device with
the Debug API on. **Outputs:** JSON to parse with `jq`; files (dump, pprof,
reports) saved with `curl -o`; state changes on the device.

```bash
# 1. Session: forward, liveness, the map
adb forward tcp:9269 tcp:9269
curl -s $BASE/ping                       # no token: {"pong":true,…}
curl -s "$BASE/help?format=json" | jq '.endpoints[].path'

# 2. Reproduce a complaint: state, core errors, the whole dump
curl -s -H "$HDR" $BASE/state | jq '{tunnel,active_in_group,last_error}'
curl -s -H "$HDR" "$BASE/logs/core?level=warning,error&limit=100" | jq '.[].message'
curl -s -H "$HDR" $BASE/diag/dump -o dump.json

# 3. Test and switch nodes
curl -s -X POST -H "$HDR" "$BASE/action/urltest?group=vpn-1-auto"
curl -s -X POST -H "$HDR" "$BASE/action/switch-node?tag=$(enc "$TAG")"

# 4. Add a rule and rebuild in one call
curl -s -X POST -H "$HDR" -H 'Content-Type: application/json' \
  -d '{"name":"No telemetry","kind":"inline","domain_suffixes":["telemetry.example"],"outbound":"block"}' \
  "$BASE/rules?rebuild=true"

# 5. Try a hand-made config, pinned against rebuilds
curl -s -X PUT -H "$HDR" -H 'Content-Type: application/json' -d '{"locked":true}' $BASE/settings/config_locked
curl -s -H "$HDR" $BASE/config > cfg.json          # edit cfg.json
curl -s -X PUT -H "$HDR" -H 'Content-Type: application/json' --data-binary @cfg.json $BASE/config
curl -s -X POST -H "$HDR" $BASE/action/reload-vpn
curl -s -X PUT -H "$HDR" -H 'Content-Type: application/json' -d '{"locked":false}' $BASE/settings/config_locked

# 6. Autotest: headless start through the guard, then read the outcome
curl -s -X POST -H "$HDR" "$BASE/action/start-vpn-headless?guard=true"
curl -s -H "$HDR" $BASE/core_reject | jq '{phase,outcome,disabled}'
```

## Rules and invariants

- **Read `/help` first, then act.** The map is served without a token and
  lists every route; an agent that guesses paths gets 404s, one that reads
  the map does not.
- **Snapshot before a dangerous write.** `GET /backup/export?include=storage`
  is the full restore point; `GET /config`, `/state/rules`,
  `/state/subs?reveal=true` are the cheap partial ones. Restore with
  `POST /backup/import`.
- **Batch writes, rebuild once.** Several writes without `?rebuild=true` and
  one `POST /action/rebuild-config` at the end; a rebuild is the expensive
  step, and the flag on every call multiplies it.
- **Headless start does not need the UI.** `POST /action/start-vpn` works
  before the home screen has built its controllers; `start-vpn-headless`
  skips the consent dialog (permission must already be granted) and with
  `?guard=true` runs the same core-reject guard as the Start button, reported
  through `GET /core_reject`.
- **Respect the 30 s budget.** Folder probes and chain probes are sequential:
  lower `timeout_ms` for big inputs instead of waiting on a 504.
- **Check the device you are on.** `POST /action/toast?msg=…` shows a toast on
  the screen; `GET /device` returns model, app and core versions.
- **Encode emoji tags.** Node and group tags go as query values; curl does not
  encode them.

## Boundaries

- Recipes are for a test device with the API enabled by its owner; the API
  is not an end-user or a remote-control surface
  ([014-AUTOMATION](../../014-AUTOMATION/FEATURE.md) is).
- No MCP server or SDK wraps the API (`§035F` cancelled); tooling is `curl`,
  `jq` and the JSON map.
- Tunnel consent, notification and location permissions are granted on the
  device (`adb shell pm grant …`), not through the API.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [031F](../../../tasks/031F-debug-api/spec.md) | ✅ Done → §043 | `adb forward` + curl as the working method; quick examples in `/help` |
| 2 | [037](../../../tasks/037-debug-api-write-config-and-lock-rebuild.md) | ✅ Implemented | The "pin a custom config" flow |
| 3 | [316](../../../tasks/316-kernel-crash-reports-access.md) | Device-verified | Crash reports and snapshots downloadable with curl |
| 4 | [494](../../../tasks/494-debug-api-debts.md) | Released v2.25.0 | Headless start through the guard for autotests |
| 5 | [592](../../../tasks/592-debug-api-help-parity.md) | N (new) | Parity of the map with the reference that the recipes rely on |
