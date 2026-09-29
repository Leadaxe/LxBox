[English](remote-rule-sets.md) · [Русский](remote-rule-sets.ru.md)

# External rule-sets and the local cache

| Field | Value |
|------|----------|
| Feature | [004-ROUTING](../FEATURE.md) |
| Promises | P8 P9 P10 P11 |
| State | ✅ written from code, 2026-09-28 |

## What it does

Allows routing by ready-made lists from the network (geosite, geoip,
ads, app lists) in `.srs` format. The user creates a rule
of the **Remote (.srs)** kind with one or several URLs; template presets also
carry external sets. The app downloads the files into its cache and gives the core
a local path; the core itself does not go to the network for lists.

## Parameters

| Parameter | Values | Default |
|---|---|---|
| Set URL (`.srs` rule) | one `http(s)://` per line, repeats and empty lines are dropped | — |
| Check for updates (own rule TTL) | Never · Every day · Every week · Every 2 weeks · Every month · Every 6 months · Every year | Every week (168 h) |
| Preset set TTL | from the template's `update_interval` (`h`/`d`/`w`, without a unit — hours, `0` — never) | week |
| Extra filters of an `.srs` rule | ports, apps, protocol, network, source, inbound, Wi-Fi | — |

Actions: ☁ in the rule row — download/re-download (✅ — everything is in the cache,
a spinner — a download is running); a long tap on a preset's ☁ — "Refresh rule-sets" and
"Clear cached files"; in the editor — "Update now", "Refresh SRS", "Clear
cached file", "Copy URL", "Paste" and the line "Updated … / last attempt
error".

## Inputs / Outputs

**Inputs:** set URLs; server responses (200 with a body, 304, errors); ETag.
**Outputs:** files in the app cache (one per set, key — the rule id
or preset+set tag) with metadata (last confirmation, last
attempt, ETag, error); in the config — `{type: local, format: binary, path}`
per set and one route rule with the list of tags.

## Rules and invariants

- **Download:** up to 3 attempts with pauses of 1 s and 3 s, retry only on
  transient failures (network, timeout, 5xx, empty body); 4xx — immediate rejection.
  The write is atomic: the file is replaced only as a whole.
- **A failure does not delete the file:** a stale working list is better than a disabled
  rule; 304 is a success, the file is not rewritten, freshness is extended, the config is not
  marked as changed.
- **An own `.srs` rule** requires the files of all sets; if even one is missing —
  the build skips the rule with the warning "skipped: no cached file
  (Download first)". The first set gives tag = the rule name, the following ones —
  `<name>-2`, `<name>-3`…
- **A preset set** without a file drops out by itself, the rest of the preset rule
  lives; a set disabled by a preset variable (for example the GeoIP layer) is not
  required, but its file is kept — if the checkbox comes back, no need to download again.
- **The Routing screen on opening** disables a rule that lacks the needed
  files; the list switch of such a rule first downloads, and enables only on
  full success. In the editor the switch of an `.srs` rule is unavailable until the download.
- A rule added from the catalog with external sets arrives
  disabled: "Added … — tap ☁ to download, then enable".
- Changing a rule's URL or kind wipes the old files and disables the rule;
  deleting a rule wipes its files; on opening the screen, files
  that no rule corresponds to are deleted.
- **Auto-update:** candidates — sets of enabled rules older than the TTL
  (or without metadata); "Never" is not updated. A pass — 30 s after
  app start and 30 s after tunnel bring-up, only in the
  foreground, with a conditional GET, with a pause between sets; a failure — one retry after
  20 s; a successful pass — no more checks until the process restarts.
  A changed file triggers a config rebuild. A manual "Update now"
  re-downloads unconditionally.
- The DNS option of an `.srs` rule works only if the set contains domains.

## Boundaries

- The contents of `.srs` are neither parsed nor shown.
- The cache is not part of the backup; after a restore, sets are downloaded
  again.
- There is not and will not be a background timer update (battery).

## Revisions

| # | Revision | Status | Summary |
|---|---|---|---|
| 1 | [011F](../../../tasks/011F-local-ruleset-cache/spec.md) | Implemented (v1.4.0) | Local cache, manual download, only `type: local` in the config |
| 2 | [011](../../../tasks/011-sealed-customrule-split.md) | ✅ Implemented | Cache of preset sets, disabling a rule without a file |
| 3 | [045](../../../tasks/045-ru-direct-geoip-fallback.md) | Released (v1.7.0) | An optional preset set: without a file the rule lives with the rest |
| 4 | [366](../../../tasks/366-rule-set-auto-update.md) | Implemented, device-verify pending | TTL and auto-update with a conditional GET at start and after tunnel bring-up |
| 5 | [434](../../../tasks/434-srs-rule-multiple-rule-sets.md) | Done | Several sets in one rule |
| 6 | [531](../../../tasks/531-ru-app-list-ruleset-in-ru-preset.md) | Done | The set of Russian apps in Ru internet segment |
| 7 | [534](../../../tasks/534-rule-set-enable-gate-download-path.md) | Done | The set gate is the same for download, the screen and the build |
