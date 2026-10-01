[English](attribution.md) · [Русский](attribution.ru.md)

# Attribution — which app, rule and route an event belongs to

The owner, the rule and the packet's path are named by the core; the client
shows a confidence level and does not hide events without an owner.

| Field | Value |
|-------|-------|
| Feature | [028-TRAFFIC_PROFILER](../FEATURE.md) |
| Promises | P7, P8, P9 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Every log event answers three questions: whose it is (the app package), how
the router decided (the rule and the group chain) and where the packet
physically went (detour, node, target). All three answers arrive from the
core together with the connection or the DNS query; the client stitches
nothing from the core log and guesses nothing by IP. When there is no owner,
the event stays in the log with a mark.

## Parameters

No settings of its own. Fixed: the unattributed alarm — more than 5 failed
events without an owner within 30 s; the ring of unowned events — 50.

## Inputs / Outputs

**Inputs:** from a connection snapshot — the owner package or the process
path, the rule, the `chain` (node and selectors), the `detour` tail, the
outbound type, the domain and the address; from a DNS event — the owner
package and the server's channel.

**Outputs:** in the event row — the app (icon and name) or "(no owner)", a
red `?` badge on an event without an owner with the tooltip "confidence /
matched via / shown because"; in the details — the "App" section (app,
confidence level, "Matched via", "Shown because") and the "Routing" section
(routing line, rule, chain, detour, outbound and its type — the same rows as
a live connection has); the banner "N unattributed events / 30s — sing-box
could not detect the owner package for some DNS/TCP traffic" and ⚠ in the
tab title.

## Rules and invariants

- **The owner comes from the core.** For a connection — the package,
  otherwise the process path; for a DNS query — the package. The string is
  taken as is: a UID suffix like `(10999)` or a "package, package" list does
  not break attribution.
- **Confidence levels.** `verified` — the core named the owner, no marker;
  `unattributed` — no owner, the `?` badge and "Shown because: system-wide
  DNS failure (no owner package detected)" on a DNS failure. The levels
  `secondary` and `inferred` are dormant: not assigned by the current code,
  the values are kept to read old exports.
- **Unattributed alarm.** Every `unattributed` event enters the unowned ring,
  but only failures count as an alarm: a DNS failure and TCP/UDP without an
  owner. More than 5 of those within 30 s — the banner and ⚠ on the tab; a
  successful DNS without an owner is normal. The ring is trimmed by the
  retention window, the alarm goes out by itself.
- **Routing line.** `process ⇒ [network] rule ⇒ selectors top-down : detour
  → … → selector (choice) → target · duration`. Left of `:` — the decision
  axis, right — the physical path; an empty rule — `final`; without a domain
  — the address; in the stream — a compact form without the process prefix.
  The group chain and the detour are stored separately; the line matches the
  live connection's line 1:1
  ([012-LIVE_STATE](../../012-LIVE_STATE/FUNCTIONS/live-connections.md)).
- The rule is the core's string, not a name from the catalog; the filter by
  rule and outbound — [filters-and-views](filters-and-views.md).
- Events without an owner are visible in the stream and caught by the
  "Unattributed" filter, but do not enter the by-domain and by-IP summaries.

## Boundaries

- The owner is determined by the core; the OS may not name it for part of the
  traffic (short connections, system processes, a WebView under another UID)
  — a loss of precision, not a breakage. Depends on OS capabilities.
- Secondary packages (WebView) and owner inference from a recent DNS address
  no longer exist (§044, §288).
- Attribution does not depend on "Forward sing-box logs": since §180 the owner
  arrives as a structured stream; the old "DNS / router events off" hint is
  removed ([605](../../../tasks/605-service-live-automation-workspaces-bugs.md)).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [048](../../../tasks/048-perapp-trace-attribution-gaps.md) | Done | Inclusive observer with confidence levels, the unattributed banner |
| 2 | [168](../../../tasks/168-profiler-on-commandclient-connections.md) | Implemented, device-verified | TCP/UDP owner from the core's data |
| 3 | [174](../../../tasks/174-restore-connection-chains.md) | — | Group chain from the core |
| 4 | [177](../../../tasks/177-unattributed-banner-dns-fail-only.md) | Implemented (A+B) | Banner only on failures |
| 5 | [180](../../../tasks/180-dns-query-stream.md) | ✅ DEVICE-VERIFIED | DNS owner from the core, log parsing removed |
| 6 | [181](../../../tasks/181-routing-section-three-axes.md) | — | Group chain and detour separately |
| 7 | [183](../../../tasks/183-cleanup-stale-dns-attribution.md) | ✅ Implemented | Guessing heuristics removed |
| 8 | [204](../../../tasks/204-conns-routing-unify-with-profiler.md) | Implemented | Routing line and the Routing section 1:1 with Conns |
| 9 | [251](../../../tasks/251-selector-fold-routing-lines.md) | — | The "selector (choice)" fold |
| 10 | [252](../../../tasks/252-physical-packet-route-line.md) | — | The physical path to the right of `:` |
