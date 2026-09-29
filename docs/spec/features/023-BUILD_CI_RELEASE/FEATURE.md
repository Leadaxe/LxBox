[English](FEATURE.md) · [Русский](FEATURE.ru.md)

# Build, CI and release — versioning, GitHub Releases, F-Droid and Google Play

LxBox is built by one GitHub Actions workflow and ships each version to GitHub Releases, F-Droid and
Google Play under three incompatible signatures. This page covers the build toolchain, the checks that run
before a merge, how the version and build code are derived from the git tag, and the release ritual. It is a
separate feature because mistakes here are invisible to tests: the version "jitters" in the branch, the build
code overtakes the release, a store receives a candidate — and the one who finds out is a user whose update
will not install.

| Field | Value |
|------|----------|
| Feature | 023-BUILD_CI_RELEASE |
| Type | Process feature (delivery infrastructure) |
| Absorbed | `§021F` |
| Layer | `.github/workflows/ci.yml` (the only workflow), `scripts/version-code.sh`, `scripts/fetch-libbox.sh`, `scripts/build-local-apk.sh` |
| Procedure | [RELEASE_PROCESS.md](../../../RELEASE_PROCESS.md) — the canonical protocol; here the rules, not a copy |
| State | ✅ written from code, 2026-09-29 · releases ship (latest — `v2.25.8`) |

## Principles it protects

1. **The tag is the only source of the version.** The version and the build code
   are computed from the git tag at build time; the code is never raised by hand.
2. **One build-code formula** — only in `scripts/version-code.sh`; CI, the local
   build and the F-Droid recipe call it rather than repeat it. Diverging codes
   break installing one build over another in both directions.
3. **Green CI is the only test gate.** The full test suite is not run locally;
   the verdict is taken by `head_sha` through the API, not from "the latest run".
4. **A candidate never reaches users.** `-rc.N` is only a GitHub pre-release for
   testers: not Latest, not in `docs/latest.json`, not in Play, not in F-Droid.
5. **The build is byte-reproducible**, otherwise F-Droid will not publish the
   release under our signature.

## Registry: CI

One workflow `CI`; concurrent runs on the same branch cancel each other.

| Event | What runs |
|---------|-----------------|
| push of a `vX.Y.Z` / `vX.Y.Z-hotfixN` tag | `meta` → `checks` → `android` → `release` + `google-play` + `publish-manifest` |
| push of a `vX.Y.Z-rc.N` tag | the same, but `release` is a pre-release; `google-play` and `publish-manifest` are skipped |
| push to `develop` / `main`, PR into them | `checks` + `PublicSubsCorpus` |
| `workflow_dispatch`, `run_mode=checks` | `checks` (with `test_path` / `test_name` — a pinpoint run without analyze) |
| `workflow_dispatch`, `run_mode=build` | + `android`: APKs in artifacts, version `X.Y.Z-dev.N` from the last tag |
| `workflow_dispatch`, `run_mode=release` | a full release; fails if HEAD is not exactly on a tag (emergency re-issue) |

| Job | What it does | Rule |
|-----|------------|---------|
| `meta` | version from the tag; pre-release flag by the `-rc.N` suffix | there are no suffixes besides `rc.N`/`hotfixN` — the formula fails on an unknown one |
| `checks` | `flutter analyze` of the whole project; the guard "pubspec in develop is a placeholder"; L10n checkers (template, UI, hardcoded literals, Kotlin); RU/EN docs parity; fastlane changelog ≤ 500 characters; contract lock check; `flutter test` | a red `checks` is fixed at once in its own commit |
| `PublicSubsCorpus` | parsing of the public subscriptions corpus (no core, no network), report as an artifact | `continue-on-error`: the reference is updated by a human |
| `android` | core fetch by the pin; version and base code into pubspec; signing from secrets; **four APKs** in separate runs (universal, `armeabi-v7a`, `arm64-v8a`, `x86_64`) with the core's native libraries narrowed; AAB | `--split-per-abi` is not used; `LXBOX_DISTRIBUTION=play` — **only** on the AAB |
| `release` | GitHub Release: `LxBox-vX.Y.Z-{arm64-v8a,armeabi-v7a,x86_64,universal}.apk`, body — `RELEASE_NOTES.md` | does not depend on `google-play` |
| `google-play` | AAB to the Play Console; "what's new" — from the fastlane changelogs (`en-US`, `ru` → `ru-RU`) | without the `PLAY_SERVICE_ACCOUNT_JSON` secret — a warning and a skip; track `PLAY_TRACK` (default `production`), status `PLAY_RELEASE_STATUS` (default `draft` — a human presses Publish) |
| `publish-manifest` | rewrites `docs/latest.json` in `main` with a `[skip ci]` bot commit | the only automatic commit in `main` |

## Registry: version and build code

```
versionCode = ((major × 10000 + minor × 100 + patch) × 100 + PRE) × 10 + ABI
PRE: 01–49 = -rc.N · 50 = release · 51–98 = -hotfixN      ABI: 0 universal · 1 armeabi-v7a · 2 arm64-v8a · 4 x86_64
```

- The default number is **the next patch**; minor/major — only by the owner's decision.
- In `develop` the pubspec `version:` is a placeholder (`-dev.N`, historically
  `0.0.0`); the real version is committed **once**, in the merge commit into
  `main`, and the tag goes on it: F-Droid reads the version from the sources at
  the tag's commit.
- A dev build (local and `run_mode=build`) gets the version `X.Y.Z-dev.N` and
  **the code of its last tag** — the release and the dev build install over
  each other. Without tags — the `0.0.0` fallback.
- The AAB carries the universal code (ABI=0); Play builds the per-ABI codes itself.
- At runtime the version is read from the APK manifest; the update check is silent on `-dev`.

## Registry: delivery channels

| Channel | How it gets there | Signature | Who updates |
|-------|--------------|---------|---------------|
| GitHub Releases | the `release` job on a tag | our key (the `ANDROID_*` secrets; without them — the runner's temporary key, which does not install over) | the user, from the app's notice |
| F-Droid | the catalogue sees the tag itself (`UpdateCheckMode: Tags ^v\d+\.\d+\.\d+(-hotfix\d+)?$`), builds from source at the tag's commit, including the fork core and `libcronet`, compares byte for byte with the APK from GitHub | **ours** (reproducible build, `Binaries` + `AllowedAPKSigningKeys` — irreversible) | the F-Droid client |
| Google Play | the `google-play` job, AAB signed with the upload key | Google's key (Play App Signing) | Play |

- An APK from one channel **will not install** over another; the app knows its
  channel and points the update notice at its own store (§390).
- The build code in the F-Droid recipe: `UpdateCheckData` reads the ABI=0 code
  from pubspec, `VercodeOperation` adds `+1`, `+2`, `+4` per block. The recipe
  reads toolchain versions from the sources (`flutter.version`, the core's
  `go.version`, `libbox.version`).
- Fastlane (descriptions, screenshots, changelogs) is read **from the tag's
  commit**: a changelog added after the tag never reaches the catalogue.
- Reproducibility rests on a fixed build path, build-id disabled on native
  libraries and dependency metadata switched off in the APK.
- `docs/latest.json` is the update-check fallback when the GitHub API has hit
  its limit: `tag`, `name`, `published_at`, `html_url`, `apk_url` (universal),
  `apk_urls` per ABI, `min_supported` — see [020-APP_SHELL](../020-APP_SHELL/FEATURE.md).

## Registry: platform and toolchain

| Parameter | Value |
|----------|----------|
| minSdk | **24** (Android 7.0) — Flutter's floor; lowered from 26 in §233 |
| targetSdk / compileSdk / NDK | from the Flutter plugin (`flutter.*`) |
| JVM | Java 17 (set in `ci.yml`) |
| Flutter | `3.47.1` — `app/android/flutter.version`, CI reads the file |
| Core | pin `app/android/libbox.version` — see [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) |

| Support tier | Android | Status |
|-------------------|---------|--------|
| Primary | 11+ (API 30+) | tested, everything works |
| Best-effort | 7.0–10 (API 24–29) | builds, installs, basic VPN should work; on ≤ 11 rendering is switched to Skia (§131) |
| Unsupported | < 7 | installation is blocked |

Android TV is best-effort (§372): the manifest is compatible, there is no separate interface.

## Release ritual rules

- **Pre-flight:** the core is the fork, not stock (the AAR from the pin, the
  fetch step in CI); a green `checks` on the head of `develop` by `head_sha`;
  `develop` is a descendant of the previous stable tag; the docs are in sync
  (CHANGELOG, README, task statuses).
- **Notes** are always bilingual, both versions complete, each in its own
  spoiler; a copy in `docs/releases/vX.Y.Z.md`; fastlane changelogs for the
  `armeabi-v7a` and `arm64-v8a` codes, ≤ 500 characters — **in the release commit**.
- **CHANGELOG** — the Keep a Changelog format, `[Unreleased]` on top, entries
  linking to tasks.
- **The merge into `main` is two-step** (`--no-commit`, then `commit -m`); the
  tag is set by a separate command. `--no-ff -m` fails on "empty commit message", and
  the tag lands on the old commit.
- **Post-flight:** bring `main` back into `develop` at once, **reverting
  pubspec** before the commit; otherwise the `checks` guard goes red.
- **Verification:** the release is Latest (an rc is a pre-release);
  `docs/latest.json` is on the new tag; the app's links to documents in `main`
  return 200; the core version in the APK carries the `-lx` suffix and equals
  the pin at the tag; on the previous version the notice appears (at startup only).
- Force-push, `main`, tags and `gh pr create` — only on the operator's explicit command.

## Revision tasks

| # | Revision | Status | Gist |
|---|---------|--------|------|
| 1 | [021F](../../tasks/021F-ci-cd-pipeline/spec.md) | Implemented | the original CI/CD: checks, build, release on a tag |
| 2 | [065](../../tasks/065-version-from-tag.md) | Done (v1.8.2) | version from the tag, no manual bumps |
| 3 | [066](../../tasks/066-pubspec-sync-hook.md) | Released v1.9.0 | pre-commit pubspec sync hook — **removed in v2.11.x** |
| 4 | [125](../../tasks/125-local-versioncode-split-per-abi.md) | Implemented | local code vs the release split-per-abi — superseded by §379 |
| 5 | [186](../../tasks/186-local-build-vc-pin-to-tag.md) | ✅ | a dev build does not overtake the release by code |
| 6 | [233](../../tasks/233-minsdk-24.md) | — | minSdk 26 → 24 |
| 7 | [379](../../tasks/379-version-code-from-version.md) | Implemented (v2.20.0) | code from the version, `--split-per-abi` dropped, real version on the merge into `main` |
| 8 | [390](../../tasks/390-install-source-aware-update-notice.md) | Done | install channel, the define only on the AAB |
| 9 | [436](../../tasks/436-google-play-upload-ci.md) | In progress | AAB upload to Play from CI, rc is not published |
| 10 | [486](../../tasks/486-ci-registry-tests.md) | Released v2.25.0 | registry tests are not skipped on CI |

## Watch for

- **Stale CI descriptions:** 021F (a draft release, a single APK
  `L×Box-vX.Y.Z.apk`, push to `main` only); the CI table in BUILD.md without
  `google-play`, `PublicSubsCorpus` and the rc rules; "Versions" in BUILD.md
  names the core `v1.14.0-lx.28-rc.1` while the pin is `v1.14.2-lx.8`.
- **A contradiction about the F-Droid signature:** RELEASE_PROCESS.md says
  "F-Droid's key", FDROID.md — our APK is published under our signature.
- **A contradiction about the Play channel:** GOOGLE_PLAY.md says "without a
  build-time define", but in fact the AAB is built with
  `LXBOX_DISTRIBUTION=play`, and the app reads it.
- **The RELEASE_PROCESS.md checklist** requires "`gh run watch` is green", while
  the same document and DEVELOPMENT_GUIDE forbid trusting `gh run watch`.
- **Play lags behind GitHub** with the `draft` status (the v2.25.8 notes: Play
  last shipped v2.25.5); §436 is still In progress — check the actual value of
  `PLAY_RELEASE_STATUS` in the repository settings.
- `(?m)^version:` in the F-Droid regexes is not anchored yet (a commented-out
  line in pubspec could match first); the status of the MR with `'%c + 4'` in
  FDROID.md may be stale.
- The contract lock check on CI compares only what is there: there is no
  contract copy on CI — see [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md).

## Related features

- [020-APP_SHELL](../020-APP_SHELL/FEATURE.md) — the update check reads
  Releases and `docs/latest.json`, the link leads to the store of its own
  channel, `-dev` is silent.
- [021-CORE_CONTRACT](../021-CORE_CONTRACT/FEATURE.md) — the core pin, AAR fetch, contract check in `checks`.
- [022-ARCHITECTURE](../022-ARCHITECTURE/FEATURE.md) — rules CI checks
  automatically (analyze, English UI, tests only on CI).
- [013-DIAGNOSTICS](../013-DIAGNOSTICS/FEATURE.md) — the app and core version
  in the dump as a check of the release APK.
- [027-DEBUG_API](../027-DEBUG_API/FEATURE.md) — the app and core version in
  `/device` as a check of the release APK.

## Maintenance notes

- A fresh worktree has no core AAR, no signing and no contract copy:
  `./tool/worktree_bootstrap.sh` before building an APK or running corpus
  tests; without the key the APK gets a debug signature and will not install
  over production.
- Debug and release APKs are signed differently: `install -r` between them
  fails, `uninstall` wipes the settings.
- Re-issuing a tag: if CI failed before the release was created — delete the
  tag, fix and repeat with the same number (safe); if the release is
  published — a last resort: delete the release and the tag, `docs/latest.json`
  may need a manual rollback; a bad APK already downloaded is cured only by the
  next patch (RELEASE_PROCESS §3).
