# Sub-agent brief

For an executor working from a brief (ТЗ). The orchestrator checks every point
at acceptance — a violation means a redo. General rules:
[`DEVELOPMENT_GUIDE.md`](DEVELOPMENT_GUIDE.md); the launcher contract:
[`CONTRACT.md`](CONTRACT.md).

---

## Do not touch

- `app/analysis_options.yaml`, `app/pubspec.lock`, `app/contract.lock`,
  `app/contract/**` (the read-only contract copy: code is fitted to the
  fixtures, not the other way round — `CONTRACT.md`).
- Changes to these files already in the tree belong to someone else and predate
  your session.

## Git

- **In your own worktree** (`.claude/worktrees/…`, the usual case): the
  executor commits.
  - `git add` file by file, only the files of the task; never `git add .` /
    `git add -A`.
  - Before the commit set the author:
    `git config user.email 247031499+Leadaxe@users.noreply.github.com` and
    `git config user.name Leadaxe`.
  - **One** commit to the worktree branch, with the message from the brief.
  - After it, check the author: `git log -1 --format=%ae` must print the
    noreply address above.
  - No `git push`: the orchestrator pushes the branch into `develop`.
  - `git stash` is forbidden: the stash stack is shared by every worktree and
    the main checkout, so a stash or pop can take someone else's work.
- **In the main tree** (no worktree): no `git add` / `git commit` — the
  orchestrator commits by pathspec.

## Checks

- `flutter analyze` baseline = 19 issues, all pre-existing; new ones — 0.
- Run locally only your own test files (`DEVELOPMENT_GUIDE.md` → “Where the
  tests run”); CI runs the full suite. Tests and analyze go through a Sonnet
  sub-agent; only the digest goes into context (“Who reads the test and linter
  output”).
- No red is acceptable in the full run — it is green as a whole (the last former
  exception, `test/contract/backup_corpus_test.dart: directions_created_on_import`,
  was closed by mini-phase B of spec 393). Any red on CI after your push is
  yours.
- After editing UI strings or the template: once before handing over, only the
  checker relevant to the change (`hardcoded_check` or `template_check`) —
  0 failures / 0 warnings. The other checkers are CI's job.

## UI text and l10n

- UI text is English only.
- The Russian catalogue `app/assets/l10n/ru/*` is keyed by the English source:
  changing a string = re-keying plus a translation with correct declension
  (Направление is neuter).

## The word «канал»

- Two worlds: the routing domain was renamed to Direction / Направление.
- IPC (`MethodChannel`, `cc_channel.dart`, `platform_channels.dart`), the
  install channel (§390) and the sing-box term «исходящий канал» (outbound)
  stay channels.
- A blind `sed` is forbidden.

## Tests

- No tests on UI-string formatting.
- Waits in tests go through conditions/events, not a fixed-length
  `Future.delayed`.
