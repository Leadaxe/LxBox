[English](README.md) · [Русский](README.ru.md)

# Specifications (L×Box)

The requirements catalog: features (the contract with the user) and tasks (a log of work cycles).

## Structure

Two levels, modeled on the core's Spec Kit
([sing-box-lx/SPECS](https://github.com/Leadaxe/sing-box-lx/tree/lx/SPECS)):

| Folder | Level | What is inside |
|---|---|---|
| [`features/`](features/) | **Features** | A black box: why the feature exists, what it promises the user, which principles it protects, boundaries. **No code and no platform** — the folder moves to another platform whole. `NNN-NAME/FEATURE.md` + `FUNCTIONS/<function>.md`. Being written anew, see [`features/README.md`](features/README.md). |
| [`tasks/`](tasks/) | **Tasks (revisions)** | A unit of work: problem → diagnosis → solution → verification. This is where the **implementation** lives: files, control flow, platform. `NNN-title.md` or a folder `NNN-title/`. More — [`tasks/README.md`](tasks/README.md). |
| [`processes/`](processes/) | **Processes** | Recurring procedures (for example, night work). Each folder has a README + templates. |

Feature → functions → revisions. A function (a file in `FUNCTIONS/`) holds a revision table —
links to the tasks that changed it. A task carries a back link to the feature/function.

## Conventions

- **Features** — `NNN-NAME` (UPPER_SNAKE), running numbering from `001`, the number is a stable
  anchor. One `FEATURE.md` per feature, the current state on top, no chronology.
  The "what, not how" rule: there are no names of files, classes, code functions or platform
  mechanisms in `features/`. Template and index — [`features/README.md`](features/README.md).
- **Tasks** — `NNN-short-kebab-title.md` (or a folder `NNN-name/spec.md` for
  multi-file tasks). Numbers are monotonic and not reused. Historical/superseded specs are
  demoted here as well.
- **The `F` index** — old feature specs (from before the move to Spec Kit) were moved to `tasks/`
  as `NNNF-name/` keeping their number: `003F-home-screen/spec.md`. `F` resolves
  collisions with tasks of the same number (`003-revoke-ux.md`); the reference `§003F` means
  the old feature, `§003` — the task. New tasks **do not get** the `F` index. The index of
  old features — [`tasks/F-INDEX.md`](tasks/F-INDEX.md).
- Free numbers (for example 001, 002, 004, 005, 013, 039, 041 after the §054 spec reorg) **are not reused** — this is normal, archive links are preserved. See [`tasks/054-spec-reorg-features-vs-tasks.md`](tasks/054-spec-reorg-features-vs-tasks.md).
- A task starts with a header: context, goals and non-goals, related features/functions.

## Documentation update map

Every spec (feature or task) **must explicitly list** which of these files
are updated together with the code. The spec section is `## Docs to update` or equivalent,
with a list of specific entries of what goes where.

| File | When it is updated |
|---|---|
| [`docs/api/debug-api-reference.md`](../api/debug-api-reference.md) | Any change to Debug API endpoints (new routes, changed query params, semantic shift). Required — bash examples of use cases. |
| [`CHANGELOG.md`](../../CHANGELOG.md) | Any user-visible or public-API change. An entry in the `Unreleased` section (moved later on the version bump). |
| [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) | Structural changes: new data flows, contracts between modules, new subsystems / directories. Optional for a cosmetic refactor. |
| [`RELEASE_NOTES.md`](../../RELEASE_NOTES.md) + [`docs/releases/vX.Y.Z.md`](../releases/) | On a version bump. The entry — what the user will see in the new release. |
| [`pubspec.yaml`](../../app/pubspec.yaml) `version:` | On a version bump. Patch (1.6.0 → 1.6.1) for a fix/small feature, minor (1.6.0 → 1.7.0) for a large one. |
| [`docs/DEVELOPMENT_REPORT.md`](../DEVELOPMENT_REPORT.md) | As significant changes accumulate (optional, for a long narrative across development cycles). |

**Rule:** the implementation phase of a spec **is not considered complete** until the corresponding docs updates are done. If a spec is only planned and is not in the release scope — `## Docs to update` is marked `[deferred till release]`.

For small tasks (typo fix, trivial refactor) the docs update may be `none` — but this **is stated explicitly**, not silently.
