[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# FEATURE 019 — CONFIG_EDITOR — viewing and editing the final config

| Field | Value |
|-------|-------|
| Type | Product feature |
| Absorbed | `§007F` |
| State | ✅ written from code, 2026-09-28 |

## Purpose

An advanced user needs to see exactly what the core will get, and sometimes to
tweak it by hand or slip in a config of their own. The feature provides the
"Config Editor" screen (side menu) — the saved core config as formatted JSON
with highlighting, editing, import and export; viewing JSON fragments of the
config in other places (a node, a rule preview); and pinning the config for
experiments through the Debug API.

The feature protects three principles:

- **The source of truth is the settings, not the text.** The pipeline is
  one-way: settings → build → config. A manual edit lives until the next
  rebuild (issue #3, `docs/ARCHITECTURE.md` "Known limitations").
- **An edit does not break the core.** Only parsed and canonicalized JSON goes
  to the core; a syntax error is a message, not a write.
- **What you selected is what you copy.** The context menu acts on the real
  selection and does not multiply.

## Promises

- **P1. The config opens formatted.** 2-space indent; unparseable text is shown
  as is, without a crash. **Witness:** unit "форматирование в фоне совпадает с
  синхронным"; invalid — manual check (Paste from clipboard with garbage).
  **Mutation:** a crash on invalid text.
- **P2. JSON5 is accepted, canonical JSON goes to the core.** `//` `/* */`
  comments and trailing commas are allowed; compact JSON is saved.
  **Witness:** units "канонизация принимает комментарии JSON5", "канонизация в
  фоне совпадает с синхронной". **Mutation:** text with comments goes to the
  core.
- **P3. A syntax error is a message with a position; the config does not
  change.** Empty text — "Config is empty". **Witness:** units "синтакс-ошибка
  JSON5 приводится к ошибке формата", "фоновая канонизация отдаёт ошибку с
  текстом"; empty — manual check. **Mutation:** an unhandled exception.
- **P4. A large config is read-only.** Above 1 048 576 characters the editor
  does not allow editing and suggests Share → external editor → Load from file.
  **Witness:** unit "граница порога только-чтения". **Mutation:** editing a
  multi-megabyte text on the device.
- **P5. A manual edit does not survive a rebuild.** **Witness:** manual check —
  edit in the editor, Save, toggle any routing setting, come back: the editor
  shows the built config (no autotest). **Mutation:** the edit "sticks"
  without pinning.
- **P6. A pinned config is not overwritten.** While pinned, rebuilds triggered
  by UI actions are silently skipped; an explicit rebuild through the Debug
  API answers 409. **Witness:** manual check through the Debug API (`PUT
  /settings/config_locked {"locked":true}`, `POST /action/rebuild-config` →
  409; no autotest). **Mutation:** a rebuild while pinned.
- **P7. The pin is never orphaned.** The toggle is visible only when the Debug
  API is enabled; turning the Debug API off in settings removes the pin.
  **Witness:** manual check (no autotest). **Mutation:** the lock stays with the
  API turned off.
- **P8. The selection menu works with what is selected.** Long tap — Cut / Copy
  / Paste / Select all menu, the selection does not collapse. **Witness:** units
  "долгий тап: меню показано, выделение не схлопнуто", "тап Copy кладёт в
  буфер выделенный фрагмент", "тап Cut…", "тап Paste…", "тап Select all…".
  **Mutation:** the menu as a modal window (the selection is lost before the
  action).
- **P9. There is one menu, and it goes away.** A tap on empty space, a scroll or
  leaving the screen removes the menu; repeated long taps and redraws do not
  spawn copies. **Witness:** units "§521 …" (eight scenarios). **Mutation:** a new
  menu instance on every redraw.
- **P10. A node's JSON is copied in the right form.** Without a detour — "Copy
  JSON"; with a detour — "Copy server JSON" / "Copy detour" / "Copy server +
  detour(s)"; copies have no `detour` field, a chain is copied whole.
  **Witness:** manual check (no autotest). **Mutation:** a copy with a dangling
  `detour`.
- **P11. A rule preview does not depend on whether the rule is enabled.**
  **Witness:** manual check (disabled rule → the View tab is not empty); the
  build skips disabled rules — unit "disabled json-правило пропускается
  (skipDisabled)". **Mutation:** an empty preview for a disabled rule.

## Controlled parameters

| Knob | Where | Values | Default |
|------|-------|--------|---------|
| Lock config (debug) | App Settings → Diagnostics, when the Debug API is enabled | on/off | off |
| Read-only threshold | — | 1 048 576 characters | fixed |

Debug API (contract — [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md)):
`GET /config` (`?pretty`), `PUT /config` (raw JSON object),
`GET /state/config_locked`, `PUT /settings/config_locked {"locked": bool}`,
`POST /action/rebuild-config` (409 while pinned). The feature produces no core
config keys — it shows and writes the config as a whole.

## Inputs / Outputs

**Inputs:** the saved config; text from the editor, the clipboard or a file;
Debug API requests; selection gestures.

**Outputs:** the config saved to the core (and the "config changed" flag with
the tunnel up); the clipboard; the `lxbox_config.json` file for Share;
snackbars "Config saved", "Pasted from clipboard", "Loaded from file", errors.

## Data flow

```
saved config → formatting (in the background) → editor
editor / clipboard / file → JSON5 parse → canonical JSON → save to the core
                                   └─ error → message, config unchanged
any UI action → [pinned?] ─ no  → rebuild from settings (edit erased)
                          └─ yes → skip, config unchanged
```

## Rules and guarantees

- The editor shows the saved file, not a snapshot of the running core; the
  node JSON view with the tunnel up is a snapshot of the core.
- "Paste from clipboard" and "Load from file" only put the text into the
  editor; it goes to the core on Save.
- Save is available while nothing is busy and the config is not read-only.
- The pin is stored in the settings; removing it does not trigger a rebuild by
  itself — the next action will do it.

## Boundaries

- There is no reverse parsing of the config into settings: an edit is
  invisible to the menu screens.
- The build, its gates and the "config changed" flag —
  [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md); settings storage and
  backup — [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md).
- Editing a single node and its form — [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md).
- File picking depends on OS capabilities (on a TV without a file manager — a
  hint about the clipboard).

## Functions

| Function | What it does | Promises | File |
|----------|--------------|----------|------|
| Final config editor | Viewing, formatting, editing, import/export, selection menu | P1–P5, P8, P9 | [config-editor.md](FUNCTIONS/config-editor.md) |
| Config pinning | A custom config through the Debug API, rebuild block | P6, P7 | [config-pin.md](FUNCTIONS/config-pin.md) |
| JSON fragment view | Node JSON and copying with detour, rule preview | P10, P11 | [json-fragment-view.md](FUNCTIONS/json-fragment-view.md) |

## Related features

- [003-CONFIG_BUILD](../003-CONFIG_BUILD/FEATURE.md) — the one-way settings → build → config pipeline whose output the editor shows; the build's gates, comparison with the running config and the "config changed" flag.
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — transport, token and port of the Debug API through which the config is written and pinned.
- [017-BACKUP_AND_STORAGE](../017-BACKUP_AND_STORAGE/FEATURE.md) — storage and backup of the settings the config is built from.
- [008-NODE_EDITOR](../008-NODE_EDITOR/FEATURE.md) — editing a single node; here the node's JSON is only viewed and copied.
- [004-ROUTING](../004-ROUTING/FEATURE.md) — rules are edited there; the View tab of a rule is the preview from this feature.
- [002-NODE_IMPORT](../002-NODE_IMPORT/FEATURE.md) — the node link (`Copy URI`) is not JSON and lives in the node menu.
- [010-VPN_SERVICE](../010-VPN_SERVICE/FEATURE.md) — restarting the running core; saving from the editor does not restart it.
- [018-WORKSPACES](../018-WORKSPACES/FEATURE.md) — the pin is stored among the app settings and belongs to the current set.

## Maintenance notes

- **Large text — only the line-by-line editor.** A single-paragraph field on a
  config of hundreds of KB gave 100 % CPU and process death (333).
- **The context menu is not a modal window.** A modal one takes the focus, and
  the selection collapses before the action (517); the menu instance must live
  exactly as long as the editor (521).
- **`PUT /config` is stricter than the editor:** it accepts only a plain JSON
  object.
