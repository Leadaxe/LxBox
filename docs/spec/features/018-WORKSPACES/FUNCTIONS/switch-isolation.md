[English](switch-isolation.md) · [Русский](switch-isolation.ru.md)

# Switch isolation — no leftovers from the previous workspace

After a workspace switch, pending operations of the previous set cannot write
into the new one, and each set keeps its own Tailscale identities.

| Field | Value |
|-------|-------|
| Feature | [018-WORKSPACES](../FEATURE.md) |
| Promises | P8, P12 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Guarantees that after a switch exactly one set lives on the scene: unfinished
operations of the previous set do not write its contents into the new one, and
the Tailscale nodes of each set keep their own identity.

## Parameters

No knobs.

## Inputs / Outputs

**Inputs:** a set switch at a moment when subscription auto-update is running,
a subscription server response is in flight, a list edit is being applied
(node on/off, move, rename) or nodes are being restored from the body cache.

**Outputs:** the previous set's write is discarded, the log shows
`workspaces: persist skipped …` / `workspaces: fetch result dropped …`; the
new set does not raise "config is stale" because of someone else's leftover.

## Rules and invariants

- **Race 515.** The source list is written as a whole; without a barrier, a
  late write of the previous set replaced the new set's contents with it, and
  the next load pinned the substitution in the slot — one subscription spread
  across all sets.
- **Barrier at the source list owner.** An instance that has outlived a set
  switch or is already closed writes nothing and does not raise the "config is
  stale" flag. The current set's instance writes as usual.
- **Early exit after the network.** A subscription response that arrives after
  the switch is discarded before parsing — no nodes, no "updated" status.
- **Auto-update is interrupted before copying.** A running pass exits at the
  nearest check (the pause between subscriptions is interrupted within a
  quarter of a second); an interrupted instance starts no new passes.
- **Writers outside the screen are not limited** — backup import, Debug API
  and the re-read steps write to the scene in the regular way.
- **Tailscale.** Node state directories are not copied into the slot: each
  slot has its own set of "node → directory" entries. "Save as" copies the
  current slot's entries into the new slot, Rename moves them, Delete removes
  only directories not referenced by other slots. An index failure does not
  stop the set operation.

## Boundaries

- Slots already corrupted before the fix are not healed — only from a backup.
- A storage-level barrier (a set epoch at every writer) is not done —
  follow-up to 515.
- Handing Tailscale state directories to nodes during the build —
  [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md); the feature only
  maintains the per-slot entry sets.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [515](../../../tasks/515-workspace-switch-stale-controller-persist.md) | Released in v2.25.2 | Write barrier for the previous set, auto-update interruption before a switch |
| 2 | [445](../../../tasks/445-tailscale-state-dir-lifecycle.md) | Implemented, no device-verify | Each slot has its own set of Tailscale identities |
| 3 | [524](../../../tasks/524-unified-source-entries.md) | Released in v2.25.3 | Unified list of source entries: the barrier moved to the new write path |
