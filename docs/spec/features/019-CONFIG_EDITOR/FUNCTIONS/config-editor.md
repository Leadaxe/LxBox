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
| Copy to clipboard / Copy icon | ⋮ menu / button row above the field | the whole editor text to the clipboard |
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
- **Leaving with unsaved edits** — as on the other edit screens. An edit is
  editor text that differs from the text the screen opened with or last
  saved by Save; Paste and Load from file count. Back (system, gesture, AppBar
  arrow) with an edit shows the shared "Unsaved changes" dialog: Save — same
  as the Save button (on a parse error the screen stays open with the error);
  Discard — leave without saving; Keep or dismiss — stay. No edit, read-only
  or still loading — leave without the dialog.
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
- **Field buttons sit above the frame, on the right** (Find, wrap, Copy,
  and the ⋮ menu last), never inside it: the text starts at the normal inset.
  Every JSON field and viewer has the ⋮ menu, so the button row is always
  there. A field with a
  caption (the node Source note, the DNS server JSON note) keeps the caption
  on the left of the same row; it wraps in the width the buttons leave.
- **Find** — the search button opens a panel in place of the button row:
  query, match count, previous / next; an empty query clears the match
  highlight.
- **The ⋮ menu** holds Format (where it applies) and Magnifier. It hides
  with the other buttons while the search panel is open.
- **Format** (a ⋮ menu item; editable JSON fields other than this screen:
  node Source, Edit server in a folder, DNS server JSON, route rule JSON, DNS
  rule sheet, the wizard's JSON field) — shown when the text looks like
  JSON. It parses the
  text as JSON5, the same way Save does, and replaces it with JSON indented by
  two spaces. It is an ordinary edit: undo reverts it and the screen counts it
  as unsaved. A parse error shows "Failed to parse JSON: …" with the position
  and leaves the text alone. JSON5 comments do not survive: if the text has
  `//` or `/*` outside strings, the dialog "Comments will be removed" asks
  first (Format / Cancel). This screen has no Format: it formats the config
  when it opens.
- **Growing fields** (node Source, rule JSON, Edit server) grow by screen
  rows, wrapped lines included, up to their limit; past it the text scrolls
  inside. Fields that wrap lines do not highlight the cursor line (one
  compact JSON line would paint the whole field).
- **Sticky headers.** While scrolling, up to three lines of the enclosing
  blocks stay pinned at the top (`"outbounds": [` → `{` → …). The editor draws
  them only without line wrapping, so this screen does not wrap by default:
  long lines scroll sideways. The wrap button above the field turns wrapping
  on (sticky headers disappear meanwhile); the choice is not saved, the screen
  opens again without wrapping. When on, the button sits on a tonal background. The node JSON and a JSON subscription Source have them too.
- **Busy.** After a wrap toggle (or Format) the wrap button and the ⋮ menu
  are disabled and show a small circular indicator instead of their icons
  until the editor has laid the lines out again; repeated taps do not pile
  up. If the layout has not finished in 30 s, the buttons come back anyway.
  There is no block folding.
- **Gestures on the field** (all JSON fields). With a selection the touch
  belongs to the editor entirely: the handles drag in any direction, the tabs
  and the page stay put. Without a selection the direction decides, once the
  finger has moved past the drag threshold:

  | Movement | Goes to |
  |---|---|
  | sideways, the text is wider than the field | the editor |
  | sideways, the whole width is visible | the tabs / page |
  | vertical, there is room to scroll that way | the editor |
  | vertical, the text is at the edge or fits in height | the page |

  The decision holds for the whole gesture: scroll the text to the edge, lift
  the finger, and the next swipe the same way scrolls the page. A long press
  selects. The Config screen (a full-height field) takes the touch entirely.
- **The selection magnifier** is drawn from the editor itself and shows the
  text under the finger however the field and the page are scrolled. The
  Magnifier item of the ⋮ menu turns it on and off; the setting is one for
  the whole app, saved (on by default), applies at once in the current field
  and in other fields the next time they open.
- **Layout indicator.** While the editor recomputes line breaking for longer
  than 300 ms (wrapping a large body), a thin progress bar runs along the top
  edge of the frame; quick recomputations do not show it.
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
| 12 | [649](../../../tasks/649-json-view-wrap-toggle.md) | Done, awaiting emulator check | Line-wrap button (off by default, not saved), gestures by direction, magnifier from the editor, layout indicator |
| 13 | [660](../../../tasks/660-editor-overflow-menu.md) | Implemented | The ⋮ menu: Format, the magnifier setting; buttons busy until the layout ends |
