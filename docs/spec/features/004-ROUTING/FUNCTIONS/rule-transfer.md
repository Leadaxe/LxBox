[English](rule-transfer.md) · [Русский](rule-transfer.ru.md)

# Rule exchange via a file

| Field | Value |
|------|----------|
| Feature | [004-ROUTING](../FEATURE.md) |
| Promises | P19 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Moves selected own rules (and, optionally, related DNS servers and
DNS rules) between LxBox installations in one file, without a full
backup. The ⋮ menu on the Rules tab: "Export rules..." and "Import rules...".

## Parameters

| Step | What the user chooses |
|---|---|
| Export rules | checkboxes per own rule (Select all / Deselect all); presets are not in the list |
| Include DNS | DNS servers and DNS rules without preset references; "Export (+N DNS)" or "Export without DNS" |
| Import rules | a file; a list of elements with their state; "Import (N)" |

The file `lxbox-rules-YYYYMMDD-HHMM.json` is an envelope
`{app: "lxbox", kind: "rules", format: 2, created_at, source_app_version,
rules[], dns_servers[], dns_rules[]}`; the elements are storage records. `format: 1`
(the 2.23.2 storage form) is read too.

## Inputs / Outputs

**Inputs:** the selected rules; an exchange file.
**Outputs:** a file in Downloads or via "share"; new rules in the list;
new DNS servers and rules; the snackbars "Rules exported", "Imported N rules",
"Imported N DNS entries", "Import failed: …".

## Rules and invariants

- "Export rules..." is always available; without own rules the screen will hint that
  only DNS can be exported. Export writes rules as is, all sanitization is
  on import.
- Rejection of the whole file: not JSON, another app, an empty list, a
  backup file (with a clear error), `format` newer than 2.
- Rejection per element (the rest live): not an object or an unknown kind —
  "Unsupported entry — skipped"; a preset — "Presets are not transferable —
  this app has its own"; a rule with an already taken visible name.
- Sanitizing an imported rule: a new id; the number — at the end of its zone
  1000–1100 (the foreign number is not carried over); `.srs` arrives disabled until
  downloaded; a dangling target → `vpn-1` and the rule disabled, with a warning;
  `direct-out`, `block`, `reject` and existing Directions are not healed;
  a dangling DNS server of the DNS option → the option disabled (Force IPv4 is kept);
  a dangling resolve server → "auto".
- DNS elements: a server with a new tag is imported; the tag already exists — "Already
  on this device", settings are not touched; a template server unknown to
  this version — "Not available in this app version"; a preset one — "Managed
  by presets automatically". A duplicate DNS rule — "Already on this device".
- The name is not changed on insertion (no suffixes) — a taken name is rejected.

## Boundaries

- Presets and their variables are not carried over — the recipient has its own template.
- Directions are not carried over; targets the recipient does not have are healed.
- A full state transfer is a backup,
  [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).
- Saving and picking a file depend on OS capabilities.

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [396](../../../tasks/396-rule-export-import.md) | implemented in the task | Export/import of selected rules, sanitizing dangling references, DNS sections |
| 2 | [398](../../../tasks/398-rule-transfer-presets-and-dedup.md) | — | Presets outside the exchange, rejection by a taken name, DNS-only export |
| 3 | [439F](../../../tasks/439F-storage-contract-1-0/spec.md) | — | `format: 2`: elements are 1.0 storage records |
