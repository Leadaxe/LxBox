[English](registry-sync-and-guards.md) · [Русский](registry-sync-and-guards.ru.md)

# Registry sync and guards — the contract as a delivery that cannot drift silently

The registry is a versioned delivery from the launcher repository: one script copies it, one lock
file pins it, two mirrors ship it, and a set of guards fails the build when any of them disagree.

| Field | Value |
|------|----------|
| Feature | [025-CONTRACT_REGISTRY](../FEATURE.md) |
| Promises | P15 P16 P17 P18 P19 |
| State | ✅ written from code, 2026-09-29 |

## What it does

Makes "which contract does this build execute" a fact that can be read from the tree and checked
by CI, and makes a hand edit of any copy impossible to miss. The source of the contract is the
launcher repository (`contract/`); the app holds copies only.

## Parameters

| Place | What it is | In git |
|---|---|---|
| launcher repo, `contract/` | the source; every edit goes there | no (foreign repo) |
| `app/contract/` | vendored copy: registry, schema, docs, corpus | no (gitignored) |
| `app/contract.lock` | `source`, `launcher_repo`, `source_sha`, `synced_at`, `sha256` of the copy | yes |
| `app/assets/contract/` | mirror shipped in the APK: `VERSION`, `registry/*.json`, `registry/protocols/*.json` | yes |
| `docs/contract/` | byte-for-byte mirror of the generated pages (`index.md`, `warnings.md`, `protocols/*.md`) + a generated `README.md` with version, hash and date | yes |

Current state: contract `1.1.99`, `source_sha 6d53d58a`, synced `2026-09-27T22:22:09Z`,
`sha256 388251fc…`.

`app/tool/sync_contract.sh` modes:

| Call | Mode | Effect |
|---|---|---|
| no arguments | restore | rebuilds `app/contract/` from the launcher commit in the lock and checks its hash; mirrors and lock untouched |
| `--to <sha>` | bump | copies that launcher commit, rewrites the lock and both mirrors |
| `LX_CONTRACT_SRC=<path>` | bump | the same from a working directory of the launcher |

## Inputs / Outputs

**Inputs:** a launcher commit or directory; the lock; the tree on disk.
**Outputs:** the copy, the lock, the two mirrors; guard verdicts in CI and in the local test run.

## Rules and invariants

- **The tree hash is over file contents** in byte order of paths (names are not hashed); the
  lock checker computes it the same way as the script.
- **Restore is safe by default**: without arguments the script never pulls the launcher's working
  tree; a bump is explicit.
- **The mirrors are rebuilt only by a bump**; a hand edit differs from the copy and fails the lock
  check, and is overwritten on the next sync.
- **The build works without the launcher repo**: CI and F-Droid have no copy; the APK reads the
  committed mirror, so registry tests must run green on the mirror alone.

| Guard | What it catches | Where it runs |
|---|---|---|
| Lock check (`check_contract_lock`) | copy ≠ lock hash; app mirror ≠ copy file by file; docs mirror ≠ generated pages | CI step "Contract lock" (no copy on CI — reports and passes); locally with the copy |
| Registry tests ([486](../../../tasks/486-ci-registry-tests.md)) | a dictionary in code diverged from the registry: uTLS fingerprints, backup codes both ways, limits; body schemas load and expand; texts of all codes filled | CI, on the mirror, not skipped |
| Docs-mirror test | a code without an anchor in `warnings.md`; the mirror README naming another version | CI |
| dart-refs guard ([491](../../../tasks/491-registry-dart-refs.md)) | `refs.dart` in registry records pointing to a deleted file; stale ones only from an allowlist that fails when an entry becomes valid again | CI |
| Round-trip guard (476) | a registry field the model silently drops | CI |
| Corpus skip guard | lists the corpus suites skipped for lack of the copy; asserts the mirror exists | CI (loud skip, green) |
| Conformance corpus (`contract/corpus/**`, [529](../../../tasks/529-contract-corpus-local-reds-triage.md)) | shared behaviour diverged from the launcher: URI cases, subscription bodies, backups, templates, per-scheme pipeline invariants | local only, with the copy |
| Public subscriptions corpus ([525](../../../tasks/525-public-subscriptions-corpus.md)) | parse numbers drifted from the reference on 68 real lists | separate non-blocking CI job |

- A new scheme, body form or template construct is added **together with a corpus fixture**;
  otherwise the other side learns about it from a user.
- Feedback to the launcher: missing corpus expectations and registry divergences go back as
  requests (529, the dart-refs allowlist note).

## Boundaries

- The core pin, AAR delivery and the core acceptance ritual (where the sync is step 2) —
  [021-CORE_CONTRACT](../../021-CORE_CONTRACT/FEATURE.md).
- CI jobs and release checks — [023-BUILD_CI_RELEASE](../../023-BUILD_CI_RELEASE/FEATURE.md);
  a fresh worktree has neither the AAR nor the copy.
- The contract process as a whole — `docs/CONTRACT.md`; the generated pages — `docs/contract/`.
- The corpus does not run on CI; its red cases are visible locally only.

## Revisions

| # | Revision | Status | Summary |
|---|---------|--------|------|
| 1 | [443](../../../tasks/443-contract-1-0-2-spec129.md) | Released v2.24.0 | Contract 1.0.2, the vendored copy and the lock |
| 2 | [460F](../../../tasks/460F-contract-registry-bundle/spec.md) | Released v2.25.0 | Registry mirror in the APK; W2b — the documentation mirror |
| 3 | [464](../../../tasks/464-contract-w2d-sync.md) · [467](../../../tasks/467-contract-111-sync.md) · [493](../../../tasks/493-contract-sync-11146.md) · [514](../../../tasks/514-contract-sync-11152.md) · [533](../../../tasks/533-contract-1-1-53-sync-overlays-body-runner.md) | Released / Done | contract syncs 1.1.0 → 1.1.53 |
| 4 | [476](../../../tasks/476-body-fields-roundtrip-guard.md) | Released v2.25.0 | Round-trip guard over every registry field |
| 5 | [486](../../../tasks/486-ci-registry-tests.md) | Released v2.25.0 | Registry tests on CI, safe `sync_contract` (restore by default) |
| 6 | [487](../../../tasks/487-worktree-bootstrap.md) | Released v2.25.0 | Worktree bootstrap restores the copy from the lock |
| 7 | [491](../../../tasks/491-registry-dart-refs.md) | Released v2.25.0 | dart-refs guard and the report for the launcher |
| 8 | [525](../../../tasks/525-public-subscriptions-corpus.md) | Released v2.25.3 | Public subscriptions corpus as a separate CI job |
| 9 | [529](../../../tasks/529-contract-corpus-local-reds-triage.md) | In progress | Triage of locally red corpus cases |
| 10 | [566](../../../tasks/566-scheme-literals-outside-dispatcher.md) | Done | Protocol set from the bundle manifest |
