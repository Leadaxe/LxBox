[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# FEATURE 018 — WORKSPACES — named settings sets

| Field | Value |
|-------|-------|
| Type | Product feature |
| Absorbed | `§417F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

Several worlds — "home", "work", "experiment" — with switching and no manual
config surgery. A set (workspace) is a named copy of **the entire state the
config is built from**: subscriptions and their bodies, Directions, rules,
DNS, variables, tunnel apps, VPN mode, language, Debug API.

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
  downloaded rule-sets and the subscription body cache; it does not contain
  the built config, the core cache database, the theme, logs, crash reports or
  service copies. **Witness:** unit "saveAs копирует все три позиции,
  current = имя, дата записана". **Mutation:** the core config inside the slot
  (the core would not see a config swapped on disk).
- **P2. No use — no traces.** No directory — current is "Default", there are
  no slots, the disk is not touched. **Witness:** unit "дефолт:
  current=Default, слотов нет, диск не трогается". **Mutation:** the directory
  is created at startup.
- **P3. Loading saves the scene before replacing it.** The scene goes into the
  current slot ("Default" gets its copy on the first load), then the target
  comes onto the scene whole. **Witness:** units "сцена уходит в current, цель
  приходит на сцену, .bak снят", "первая загрузка без папки у current
  создаёт «Default»". **Mutation:** loading without saving the current one.
- **P4. Loading the current slot does nothing** (the tunnel is not touched).
  **Witness:** units "load current → alreadyCurrent: стоп не зовётся",
  "load current → no-op, файлы не трогаются". **Mutation:** tunnel stop.
- **P5. The tunnel survives a switch.** If it was up, it goes down, the config
  is rebuilt from the new set and the tunnel comes up again; if it was not up,
  it is not started. **Witness:** units "load другого: стоп → файлы → … флаг
  автозапуска один раз", "VPN был опущен → автозапуска нет". **Mutation:**
  auto-start with the tunnel down.
- **P6. After loading, the config comes from the new set.** **Witness:** units
  "загрузка слота → configDirty → сборка из настроек нового слота", "init не
  опускает флаг процесса при выровненном mtime". **Mutation:** the "config is
  stale" flag derived only from file modification times.
- **P7. An interrupted load is completed.** Process killed in the middle of
  copying → on the next start, before any settings read, the steps are
  repeated; if the target has disappeared, the journal is cleared and the
  scene stays as it is. **Witness:** units "pending load → повтор шагов",
  "pending с исчезнувшей целью → журнал снят", contract "recover before any
  settings read". **Mutation:** completion after the first settings read.
- **P8. A leftover of the previous set does not write into the new one.**
  **Witness:** units "РЕГРЕСС (а)…(в)", "контроллер ТЕКУЩЕГО поколения пишет как
  обычно". **Mutation:** remove the write barrier — one set's subscriptions end
  up in all of them.
- **P9. A slot name is a safe folder name.** **Witness:** units "правила
  имени = имени папки", "saveAs с плохим именем → invalidName, ничего не
  создано". **Mutation:** the name `..` passes.
- **P10. The current slot cannot be deleted; a name cannot be taken twice.**
  **Witness:** units "delete current → isCurrent…", "rename в занятое имя →
  exists", "rename current переименовывает папку и current". **Mutation:**
  deleting the current slot.
- **P11. "Save as" into an existing name replaces the slot entirely** — after
  the "Overwrite" confirmation. **Witness:** unit "повторный saveAs в то же имя
  перезаписывает слот целиком"; the dialog — manual check. **Mutation:** merge.
- **P12. Each slot has its own Tailscale identities.** **Witness:** units "Save
  as → сборка другого слота → Load → Rename → Delete", "без индекса Tailscale
  операции Workspaces файлов не создают". **Mutation:** state directories are
  copied into the slot.
- **P13. A slot in the old storage form loads.** **Witness:** units "загрузка
  слота 2.23.2: сцена мигрирует, исходник слота — копией…", "слот текущей
  формы копии не получает". **Mutation:** the original is lost.
- **P14. A corrupt directory = a missing one.** **Witness:** unit "битый
  справочник читается как отсутствующий". **Mutation:** startup crash.

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

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Saving and loading a set | Save as, Load, slot contents, tunnel, completion journal | P1–P7, P11, P13, P14 | [save-and-load.md](FUNCTIONS/save-and-load.md) |
| Slot management | List, names, renaming, deletion | P9, P10 | [slot-management.md](FUNCTIONS/slot-management.md) |
| Switch isolation | Leftovers of the previous set do not write into the new one; Tailscale identities per slot | P8, P12 | [switch-isolation.md](FUNCTIONS/switch-isolation.md) |

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — after a load the config is rebuilt from the new scene through the regular build and its gates; the build also assigns Tailscale state directories to nodes.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — tunnel stop and start around a switch.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — the backup sees only the scene, not the slots; slots in the old storage form are loaded by its migration.

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
