[English](config-validation.md) · [Русский](config-validation.ru.md)

# Final config check — stopping configs the core would refuse to start

Before saving, the built config is checked for dangling references, empty groups and detour rings; a
config that fails is neither written to disk nor passed to the core.

| Field | Value |
|------|----------|
| Feature | [003-CONFIG_BUILD](../FEATURE.md) |
| Promises | P9 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The last line before saving: checks the built JSON for errors
with which the core is guaranteed not to start, and does not let such a config
reach the disk and the core. The healing stages before it have already removed everything
that can be removed by degradation; only what the user must
fix themselves reaches this point.

## Parameters

No knobs of its own. Checks (all fatal):

| Check | What it catches |
|---|---|
| Rule reference | `route.rules[].outbound` to a tag that is not among `outbounds`/`endpoints` |
| `route.final` | A target that is not in the config |
| Detour reference | A node's or endpoint's `detour` to a non-existent tag |
| Detour ring | A cycle in the "node → detour" graph taking into account the "group → each member" edges (selector/urltest) |
| Empty urltest | A `urltest` group without members |
| Selector `default` | Not a string or not from the `outbounds` members |
| DNS resolvers | `dns.final`, `route.default_domain_resolver` to a missing server; to a `fakeip`/`hosts` server |
| DNS groups | A group empty after filtering, a `fakeip`/`hosts` member, a ring of groups (one per ring) |

A rule with an `action` without a string `outbound` (for example `reject`) is not
counted as an error; an empty or absent resolver — neither.

## Inputs / Outputs

**Inputs:** the built JSON (after all healing and the graph sanitizer).
**Outputs:** a list of problems with severity. On any fatal the build
returns a rejection instead of JSON; the reasons — in the log, one line each, and in the
last build error.

## Rules and invariants

- A fatal config is not saved: the previous config stays on disk and in the core,
  the "config is stale" flag stays set, the blue banner is shown.
- What the user sees:
  - a detour ring — a sheet with the list of culprit nodes (no more than three
    are shown: fix the first ones and rebuild); a tap on a culprit opens
    its owner's screen; VPN start and reconnect are cancelled;
  - other fatals — the snackbar "Config rebuild failed: <reasons>" on a build triggered by a
    user action; on a silent build (background, launch) there is no snackbar;
  - Start with other fatals proceeds to start on the previously saved
    config (the snackbar is shown, the banner stays).
- The ring culprits are the minimal set of edges whose removal breaks
  the ring; structural "group → member" edges are never culprits.
- The check works only on a built config: JSON written by hand
  via the edit screen or the Debug API does not go through it.
- A dangling DNS group member is not caught here: the build filters it out with a
  warning.

## Boundaries

- Healing what can be degraded — [build pipeline](build-pipeline.md).
- DNS checks on the merits — [005-DNS](../../005-DNS/FEATURE.md); a core
  rejection at start with the node name and auto-disabling of the node —
  [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.md).
- The node body schema (unknown keys, types) is checked by the registry gate before
  this stage — [021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [026F](../../../tasks/026F-parser-v2/spec.md) | Implemented | Checking references, empty groups and the selector `default` |
| 2 | [141](../../../tasks/141-deep-code-audit-hardening.md) | In progress | Fatal blocks saving; detour rings; non-string `default` |
| 3 | [219](../../../tasks/219-deep-audit-2026-07.md) | Done (audit) | The `route.final` check |
| 4 | [254](../../../tasks/254-detour-cycle-fatal-detector.md) | Agreed by the owner | Rings taking groups into account, minimal set of culprits, the sheet |
| 5 | [312F](../../../tasks/312F-dns-group/spec.md) | Implemented | Empty groups, invalid members, rings of groups |
| 6 | [384](../../../tasks/384-fakeip-resolver-gate-and-lost-running-snapshot.md) | Done, DEVICE-VERIFIED | `fakeip`/`hosts` under resolvers — fatal |
| 7 | [393F](../../../tasks/393F-directions/spec.md) | — | The check is the last line after the graph sanitizer |
| 8 | [419](../../../tasks/419-dangling-dns-resolver-heal-in-build.md) | Done | The reason for a rebuild fatal is visible from the banner's snackbar |
