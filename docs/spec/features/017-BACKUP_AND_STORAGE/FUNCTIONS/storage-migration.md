[English](storage-migration.md) · [Русский](storage-migration.ru.md)

# Storage migration — a one-time upgrade of settings from the 2.23.2 form

On the first launch of v2.24.0 or later, LxBox converts old-form settings to
storage contract 1.0 once, keeps the original as a copy and builds the same
config as before.

| Field | Value |
|-------|-------|
| Feature | [017-BACKUP_AND_STORAGE](../FEATURE.md) |
| Promises | P18–P20 |
| State | ✅ written from code, 2026-09-28 |

## What it does

On the first launch of a version with storage contract 1.0 (v2.24.0+), a
settings document in the old 2.23.2 form is converted once into the 1.0
form — so that the built config before and after is the same. The user does
nothing and notices nothing; the original is kept as a copy. The same
migration applies to all old-form inputs: the document on disk, a settings
set slot, the `storage` block of a full backup and the Debug API import
body.

## Parameters

| What | Value |
|------|-------|
| Form marker | `storage_version`; absent — the 2.23.2 form; not a number — the 2.23.2 form with a warning |
| Known form | `1`; a document with a higher version is read as current and not rewritten |
| Original copy | document bytes before migration, written once and kept for the whole lifetime of the installation |

There are no user knobs.

## Inputs / Outputs

**Inputs:** an old-form document (subscriptions, servers, folders, chains,
rules, DNS under the old keys); subscription bodies from the cache — to
translate links to their nodes; template presets — for preset DNS server
references.

**Outputs:** a 1.0-form document; the original copy; one log line with the
result and counters; losses — as a warning naming the records.

## Rules and invariants

- **Order:** read → migrate in memory → copy of the original (if not there
  yet) → atomic write of the new document. There is no "migrated" mark: the
  marker is the document form itself. A kill between steps — the old file
  stays, the next start migrates again (P19).
- **Idempotent:** a current-form document is returned as is, without a
  write; the result fed back in does not change (P18).
- **Keys:** the old keys of sources, chains, rules and DNS move to
  `sources[]`, `rules[]`, `dns{}`; chains go to the tail of `sources[]` in
  the old order; the legacy Directions pair `channels` is renamed to
  `directions`; keys with no readers are removed and listed in the log.
- **Node links** (source and folder member detour, chain positions) are
  translated by the state before migration: a folder or subscription node —
  a pair `{container id, raw tag}`, including a disabled one; a single
  server, a Direction, `direct-out`, a chain — a root `{tag}`; not found or
  ambiguous — a root with a warning, the build resolves the link
  fail-closed; self-links that 2.23.2 did not emit are removed (P20).
- **Folder groups** of the old text form become auto-select nodes;
  unresolvable members are removed with a warning.
- A JSON-rule array is split into records per object; unreadable text is
  kept verbatim with a warning.
- A version together with legacy keys — the legacy keys are dropped with a
  warning.
- A corrupted main file and a previous copy of the old form: recovery
  migrates and writes at once.
- Parallel first reads wait for one migration; the "config is stale" flag
  is not raised by the migration.
- A failure of the migration itself — an error in the log, the document as
  it was, no write: better the old form in memory than wiped settings.

## Boundaries

- Rolling back to 2.23.2 on top is not supported by the OS (an older
  version cannot be installed); the original is available only to test
  benches through Debug API `from=v0_bak`.
- Other one-time migrations of past years are removed (§159, §229): garbage
  of old keys is harmless and goes away on the first backup import.
- Removing this migration and the original copy is tech debt (§440).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [159](../../../tasks/159-backup-allowlist-strict-filter.md) | Done | One-time key cleanups removed; the only cleanup is the allowlist at the input |
| 2 | [229](../../../tasks/229-remove-preset-id-migration.md) | Done | The one-time `preset_id` migration removed |
| 3 | [393F](../../../tasks/393F-directions/spec.md) | Released v2.21.0 | `channels` → `directions` |
| 4 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | Migration of the 2.23.2 form → 1.0, original copy, repeat after failure, node links |
| 5 | [440](../../../tasks/440-remove-storage-v0-migration.md) | Backlog | Remove the migration and the original copy |
| 6 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Vars of template DNS servers and presets move into the record |
| 7 | [447](../../../tasks/447-v2-24-0-avd-findings.md) | Fixed | Findings of the v2.24.0 check on the emulator |
