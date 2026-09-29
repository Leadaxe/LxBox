[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Backup and storage — full settings backup, desktop transfer and durable storage

LxBox backs up its VPN settings — subscriptions, servers, routing rules, DNS,
split tunneling — to a JSON file and restores them by merge or replace. A
separate LX Backup 1.0 file moves the shared part of the settings to and from
the desktop launcher. Underneath, settings live in one document with atomic
writes, recovery of a corrupted file and a one-time migration from the 2.23.2
storage form.

| Field | Value |
|-------|-------|
| Feature | 017-BACKUP_AND_STORAGE |
| Type | Product feature |
| Absorbed | `§040F` `§439F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

Everything the user has configured must survive a process kill, an app
update and a phone change. The feature provides three things:

- **Full backup** of the same installation: a JSON snapshot of settings by
  category and restore by merge or replace — including one tap from the
  empty home screen.
- **Transfer to desktop** — exchanging the shared part of settings with the
  desktop launcher in the LX Backup format (contract 1.0): whatever the
  other side has no place for is dropped and named.
- **Reliable storage**: one record form (the same as in LX Backup 1.0),
  atomic writes, recovery of a corrupted file, a one-time migration of the
  old form, deferred writing of edits, protection against writes "from the
  past".

Principles: **the file is a serialization of state** (importing your own
export returns the same state, no "carry-along" fields); **no silent
losses** (whatever is not applied is named by a code, a counter, a log
entry); **the input is default-deny**; **a failure does not wipe settings**
(the previous or the new whole state).

## Promises

- **P1. A secret does not leave by accident.** "Debug API config" on export
  is off by default; without it Debug API keys are not written to the file.
  **Witness:** unit tests "without Debug API config the Debug API keys are
  stripped from vars", "only Debug API config — only Debug API keys".
  **Mutation:** Debug keys travel with "App settings".
- **P2. Export writes out everything import accepts.** **Witness:** unit
  tests "allowlist ⊆ export (all categories)", "Directions and their
  migration marker are exported in Routing". **Mutation:** a key added to
  the allowlist but not to a category.
- **P3. Full backup round-trip is lossless.** Export of all categories →
  reset → import = the original storage. **Witness:** unit test "round-trip:
  export → reset → import → bytewise equal". **Mutation:** a key outside
  the categories.
- **P4. A foreign file is rejected before applying.** Not JSON, no
  `app: lxbox` / `kind: backup` markers, no `storage` block (format before
  v1.7.3) — "Invalid backup" with a reason, nothing written. **Witness:**
  unit tests "not JSON — rejected", "no app/kind markers — rejected", "old
  format without storage — rejected". **Mutation:** partial parsing.
- **P5. The input is default-deny.** Unknown top-level keys and vars are
  dropped in both modes and counted ("N unknown keys skipped").
  **Witness:** unit tests "foreign key dropped", "foreign var dropped, known
  ones kept", "merge filters too". **Mutation:** filtering only in replace
  mode.
- **P6. Merge deletes nothing.** Sources are appended by `id`, vars by key,
  whatever is absent in the file stays. **Witness:** unit tests "merge keeps
  untouched keys", "sources are appended by id". **Mutation:** merging
  sources by replacing the list.
- **P7. Replace replaces the whole settings document.** "Replace all" writes
  only the selected categories of the file; unselected categories of the
  current settings are not kept. **Witness:** unit test "replace only
  Routing: rules and DNS; neither sources nor chains". **Mutation:** replace
  per category.
- **P8. Device properties survive replace.** If the file is silent about the
  Debug API and about the "already asked" flags of startup prompts, the
  current values stay; a key from the file wins; `wizard_*` flags are never
  accepted from the file. **Witness:** unit tests "replace keeps the Debug
  API absent in the snapshot", "keys from the snapshot win", "replace keeps
  startup prompt flags". **Mutation:** replacing vars wholesale.
- **P9. An old backup restores.** A 2.23.2-form block migrates before the
  category filter; the preview counts the migrated block; the core config
  = golden. **Witness:** unit tests "block migrates: preview counts by
  record kind", "2.23.2 backup → replace all categories → config = golden".
  **Mutation:** filtering by legacy keys.
- **P10. LX Backup: 1.0 is written, 1.0 and 0.x are read, newer — rejected
  whole.** **Witness:** unit tests "write 2, read 2 and legacy 1", "greater
  than readable and outside {1, 2} — rejected". **Mutation:** partial
  parsing of a new version.
- **P11. Transfer is a serialization of state.** Export → import into empty
  = original; repeated import adds nothing. **Witness:** unit tests
  "round-trip: export → import into empty = original", "two same-named
  folders in the file — two folders; repeated import does not grow".
  **Mutation:** deduplicating nodes by name, not by body.
- **P12. Transfer losses are named.** An unknown field, a field of the wrong
  type, a key outside the slice table, an LxBox setting with no place in 1.0
  — a warning code on import and export. **Witness:** unit tests "unknown
  record field is named, not swallowed", "record key outside the table is
  cut with a name", "loss with no home in 1.0 is named". **Mutation:**
  silently cutting a field.
- **P13. Transfer does not overwrite your own.** A taken Direction or chain
  tag — the incoming one is not applied and is named; "disabled" marks are
  merged. **Witness:** unit tests "taken tag is not applied and is named",
  "marks from the file are added". A live WARP registration is not
  overwritten — `no witness`. **Mutation:** "last writer wins".
- **P14. A rule does not go nowhere.** A rule with a target unknown to the
  receiver arrives disabled; `route.final` to nowhere is not applied; an
  incoming Direction makes the rule working. **Witness:** unit tests
  "nonexistent outbound disables the rule", "incoming target makes the rule
  working". **Mutation:** checking targets before merging sources.
- **P15. Only portable vars are transferred** — the list matches the
  contract registry, others — `backup_var_skipped`. **Witness:** unit tests
  "matches the registry", "non-portable var is skipped with a warning".
  **Mutation:** transferring machine paths and interfaces.
- **P16. The core verdict is not transferred**, node disabling is.
  **Witness:** unit tests "safeguard: after import the node is disabled, no
  verdict", "file with a verdict: the entry is removed, the node stays
  disabled". **Mutation:** the verdict travels in the file.
- **P17. A node link follows the node.** Address `{folder_id?, tag}`;
  rename and move rewrite all links, deletion clears them and names the
  affected ones, changing a folder prefix does not touch links.
  **Witness:** unit tests "renaming a folder member rewrites all carriers",
  "moving between folders rewrites folder_id", "deletion clears links and
  names the affected", "changing tag_policy does not touch links".
  **Mutation:** matching by a similar tag.
- **P18. The storage migration is one-time and harmless.** Idempotent; the
  original is copied once; the config before and after matches; a document
  newer than the known form is read and not rewritten. **Witness:** unit
  tests "idempotent", "the original copy is written once", "config matches
  golden", "a version above the known one is not rewritten". **Mutation:**
  migration on every start.
- **P19. An interrupted migration is repeated.** **Witness:** unit tests
  "failure between writing the copy and writing the document: old file +
  copy → migration again", "corrupted main file, previous copy of the old
  form: recovery migrates and writes". **Mutation:** a "migrated" mark
  before the write.
- **P20. Chain positions and detour point to a node.** After migration a
  link to a subscription or folder node is a pair `{container id, raw
  tag}`, including links to disabled targets; not found — a root `{tag}`
  with a warning. **Witness:** unit tests "subscription node from the body
  cache — pair {subscription id, raw tag}", "chain positions: disabled
  server — root, node of a disabled folder — pair", "ambiguous string — root
  with a warning". **Mutation:** translating links without subscription
  bodies.
- **P21. The write is atomic.** A kill at any moment leaves the previous or
  the new whole file; a corrupted main file is recovered from the previous
  copy; orphaned temporary files are removed; parallel writes do not
  interfere. **Witness:** unit tests "corrupted main, valid copy →
  recovery", "copy only from a valid main", "orphaned temporary file is
  removed", "concurrent writes leave no orphans". **Mutation:** writing
  over the main file.
- **P22. A corrupted file without a copy is not overwritten** until the
  first edit; settings are at defaults. **Witness:** unit tests "corrupted
  main, no copy → empty, corruption flag", "after reset and an edit — main
  rewritten, flag cleared". **Mutation:** immediately writing an empty
  document.
- **P23. An edit is visible at once, on disk — on leaving.** Editor edits
  are visible to the rebuild and to Start before the write; to disk — in one
  write on leaving the screen or backgrounding. **Witness:** unit test
  "staged rules are visible to a reader before the disk write"; widget tests
  "write on leaving the screen when there are unsaved changes", "write on
  backgrounding". **Mutation:** writing to memory only on leaving.
- **P24. A write "from the past" does not go through.** A controller that
  outlived a settings-set switch does not write into the new set; a halted
  update pass does not continue. **Witness:** unit tests "a deferred fetch
  of the old controller does not touch the new slot", "halt interrupts the
  pass between subscriptions". **Mutation:** writing without a generation
  check.
- **P25. Transfer is written against fresh state:** the LX import plan is
  recomputed at confirmation time, not taken from the preview.
  `no witness`.

## Controlled parameters

| Setting | Where | Values | Default |
|---------|-------|--------|---------|
| Server lists / Routing / App settings / VPN system toggles | Backup & restore → Export | on/off | on |
| Debug API config | same place, with a warning | on/off | **off** |
| Import categories | import preview | those present in the file | all present in the file |
| Mode | import preview | Merge with existing / Replace all | Merge |
| Save method | export sheet | to file / to Downloads / share | user's choice |

Fixed: full backup name `lxbox-backup-v<version>-<YYYYMMDD-HHMM>.json`
(locale-independent); transfer file `lx-backup.json`, `lx_backup: 2`
(contract 1.0), `1` and `2` are read; form marker `storage_version: 1`.
The feature emits no core config keys
([003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md)).

## Inputs / Outputs

**Inputs:** categories and mode; a JSON file; Debug API
`GET /backup/export`, `POST /backup/import`; the settings document from
disk; screen edits.

**Outputs:** full backup `{app: "lxbox", kind: "backup", created_at,
source_app_version, storage{…}, vpn_settings{…}}`; LX Backup 1.0
(`lx_backup`, `exported_by`, `exported_at`, `sources`, `directions`, `rules`,
`dns`, `vars`, `route`, `warp`); applied settings; summaries; `backup_*` codes.

## Data flow

```
Full backup:  settings → categories → envelope + VPN block → file
Restore: file → markers → migration of an old block → preview (categories,
   counters, mode) → merge: sources by id + upsert | replace: whole document
   (+ device Debug API and prompt flags) → default-deny allowlist → atomic
   write → Directions seeding → VPN block → summary + "Restart now"
Transfer: settings → record slice + thin layer → LX Backup 1.0;
   file → 1.0 | 0.x decoder → plan against the fresh receiver → preview → write → summary
Storage: edit → memory (at once) → one atomic write (leaving/backgrounding)
Start: document → old form? → migration → copy of the original → write
```

## Rules and guarantees

- Full backup and transfer are different formats; each input rejects the
  other's.
- Full backup categories (except the VPN block) slice one settings document;
  the form marker travels with any set. Chains go with "Server lists".
- Preview before writing; replace has a separate "Replace all data?"
  confirmation. Restore from the empty home screen: no preview, replace, all
  categories.
- One record form for disk, full backup, LX Backup and Debug API; one
  migration of the old form for all inputs.

## Boundaries

- Settings sets — [018-WORKSPACES](../018-WORKSPACES/FEATURE.md); here — which
  data sets they carry and write protection from stale controllers.
- The meaning of the settings themselves is in their features; the rules
  file — [004-ROUTING](../004-ROUTING/FUNCTIONS/rule-transfer.md).
- Neither in the backup nor in the transfer: core cache, logs, crash
  reports, rule-set cache, subscription bodies, the built config, Tailscale
  state, slots, theme ([020-APP_SHELL](../020-APP_SHELL/FEATURE.md)).
- No encryption, cloud auto-backup, or choice of individual subscriptions.
- Depends on OS capabilities: picking and saving a file (on TV — a hint),
  "Share", Downloads, backgrounding; an older version cannot be installed
  over.

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Full backup export | Saves this installation's settings to a JSON snapshot: categories, snapshot format, save methods. | P1–P3 | [full-backup-export.md](FUNCTIONS/full-backup-export.md) |
| Full backup restore | Brings settings back from a backup file: validation, preview, merge or replace, allowlist, what survives. | P4–P9 | [full-backup-restore.md](FUNCTIONS/full-backup-restore.md) |
| Transfer to desktop | Exchanges the shared part of settings with the desktop launcher in LX Backup 1.0: write, read, merge, named losses. | P10–P16, P25 | [desktop-transfer.md](FUNCTIONS/desktop-transfer.md) |
| Storage contract | Defines what the app stores and in which form: data sets, 1.0 records, node links. | P17 | [storage-contract.md](FUNCTIONS/storage-contract.md) |
| Storage migration | Converts settings in the 2.23.2 form to storage contract 1.0 once, with the same built config. | P18–P20 | [storage-migration.md](FUNCTIONS/storage-migration.md) |
| Durable writes | Keeps settings intact through kills and switches: atomic writes, recovery, deferred writes, races. | P21–P24 | [durable-writes.md](FUNCTIONS/durable-writes.md) |

## Related features

- [001-SUBSCRIPTIONS](../001-SUBSCRIPTIONS/FEATURE.md) — subscription records in
  storage and in the backup; subscription bodies are not copied but re-fetched.
- [003-CONFIG_BUILD · P11](../003-CONFIG_BUILD/FEATURE.md#promises) — the
  "config is stale" flag and aligning the config time on settings writes; the
  config is built from the restored settings.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — rules and Directions in the backup;
  a separate rules file.
- [005-DNS](../005-DNS/FEATURE.md) — DNS records in the backup and their merge
  on transfer.
- [006-DETOUR_AND_BALANCE](../006-DETOUR_AND_BALANCE/FEATURE.md) — detour links
  and chain positions are stored as a node address; their renaming and deletion
  is handled by this feature's link registry.
- [009-NODE_HEALTH](../009-NODE_HEALTH/FEATURE.md) — ping settings in the
  backup; the core rejection verdict is not transferred.
- [015-WARP](../015-WARP/FEATURE.md) — registrations travel as `warp[]` records;
  a live registration is not overwritten.
- [018-WORKSPACES](../018-WORKSPACES/FEATURE.md) — the backup sees only the
  scene; slots in the old form are loaded by the storage migration; the write
  barrier against stale controllers.
- [020-APP_SHELL](../020-APP_SHELL/FEATURE.md) — language and preferences are in
  the backup, the theme is not; startup prompt flags survive replace.
- [030-TAILSCALE](../030-TAILSCALE/FEATURE.md) — Tailscale node state (device
  identities) is not in the backup and lives per slot.

## Maintenance notes

- A new settings key goes both into the import allowlist and into an export
  category: the asymmetry already lost Directions (§221), auto-ping (§349),
  MASQUE (§219). The guard is P2. The reverse asymmetry is not caught by a
  test: `wizard_*` flags travel in the backup and give "unknown keys
  skipped" on your own backup.
- The replace caption "Wipes existing data in selected categories" does not
  match P7: unselected categories go too.
- After a restore from "Backup & restore" the screens keep the old snapshot
  until restart — hence "Restart now"; from the home screen the sources are
  re-read automatically.
- A new data set must be classified: into the document (and into a
  category) or explicitly a "device property".
- The 2.23.2 form migration is tech debt to remove (§440, backlog); while it
  lives, the original copy of the file is kept for the whole lifetime of the
  installation.
