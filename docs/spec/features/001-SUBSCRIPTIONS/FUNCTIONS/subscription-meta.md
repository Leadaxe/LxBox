[English](subscription-meta.md) · [Русский](subscription-meta.ru.md)

# Subscription metadata

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | P4, P13 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Reads service information about the subscription from the provider's response and shows it
to the user: how much traffic has been used out of the limit, when it expires,
what the subscription is called, where to contact support, how often
the provider advises updating.

## Parameters

No settings of its own.

## Inputs / Outputs

**Input — response headers** (name case does not matter):

| Header | What it gives |
|---|---|
| `subscription-userinfo` | `upload=…; download=…; total=…; expire=…` — bytes and unix seconds |
| `profile-title` | the subscription name; a `base64:…` value is decoded |
| `Content-Disposition` | fallback name: `filename*=UTF-8''…` → `filename="…"` → `filename=…`; the extensions `.txt .yaml .yml .json .conf` are cut |
| `profile-update-interval` | update interval in hours |
| `support-url` | support link |
| `profile-web-page-url` | the provider's page |

If there are no headers, the same keys are taken from comment lines at the beginning of the body
(`#`, `//`, `;` + `key: value`); reading stops at the first
non-comment line, unrelated keys are ignored. HTTP headers
take priority.

**Output (subscription header):** `N nodes` (`N +D⚙ nodes` with detour nodes),
"M off", a "used / total" bar with a non-zero limit, "Expires: N days left /
N hours left / Expired", the "Support" chip (Telegram icon for `t.me`) and "Web
page", the "N entries dropped" line.

## Rules and invariants

- `upload`/`download`/`total`: unparsable → 0. `expire`: unparsable or
  absent → "no expiry"; `expire=0` is shown as no expiry.
- The name from `profile-title` (or `Content-Disposition`) is set only on the
  first successful update of a subscription without a name; a rename by the
  user is not overwritten. Without a name the URL host is shown.
- Metadata is replaced entirely on every successful response; a failure and an empty
  response do not touch it.
- `profile-update-interval` changes the subscription interval if its interval is not
  `-1` ([auto-update.md](auto-update.md)).
- Used = upload + download; the bar is capped at 100 %.
- There are no threshold warnings about expiry or traffic — display only.

## Boundaries

- Metadata does not affect the core config or the subscription "composition".
- A file subscription takes metadata from comments at the beginning of the file at
  import; after that it does not change.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [006F](../../../tasks/006F-servers-ui/spec.md) | Implemented | Subscription header: name, support links, Telegram icon |
| 2 | [010F](../../../tasks/010F-quick-start-and-offline/spec.md) | Implemented | Name, update time and node count in the entry |
| 3 | [027F](../../../tasks/027F-subscription-auto-update/spec.md) | Implemented | Interval from `profile-update-interval` |
| 4 | [219](../../../tasks/219-deep-audit-2026-07.md) | Done / findings in progress | Unparsable `expire` → "no expiry", not 1970 |
| 5 | [129F](../../../tasks/129F-file-subscription/spec.md) | Spec (implemented) | `# key: value` at the beginning of the file → file subscription metadata |
