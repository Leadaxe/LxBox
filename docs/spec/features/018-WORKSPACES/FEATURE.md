[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Workspaces — named VPN settings sets with one-tap switching

LxBox Workspaces keep several named sets of VPN settings, such as "home", "work"
and "experiment", and switch between them in one tap. A set holds everything the
sing-box config is built from: subscriptions, Directions, routing rules, DNS,
tunnel apps, VPN mode and language. On a switch the app saves the current set,
rebuilds the config and brings the tunnel back up if it was running.

| Field | Value |
|-------|-------|
| Feature | 018-WORKSPACES |
| Type | Product feature |
| Absorbed | `§417F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

The user keeps several worlds — "home", "work", "experiment" — and switches
between them without editing the config by hand. A set (workspace) is a named
copy of **the entire state the config is built from**: subscriptions and their
bodies, Directions, rules, DNS, variables, tunnel apps, VPN mode, language,
Debug API.

The model is save slots. The **scene** is the app's working state; there is
exactly one. A **slot** is a saved copy of the scene under a name. **Current**
is the name of the slot that is on the scene now; until first use it is
"Default" with no copy. There is no "Save" button: loading another slot saves
the scene into the current one by itself.

Principles: **nothing to lose** — a switch saves the scene first, and a
confirmation is asked only when "Save as" overwrites a slot; **one world on
the scene** — leftovers of the previous set do not write into the new one;
**no use, no cost** — until the first "Save as" nothing is written to disk.

## Promises

- **P1. Slot contents are fixed.** A slot contains the settings file, the
  downloaded rule-sets and the subscription body cache; it does not contain the
  built config, the core cache database, the theme, logs, crash reports or
  service copies. **Witness:** unit "saveAs copies all three items, current =
  name, date recorded". **Mutation:** the core config inside the slot (the core
  would not see a config swapped on disk).
- **P2. No use — no traces.** No directory — current is "Default", there are no
  slots, the disk is not touched. **Witness:** unit "default: current=Default,
  no slots, the disk is not touched". **Mutation:** the directory is created at
  startup.
- **P3. Loading saves the scene before replacing it.** The scene goes into the
  current slot ("Default" gets its copy on the first load), then the target
  replaces the scene whole. **Witness:** units "the scene goes to current, the
  target comes onto the scene, .bak removed", "the first load without a folder
  for current creates “Default”". **Mutation:** loading without saving the
  current one.
- **P4. Loading the current slot does nothing** (the tunnel is not touched).
  **Witness:** units "load current → alreadyCurrent: stop is not called", "load
  current → no-op, files are not touched". **Mutation:** tunnel stop.
- **P5. The tunnel survives a switch.** If it was up, it goes down, the config
  is rebuilt from the new set and the tunnel comes up again; if it was not up,
  it is not started. **Witness:** units "load of another slot: stop → files → …
  auto-start flag once", "VPN was down → no auto-start". **Mutation:**
  auto-start with the tunnel down.
- **P6. After loading, the config comes from the new set.** **Witness:** units
  "slot load → configDirty → build from the new slot's settings", "init does not
  clear the process flag when mtime is aligned". **Mutation:** the "config is
  stale" flag derived only from file modification times.
- **P7. An interrupted load is completed.** Process killed in the middle of
  copying → on the next start, before any settings read, the steps are repeated;
  if the target has disappeared, the journal is cleared and the scene stays as
  it is. **Witness:** units "pending load → steps repeated", "pending with a
  vanished target → journal cleared", contract "recover before any settings
  read". **Mutation:** completion after the first settings read.
- **P8. A leftover of the previous set does not write into the new one.**
  **Witness:** units "REGRESSION (a)…(c)", "a controller of the CURRENT
  generation writes as usual". **Mutation:** remove the write barrier — one
  set's subscriptions end up in all of them.
- **P9. A slot name is a safe folder name.** **Witness:** units "name rules =
  folder name rules", "saveAs with a bad name → invalidName, nothing created".
  **Mutation:** the name `..` passes.
- **P10. The current slot cannot be deleted; a name cannot be taken twice.**
  **Witness:** units "delete current → isCurrent…", "rename to a taken name →
  exists", "rename current renames the folder and current". **Mutation:**
  deleting the current slot.
- **P11. "Save as" into an existing name replaces the slot entirely** — after
  the "Overwrite" confirmation. **Witness:** unit "a repeated saveAs into the
  same name overwrites the slot entirely"; the dialog — manual check.
  **Mutation:** merge.
- **P12. Each slot has its own Tailscale identities.** **Witness:** units "Save
  as → build of another slot → Load → Rename → Delete", "without a Tailscale
  index Workspaces operations create no files". **Mutation:** state directories
  are copied into the slot. In detail —
  [030-TAILSCALE](../030-TAILSCALE/FUNCTIONS/device-identity-and-state.md).
- **P13. A slot in the old storage form loads.** **Witness:** units "loading a
  2.23.2 slot: the scene migrates, the slot original is kept as a copy…", "a
  slot in the current form gets no copy". **Mutation:** the original is lost.
- **P14. A corrupt directory = a missing one.** **Witness:** unit "a corrupt
  directory is read as missing". **Mutation:** startup crash.

## Controlled parameters

| Knob | Values | Default |
|------|--------|---------|
| Slot name | 1–64 characters after trimming whitespace; no `/`, `\`, control characters, no leading dot; comparison is case-sensitive | "Default" is suggested while the current slot has no copy; otherwise empty |

The feature emits no core config keys: the config is built from the scene in
the regular way ([003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md)).

## Inputs / Outputs

**Inputs:** the button with the current set's name to the right of "L×Box" on
the home screen; the "Workspaces" popup: the Load section (slots in
alphabetical order, current one marked, save date and size, "⋮" menu —
Rename / Delete) and the Save section ("Save as…"); app start (journal
completion).

**Outputs:** the new set's scene; the rebuilt config; the tunnel in its
previous position; snackbars "Workspace “X” loaded", "Saved as “X”", error
texts; the modal "Loading workspace…" indicator while loading.

## Data flow

```
Load X:  stop probes and auto-update → stop tunnel (remember "was up")
         → flush settings to disk → journal {load X}
         → scene → current's slot → slot X → scene → current = X, journal cleared
         → "config is stale" flag → re-read state, recreate the home screen
         → rebuild config → if the tunnel was up and the build succeeded — start
Save as Y: flush to disk → scene → slot Y → current = Y (tunnel not touched)
```

## Rules and guarantees

- Slot operations run strictly one at a time; the set button is disabled while
  a load is in progress. No process restart is needed: state is re-read and
  the home screen is recreated.
- The settings backup copy is deleted after a load — it is a snapshot of the
  previous slot, and restoring from it would swap the set.
- The tunnel is started again only if the rebuild succeeded; otherwise the
  start is skipped (the reason goes to the log).
- Subscription updates started before the switch are discarded entirely; the
  new set updates its own subscriptions on its own triggers.

## Boundaries

- Switching from the Intent API and automation apps is not supported; the set
  name is not shown in the notification.
- There are no subscriptions shared between sets (the overlay model was
  rejected).
- The backup covers only the scene, not the slots; to export a slot, load it
  and make a backup. Importing a backup directly into a slot is not supported —
  [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md).
- Connections dropping during a switch is expected: there is no hot swap by
  construction (core cache database, inbounds, tunnel apps).
- Slots overwritten before race 515 was fixed are not restored by the feature.
- Not planned (owner decision 2026-09-29, audit [591](../../tasks/591-spec-kit-revision-audit.md)): a "set epoch" barrier at every
  storage writer (follow-up to 515) — protection against race 515 stays at the
  subscription owner level; a separate chain-order migration on loading a set
  (`417F` §2.6).

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Saving and loading a set | Saves the state under a name and loads another set with the tunnel kept in place: Save as, Load, slot contents, completion journal. | P1–P7, P11, P13, P14 | [save-and-load.md](FUNCTIONS/save-and-load.md) |
| Slot management | Lists saved sets and lets the user rename or delete them under safe folder-name rules. | P9, P10 | [slot-management.md](FUNCTIONS/slot-management.md) |
| Switch isolation | Keeps leftovers of the previous set from writing into the new one and gives each slot its own Tailscale identities. | P8, P12 | [switch-isolation.md](FUNCTIONS/switch-isolation.md) |

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — after a load the config
  is rebuilt from the new scene through the regular build and its gates; the
  build also assigns Tailscale state directories to nodes.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — tunnel stop and start
  around a switch.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — the backup
  sees only the scene, not the slots; slots in the old storage form are loaded
  by its migration.
- [030-TAILSCALE](../030-TAILSCALE/FEATURE.md) — the Tailscale device identity
  (state directory per node) that each slot keeps its own set of.

## Maintenance notes

- **A new state file must be classified:** either part of the slot contents or
  explicitly a "device property". Otherwise it silently becomes shared by all
  sets.
- **File modification time is not a signal.** Flushing to disk aligns it within
  the same second; the "config is stale" flag after a load is set explicitly
  (447).
- **Any asynchronous settings writer that outlives the screen is a candidate
  for race 515.** The barrier sits at the subscription owner level; writers
  outside the screen (backup import, Debug API) are intentionally not limited
  by it.
- **Journal completion comes before the first settings read**, otherwise the
  old scene from the cache lands on top of the completed slot.
