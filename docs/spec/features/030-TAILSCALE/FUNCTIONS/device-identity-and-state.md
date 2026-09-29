[English](device-identity-and-state.md) · [Русский](device-identity-and-state.ru.md)

# Device identity and state — a state directory per node that survives renames

Every Tailscale node gets its own state directory where the core keeps the
machine keys and the login; the app binds it to a stable node key, so the
device stays the same in the tailnet after a rename, a move or a Workspace
switch.

| Field | Value |
|-------|-------|
| Feature | [030-TAILSCALE](../FEATURE.md) |
| Promises | P6–P10 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Issues a directory name to a node the first time it reaches the build, writes
it into the config as `state_directory`, keeps the record through node
operations, deletes the directory together with the node (once the core is
stopped), adopts directories left by 2.24.0, and gives each Workspace slot its
own set of records. The user sees one device in the tailnet per node, not a
new one after every rename.

## Parameters

| What | Value |
|------|-------|
| Directory | `tailscale/<name>/` in the app's files directory; the name is the final tag sanitized to `[A-Za-z0-9._-]`, then `-1`, `-2`… when taken |
| Index | `tailscale_state.json`: `slots` (slot → node key → directory name), `legacy` (directories found when the index was created) |
| Node key | own server: server id, `#2`, `#3` for further Tailscale nodes of it; folder member and subscription node: container id + raw tag, `#2` for namesakes |
| Own `state_directory` in the body | no record, the directory is never touched |
| "Core stopped" | the tunnel status `disconnected` or `revoked`; a channel error counts as running |

## Inputs / Outputs

**Inputs:** the stored sources before and after an operation; the build; the
Workspace directory (slot names, current); the tunnel status.

**Outputs:** `state_directory` on the config entry; the index; app log lines
"Tailscale state of node … kept", "Tailscale state of a removed node deleted",
warnings when the index is unreadable or a target key is already taken.

## Rules and invariants

- **A name is issued once** and never changes (P6): rename, tag prefix
  change, member rename, moves between folders or into a server and back,
  swaps of namesakes rewrite the key of the record; the files stay. Disabling
  a node, member, folder or source keeps the record — keys are computed over
  all stored nodes.
- **The path is written at emission only** (P7): with a known root the entry
  gets `<root>/tailscale/<name>`; the stored body never carries a path.
  Without an index the name falls back to the final tag with a warning.
- **Deletion** (P8): the record goes at once, so a namesake added next does
  not inherit the identity; the directory goes when nobody references it and
  the core is stopped — at the operation itself or at the next build with the
  core stopped. Ghost slots (absent from the Workspace directory) and their
  directories are removed the same way. A node that vanished from a
  subscription body is treated as deleted at the build.
- **Unresolved containers keep their records**: a subscription without a
  cached body, a server with an unreadable body, a member with broken text.
- **Adoption** (P9): on the first build of a slot, a directory named the way
  2.24.0 named it (final form, then `-1`, `-2`… in node order) that is listed
  in `legacy` and not referenced by another slot is bound to the node. A node
  that already has a record never takes an old directory. While a slot of the
  Workspace directory has no records, `legacy` directories are never deleted;
  `legacy` is cleared once every slot has been built or deleted.
- **A taken target key** (a stale record on the key a node moves to): the
  moving node wins, a warning is logged, the stale directory becomes an
  orphan.
- **Workspaces**: Save as copies the current slot's records into the target
  (the copy in both slots is one tailnet device; a one-time key is spent
  once), Rename moves the set, Delete drops it and removes unreferenced
  directories at once, Load touches nothing. No operation copies the files.
- **Nothing on disk without nodes** (P10): the index is created at the first
  build that has a Tailscale node or finds directories; an unreadable index
  is treated as empty and the slot goes through adoption again. Index
  operations run one at a time; a failed index operation never stops the
  build or the Workspace operation.
- **Backup and reinstall:** the index and the directories are outside the
  settings file and outside a slot copy, so a backup restores the node body
  without the identity. On the same device the restored sources keep their
  ids and find their records; on another device, or after clearing the app
  data, the node registers as a new device and needs a fresh key.

## Boundaries

- The Workspace promise itself —
  [018-WORKSPACES · P12](../../018-WORKSPACES/FEATURE.md#promises); the
  storage contract row — [017-BACKUP_AND_STORAGE](../../017-BACKUP_AND_STORAGE/FEATURE.md).
- A directory whose 2.24.0 name was suffixed differently than the stored
  node order gives is not adopted (a disabled namesake in the middle of the
  list shifted the suffixes); such a node joins as a new device.
- Editing `auth_key` or `control_url` does not issue a new directory: a node
  with a saved login ignores the new key.
- The Android system backup includes `files/` together with the `tailscale/`
  keys — stock behaviour (`android:allowBackup` at its default), by design: the
  login credentials move to a new phone with the rest of the data (owner's
  decision 2026-09-29, audit 591 · 80). Consequence: restoring onto a new
  device while the old one is alive yields two copies of one tailnet identity;
  the user resolves it by logging out on one of them.
- No confirmation names the loss of the tailnet login when a Tailscale node
  or a slot is deleted.

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [435](../../../tasks/435-node-sections-tailscale.md) | Cancelled, replaced by §575/§578 | `state_directory` per node from the final tag; the lifecycle norm (§9.8) |
| 2 | [445](../../../tasks/445-tailscale-state-dir-lifecycle.md) | Implemented, no device-verify | Stable node keys, the index, orphans, adoption, per-slot records |
| 3 | [449](../../../tasks/449-tailscale-default-hostname.md) | Implemented, no device-verify | The identity keeps the tailnet name; the hostname is an initial form value only |
| 4 | [575](../../../tasks/575-remove-node-sections.md) | Implemented (phases 1–3) | The lifecycle stays while node sections go |
