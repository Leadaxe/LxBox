# Building L×Box

**Symbols used in this file**

| Symbol | Meaning |
|--------|--------|
| ✓ | Present / happens by default |
| ○ | Optional, or only when explicitly enabled |
| ✗ | Absent / not done by default |
| ⚠ | Prohibition or important warning |

---

## The Flutter app

The **`app/`** directory is the L×Box project. Dependencies come from `flutter pub get`. The native VPN lives in `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/` (our own `BoxVpnService`, not a Flutter plugin). libbox on Android is the **[`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)** fork (branch `lx-1.14`): AWG/AWG2 (AmneziaWG) + native XHTTP ([§097](spec/features/097%20awg2-amneziawg2/spec.md)) + MASQUE / idle-suspend / balancer. The AAR is wired in as the file `app/android/app/libs/libbox.aar` (a relative `files("libs/libbox.aar")` in `build.gradle`); downloading it and pinning the version is [§104](spec/tasks/104-libbox-fork-ci-fetch.md) — see [“The sing-box-lx core (libbox)”](#the-sing-box-lx-core-libbox). Pin history: stock `com.github.singbox-android:libbox:1.13.11` from JitPack ([task §060](spec/tasks/060-libbox-1-13-migration/spec.md)) ← `io.github.sagernet:libbox:1.12.12`.

Config import via the **Read** button accepts **JSON** or **JSON5/JSONC** (`//` and `/* */` comments — the `json5` parser); canonical JSON is then handed to the core. The source is either the clipboard or the system file picker.

```bash
cd app
flutter pub get
flutter run   # Android device or emulator
```

### Local release build

The script [`scripts/build-local-apk.sh`](../scripts/build-local-apk.sh) is the canonical way to produce a local release APK (minimal, arm64-only):

```bash
./scripts/build-local-apk.sh
```

| What it does | Mark |
|------------|---------|
| Version in pubspec: versionCode **pinned to the latest release tag** (§186, see below); versionName is `X.Y.Z` on a tag, otherwise `X.Y.Z-dev.<since>` | ✓ |
| `scripts/fetch-libbox.sh` — the sing-box-lx core at the pin in `app/android/libbox.version`, idempotent (see [“The sing-box-lx core”](#the-sing-box-lx-core-libbox)) | ✓ |
| `LXBOX_ABI_FILTER=arm64-v8a --target-platform android-arm64` — APK for arm64 only; the resulting `app-release.apk` is renamed to `app-arm64-v8a-release.apk` | ✓ |
| `flutter build apk --release` (extra arguments pass through `"$@"`) | ✓ |
| `--dart-define` **version** markers (`BUILD_LOCAL`, `BUILD_GIT_DESC`, …) | ✗ removed in §065/§066: the version lives in pubspec, About reads `PackageInfo`. This concerns the version only — it is NOT a ban on defines in general, see `LXBOX_DISTRIBUTION` below |
| `--dart-define=LXBOX_DISTRIBUTION` | ✗ not set → the installer-based fallback yields `github`, which is correct for a local build |

##### `--dart-define` flags

| Flag | Values | Who sets it | Why |
|---|---|---|---|
| `LXBOX_DISTRIBUTION` | `github` \| `play` \| `fdroid` | **the CI AAB step only** (`=play`) | §390 — the install channel: where to send the user for a new version. Each channel has its own signature; a GitHub APK will not install over a Play or F-Droid build. Unset → runtime fallback via `installingPackageName`, defaulting to `github` |

⚠ **The flag is NOT set for APKs** — neither in CI nor in the F-Droid recipe.
F-Droid compares the bytes of its own build against the APK from GitHub Releases
(`binary:` in the recipe — reproducible builds, the signature stays ours), and any
`--dart-define` ends up in the compiled Dart and breaks that comparison. For APKs
the channel is determined at runtime from the installer. See
[`FDROID.md`](FDROID.md).

| Flag | Values | Who sets it | Why |
|---|---|---|---|
| `LXBOX_SUPPORT_URL` | URL | manually, while debugging | §356 — point the support feed at a test source |
| `DONATE_URL` | URL | manually | source for `docs/donate.json` |

Requires `git` and a JDK (for Gradle); the script downloads the core `app/android/app/libs/libbox.aar` itself.

##### ⚠ The build hangs (CPU≈0) — memory-starvation stall

`app/android/gradle.properties` sets `org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G …`. On a 16 GB machine the Gradle heap plus metaspace plus the Kotlin/dex workers do not fit, the process starts swapping, and `assembleRelease` hangs at CPU≈0 — a stall, not compilation.

| | |
|---|---|
| Symptom | `flutter build apk` sits on `assembleRelease` for minutes; `ps aux \| grep java` shows the java processes below 5% CPU |
| Fix | free up RAM (close heavy applications), kill the stuck daemon (`pkill -f gradle` or `rm -rf ~/.gradle/daemon`), rebuild with a cap: `GRADLE_OPTS='-Dorg.gradle.jvmargs=-Xmx5G' ./scripts/build-local-apk.sh --no-daemon`, optionally plus `--max-workers=4` |
| Radical | lower `-Xmx` in `gradle.properties` to match the machine's RAM |

#### versionCode — how it is derived, and why it is pinned to the tag ([§186](spec/tasks/186-local-build-vc-pin-to-tag.md))

**Who contributes what** (verified with `aapt dump badging` on a built APK):

| Layer | Value | Who |
|------|----------|-----|
| `pubspec.yaml` `version: X.Y.Z+<code>` | code = `((major×10000 + minor×100 + patch)×100 + PRE)×10 + ABI` (§379) | computed by [`scripts/version-code.sh`](../scripts/version-code.sh), written by CI and by the local script |
| Flutter's ABI multiplier | **not applied** — `--split-per-abi` was removed (§379); otherwise it would multiply our number by `ABI×1000` on top | — |
| Final value in the APK manifest | exactly what pubspec says | — |

⚠ Bumping `versionCode` by hand is unnecessary and must NOT be done — the code is derived deterministically from the version. Verified on an APK: `v2.19.7` + arm64 → `21907502`.

**Why pin to the tag and not to HEAD:** the release CI builds on the tag's commit. A local build on a development branch has moved ahead, but the versionCode is computed from the **tag name**, and the formula strips the `-dev.N` tail — so the local arm64 versionCode equals the release one exactly. With equal codes `adb install -r` works in both directions (only a strictly lower code is blocked).

| Case | versionCode | Behaviour |
|--------|-------------|-----------|
| The branch has a tag `vN.N.N` | that tag's code for arm64 | local code = release code → the release installs over the local build and vice versa |
| No tag at all | code derived from `0.0.0` → `502` (fallback, `version: 0.0.0+502`) | the downgrade risk does not apply without releases |
| After a NEW release (new tag) | follows the new tag automatically | self-maintaining |

## The sing-box-lx core (libbox)

Since §097 the app's core has been the **[`Leadaxe/sing-box-lx`](https://github.com/Leadaxe/sing-box-lx)** fork (branch `lx-1.14`), not stock sing-box.

| What | Mark |
|-----|---------|
| AWG/AWG2 (AmneziaWG) fields in the `wireguard` endpoint | ✓ build tag `with_awg` |
| Native `type:"xhttp"` transport (Xray splithttp) | ✓ build tag `with_xhttp` |
| A release on stock `com.github.singbox-android:libbox:1.13.11` | ⚠ **impossible** — the stock core rejects configs carrying AWG fields and `xhttp` |

The fork publishes artifacts in its own GitHub Releases (workflow `lx-release.yml`):

| Artifact | Mark |
|----------|---------|
| `libbox-<ver>.aar` (modern: minSdk 23, 4 ABIs, ~110 MB as of lx.25) | ✓ the one we use |
| `libbox-legacy-<ver>.aar` (minSdk 21) | ✗ unused — our minSdk is 24, so the modern AAR (minSdk 23) is enough |
| `SHA256SUMS` | ✓ verification of the downloaded AAR |

The core version is reported by `Libbox.version()` (About/Debug) in the form `1.14.0-lx.N`; the current pin is `v1.14.0-lx.27-rc.1`.

### How the core reaches the build ([§104](spec/tasks/104-libbox-fork-ci-fetch.md))

`app/android/app/libs/` is in `.gitignore` (the AAR is ~110 MB and is not committed); `app/android/app/build.gradle.kts` wires the core in as a file:

```kotlin
implementation(files("libs/libbox.aar"))
```

[`scripts/fetch-libbox.sh`](../scripts/fetch-libbox.sh) puts the AAR in place: it downloads `libbox-<ver>.aar` plus `SHA256SUMS` from the fork's GitHub Releases, checks the hash, and writes the marker `.libbox.version` (re-running the same version is a no-op). The version pin is the file **`app/android/libbox.version`**, the single source of truth for both local builds and CI:

| Who calls fetch | Mark |
|--------------------|---------|
| `scripts/build-local-apk.sh` (local build) | ✓ automatically |
| `ci.yml` → job `android` → step `Fetch sing-box-lx core (libbox.aar)` | ✓ automatically |
| By hand (fresh clone, `flutter build` without the script): `./scripts/fetch-libbox.sh`; version override: `./scripts/fetch-libbox.sh v1.14.0-lx.N` | ○ |

The `checks` job does not need the AAR (`flutter analyze` / `test` are pure Dart).

Rejected alternatives for delivering the core to CI:

| Option | Mark |
|---------|---------|
| **Download from the fork's GH Releases + `files("libs/libbox.aar")`** | ✓ **the chosen path**: the repo is public (curl without a token), `SHA256SUMS` verification, pinned by the single file `libbox.version` |
| JitPack (`com.github.Leadaxe.sing-box-lx:libbox:<tag>`) | ✗ JitPack builds from source — `gomobile bind` (Go + NDK) does not work on its builders, and it will not serve prebuilt AARs from Releases |
| GitHub Packages (Maven) | ✗ requires a token even for public packages (in every clone and in CI), plus a separate maven-publish step in the fork's `lx-release.yml` |

- ⚠ Updating the core means raising the pin in `app/android/libbox.version`, rebuilding locally (fetch re-downloads the AAR on its own), running the smoke tests (Start/Stop, vless + wg + awg regression) and updating the [“Versions”](#versions) section.

## A minimal config for testing on a phone

The file **[`docs/examples/minimal_local_test.json`](examples/minimal_local_test.json)** is valid sing-box JSON: just **tun** plus **direct/block** in the selector, with no paid or third-party proxy. It is enough to confirm that **Read → Start** brings the tunnel up and that the **proxy** group with the **direct** / **block** nodes appears in the UI. The internet keeps working as usual through direct — this is not a bypass.

⚠ The core is controlled through the **libbox CommandClient**, not Clash HTTP (the Clash API was removed in §122). An `experimental.clash_api` block in a config is a **fatal startup failure** on our core (built without `with_clash_api`): `clash api is not included in this build`. Do not put it in a config you intend to test.

## CI (GitHub Actions)

Workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml); the full release protocol is in [RELEASE_PROCESS.md](RELEASE_PROCESS.md).

| Event | What runs |
|---------|-----------------|
| push / PR to `main`, `develop` | ✓ `checks` only (`flutter analyze`, L10n checks, `flutter test`) — no Java or Gradle |
| push of a `v*` tag | ✓ `meta` + `checks` + `android` + `release` + `publish-manifest` (a full release) |
| `workflow_dispatch`, `run_mode=checks` | ○ `checks` only |
| `workflow_dispatch`, `run_mode=build` | ○ `checks` + `android` (APK in artifacts, no release) |
| `workflow_dispatch`, `run_mode=release` | ○ a full release without a tag (emergency re-issues) |

From the terminal (`gh auth login`):

```bash
gh workflow run CI -f run_mode=checks   # ✓ analyze + test
gh workflow run CI -f run_mode=build    # ○ + APK in artifacts
```

The `android` job builds **release** APKs only: universal (fat, all ABIs) plus three per-ABI ones, one run per target (§379: `--split-per-abi` was removed because it broke the versionCode scheme). CI does not build debug APKs. Before building, the `Fetch sing-box-lx core` step downloads the fork core at the pin in `app/android/libbox.version` (see [“The sing-box-lx core”](#the-sing-box-lx-core-libbox)).

### Localization in the build and in CI (§279 / §285)

- **There is no string codegen** (§285): the UI is localized through natural keys
  (`getLocalText.s/.plural`, the English text *is* the key), and the dictionary is
  `assets/l10n/<tag>/ui.json` (an asset, not codegen). ARB / gen_l10n / `l10n.yaml`
  are gone, and `flutter: generate` was removed from pubspec. A missing translation
  falls back to the English key (under `--strict` that is an `ui_check` failure).
- **The `L10n checks` step** in the `checks` job runs four guard checkers
  ([`app/tool/l10n/README.md`](../app/tool/l10n/README.md)): `ui_check`
  (natural-key dictionary ↔ `getLocalText` call sites in the code:
  missing/orphan/shape/arity), `template_check` (unknown and missing overlay keys
  against the English strings extracted from `wizard_template.json`),
  `hardcoded_check` (a ratchet against new hardcoded display strings, plus
  rendering locality), and `kotlin_check` (native Android literals plus parity
  between `values/strings.xml` and `values-ru/`). All run with `--strict` on every
  push and PR — warnings are fatal.

### Release signing (one key across builds)

| Situation | Mark |
|----------|---------|
| The **`ANDROID_*`** secrets are set in Actions | ✓ the same key across CI builds, so APKs can be updated in place |
| No secrets | ○ the release is signed with the runner's temporary key; installing in place usually **fails** without uninstalling first |

#### Do it all automatically (recommended)

From the root of the cloned repository (needs a **JDK** with `keytool`, **openssl**, and **`gh auth login`**):

```bash
./scripts/bootstrap-android-signing-for-ci.sh
```

| What the script produces | Mark |
|-------------------|---------|
| `app/android/upload-keystore.jks` + `app/android/key.properties` | ✓ created if absent (both in [`.gitignore`](../app/android/.gitignore)) |
| Secrets on GitHub | ✓ uploaded through `gh` |
| The password printed during generation | ○ save it to a password manager (a copy lives in the local `key.properties`) |

Individual steps:

```bash
./scripts/init-android-release-keystore.sh   # ✓ keystore + key.properties only
./scripts/setup-android-ci-secrets.sh          # ✓ gh only (passwords from key.properties)
```

- ○ Override the passwords at keystore creation: `ANDROID_SIGNING_PASSWORD='…' ./scripts/init-android-release-keystore.sh`
- ○ Recreate the key: `FORCE=1 ./scripts/init-android-release-keystore.sh`

#### GitHub secrets (manual setup)

| Secret | Contents | Mark |
|--------|------------|---------|
| `ANDROID_KEYSTORE_BASE64` | `openssl base64 -A -in upload-keystore.jks` (a single line) | ✓ required to use your own signature |
| `ANDROID_KEYSTORE_PASSWORD` | Store password | ✓ |
| `ANDROID_KEY_PASSWORD` | Key password | ✓ |
| `ANDROID_KEY_ALIAS` | Alias (for example `upload`) | ✓ |

By hand through **`gh`** (if you are not using the script above):

```bash
./scripts/setup-android-ci-secrets.sh app/android/upload-keystore.jks
```

- ○ A different repository: `GH_REPO=owner/L×Box ./scripts/setup-android-ci-secrets.sh`

Before `flutter build apk --release` the workflow recreates temporary `app/android/upload-keystore.jks` and `app/android/key.properties` on the runner from the secrets. A local **`flutter build apk --release`** after bootstrap uses those same files in `app/android/`.

- ⚠ Never commit the keystore or the `key.properties` holding secrets.

## Versions

- **Flutter 3.41.6** is pinned in the file `app/android/flutter.version` — CI reads it in the `Flutter version pin` step, so upgrading means editing that file, not the workflow. **JDK 17** is set in `ci.yml` directly; when it changes, update `ci.yml` and this file.
- The core is **sing-box-lx `v1.14.0-lx.27-rc.1`** (fork branch `lx`): pinned in `app/android/libbox.version` (the single source for local builds and CI, read by `scripts/fetch-libbox.sh`); the local `app/android/app/libs/libbox.aar` must match the pin (fetch tracks this through the `.libbox.version` marker). The single source of truth for the core version and its build tags is [KERNEL.md](KERNEL.md) plus the pin file itself. When updating: raise the pin, rebuild locally, run the smoke tests and update this line.
