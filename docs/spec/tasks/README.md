[English](README.md) · [Русский](README.ru.md)

# Tasks log

A log of completed tasks with reports — for history and reporting.

Unlike `docs/spec/features/NNN/spec.md` (which describes a feature as such — "what it is and how it works"), a tasks file describes **a specific work cycle**: the problem, the diagnosis path, the solution, the risks, the verification criteria.

The format is one markdown file per task:

```
docs/spec/tasks/NNN-short-kebab-title.md
```

Numbers are monotonic and not reused. If a task grows into a feature, a `spec.md` in `features/` appears in addition, and the task stays as a chronicle.

## Old feature specs — the `F` index

Before the move to Spec Kit (modeled on sing-box-lx), the `features/` folder held specs
of the form `NNN name/spec.md` with the implementation inside (files, control flow). By content they are
tasks, so they were moved here **keeping their number** with the `F` index:

```
features/050 libbox-debug-build/   →   tasks/050F-libbox-debug-build/
```

- `F` resolves collisions with tasks of the same number: `003-revoke-ux.md` and
  `003F-home-screen/` are different things; in text, `§003F` is the old feature, `§003` is the task.
- Files inside the folder were not renamed (`spec.md`, `plan.md`, `tasks.md`, …).
- New tasks do not get the `F` index. The current feature description is in
  [`../features/`](../features/README.md); `NNNF` is a source of revisions for it.
- The index of the moved specs — [`F-INDEX.md`](F-INDEX.md) (formerly `features/README.md`).

## Known number collisions

Parallel sessions sometimes take the same number before committing. Where this has already
entered history (links in commits/code/memory are fixed), the number is **not**
renumbered; instead the pair is told apart by an alias suffix in the header of each file:

| # | File | Alias | Summary |
|---|------|-------|---------|
| 128 | [`128-force-direct-out-detour.md`](128-force-direct-out-detour.md) | §128-detour | `detour: direct-out` — won't-fix |
| 128 | [`128-jni-callback-crash-android10.md`](128-jni-callback-crash-android10.md) | §128-jni | defensive try/catch on JNI callbacks (Android 10) |
| 143 | [`143-interrupt-connections-on-node-switch.md`](143-interrupt-connections-on-node-switch.md) | §143-interrupt | dropping connections on node switch |
| 143 | [`143-warp-masquerade-id-ip-ib.md`](143-warp-masquerade-id-ip-ib.md) | §143-warp | WARP core-masquerade `id/ip/ib` |

> §505 — the collision **was resolved by merging**: `505-home-badge-cold-start.md` and
> `505-home-node-badge-user-server.md` described the same defect; task §513
> merged the first into the second ([`505-home-node-badge-user-server.md`](505-home-node-badge-user-server.md)) and deleted it.
>
> §146 — **not** a collision: `146-warp-quic-initial-fragmented-i1.md` + `146-test-vectors/`
> belong to one task (the directory holds hex vectors for it).
>
> §180 — **not** a collision: `180-dns-query-stream.md` (the main task, DNS stream
> SPEC 018) + `180-FEEDBACK-kernel-dns-unimplemented.md` +
> `180-FEEDBACK-2-kernel-dns-processinfo-empty.md` (two pieces of feedback to the core team on
> the same topic) — one pool, not parallel sessions.

**Prevention:** before committing a new task — `git status` + take a genuinely
free number (gap search in `tasks/`), not "the next one in order".

## Report sections

```markdown
# NNN — Task title

| Field | Value |
|-------|-------|
| Status | Done / In progress / Blocked / Abandoned |
| Start date | YYYY-MM-DD |
| End date | YYYY-MM-DD |
| Commits | `sha1 short` + message |
| Related specs | links to features/NNN |

## Problem
What is broken / what is missing. Symptoms, context, user impact.

## Diagnosis
How the root cause was found. Which experiments, which false leads.

## Solution
What was actually done. With references to specific files/lines.

## Risks and edge cases
What can go wrong. What is intentionally **not** covered.

## Verification
How it was verified. Unit / manual / smoke build. Acceptance criteria.

## Unresolved / follow-up
Deferred to separate tasks (stating which).
```

## When to create one

- Any bug with a non-trivial root cause (not "fixed a typo")
- Any refactoring session with architectural consequences
- Any performance pass with measurements
- Release preparation (assemble the changelog + check the migration)

## When NOT to create one

- Trivial fixes (typo, one-to-one replacement, a local edit without side effects)
- Features — they have `features/NNN/spec.md`. But a feature may come with a task "implementation of X for feature Y".
