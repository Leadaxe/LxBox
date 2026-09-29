[English](running-config.md) · [Русский](running-config.ru.md)

# Running config and freshness verdict — is the core running the saved config

The verdict feeds the "restart needed" banner owned by 003-CONFIG_BUILD.

| Field | Value |
|-------|-------|
| Feature | [012-LIVE_STATE](../FEATURE.md) |
| Promises | P20, P21 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Keeps a snapshot of the config the running core was actually built from, and
answers the question "does the saved config differ from the running one".
While the tunnel is up, everything shown about nodes (list, type, path) is
taken from the running config, not from the file that may have already moved
ahead.

## Parameters

No settings of its own.

## Inputs / Outputs

**Inputs:** `GetRunningConfig` (the canonical JSON of the running core, with
the start overrides applied); the saved config; the core's `FormatConfig`; the
tunnel start overrides (`auto_redirect`, our own package appended to
`include_package`).

**Outputs:** a running-config snapshot per session; the node model for the
screens; the verdict `fresh` / `stale` / `unknown`.

## Rules and invariants

- **When it is taken.** On the tunnel transition to "connected" and after a
  core reload; not as a side effect of groups arriving.
- **Session ownership.** Every reset of the snapshot opens a new session; a
  reply that came from the previous one is dropped. At most one capture runs at
  a time.
- **Retries.** Up to 12 attempts in steps of 0.4 s (the core is not started
  yet — no reply). After a reload the first request is after 1.2 s, and a reply
  equal to the previous snapshot counts as "the core is still the old one"; if
  the core consistently returns the same across all attempts, it is an
  identical config and it is accepted. Attempts exhausted without a reply — no
  snapshot until the end of the session.
- **Which model is shown.** Tunnel up and a snapshot exists — the running one;
  tunnel down or no snapshot (old core, race) — the saved one.
- **Verdict.** The saved config is brought to the core's canonical form
  (`FormatConfig`) after applying the same overrides the core applies: only the
  first tun input; `auto_redirect` is assigned (and `false` overwrites the
  profile); our own package is appended to the end of `include_package`
  without sorting and deduplication, only in the "selected only" mode; no tun
  input — nothing. Then the strings are compared: equal — `fresh`, not —
  `stale`.
- No snapshot, no canonical form, overrides could not be determined —
  `unknown`. `unknown` does not clear the banner: an extra banner is better
  than a missed change.
- The verdict is called only to clear a false banner with the tunnel up; it
  cannot raise it.

## Boundaries

- When to show the "restart needed" banner and what raises it —
  003-CONFIG_BUILD.
- Viewing the resulting config — 019-CONFIG_EDITOR.
- On a core without `GetRunningConfig` there is no snapshot, everything works
  from the saved one.

## Revisions

| # | Revision | Status | Essence |
|---|----------|--------|---------|
| 1 | [311](../../../tasks/311-running-config-from-kernel.md) | implemented, since core `lx.17-rc.1` | Running-config snapshot as the source of truth about nodes |
| 2 | [324](../../../tasks/324-saved-vs-running-canonical-diff.md) | ✅ Implemented (DEVICE-PENDING) | Verdict by the core's canonical form instead of comparing files |
| 3 | [384](../../../tasks/384-fakeip-resolver-gate-and-lost-running-snapshot.md) | Done, DEVICE-VERIFIED | An identical config after a reload is accepted |
