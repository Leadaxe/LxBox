# The launcher contract

What the launcher contract is and how LxBox works with it. The contract's own
generated documentation (warning codes, registry pages) is mirrored in
[`docs/contract/`](contract/README.md) — this page is about the process, not
the content.

---

## What it is

- Everything **both** apps see — LxBox and the desktop launcher — is described
  in the shared contract **before** it is implemented in code (SPEC 103).
- Why: two parsers that diverge on one subscription give the user a different
  node set on the phone and on the desktop; finding that afterwards costs more
  than describing it up front.
- SPEC 103 is the launcher's spec and lives in the launcher repo (this repo's
  `docs/spec/tasks/103-…` is an unrelated task). The in-repo spec for the
  registry mirror is feature
  [460](spec/features/460%20contract-registry-bundle/spec.md).

## Where it lives

| Place | What it is |
|-------|------------|
| launcher repo, `contract/` | The source. All edits go there. |
| `app/contract/` | Vendored **copy**, written by `app/tool/sync_contract.sh`. Gitignored, read-only — never edited. |
| `app/contract.lock` | sha256 of the copy, written by the same script. |
| `app/assets/contract/` | Committed mirror of the registry — what tests and the app read on CI. |
| `docs/contract/` | Byte-for-byte mirror of the contract's generated docs. Not edited by hand. |

## What is normative

- `registry/**` — protocol dictionaries, allowlists, warning codes, limits,
  variables.
- `schema/**`.
- `docs/**` — PARSING_PRINCIPLES, IDENTITY, TEMPLATE_LANG, BACKUP.
- Code must match them, not the other way round: code is fitted to the
  fixtures, never the fixtures to the code.

## How it is kept honest

- **Sync tests.** Every dictionary is under a sync test
  (`test/contract/registry_sync_test.dart`). A registry without a check is just
  text: the list in code drifts, the registry stays, the sides diverge silently.
- **Shared corpus.** Shared behaviour is covered by `contract/corpus/**`; the
  launcher runs the same fixtures. A new schema, subscription body shape or
  template-language construct is added **together with a fixture** — otherwise
  the other side learns about it from a user.
- **Per-app override.** A deliberate difference is recorded as a per-app
  override with a link to the decision (`IDENTITY.md` §4, `PARSING_PRINCIPLES.md` §7). An
  orphan override is an error.

## Syncing the copy

- Before running **corpus** tests, restore the vendored copy. Registry tests read
  the `app/assets/contract` mirror and are not skipped on CI.

```bash
bash app/tool/sync_contract.sh              # restore app/contract from the lock
bash app/tool/sync_contract.sh --to <sha>   # bump from a launcher commit
LX_CONTRACT_SRC=<path> bash app/tool/sync_contract.sh   # bump from a local checkout
```

- A fresh git worktree lacks `app/contract/` — see
  [`DEVELOPMENT_GUIDE.md`](DEVELOPMENT_GUIDE.md) → “Where the tests run”.

## CI trap

- ⚠ `app/contract/` is gitignored and absent on CI. A test that reads the copy or
  the corpus without an `existsSync` gate is green locally and red on CI.
- Tests that need the registry read the committed mirror `app/assets/contract`.
