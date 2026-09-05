# Publishing on F-Droid

Related: [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md) — cutting a release,
[`BUILD.md`](BUILD.md) — building the APK.

## How it works

F-Droid does not take the APK from a GitHub Release. Their builder reads
`commit:` from the metadata, clones the repository at that tag and builds
everything itself — including `libbox.aar` from the `Leadaxe/sing-box-lx`
sources.

| What | Where |
|---|---|
| Metadata | `metadata/com.leadaxe.lxbox.yml` in `fdroid/fdroiddata` |
| Fork | `gitlab.com/leadaxe/fdroiddata`, branch `com.leadaxe.lxbox` |
| Request for packaging | [rfp#4218](https://gitlab.com/fdroid/rfp/-/work_items/4218) |
| MR | [fdroiddata!44731](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/44731) |

The GitLab token (scope `api`) lives in `~/.gitlab-token`, mode `600`, outside
the repository. Pass it inline in the push URL once — do **not** bake it into
the `remote`.

## Updating for a new release

Auto-pickup is on: F-Droid reads the version from `app/pubspec.yaml` at the new
tag. A manual MR is only needed when the recipe itself changes.

When editing by hand, each of the three build blocks needs a new `versionName`,
`versionCode` (its own ABI digit) and `commit` (the **full hash**, not the tag),
plus `CurrentVersion` / `CurrentVersionCode` at the bottom of the file. The code
is computed by [`scripts/version-code.sh`](../scripts/version-code.sh):

```bash
scripts/version-code.sh 2.20.4 arm64-v8a   # 22004502
```

Toolchain versions must not be edited — they are read from the sources
(`android/flutter.version`, the core's `go.version`, `android/libbox.version`),
and `srclibs` are pinned by branch. No hardcoded version may remain in the
F-Droid metadata: that is a direct requirement from the reviewer.

Run **both** linters before pushing (`pip install fdroidserver`):

```bash
fdroid lint com.leadaxe.lxbox && fdroid rewritemeta com.leadaxe.lxbox && git diff --quiet metadata/com.leadaxe.lxbox.yml && echo ok
```

`lint` tolerates long lines while `rewritemeta` rewraps them — and that is a
separate job in their CI, which will fail.

Pushing starts their pipeline on its own; there is no separate command. Building
the three ABIs takes **about 3 hours**, and the `fdroid build` log must contain
three `1 build succeeded` lines. Open the MR only after a green run — their
CONTRIBUTING requires it.

## Screenshots and descriptions

Files live in `fastlane/metadata/android/{en-US,ru}/` — **in the repository
root**, not under `app/` (F-Droid does not see them there).

| What | File |
|---|---|
| App title | `title.txt` |
| Short description (≤80 characters) | `short_description.txt` |
| Full description | `full_description.txt` |
| Icon | `images/icon.png` |
| Screenshots | `images/phoneScreenshots/N.png` — the number sets the order |
| Changelog | `changelogs/<versionCode>.txt` |

⚠ **The metadata is read from the release commit, not from the branch.** A
screenshot added to `develop` after the tag will not reach the listing — that
needs a new release. We already got burned by this: v2.19.4 shipped without
screenshots and had to be followed by v2.19.5.

⚠ The changelog filename is the same versionCode as in the metadata. If they do
not match, F-Droid will not show the changelog at all.

⚠ Do not photograph the Servers screen — it holds personal subscriptions. Use
the public ones from `public-servers-manifest.json` for shots.

```bash
adb exec-out screencap -p > shot.png
```

## How the F-Droid build differs

| What | Why |
|---|---|
| `libbox.aar` from source | prebuilt binaries are forbidden; upstream sing-box is packaged the same way |
| `libcronet.a` from source | `cronet-go` ships a prebuilt blob; we build Chromium ourselves and `cmp` the result against it. **~50 minutes per ABI** |
| Three APKs, one per ABI | three build blocks, each with its own `--target-platform` and `LXBOX_ABI_FILTER` |
| The JDK 17 check is stripped | their image is Debian trixie: JDK 21, and there is no `openjdk-17` package |
| The legacy AAR variant is stripped | gomobile needs an SDK platform for each variant |

⚠ **§390: the recipe must NOT carry `--dart-define=LXBOX_DISTRIBUTION`.**

The temptation is understandable — tell the build outright that it is the
F-Droid one. But the blocks carry `binary:` (a byte-for-byte comparison against
the APK from GitHub Releases), and that is exactly what reproducible builds are:
F-Droid ships the app under **our** signature instead of its own. Any
`--dart-define` ends up inside the compiled Dart code — the GitHub APK is built
without the flag, the F-Droid APK would carry it, the bytes diverge and the
comparison fails.

So the channel of an APK is decided at **runtime** from `installingPackageName`:
installed from the F-Droid client → `org.fdroid.fdroid` → `fdroid`; sideloaded
from GitHub → `null` or a browser → `github`. Both branches are correct, and no
flag is needed.

The define survives only for the AAB (Google Play): Play distributes a separate
artifact, which is not compared against `binary:`.

Both core patches are applied by a single `sed` over
`cmd/internal/build_libbox/main.go`.

⚠ **`--target-platform` does NOT filter the core's native code.** It narrows only
the Flutter engine and the Dart AOT snapshot, while the `.so` files from the AAR
(all three ABIs) land in the APK untouched — 31 MB grows to 71 MB without a
filter. Hence `LXBOX_ABI_FILTER` in
[build.gradle.kts](../app/android/app/build.gradle.kts): it clears
`ndk.abiFilters` and drops the foreign ABIs through `packaging.jniLibs.excludes`.

### Gotchas in their buildserver

1. `make.bash` needs a bootstrap Go → `apt-get install golang-go` plus
   `GOROOT_BOOTSTRAP`.
2. **The scanner runs BETWEEN `prebuild:` and `build:`.** Anything produced in
   `prebuild` looks to it like a suspicious binary and demands a `scanignore`.
   Building the core belongs in `build:` — then the scanner only ever sees
   sources.
3. `git -C $$srclib$$ checkout` **must carry `-f`**: fdroidserver wipes the
   keysigning configs inside the Flutter clone, the tree is dirty, and a plain
   checkout refuses to switch.
4. The core needs **three** submodules: `sing-tun`, `wireguard-go`, `gvisor`.
   Look them up in the core's `go.mod`, not in `.gitmodules` (which lists three
   more, heavy, client-side ones):
   `grep -A15 '^replace' go.mod | grep '=> \./'`.
5. **`rewritemeta` checks key order and the final byte.** The order comes from
   their schema and is not alphabetical: `Binaries` right after `Repo`,
   `AllowedAPKSigningKeys` before `MaintainerNotes`. It also fails on a missing
   trailing `\n`. Do not guess the diagnosis — the job prints a ready-made diff,
   apply it literally.
6. GitLab's default job limit is **1 hour**, which three ABIs do not fit into.
   Raised to 5 through `build_timeout` in the project API. Runner variance is
   wide: the same Chromium took 25 minutes once and 50 another time.
7. The first CI run on GitLab requires account verification (phone or card),
   otherwise the pipeline fails as “yaml invalid” with zero jobs.
8. **The APK must not carry `DEPENDENCY METADATA`.** By default AGP puts a
   dependency list, encrypted with Google's key, into the APK Signing Block. The
   F-Droid scanner rejects the whole APK: `Found extra signing block`. Disabled
   with `dependenciesInfo { includeInApk = false }` in
   [`app/android/app/build.gradle.kts`](../app/android/app/build.gradle.kts);
   left enabled for the AAB, since Google Play builds from the bundle.
9. **A pin to a generated branch can evaporate.** `cronet-go` keeps its built
   libraries in the `go_dev` branch, which upstream rewrites: on 6 August our pin
   fell out of every branch and `git clone` could no longer reach it
   (`unable to read tree`). The cure is a core update — the pin must match what
   the core's `go.mod` says, and that must be reachable by an ordinary clone.

### Resolve MR threads explicitly

Reviewer remarks live in **threads**, not in the general feed. Replying in text
is not enough: the thread stays open until someone presses **Resolve**, and the
MR sits at `blocking_discussions_resolved: false`. To a maintainer that reads as
“the author has not answered yet” — the `waiting-for-upstream` label stays on and
the queue passes by. This cost us a day and a half: every remark had been
addressed in substance, but five threads were left unmarked.

Look at `discussions`, not at the `notes` feed:

```bash
curl -sS --header "PRIVATE-TOKEN: $(cat ~/.gitlab-token)" \
  "https://gitlab.com/api/v4/projects/36528/merge_requests/44731/discussions?per_page=100" \
  | python3 -c "import sys,json; print(sum(1 for d in json.load(sys.stdin) for n in d['notes'] if n.get('resolvable') and not n.get('resolved')), 'unresolved')"
```

To close one: `PUT .../discussions/<id>?resolved=true`.

## Reproducibility

The mode is **on**: `Binaries` (the release APK URL, one per block) and
`AllowedAPKSigningKeys` in the metadata. F-Droid builds the app itself,
downloads ours, compares bit for bit — and publishes **ours**, with our
signature. Installing from the catalogue and from GitHub yields the same
application, and updates flow in both directions.

⚠ **There is no way back.** Android does not allow updating an app with a
different key: dropping `Binaries` would move the catalogue to F-Droid's own
signature, and to the system that is a different application. Losing
`upload-keystore.jks` means the end of updates.

⚠ **Every release must match bit for bit**, otherwise the version simply never
reaches the catalogue. Verified on v2.20.6, all three ABIs: **455 files, zero
differences**.

Three native libraries used to differ:

| File | Cause | Fix |
|---|---|---|
| `libapp.so` | the absolute build path is baked into the Dart AOT snapshot | build at the same path our CI uses: `mv` into `/home/runner/work/LxBox/LxBox` at the start of `build:` |
| `libflutter_zxing.so` | the two sides passed different flags to the linker | the flag is set once in `build.gradle.kts` and removed from the metadata |
| `libdartjni.so` | `.note.gnu.build-id` | `--build-id=none` |

⚠ **The NDK adds `-Wl,--build-id=sha1` unconditionally**
(`build/cmake/flags.cmake:72`, a workaround for old LLDB). The name is
misleading: lld hashes the output file **before** strip, together with the debug
information that holds the absolute paths. Those paths never reach the shipped
`.so` — hence a different fingerprint for otherwise identical libraries. Measured
on `libdartjni.so`: exactly **20 bytes at offset `0x2e0`**, everything else
identical.

The flag is set in [`app/android/build.gradle.kts`](../app/android/build.gradle.kts)
through `-DCMAKE_SHARED_LINKER_FLAGS` rather than in the recipe: the F-Droid
build uses that same file, so both sides share one source. The mechanism was
confirmed by building, not inferred from documentation — `-D` replaces the whole
cache variable, so both outcomes were ruled out by measurement: the
`.note.gnu.build-id` section is gone and the set of sections is unchanged. The
fallback would be patching `add_link_options("LINKER:--build-id=none")` into the
package's `CMakeLists.txt`.

⚠ **`--filesystem-root` does not help** and nobody in the catalogue uses it:
`flutter build apk` does not accept the flag, and passing it through
`--extra-front-end-options` never reaches `dartPluginRegistrantUri` (confirmed by
building).

### How to compare

```bash
scripts/verify-fdroid-apk.sh <apk-from-fdroid> <apk-from-github>
scripts/verify-fdroid-apk.sh --blocks <apk>     # signing blocks only
```

Both checks are mandatory, and here is why.

⚠ **Compare `META-INF/` separately:** it holds not just the signature (comparing
that is pointless — the keys differ) but also some 76 androidx version-metadata
files, which would otherwise drop out of the comparison entirely.

⚠ **A file-by-file comparison does not cover the APK Signing Block.** It sits
between the data and the Central Directory — outside the zip structure, where
`unzip` cannot see it. We got burned by this: 455 files matched while `check apk`
failed on 7185 bytes of `DEPENDENCY METADATA` (id `0x504b4453`).

A size difference between APKs with identical contents is normal: ours is about
12 KB heavier because of the v2/v3 signing block. There is no `.RSA` file in the
archive — the signature sits before the Central Directory, `keytool -printcert`
will not work on it, and `apksigner verify --print-certs` is required.

## The versionCode scheme

§379 — one formula for both channels, ABI at the end:

```
versionCode = ((major × 10000 + minor × 100 + patch) × 100 + PRE) × 10 + ABI
```

`PRE`: `01-49` = `-rc.N`, `50` = release, `51-98` = `-hotfixN`.
`ABI`: `0` universal, `1` armv7, `2` arm64, `4` x86_64.

The formula lives only in [`scripts/version-code.sh`](../scripts/version-code.sh)
and the arithmetic must not be duplicated. The full layout and the staging rules
are in [§379](spec/tasks/379-version-code-from-version.md).

**Why the ABI goes last:** the catalogue sorts versions by versionCode. With the
ABI in front (which is what Flutter does under `--split-per-abi`:
`ABI * 1000 + code`) an x86_64 build of an old release ends up “newer” than an
armv7 build of a new one. This was a reviewer requirement.

That is also why `--split-per-abi` was dropped on GitHub — otherwise Flutter
would multiply the ABI on top of our number. Instead of one split run there is
one run per target. The numbers for a given release match between GitHub and
F-Droid.

### Automatic updates

Before §379 `checkupdates` could not read the version at all: `pubspec.yaml` held
a placeholder and `versionCode` was a commit count, not a function of the tag. So
`UpdateCheckMode: None` was set and every version needed a manual MR.

```yaml
AutoUpdateMode: Version
UpdateCheckMode: Tags
VercodeOperation:
  - '%c + 1'
  - '%c + 2'
  - '%c + 4'
UpdateCheckData: app/pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+
CurrentVersion: 2.20.4
CurrentVersionCode: 22004504
```

`UpdateCheckData` reads the code with **ABI=0** out of pubspec
(`2.20.4+22004500`), and `VercodeOperation` substitutes each block's ABI digit.
There are as many operations as there are build blocks.

⚠️ The operation is `%c + ABI`, **not** `%c * 10 + ABI`. The multiplication by 10
already sits inside the §379 formula, and pubspec receives a finished code. The
extra multiplication yields `220045002` instead of `22004502` — an order of
magnitude larger, and it cannot be rolled back: Android refuses a lower
`versionCode`. The `app.atrium` precedent is no help here — its pubspec holds a
code *without* the ABI, which is why `* 10` is appropriate there.

⚠ `AutoUpdateMode` is a bare `Version`, without `v%v`. Under `Tags` the real tag
is known from the check and is substituted into `commit:` verbatim
(`checkupdates.py`: `if tag: b.commit = tag`). The schema rejects a template with
`%v`.

### Network requests and the first-run consent

The first-run prompt "Check for updates?" sets `auto_check_updates` (default
**false**). It gates every background request to the project's own files:

| Request | When | Gated by the flag |
|---|---|---|
| GitHub Releases API → `docs/latest.json` fallback | app launch, ≤ once per 24 h | yes (§379) |
| `app/assets/support.json` — the author's message feed (the same file is bundled into the APK) | home screen with the tunnel up, once per process | yes (§422); without consent the feed comes from the last cached copy, and before that from the bundled one |
| `app/assets/donate.json` — donation methods (the same file is bundled) | only when the user opens About → Support | no — explicit user action |
| `public-servers-manifest.json` — community test servers | only when the user opens that screen | no — explicit user action |

So with "Skip" the app makes no request to `raw.githubusercontent.com` on its
own. This was raised in the fdroiddata review (#61).

### The price of three ABIs

There is no cache between blocks: each one compiles Go, Chromium and the core
from scratch. One ABI takes 45–70 minutes, three take **2–3 hours** (measured on
v2.20.4 and v2.20.6).
