[English](desktop-transfer.md) · [Русский](desktop-transfer.ru.md)

# Transfer to desktop (LX Backup) — sharing settings with the desktop launcher

LxBox exchanges subscriptions, servers, rules, DNS and WARP registrations with
the desktop launcher in the LX Backup 1.0 format and names everything that did
not fit.

| Field | Value |
|-------|-------|
| Feature | [017-BACKUP_AND_STORAGE](../FEATURE.md) |
| Promises | P10–P16, P25 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The "Transfer to desktop" card on the Backup & restore screen moves the
shared part of settings between the phone and the desktop launcher:
subscriptions, servers, folders, chains, Directions, rules, DNS, portable
vars, `route.final`, WARP registrations. The format is LX Backup of contract
1.0; whatever the other side has no place for is dropped and named
("Anything the other side has no place for is dropped, and the app tells you
exactly what did not make it."). This card does not replace the full backup.

## Parameters

| What | Value |
|------|-------|
| Export file name | `lx-backup.json` |
| Written version | `lx_backup: 2` (contract 1.0) |
| Read versions | `1` (the 0.x family) and `2`; greater — rejected with "update the app"; not a number / no field — "not an LX Backup file" |
| Portable vars | `auto_detect_interface`, `dns_cache_capacity`, `dns_default_domain_resolver`, `dns_final`, `dns_optimistic`, `dns_store_cache`, `dns_strategy`, `ipv6_enabled`, `log_level`, `resolve_strategy`, `tls_fragment`, `tls_fragment_fallback_delay`, `tls_mixed_case_sni`, `tls_record_fragment`, `tun_address`, `tun_address6`, `tun_mtu`, `tun_stack`, `urltest_interval`, `urltest_tolerance`, `urltest_url` — a mirror of the contract registry |
| Save method | the same sheet as for the full backup |

## Inputs / Outputs

**Inputs:** current settings (export); an LX Backup 1.0 or 0.x file
(import); preview confirmation.

**Outputs:** the file `{lx_backup, exported_by{app, version}, exported_at,
sources[], directions[], rules[], dns{}, vars{}, route{final}, warp[]}`;
on export losses — the "Not included in the file" dialog ("These settings
have no place in the shared format:"). The "Import backup" import preview:
"From <app> <version>", counters Directions / Chains / Rules / Subscriptions
/ Servers / Variables / DNS entries / WARP accounts, the "Not applied
as-is:" list and the line "Importing replaces the current rules.". Result —
"Imported N rules, M directions and K settings" (variants) with "; chains:
N", or "Imported N rule(s), M items not applied".

## Rules and invariants

- **Export:** source records — the same form as in storage, sliced by the
  contract field table; LxBox fields with no home in 1.0 are named
  `backup_local_only_dropped` with one warning per record; marks of
  disabled nodes travel, the core verdict does not (P16).
- **Source merge:** a subscription — by URL; a folder — by `id`, then by
  name among the existing ones; a node — by body (two same-named folders —
  two folders). A repeated import adds nothing (P11). A matched folder takes
  the file's settings but keeps its own `id` and name.
- **Directions and chains:** a taken tag — the incoming one is not applied
  (`backup_direction_exists`, `backup_chain_exists`), your own stays (P13).
- **Rules:** replace the receiver's rules; the order — by the file's numbers.
  A rule's target is checked after merging sources and Directions: an unknown
  target — the rule is disabled (`backup_unknown_outbound`); `route.final`
  to nowhere — not applied (`backup_final_dropped`) (P14). A foreign preset
  arrives disabled (`backup_unknown_preset`).
- **DNS** — by merge; a record with no place — `backup_dns_entry_skipped`.
- **Vars:** only portable ones; others — `backup_var_skipped` with a reason
  (`not_portable`, `undeclared`, `superseded`, `no_record`) (P15).
- **WARP:** a registration is applied only if there is none of your own; an
  unparsed one — `backup_warp_skipped`.
- **The unfamiliar is named:** a record field — `backup_unknown_field`, a
  field of the wrong type — `backup_field_type_mismatch`, a record kind with
  no place — `backup_source_kind_unsupported`, a simplified group —
  `backup_group_degraded`, node sections — `backup_section_record_dropped`
  (P12). The file is still read.
- The import plan is computed once for the preview and **again** at write
  time — against fresh state (a background subscription update between the
  preview and the confirmation is not overwritten) (P25).
- All sections are written to memory and to disk in one write at the end:
  an interruption does not leave half of the settings.

## Boundaries

- The full backup is neither read nor written by this card —
  [full backup restore](full-backup-restore.md).
- App settings, debugging, VPN toggles, split tunneling — are not
  transferred (local-only).
- There is no choice of individual sections on import.
- The format norms are the contract with the launcher (`docs/contract/`);
  here — LxBox's behavior as a party to the contract.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [393F](../../../tasks/393F-directions/spec.md) | Released v2.21.0 | Directions, chains, DNS, WARP, `route.final` in the transfer; taken-tag codes |
| 2 | [401](../../../tasks/401-backup-state-serialization.md) | DEVICE-VERIFIED | Backup = serialization of state; the carry-along pocket removed, losses named |
| 3 | [406](../../../tasks/406-import-canonical-body-case-sensitive-tags.md) | Done | Canonical node body, case-sensitive tags |
| 4 | [407](../../../tasks/407-backup-corpus-pre-state-merge.md) | Done | Corpus: case pre-state and a merge run |
| 5 | [409](../../../tasks/409-direction-ping-options-backup.md) | Done | Direction node-test budget in the transfer |
| 6 | [438](../../../tasks/438-lx-backup-1-0-read-write.md) | Released v2.24.0 | Writing 1.0, reading 1.0 and 0.x, rejecting newer |
| 7 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | Released v2.24.0 | Translator removed: file and storage are one record form |
| 8 | [441](../../../tasks/441-template-preset-vars-in-record.md) | Released v2.24.0 | Vars of template DNS servers and presets in the record |
| 9 | [489](../../../tasks/489-core-reject-verdict-not-backup.md) | Released v2.25.0 | The safeguard verdict does not travel in the backup |
| 10 | [511](../../../tasks/511-ui-review-findings-after-v2251.md) | Released v2.25.2 | Order of created records in `sources[]` as in the file |
