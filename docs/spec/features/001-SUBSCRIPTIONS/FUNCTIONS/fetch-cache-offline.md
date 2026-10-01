[English](fetch-cache-offline.md) · [Русский](fetch-cache-offline.ru.md)

# Request, cache and offline start — keeping the working node list through failures and restarts

A subscription request is retried on errors, a failed or empty response keeps the previous nodes,
and the last good response is cached so the nodes are available after a restart without network.

| Field | Value |
|------|----------|
| Feature | [001-SUBSCRIPTIONS](../FEATURE.md) |
| Promises | P1, P8, P15 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Performs one subscription update and guarantees that **the working node list
is not lost** either on a failed request or on a restart without network. The last
successful response (body and headers) is stored on the device and serves as the node
source at start and as the contents of the Source tab.

## Parameters

No settings of its own. Request constants: 3 attempts, pauses of 1 s and 3 s, attempt
timeout 9 s (worst case ≈ 31 s). A 4xx response is not retried; 5xx, network
errors and timeouts are retried.

## Inputs / Outputs

**Input:** a subscription (URL + identity, see [fetch-identity.md](fetch-identity.md)).

**Output by outcome:**

| Outcome | Nodes | Body cache | Status | Shown in the list |
|---|---|---|---|---|
| ≥ 1 node | new | overwritten | OK, success time | `N nodes` |
| 0 nodes with HTTP 200 | previous | previous | error, failures +1 | `N nodes (update failed: 0 parsed)` or `0 nodes — <hint>` |
| HTTP error / network | previous | previous | error, failures +1 | `N nodes (update failed)` or the error text |
| After a restart | from cache | — | as saved | `N nodes (cached)` |

List row: node count · interval · "N ago" / "never" · "(N fails)".
Subscription Settings tab: OK / Failed (N in a row) / Refreshing… / Never
updated, "Last success · Last attempt · N nodes", "Refresh now" button.

## Rules and invariants

- **Attempt mark before the network:** the "updating" status and the attempt time
  are saved before the request, so restarts do not cause repeated requests
  sooner than 15 min.
- **A 200 response without nodes is a failure**, not a success: the cache and nodes are untouched,
  the log gets a hint of what came instead of a subscription (HTML, challenge…).
- Reasons for rejecting entries of the last parse are shown in the subscription
  summary ("N entries dropped") — both on success and on an empty response.
- The cache is written atomically (temporary file → rename): a killed process will not
  leave a truncated body. A cache write failure does not break the update.
- **Rehydration at start:** subscriptions without nodes are restored from the cache, with the same
  import rules. A user edit made during rehydration
  (reordering, renaming, deleting) is not overwritten. Node marks
  are not cleaned on rehydration. A cache parsed into 0 nodes leaves the
  subscription empty with a log entry.
- A failure and an empty response do not mark the config as changed; a success does only when
  the composition of an enabled subscription changed ([on-update-action.md](on-update-action.md)).
- The Source tab shows the saved headers and body; "Re-fetch live"
  makes a live request with the same identity and does not write to the cache. Important
  headers (`profile-*`, `support-url`, `subscription-userinfo`,
  `content-type`) are shown separately, the rest — under an expander.
- A response arriving after a workspace switch is discarded.

## Boundaries

- The cache is dropped by clearing app data; it is not backed up.
- A file subscription is not requested — its cache is the source
  ([file-subscription.md](file-subscription.md)).
- Body parsing and the "what came" hint — [002-NODE_IMPORT](../../002-NODE_IMPORT/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [010F](../../../tasks/010F-quick-start-and-offline/spec.md) | Implemented | Body cache on disk, nodes are not reset on error |
| 2 | [027F](../../../tasks/027F-subscription-auto-update/spec.md) | Implemented | Statuses never/ok/failed/inProgress, sweep of a stuck status at start |
| 3 | [101](../../../tasks/101-rehydrate-bootstrap-race.md) | DONE | Rehydration by entry reference, empty response = failure, atomic cache |
| 4 | [219](../../../tasks/219-deep-audit-2026-07.md) | Done / findings in progress | Retries, closing the client, tracking the cache write |
| 5 | [331](../../../tasks/331-blue-banner-and-manual-refresh-reaction.md) | ✅ DEVICE-PENDING | Attempt/failure metadata does not raise the change flag |
| 6 | [506](../../../tasks/506-silent-parse-loss-reasons.md) | — | Rejection reasons are collected on the subscription path too |
| 7 | [561](../../../tasks/561-dropped-only-in-source-summary.md) | Done | Rejections live in the subscription summary, restored from cache |
| 8 | [515](../../../tasks/515-workspace-switch-stale-controller-persist.md) | Released v2.25.2 | A response after a workspace switch is not written |
