[English](durable-writes.md) · [Русский](durable-writes.ru.md)

# Durable settings writes

| Field | Value |
|-------|-------|
| Feature | [017-BACKUP_AND_STORAGE](../FEATURE.md) |
| Promises | P21–P24 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Guarantees that a process kill, backgrounding or a settings-set switch
leaves no half-written file and loses no edit: the settings document is
written whole and atomically, a corrupted one is recovered from the previous
copy, editor edits are visible at once and land on disk in one write, a
write "from the past" does not go through.

## Parameters

| What | Value |
|------|-------|
| Immediate write | toggles and single actions — to disk at once |
| Deferred write | editors (Routing, DNS, VPN Settings, Tunnel apps, etc.): an edit — to memory at once; to disk — on leaving the screen or backgrounding |
| Previous copy | made before every write, only from a valid main file |

There are no user knobs.

## Inputs / Outputs

**Inputs:** screen edits; backup and transfer import; Debug API;
backgrounding and leaving a screen; a process kill at any moment.

**Outputs:** a whole document on disk; on corruption — the recovered state
or default settings with a corruption flag in the log.

## Rules and invariants

- **Atomicity:** copy of the valid main → write to a temporary file with a
  flush to the medium → atomic replace. A kill at any step leaves the
  previous or the new whole document (P21). Every write has its own
  temporary file; parallel writes do not interfere.
- **Reading at start:** no main — a new installation (the document carries
  the form marker at once); main reads — it is used; main corrupted
  (including empty) — recovery from the previous copy, a warning in the log;
  no copy — default settings, a corruption flag, an error in the log once.
- **A corrupted file is not overwritten** until the user's first edit: it
  stays for manual diagnostics; the first write overwrites it and clears the
  flag (P22). Orphaned temporary files are removed on read.
- **Deferred write (§107):** every editor edit goes into the in-memory
  settings at once — the rebuild on returning to the home screen, the Start
  gate and the start see it before the disk write. To disk — in one write on
  leaving the screen or backgrounding; with nothing unsaved — no write
  (P23).
- **The "config is stale" flag** is raised only by config-significant
  writes; a settings write without a config edit aligns the config time so
  that there is no false "stale" after a kill —
  [003-CONFIG_BUILD · P11](../../003-CONFIG_BUILD/FEATURE.md#promises).
- **A write "from the past" (§515):** a subscription controller that
  outlived a settings-set switch does not write into the new set — neither a
  deferred fetch nor a node toggle; a disposed controller does not write; a
  halted auto-update pass is interrupted between subscriptions and starts no
  new ones (P24).
- The transfer import writes all sections to memory and flushes to disk
  once.

## Boundaries

- Writers outside the subscriptions screen (backup import, Debug API) are
  intentionally not limited by the generation barrier —
  [018-WORKSPACES](../../018-WORKSPACES/FEATURE.md).
- Atomic replace is a property of the file system of the app's internal
  storage (depends on OS capabilities).
- There is no transaction log between the document and other data sets:
  each file is atomic on its own.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [072](../../../tasks/072-settings-storage-atomic-write.md) | Released v1.9.0 | Atomic write, previous copy, recovery of a corrupted file |
| 2 | [076F](../../../tasks/076F-settings-and-config-lifecycle/spec.md) | Released v1.9.0 | Deferred write on leaving a screen |
| 3 | [107](../../../tasks/107-lazy-persist-stale-read-race.md) | DONE (v2.0.2) | An edit goes to memory at once: the rebuild does not read unsaved state |
| 4 | [113](../../../tasks/113-false-config-changed-banner.md) | In progress | Aligning the config time on settings writes |
| 5 | [141](../../../tasks/141-deep-code-audit-hardening.md) | In progress | A unique temporary file per write, orphan cleanup |
| 6 | [338](../../../tasks/338-auto-reload-on-settings-change.md) | DEVICE-VERIFIED | The write on leaving does not re-raise the "stale" flag |
| 7 | [515](../../../tasks/515-workspace-switch-stale-controller-persist.md) | Released v2.25.2 | Generation barrier: the previous set's controller does not write into the new one |
