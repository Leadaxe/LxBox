[English](config-editor.md) · [Русский](config-editor.ru.md)

# Final config editor — the core config as editable, highlighted JSON

The Config Editor screen shows the saved sing-box config with line numbers and
syntax highlighting and saves an edited, pasted or loaded config to the core.

| Field | Value |
|-------|-------|
| Feature | [019-CONFIG_EDITOR](../FEATURE.md) |
| Promises | P1–P5, P8, P9 |
| State | ✅ written from code, 2026-09-28 |

## What it does

The "Config Editor" screen (side menu: "View, edit, import JSON") shows the
saved core config as formatted JSON with line numbers and syntax
highlighting, lets the user tweak it, substitute text from the clipboard or a
file, copy it, share it and save it to the core.

## Parameters

| Action | Where | Behavior |
|--------|-------|----------|
| Save | AppBar | JSON5 parse → canonical JSON → save; snackbar "Config saved" |
| Paste from clipboard | ⋮ menu | clipboard text, formatted, into the editor; empty clipboard — "Clipboard is empty" |
| Load from file | ⋮ menu | file text (UTF-8), formatted, into the editor |
| Copy to clipboard / Copy icon | ⋮ menu / editor corner | the whole editor text to the clipboard |
| Share | ⋮ menu | `lxbox_config.json` file with the editor text |
| Read-only threshold | — | above 1 048 576 characters |

## Inputs / Outputs

**Inputs:** the saved config at the moment of opening; the clipboard; the
chosen file; selection gestures.

**Outputs:** the config saved to the core; the clipboard; the file for Share;
snackbars and errors on screen.

## Rules and invariants

- **Formatting in the background.** Opening and text substitution format JSON5
  with a 2-space indent off the main thread; while it runs — a progress bar.
  Unparseable text — as is.
- **Saving is strict in meaning, lenient in syntax.** Comments and trailing
  commas are allowed; compact canonical JSON goes to the core. Empty — "Config
  is empty"; syntax — "Failed to parse config: …" with the position; the core
  config does not change.
- **Substitution ≠ saving.** Paste and Load from file change only the editor
  text.
- **Read-only** for a config that is too large: banner "File is too large to
  edit on device. Share it, edit externally, then load it back.", Save is
  disabled.
- **One-way.** A saved edit works until any UI action rebuilds the config from
  the settings; the menu screens do not see it. To keep the edit — pinning
  ([config-pin.md](config-pin.md)).
- **Tunnel up.** Saving does not restart the core; if the config differs from
  the running one — the "config changed" flag.
- **Input works like a regular system text field** (shared by all JSON fields
  of the app): the keyboard sees the whole text, its arrows move the cursor,
  its Copy copies the whole selection; the cursor line stays above the
  keyboard.
- **Selection menu** — the editor's native menu in the app language: Cut /
  Copy / Paste / Select all over the live selection (a read-only field offers
  only Copy / Select all, §607).
- **Find** — the icon in the field corner opens a panel: query, match count,
  previous / next; an empty query clears the match highlight.
- **Sticky headers.** While scrolling, up to three lines of the enclosing
  blocks stay pinned at the top (`"outbounds": [` → `{` → …) — only without
  line wrapping (an editor limitation), so on this screen, which wraps lines,
  they do not show; the node JSON and a JSON subscription Source have them.
  There is no block folding.
- **Highlighting** of JSON; in fields that take anything — by the look of the
  text: JSON, WireGuard INI, links (`scheme://…`) or none.
- A file picking error or a missing file manager — a clear text, not a
  technical exception.

## Boundaries

- Shows the saved file, not a snapshot of the running core.
- Comparison with the running config and restart — [003-CONFIG_BUILD](../../003-CONFIG_BUILD/FEATURE.md),
  [010-VPN_SERVICE](../../010-VPN_SERVICE/FEATURE.md).
- There is no reverse parsing into settings (issue #3).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [007F](../../../tasks/007F-config-editor/spec.md) | Implemented | Indented formatting on open, compact JSON on save |
| 2 | [041](../../../tasks/041-user-error-format-helper.md) | ✅ Implemented | File and Share errors as human-readable text |
| 3 | [219](../../../tasks/219-deep-audit-2026-07.md) | Done (audit) | Copying to the clipboard without a race with the snackbar |
| 4 | [333](../../../tasks/333-large-text-virtualization.md) | ✅ Implemented, device-verified | Line-by-line editor, background formatting, read-only threshold, JSON5 error without a crash |
| 5 | [372](../../../tasks/372-android-tv-support.md) | — | Load from file on a device without a file manager — a hint |
| 6 | [431](../../../tasks/431-file-picker-12-plus-plugins-major-bump.md) | Done, DEVICE-VERIFIED | Reading the chosen file as UTF-8 |
| 7 | [517](../../../tasks/517-editor-selection-and-dns-shield-udp.md) | Released in v2.25.2 | The selection menu does not collapse the selection |
| 8 | [521](../../../tasks/521-editor-menu-hide-and-single-overlay.md) | Released in v2.25.3 | One menu, explicit removal triggers |
| 9 | [554F](../../../tasks/554F-schema-driven-node-editor/spec.md) | Idea; only highlighting done | JSON syntax highlighting |
| 10 | [607](../../../tasks/607-l10n-backup-shell-bugs-from-591.md) | Done | A read-only field's selection menu has no Cut / Paste |
| 11 | [624](../../../tasks/624-sora-editor-for-json-fields.md) | Implemented | Native editor: input and keyboard like a system field, sticky headers instead of folding, JSON / INI / URI highlighting |
