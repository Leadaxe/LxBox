[English](subscription-meta.md) · [Русский](subscription-meta.ru.md)

# Subscription metadata — traffic, expiry, name and support links from the provider

The app reads traffic usage, expiry, name, update interval, description and support links from the provider's
response headers or body comments and shows them in the subscription header.

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
| `announce` | the subscription description (e.g. a legend for the emoji in node names); a `base64:…` value is decoded as UTF-8, otherwise taken as is |

If there are no headers, the same keys are taken from comment lines at the beginning of the body
(`#`, `//`, `;` + `key: value`); reading stops at the first
non-comment line, unrelated keys are ignored. HTTP headers
take priority.

**Output (subscription header):** `N nodes` (`N +D⚙ nodes` with detour nodes),
"M off", a "used / total" bar with a non-zero limit, "Expires: N days left /
N hours left / Expired", the description text, the "Support" chip (Telegram icon for `t.me` / `telegram.me` / `tg://` links, §657) and "Web
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
- `announce`: `\r\n` → `\n`, whitespace trimmed at the edges of the whole text,
  more than two line breaks in a row collapse to two, at most 2000 characters
  (graphemes) are kept. An empty result or broken base64 means no field (broken
  base64 — a warning in AppLog); the subscription updates as usual.
- The description is shown under the "Expires" line, above the "Support" / "Web
  page" chips, in the style of the neighbouring header lines, as is: multi-line,
  no translation, no markup, links are not clickable. Collapsed — at most 4 lines
  with an ellipsis; a longer text expands on tap and collapses on a second tap, a
  short one does not react. No field — no block.
- The Source tab, Response headers block: a `base64:…` value that decodes to
  UTF-8 (the same decoder as for `profile-title`) is shown decoded, with a small
  dashed-underlined `base64` label under the header name. Tapping the label
  toggles that row between the decoded and the original value; the state is per
  row and is not kept between screen openings. A value without the prefix, with
  broken base64 or non-UTF-8 bytes is shown as is, without the label. Copying the
  block copies the original values.

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
| 6 | [648](../../../tasks/648-subscription-announce.md) | Implemented, device-pending | Subscription description from the `announce` header |
| 7 | [650](../../../tasks/650-source-headers-base64-toggle.md) | Implemented, device-pending | Source tab: `base64:` headers decoded, with a toggle |
