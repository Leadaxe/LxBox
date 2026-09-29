[English](self-documentation.md) · [Русский](self-documentation.ru.md)

# Self-documentation — the capability map served by the server itself

`GET /help` returns the map of every route as text or JSON without a token,
so an agent can discover what the API can do before it has the secret.

| Field | Value |
|-------|-------|
| Feature | [027-DEBUG_API](../FEATURE.md) |
| Promises | P10 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Serves the hand-written capability map: every prefix and sub-route, its
method, parameters, body shape and a one-line description, plus the auth and
transport facts (header, bind address, default port, host check). Text is for
a person or an LLM reading the response directly; JSON is for tooling that
builds calls from a list of `{method, path, params, body, description}`.

## Parameters

| Parameter | Values | Default |
|-----------|--------|---------|
| `format` | `text` — markdown; `json` — structured; anything else — 400 as plain text | `text` |

No token is needed: `/help` and `/ping` are the two unauthenticated paths;
the host check still applies.

## Inputs / Outputs

**Inputs:** `GET /help[?format=text|json]`.

**Outputs:** `text/markdown` — sections Health, State, Device, Config, Pool,
Logs, Actions, WARP, Rules, Subscriptions, Nodes, Directions, Chains, Folders,
Core-rejected nodes, Wi-Fi history, Files, Traffic Profiler, Support feed,
Diagnostics, Settings, Backup, Errors, Quick Examples, Notes; or JSON
`{server, docs, auth, transport, endpoints:[{method, path, auth?, params?,
body?, description, response?}]}`, pretty-printed.

## Rules and invariants

- **Parity with the router is tested from both sides.** Every mounted prefix
  must have at least one JSON entry (`path == prefix` or under it); every JSON
  path, with `{id}`/`{tag}`/`{idx}` placeholders replaced, must resolve to a
  mounted route. A route added without a `/help` entry fails the unit test.
- **The map is written by hand.** There is no generator from the router or
  from the reference; the text and JSON forms are two separate literals and
  are edited together. The JSON form must keep every nested key a string —
  the serialiser test guards it.
- **Rule for a new route: an entry in `/help` (text and JSON) + a line in
  the reference.** The reference
  ([`docs/api/debug-api-reference.md`](../../../../api/debug-api-reference.md))
  is wider on purpose (examples, flows, semantics); `/help` is the short map.
  When they disagree, the code is right and both are fixed.
- **Known gaps** (task 589, open): `POST /settings/rebuild-config`,
  `GET /files/external` and the `source` parameter of `POST /logs/clear` are
  missing from the JSON form; the 413/502/504 codes are absent from the
  Errors section; `POST /subs/reorder`, `GET /subs`,
  `/settings/enabled_groups`, `GET /diag/stderr` and the `warnings` field list
  are described by an older behaviour. The task also adds a parity test
  "every path of `/help?format=json` occurs in the reference".
- **The text form is an agent's first read.** It states the setup (`adb
  forward tcp:9269 tcp:9269`, the `Authorization` header, where the token is
  copied from) and ends with runnable examples and notes (emoji tags must be
  URL-encoded, timestamps are ISO-8601 UTC, the token is stable until
  regenerated).

## Boundaries

- `/help` describes routes, not domain semantics: what a rule field or a
  chain position means is in the owning feature and the reference.
- No OpenAPI or MCP output; the JSON form is the raw material for one, and
  the MCP wrapper (`§035F`) was cancelled.
- Content parity with the reference is not yet tested (task 589); only the
  router parity is.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [031F](../../../tasks/031F-debug-api/spec.md) | ✅ Done → §043 | `/help` text and JSON without a token |
| 2 | [218](../../../tasks/218-debug-help-sync.md) | DONE | `/help` matches the mounted routes |
| 3 | [494](../../../tasks/494-debug-api-debts.md) | Released v2.25.0 | `/help` text and JSON updated together with the reference |
| 4 | [510](../../../tasks/510-review-findings-after-v2251.md) | — | `/pool` was missing from the JSON form; the "every mounted prefix is in `/help`" test |
| 5 | [589](../../../tasks/589-debug-api-help-parity.md) | N (new) | Catch `/help` up with the code; parity test with the reference |
| 6 | [035F](../../../tasks/035F-mcp-server/spec.md) | 🚫 Cancelled | An MCP server generated from the map — not to be implemented |
