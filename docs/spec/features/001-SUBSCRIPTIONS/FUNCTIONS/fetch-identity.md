[English](fetch-identity.md) · [Русский](fetch-identity.ru.md)

# Subscription request identity — User-Agent and HWID headers for provider panels

Sets the User-Agent and HWID headers the app sends with a subscription request, globally or per
subscription.

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | P7 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Defines **who the app introduces itself as** in the subscription HTTP request. Panels
(Remnawave, Marzban and similar) pick the response format by User-Agent and count
devices against the limit by the HWID headers. The settings affect only the
subscription request — not the core config, and they do not mark it as changed.

## Parameters

Global (Settings → Subscriptions → Fetch identity):

| Parameter | Values | Default |
|---|---|---|
| Custom User-Agent | string, surrounding whitespace is trimmed; free input or a client preset | empty = `LxBox-android/<version>` |
| Send HWID | on/off | off |
| HWID · `x-hwid` | string; Regenerate gives a new UUIDv4 | UUIDv4, generated on first display |
| `x-device-os` | string | `android` |
| `x-ver-os` | string | the device OS version |
| `x-device-model` | string | the device model |

On a subscription (Settings → Fetch identity → Custom identity): the same set of
fields. Enabling Custom copies the current global values (with device values
already filled in); disabling discards the snapshot.

## Inputs / Outputs

**Output — GET request headers:**

| Header | When |
|---|---|
| `User-Agent` | always |
| `x-hwid` | Send HWID on and HWID non-empty |
| `x-device-os`, `x-ver-os`, `x-device-model` | together with `x-hwid`, each — if the value is non-empty |

## Rules and invariants

- Default mode: UA = the global override, otherwise the branded one. Custom mode:
  UA and HWID headers **only** from the subscription snapshot; global ones are ignored;
  an empty snapshot UA → the branded one (an empty header is not sent).
- Branded UA: `LxBox-android/<version>`; a leading `v`, brackets, `;` and
  spaces are cut from the version; with an empty version — `unknown`. It never contains the
  `singbox` substring (on it some panels return a JSON config).
- The UA field has a list of popular-client presets: LxBox (default, clears the
  field), Happ, v2RayTun, Streisand, Karing, v2rayNG, Hiddify, sing-box. A preset
  only fills the field and can be edited further; which preset was picked is not
  stored, only the string. Presets exist for panels that send the full format
  (for example xray JSON with ws `path` and headers) only to "their" clients and
  give everyone else stripped links or a refusal. Clash-family clients are not
  offered: Clash YAML is not parsed. The default never changes on its own: a
  foreign UA is a disguise, and a panel with an HWID gate may answer it with a stub.
- The hint under the field says the format depends on User-Agent and suggests
  another client's UA (for example Happ) when the subscription loads but nodes fail.
  It does not block.
- Regenerate HWID = a new device for the panel; the old one may occupy a limit
  slot. There is no warning.
- The live response view in the subscription's Source tab uses the same
  identity as the update.
- If device values are unavailable, the corresponding headers are not sent.

## Boundaries

- The HWID is sent only as a header; it is put neither into the UA nor into the query.
- The OS device identifier is not used — the HWID is random.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [114](../../../tasks/114-subscription-user-agent-rebrand.md) | In progress | UA `LxBox-android/<ver>`, without `singbox` — the panel returns a URI list |
| 2 | [118F](../../../tasks/118F-subscription-fetch-identity/spec.md) | Released v2.0.6 | Global custom UA and opt-in HWID with device-meta, all overridable |
| 3 | [289](../../../tasks/289-per-subscription-fetch-identity.md) | — | Default / Custom identity on the subscription, snapshot from the global values |
| 4 | [346](../../../tasks/346-subs-full-crud-debug-api.md) | — | The subscription identity is also configurable via the Debug API |
| 5 | [610](../../../tasks/610-user-agent-presets.md) | — | Popular-client presets in the Custom User-Agent field, new hint under the field |
