# L×Box development guide

Short rules for working on the code. Anything covered by another document is a
link, not a copy.

| Topic | Source of truth |
|-------|-----------------|
| Git, branches, commits, UI language, testing policy, sub-agent brief | [`AGENTS.md`](../AGENTS.md) |
| Architecture, config pipeline, detour, module map | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| Sanitiser/guard registry | [`GUARDS.md`](GUARDS.md) |
| Storage format, NodeLink | [`STORAGE.md`](STORAGE.md) |
| `wizard_template.json` | [`TEMPLATE.md`](TEMPLATE.md) |
| Localization | [`l10n.md`](l10n.md) |
| Build, signing, CI jobs, worktree bootstrap | [`BUILD.md`](BUILD.md) |
| Core (libbox fork), version bumps | [`KERNEL.md`](KERNEL.md) |
| Release, versioning, tags | [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md) |
| Launcher contract | [`docs/contract`](contract/), `AGENTS.md` → SPEC 103 |

---

## The development process

### 1. Spec first

- Before code: `docs/spec/features/NNN name/spec.md` — even for small features.
- A feature spec = status, context, implementation, files, acceptance criteria.
- Bugs with a non-trivial cause, perf passes, refactors, one-off work:
  `docs/spec/tasks/NNN-title.md`, template and criteria in
  [`docs/spec/tasks/README.md`](spec/tasks/README.md).
- Features describe a capability; tasks log one work cycle.
- Index of live features: [`docs/spec/features/README.md`](spec/features/README.md).
  Demoted/superseded specs live in `docs/spec/tasks/` (§054).

### 2. Commits

- One commit = one logical unit; prefixes `feat:` `fix:` `refactor:` `docs:` `ci:` `release:`.
- When and what to commit/push — `AGENTS.md`.

### 3. Build and release

- Local build: `./scripts/build-local-apk.sh`; details — `BUILD.md`.
- Release, version in `pubspec.yaml`, build code from `scripts/version-code.sh`
  (never by hand) — `RELEASE_PROCESS.md`.

---

## Architectural principles

### Defaults live in the template

- Every baseline value comes from `app/assets/wizard_template.json` — never a
  hardcoded default in Dart. Sections and semantics — `TEMPLATE.md`.
- User overrides go to storage through `SettingsStorage` (`STORAGE.md`).

### Saving settings

- Complex forms (many interdependent fields) get an explicit Save in the action
  bar plus a `PopScope` back-guard with Save / Keep editing / Discard.
  Examples: `custom_rule_edit_screen.dart`, `direction_edit_screen.dart`,
  `chain_edit_screen.dart`, `dns_server_edit_screen.dart`.

### Offline-first

- Subscriptions are cached on disk; the config is rebuilt from cache without network.
- Network is needed only for fetching subscriptions, remote SRS and the speed test.
- `buildConfig` never fetches subscriptions over HTTP — that is `AutoUpdater` (spec 027).

### Config pipeline and detour

- `buildConfig` stages, post-steps, validator — `ARCHITECTURE.md`.
- Detour servers, `DetourPolicy` (register / use / override) — spec
  [018](spec/features/018%20detour%20server%20management/spec.md),
  `app/lib/services/builder/server_list_build.dart`; `overrideDetour` is a
  NodeLink since §439 — `STORAGE.md`.

### Interface language

- UI text is English only, through `getLocalText.s("English text")`; the English
  string is the key (§285).
- A hardcoded literal in a display position fails `hardcoded_check`.
- Translations: `assets/l10n/<tag>/ui.json`; everything else — `l10n.md`.
- Docs are English; code comments, commits and chat may be Russian.

---

## Testing

### Where the tests run

Owner's decision, 2026-09-18 (policy — `AGENTS.md`).

- A full `flutter test` is **never** run locally — not while working, not before
  a commit, not in release pre-flight. CI's `checks` job runs it on every push to
  `develop` and on every tag.
- Locally before a commit:
  - `cd app && flutter analyze` — the whole project, **no path argument**
    (narrowing to `lib/ test/` lets through errors CI will catch);
  - `flutter test` on the test files this task wrote or changed, plus cases that
    bear directly on the change. Not a whole `test/` directory, not the whole
    contract corpus, not all goldens.
- Checkers (`tool/l10n/*_check.dart`, `tool/docs/parity_check.dart`,
  `tool/check_contract_lock.dart`) are not required locally — the same `checks`
  job runs them on CI (owner's decision, 2026-09-24; ui + hardcoded take about a
  minute locally). One exception: a task that edits UI strings or the template
  runs the one relevant checker (`hardcoded_check` / `template_check`) once
  before the commit, through the Sonnet grepper. A red checker on CI is fixed as
  its own commit, like a red test.
- After a push the CI verdict is mandatory: find the run by `head_sha` and read it
  through the API:
  ```bash
  gh api "repos/Leadaxe/LxBox/actions/runs?head_sha=$(git rev-parse HEAD)" \
    -q '.workflow_runs[] | "\(.id) \(.status) \(.conclusion)"'
  gh api repos/Leadaxe/LxBox/actions/runs/<id> -q '"\(.status) \(.conclusion) \(.head_sha)"'
  ```
- `gh run list` / `gh run watch` return stale runs — do not trust them.
- Red CI is fixed at once, as its own commit.
- With several agents: the executor pushes and does not wait; a separate on-duty
  agent watches CI; the next task starts without waiting.
- ⚠ `app/contract/` is gitignored and absent on CI. A test reading it without an
  `existsSync` gate is green locally and red on CI. Tests that need the registry
  read the committed mirror `app/assets/contract`.
- ⚠ A fresh git worktree lacks gitignored artifacts (libbox AAR, signing,
  `app/contract/`): run `./tool/worktree_bootstrap.sh` from the repo root before
  APK builds or corpus tests (`BUILD.md` → “Git worktree bootstrap”).
  `bash app/tool/sync_contract.sh` restores `app/contract/` from the lock; a bump
  needs `--to <sha>` or `LX_CONTRACT_SRC`.
- Test tree mirrors `lib/` by area (models, parser, builder, subscription,
  contract, …); the case count is in the CI log.

### Who reads the test and linter output

Owner's decision, 2026-09-24.

- Raw output of `flutter test`, `flutter analyze`, the checkers and CI logs is not
  read by the reasoning agent (Fable/Opus).
- A cheap sub-agent (Sonnet, low effort) runs the command, greps it and hands up a
  digest: green/red, failing tests/issues with file:line, the first stack trace of
  each failure, counts.
- The reasoning agent decides on fix / redo / commit; diagnosis is its job.
- Minimal set at every step: one test file while iterating, the task's own files
  before a commit; big suites only on CI, read by the on-duty agent by `head_sha`.
- Every executor brief states it explicitly: “tests and analyze run through a
  Sonnet sub-agent; only the digest goes into context”.

### Manual smoke on a device (before a release)

- Clean install → add a subscription → Start → traffic flows.
- Update over the same signature → settings survive.
- Offline launch → config built from cache.
- All subscriptions disabled → Start → no crash.
- Speed test with VPN on → result above 0.
- DNS servers changed → restart → names resolve.

---

## Critical risks

- **Missing outbound reference crashes the core.** sing-box checks at start that
  every referenced outbound exists; the error names the *referrer*, not the
  culprit. Any new path that emits an outbound, group or reference must be checked
  against [`GUARDS.md` → layer 4](GUARDS.md#layer-4--config-assembly).
  Test: disable every subscription → Start → no crash.
- **No Clash API (§122).** `experimental.clash_api` in the config is a fatal start
  error; control and streams go through libbox CommandClient. Keep the three CC
  clients (status / screen / profiler) separate; push to an `EventSink` only from
  the main thread, one native sink per channel, fan-out via broadcast.
- **VPN permission.** A refusal or revoke arrives as `onRevoke` — handle it.
- **Signatures.** Debug and release APKs are signed differently: `adb install -r`
  fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`; `adb uninstall` wipes settings.
- **`local.properties` `sdk.dir`** is rewritten by Flutter on every run — set
  `ANDROID_HOME` / `ANDROID_SDK_ROOT` in the shell profile.

---

## Dependencies

- Core: `sing-box-lx` fork, pin in `app/android/libbox.version`, AAR via
  `scripts/fetch-libbox.sh` — bump procedure in `KERNEL.md`; after a bump test
  start/stop and the CommandClient streams.
- Flutter: pin in `app/android/flutter.version` (CI reads it).
- Gradle: wrapper; AGP: `app/android/settings.gradle.kts`; JDK 17 in `ci.yml`.

---

## AI assistants

- `app/CLAUDE.md` is gitignored: each developer/agent keeps a local copy
  (generate with `/init` if missing). Shared rules live in `AGENTS.md`.
