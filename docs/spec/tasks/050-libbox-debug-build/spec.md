# 050 — libbox debug build для root cause refnum 42 race

| Поле | Значение |
|------|----------|
| Статус | **Done (2026-05-10)** — root cause найден без debug build (см. findings.md). Real cause: unhandled `SecurityException` в `WifiManager.connectionInfo` propagates через JNI → ClassLinker abort с misleading `Unknown reference: 42`. Defensive `try/catch SecurityException` + permission gate в `BoxService.startSingbox` (location + `NEARBY_WIFI_DEVICES` на API 33+) + permission UX в Flutter (runtime prompt + Settings fallback). |
| Дата | 2026-05-10 |
| Связанные spec'ы | [`049 sing-box wrapper deep audit`](../049-singbox-wrapper-deep-audit/spec.md) — все Phase G/H findings, F12.3 attempts log |
| Branch | `diag/libbox-debug-build` (создать новую от `diag/refnum-42-clean-split`) |

---

## Цель в одну фразу

Собрать `libbox.aar` с debug symbols (unstripped Go binary), reproduce `refnum 42` crash на устройстве, через `addr2line` найти **точную Go function:line** где наш `Seq.Ref` для `CommandServerHandler` destroyed prematurely.

## Зачем

В §049 Phase A-H мы:
- Сделали F1 split (mirror reference SagerNet)
- Migrated `BoxApplication object` → `class : Application()` registered
- Removed `Seq.setContext(this)`, added `logMaxLines=3000`, removed `Libbox.setMemoryLimit(true)`
- 6 attempts re-enable F12.3 `readWIFIState` — каждый раз crash `Unknown reference: 42`
- Phase G7 deterministic подтвердил: refnum N = наш `BoxService` Java instance в `Seq.RefMap`
- Reference SagerNet/sing-box-for-android на same libbox 1.13.11 имеет **identical Java code** и **не падает** в production

Все blind diff'ы исчерпаны. Без debug symbols в `libbox.so` мы не можем точно сказать **какая Go function** делает `destroyRef(42)` преждевременно. Нужен инструмент.

## Pre-requisites (что есть на этой машине)

| Ресурс | Статус | Где |
|---|---|---|
| Go toolchain | go1.25.5 darwin/amd64 | `/usr/local/bin/go` |
| Android NDK | 28.2.13676358 | `/usr/local/share/android-commandlinetools/ndk/28.2.13676358` |
| JDK | OpenJDK 17.0.18 | system default |
| Phone via wifi-adb | OnePlus CPH2411 (Android 15) | `192.168.1.71:5555`, USB serial `CE8XX48PCI79U4XG` |
| Sing-box source | Public repo | `https://github.com/SagerNet/sing-box`, tag `v1.13.11` |
| Reference SFA | Already cloned | `/tmp/sfa-fresh/sfa` (commit `3b3883e` — libbox 1.13.11) |
| Decompiled `go.Seq` | Already done | `/tmp/Seq.java` (CFR decompiled) |
| Stripped libbox.so | На disk | `/tmp/libbox-decompile/jni/arm64-v8a/libbox.so` (62MB, для symbol resolve sanity check) |

Build target identified из `.go.buildinfo` секции stripped libbox.so:
- Path: `github.com/sagernet/sing-box/build/arm64/libbox`
- Module: `github.com/sagernet/sing-box (devel)` — built from local checkout
- Compiler: Go 1.25.6 (наш 1.25.5 — близко, но если будут issues — `go install golang.org/dl/go1.25.6@latest`)

**Внимание**: путь `build/arm64/libbox` НЕ существует в public sing-box repo (проверено через GitHub API). Это maintainer's local build dir. Реальный package для gomobile bind находится в **`experimental/libbox/`** (37 .go files).

## Известные complications

1. **gomobile bind с большим dependency graph**. Sing-box имеет 100+ deps (видно в `.go.buildinfo` strings). gomobile исторически имел ограничения на cgo / сложные deps. May require build tags tweaking.

2. **Build target переnaming**. Reference's `singbox-android/libbox` GitHub repo — это просто wrapper хостящий pre-built AAR (uploaded by `flutter-lib` maintainer через Git LFS). Build pipeline не публичный. Нужно reverse-engineer из:
   - `experimental/libbox/build_info.go` — может содержать build tags
   - `experimental/libbox/link_flags_*.go` — linker flags для разных платформ

3. **Go version drift**. libbox.so на устройстве собран Go 1.25.6, у нас 1.25.5. Patch-level разница, но если build error возникает с unknown directive — install 1.25.6 явно через `go install golang.org/dl/go1.25.6@latest`.

4. **AAR replacement в Gradle**. Сейчас:
   ```
   implementation("com.github.singbox-android:libbox:1.13.11")  // JitPack
   ```
   После build — заменить на local file:
   ```
   implementation(files("../../libs/libbox-debug.aar"))
   ```

## Шаги

### Phase A — Build environment setup (~30 минут)

```bash
# 1. Clone sing-box
mkdir -p /tmp/libbox-build && cd /tmp/libbox-build
git clone --depth=1 --branch v1.13.11 https://github.com/SagerNet/sing-box
cd sing-box

# 2. Inspect actual gomobile target
ls experimental/libbox/
cat experimental/libbox/go.mod 2>/dev/null  # если есть submodule
cat go.mod | head -3

# 3. Установить gomobile (последний)
go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
export PATH="$HOME/go/bin:$PATH"

# 4. Init gomobile (создаёт env config)
gomobile init

# 5. Setup Android NDK env vars
export ANDROID_NDK_HOME=/usr/local/share/android-commandlinetools/ndk/28.2.13676358
export ANDROID_HOME=/usr/local/share/android-commandlinetools
```

### Phase B — Build debug AAR (~30-60 минут first time, ~5-10 min iterative)

```bash
cd /tmp/libbox-build/sing-box

# Build с debug symbols. Ключевые flags:
#   -ldflags="-w=false -s=false"  — НЕ strip symbols + DWARF debug info
#   -tags=                         — какие build tags включить (см. ниже)
#   -target=android/arm64          — только наша ABI (ускорит build)
#   -androidapi=26                 — соответствует нашему minSdk
#   -o libbox-debug.aar            — output

gomobile bind \
  -target=android/arm64 \
  -androidapi=26 \
  -ldflags="-w=false -s=false" \
  -tags="with_quic with_grpc with_dhcp with_wireguard with_ech with_utls with_clash_api with_v2ray_api with_gvisor with_conntrack" \
  -o libbox-debug.aar \
  ./experimental/libbox

# Проверить что symbols есть:
unzip -j libbox-debug.aar 'jni/arm64-v8a/libbox.so' -d /tmp/check-symbols/
file /tmp/check-symbols/libbox.so
# expected: "ELF 64-bit LSB shared object, ARM aarch64, version 1 (SYSV), dynamically linked, with debug_info, not stripped"

ls -lh libbox-debug.aar
# expected: ~150-300MB (vs stripped 35MB)
```

**Build tags из `.go.buildinfo`**: посмотреть какие реально используются в production stripped libbox:
```bash
go version -m /tmp/libbox-decompile/jni/arm64-v8a/libbox.so | grep -E "build\s+\-tags"
```

### Phase C — Replace AAR в LxBox build (~15 минут)

```bash
cd /Users/macbook/projects/LxBox

# 1. Создать ветку
git checkout -b diag/libbox-debug-build diag/refnum-42-clean-split

# 2. Создать libs dir и скопировать debug AAR
mkdir -p app/android/app/libs
cp /tmp/libbox-build/sing-box/libbox-debug.aar app/android/app/libs/

# 3. Обновить build.gradle.kts
```

В `app/android/app/build.gradle.kts`:
```kotlin
dependencies {
    // §050 debug build — local AAR с unstripped Go symbols вместо JitPack
    // implementation("com.github.singbox-android:libbox:1.13.11")
    implementation(files("libs/libbox-debug.aar"))
    // ... остальные deps без изменений
}
```

```bash
# 4. Build app
bash scripts/build-local-apk.sh --build-number=12000

# 5. Install на phone
adb -s 192.168.1.71:5555 install -r app/build/app/outputs/flutter-apk/app-release.apk
```

### Phase D — Trigger crash + symbol resolve (~10 минут)

Условия repro: F12.3 enabled (readWIFIState non-null), cold start. См. §049 для test sequence.

```bash
# Force-stop для clean cold start
adb -s 192.168.1.71:5555 shell "am force-stop com.leadaxe.lxbox"
sleep 2

# Запустить app + VPN через Debug API
TOKEN="357f5aacdf154419d2787ec61e3ad9f2"
adb -s 192.168.1.71:5555 shell "am start -n com.leadaxe.lxbox/.MainActivity"
sleep 5
adb -s 192.168.1.71:5555 forward tcp:9270 tcp:9269
curl -sf -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:9270/action/start-vpn"

# Ждём crash 1-90 секунд
sleep 90

# Pull tombstone
adb -s 192.168.1.71:5555 shell "dumpsys dropbox --print" > /tmp/dropbox-debug.txt
grep -A100 "data_app_native_crash" /tmp/dropbox-debug.txt | tail -200 > /tmp/crash-debug.txt
```

В crash backtrace будут адреса вида `pc 0000000001d1bcdc /data/.../libbox.so (go_seq_from_refnum+228)`. Эти PC относительно libbox.so load base. Resolve через NDK addr2line:

```bash
NDK_BIN=/usr/local/share/android-commandlinetools/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin

# extract libbox.so из debug AAR (с symbols)
unzip -j /tmp/libbox-build/sing-box/libbox-debug.aar 'jni/arm64-v8a/libbox.so' -d /tmp/

# Для каждого pc в backtrace:
$NDK_BIN/llvm-addr2line -e /tmp/libbox.so -f -C 0x01d1bcdc
$NDK_BIN/llvm-addr2line -e /tmp/libbox.so -f -C 0x01d167e8
$NDK_BIN/llvm-addr2line -e /tmp/libbox.so -f -C 0x00b5b0e8

# Также disassembly вокруг crash addr:
$NDK_BIN/llvm-objdump -d --disassemble-symbols=go_seq_from_refnum /tmp/libbox.so | head -50
```

Это даст: `gomobile/seq/refnum.go:42` (или similar) — точная Go функция, которая делает `destroyRef`. Мы увидим **call site** который преждевременно decRef'ит наш handler ref.

### Phase E — Diagnose root cause + fix

С точным call site в Go runtime:
- Если destroyRef вызывается из `runtime.SetFinalizer` → Java side держит ref недостаточно strongly
- Если из `cgo cleanup` path → cgo argument проблема в том как Java→Go параметры передаются
- Если из gomobile generated proxy code → bug в gomobile itself

В зависимости от root cause:
- (a) Java workaround: pin extra reference в Application static field
- (b) gomobile patch: rebuild gomobile с fix и rebuild libbox
- (c) Reference upstream report: открыть issue в SagerNet/sing-box если bug
- (d) Last resort: stay deferred, switch to libbox 1.14-alpha (reference у которого работает)

## Success criteria

- [ ] `libbox-debug.aar` собран, libbox.so с DWARF debug info
- [ ] `addr2line` resolved минимум 3 frames из `Unknown reference: N` crash backtrace в Go file:line
- [ ] Documented в `docs/spec/tasks/050-libbox-debug-build/findings.md`:
  - Точное место в gomobile/seq runtime где destroyRef triggered
  - Trigger condition (что в нашем коде / lifecycle вызывает this path)
  - Recommendation: workaround / upstream issue / blocked-on-upgrade
- [ ] Decision made on F12.3 — fix possible or final defer

## Если не получится

Acceptable failure modes:
1. **gomobile build fail** на cgo / unsupported deps. Documented в findings, F12.3 stays deferred. Tracking issue для libbox 1.14-alpha upgrade (в reference seq lifecycle может быть changed).
2. **debug AAR построен но crash не reproduced** на debug variant — debug build memory layout другой может closing race window. Then try with `-gcflags="all=-N -l"` для disable optimizations.
3. **addr2line returns `?? ??:0`** — DWARF info incomplete. Try `gomobile bind -ldflags="-w=false -s=false -compressdwarf=false"` для full DWARF.

## Tracking — что дальше после этого task'а

Если debug build identifies fixable Java-side issue → patch + close F12.3 deferred status в §049.

Если identifies gomobile / Go runtime issue без feasible workaround → upgrade libbox 1.14-alpha trial (отдельная task `051-libbox-114-upgrade`).

Если debug build infeasible → close §049/§050 как "F12.3 environment-incompatible, blocked on libbox API stability".

## References

- `/tmp/Seq.java` — CFR-decompiled gomobile/seq runtime
- `/tmp/libbox-decompile/jni/arm64-v8a/libbox.so` — stripped производственный binary для compare
- `/tmp/sfa-fresh/sfa` — reference SagerNet checkout @ commit 3b3883e (libbox 1.13.11)
- §049 spec — full Phase A-H attempts log + reference deltas
- `scripts/diag/post-crash-capture.sh` — quick logcat + dropbox snapshot
- `scripts/diag/run-phase-g7.sh` — automated test cycle (модифицировать под F12.3 trigger)

Точные адреса для addr2line из последнего crash на v11400 (см. tombstones `/tmp/dropbox-after-uitest.txt`):
```
#01 pc 0000000001d1bcdc  libbox.so (go_seq_from_refnum+228)
#02 pc 0000000001d167e8  libbox.so (cproxylibbox_CommandServerHandler_WriteDebugMessage+68)
#03 pc 0000000000b5b0e8  libbox.so  (no symbol — Go internal, нужен debug build)
```

Frame #03 — most interesting, это **caller** который **триггерит** WriteDebugMessage с stale refnum. Без debug symbols мы видим только PC=0x00b5b0e8.

---

## Estimate

| Phase | First-try | Best-case (if smooth) |
|---|---|---|
| A: env setup | 30 min | 15 min |
| B: build debug AAR | 60-180 min (build errors могут быть) | 30 min |
| C: AAR replace + LxBox rebuild | 15 min | 10 min |
| D: crash repro + addr2line | 15 min | 10 min |
| E: diagnose + decide | 30-60 min | 20 min |
| **Total** | **2.5-5 hours** | **1.5 hours** |

Suitable для self-contained session с фокусом только на этот task.
