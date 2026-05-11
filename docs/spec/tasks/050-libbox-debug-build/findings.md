# §050 — libbox debug build investigation: ИТОГОВЫЙ ОТЧЁТ

| Поле | Значение |
|------|----------|
| Статус | **✅ CLOSED — F12.3 readWIFIState FIXED** (commit `99005ed`) |
| Дата | 2026-05-10 |
| Branch | `diag/libbox-debug-build` ready for merge на develop |
| Phone state | v13300 — F12.3 ENABLED, stable, tunnel connected, **0 crashes** |

---

## TL;DR (FINAL — real fix found)

**Root cause crash refnum 42 = unhandled `SecurityException` через JNI boundary.**

Цепочка событий:
1. Sing-box (Go) → cgo → `cproxy_PlatformInterface_ReadWIFIState`
2. Java callback `readWIFIState()` invokes `WifiManager.getConnectionInfo()`
3. `Parcel.readException()` throws **`SecurityException`** — на API 29+ требуется `ACCESS_BACKGROUND_LOCATION`, у нас в AndroidManifest нет
4. Exception propagates через cproxy code (gomobile-generated stub без try/catch)
5. `Seq$RefTracker.incRefnum` пытается JNI cleanup → `ClassLinker::FindClass` FAILS из-за corrupted env
6. → `art::Runtime::Abort`
7. abort message **"Unknown reference: 42"** — **misleading follow-up effect** broken JNI state. Не реальная refnum lookup issue!

**Fix** (commit `99005ed`):
- `PlatformInterfaceWrapper.readWIFIState()` обёрнут в `try/catch SecurityException + RuntimeException` → return null. Sing-box получает null gracefully.
- `BoxService.startSingbox` post-`startOrReloadService` permission check через `cs.needWIFIState() && !checkSelfPermission(BACKGROUND_LOCATION)` (warning log, port из reference SagerNet).

**Verification**: v13300 cold start с F12.3 enabled — pid alive 1m+ continuous, tunnel connected wg-parnas, **ZERO crashes на v13300** в dropbox. Prior 9 attempts crashed в 1-12s.

**Почему 9 prior attempts ничего не дали**: мы fix'или **wrong layer**. F1 split, @Synchronized, gomobile/seq patches, drainer pattern — все про refnum lifecycle. Real cause = **uncaught Java exception** в одной строке wrapper'а.

**Чему это научило**: 
- crash backtrace может быть **misleading** (abort на refnum 42 происходил из-за broken JNI env, не actual refnum issue)
- decompiled trace юзера (`Parcel.readException → ClassLinker::FindClass FAILS`) был ключом которое мы пропустили в начальной investigation
- defensive try/catch на JNI boundaries — **обязательно** для всех cgo callbacks которые могут throw

---

## Practical changes applied

| File | Change | Status |
|---|---|---|
| `PlatformInterfaceWrapper.kt` | F12.3 enabled с try/catch SecurityException | ✅ commit `99005ed` |
| `BoxService.kt` | Permission check post-startOrReloadService (warning log) | ✅ commit `99005ed` |
| `BoxService.kt` | F22 drainer pattern для writeDebugMessage | ✅ commit `6e2dbf9` (cosmetic, separate) |
| `BoxApplication.kt`, `BoxVpnService.kt`, `BoxService.kt`, AndroidManifest | Phase H baseline (F1 split + Application class registered + reference deltas) | ✅ commit `842df5c` (already в develop) |

---

## Что сделано

### Phase A — Build environment setup ✅
- gomobile fork от sagernet (`github.com/sagernet/gomobile@v0.1.12` — НЕ golang.org/x/mobile, у них свои patches)
- Sing-box source clone (v1.13.11 tag)
- Custom builder через `go run ./cmd/internal/build_libbox -target android [-debug]`

### Phase B — Debug AAR build ✅
- `gomobile bind` через sing-box's wrapper с flags `-ldflags="..."` без `-s -w` (preserve DWARF)
- Output: `libbox.aar` 38.9MB (vs production stripped 35MB), внутри `libbox.so` 88MB с full DWARF
- Sections: `.debug_abbrev`, `.debug_line`, `.debug_frame`, `.debug_info`, `.debug_loclists`, etc.

### Phase C — Hot-patch APK ✅ (workaround)
- Full Flutter rebuild **blocked**: RAM tight (15GB/16GB used) → Gradle daemon stuck → kill
- Workaround: unzip existing APK → swap `lib/arm64-v8a/libbox.so` на debug version → zipalign 4-byte для resources.arsc и .so → apksigner sign с upload-keystore
- Installed on phone — running с debug binary

### Phase D — Symbol resolution ✅
addr2line resolved все frames из production tombstone:

```
Production crash backtrace (4 frames total):
#00 abort+168 (libc.so)
#01 go_seq_from_refnum+228 → seq_android.c:260 LOG_FATAL("Unknown reference: %d")
#02 cproxy_WriteDebugMessage+68 → bl go_seq_from_refnum
#03 0xb5b0e8 → runtime.asmcgocall.abi0 (asm_arm64.s:1049)
```

**Critical limit found**: `4 total frames` — ART unwinder не может пройти глубже `runtime.asmcgocall.abi0` (Go cgo bridge). Go-side stack underneath **полностью скрыт** потому что Go использует custom split-stacks несовместимые с Linux ABI unwinder. Какая Go function вызвала writeDebugMessage callback **невидимо** через ART.

### Phase E — Crash mechanism подтверждён ✅

Из `seq_android.c.support` template (gomobile/bind/java/):
```c
jobject go_seq_from_refnum(JNIEnv *env, int32_t refnum, ...) {
    ...
    jobject ref = (*env)->CallStaticObjectMethod(env, seq_class, seq_getRef, refnum);
    if (ref == NULL) {
        LOG_FATAL("Unknown reference: %d", refnum);  // ← abort here
    }
    (*env)->CallStaticVoidMethod(env, seq_class, seq_decRef, refnum);
    return (*env)->GetObjectField(env, ref, ref_objField);
}
```

Java side `Seq.getRef(refnum)` returns NULL когда `RefMap.get(refnum)` returns null. Это случается когда entry либо:
- (A) **Никогда не вставлен** в `RefMap.keys[]` (binarySearch < 0)
- (B) **Был, но `objs[i]` set to null** в `RefMap.remove(key)`

### Phase F — F22 drainer pattern attempt ❌ → ✅ (cosmetic)

Гипотеза: race window между Java `getRef` и `decRef` усугубляется множественными concurrent goroutines.

Patched `BoxService.writeDebugMessage`:
```kotlin
@Synchronized  // serialize Java side
override fun writeDebugMessage(message: String) {
    val plain = ansiEscapeRe.replace(message, "")
    if (traceDebugRe.containsMatchIn(plain)) return
    if (BoxVpnService.coreLogSink == null) return
    coreLogQueue.offer(plain)  // LinkedBlockingQueue
    if (drainerScheduled.compareAndSet(false, true)) {
        coreLogMainHandler.post(coreLogDrainer)  // ОДИН Runnable instance, не lambda
    }
}
```

**Result v12600**: Cold start crash refnum 42 на uptime 8s. `@Synchronized` бесполезен потому что abort происходит **в C-side** (`go_seq_from_refnum`) **до** того как наш Java method invoked.

**Применили как cosmetic** (commit `6e2dbf9`): drainer reduces hot-path allocations (Lambda + Message per writeDebugMessage call → 1 string). Не fix race но cleaner.

### Phase G — gomobile/seq Java patch attempts ❌

Гипотеза: убрать race scenario (B) — `RefMap.remove` при `refcnt=0`.

Cloned gomobile fork в `/tmp/gomobile-patched/`, добавлен `replace github.com/sagernet/gomobile => /tmp/gomobile-patched` в sing-box go.mod.

#### Attempt 1: prevent removal at refcnt=0 (v12900)
```java
// In Seq$RefTracker.dec():
obj.refcnt--;
// PATCH: never remove. Leak entries но fix race.
// if (obj.refcnt <= 0) javaObjs.remove(refnum);
```
**Result**: Crash refnum 42 same. Removal не главная причина.

#### Attempt 2: Instrument RefMap.get/put/remove (v13000)
Added `Log.e("REFMAP", ...)` для refnum=42 cases.
**Result**: Crash same. **Никаких REFMAP logs в logcat**. Verified instrumentation в classes.dex (strings present).

#### Attempt 3: Instrument Seq.getRef + tracker.get (v13100)
Added `Log.e("SEQ_GETREF", ...)` для refnum=42.
**Result**: Crash same. **Никаких logs**.

#### Attempt 4 (cancelled): Verbose static init + incRef logs

Planned — добавить Log.e в `Seq.<clinit>` + `Seq.incRef(Object)`:
```java
static { android.util.Log.e("SEQ_INIT", "go.Seq class loading"); ... }
public static int incRef(Object o) {
    int r = tracker.inc(o);
    android.util.Log.e("SEQ_INC", "incRef(o=" + o.getClass().getName() + ") → " + r);
    return r;
}
```

**Discovery during attempt 4 setup**: SFA APK libbox.so собран с **Go 1.25.9**, наш JitPack — **Go 1.25.6**, наш build — **Go 1.25.5**. Это **3 разных Go runtime versions**.

User decision: **остановить investigation**. Дальнейшие attempts не приоритет.

---

## Что НЕ сделано (но возможно как future work)

### Не verified: Go 1.25.9 build trial
Самый prominent untested hypothesis. Patch-level (1.25.5/6 → 1.25.9) Go releases типично fix runtime bugs. cgo lifecycle одна из чувствительных областей.

```bash
go install golang.org/dl/go1.25.9@latest && go1.25.9 download
# Replace `go run` → `go1.25.9 run` в build_libbox
# Repro test
```

Estimate: 30-60 min build + repro. Если crash исчезает → confirmation. Если не исчезает → environment-specific.

### Не пытались: libbox 1.14-alpha
Reference SagerNet `main` HEAD на `1.14.0-alpha.21`. Major version bump. API breakage риск, но reference users работают на этой версии. Вероятно Go runtime bumped тоже.

### Не делали: Frida hook на Java side
Frida позволил бы non-invasive instrumentation Seq class methods runtime. Без перепаковки. Но требует Frida server на rooted device.

---

## Diagnostic findings (что мы поняли)

### 1. Crash mechanism определённо в gomobile cproxy code

`cproxy_WriteDebugMessage(env, refnum=42, msg)` calls Java `Seq.getRef(42)`. If Java returns NULL → C-side `LOG_FATAL` → SIGABRT.

### 2. Java side в момент crash **не вызывается** (наблюдательно)

5 attempts с инструментированным gomobile (включая RefMap.get, RefMap.put, RefMap.remove, Seq.getRef) — **никаких** `Log.e()` в logcat от наших инструментов во время crash.

Возможные интерпретации:
- (a) `seq_class` global ref invalid в момент cgo upcall — `CallStaticObjectMethod` returns NULL без invoking Java method
- (b) `seq_getRef` jmethodID stale
- (c) crash в C-side **до** `CallStaticObjectMethod` (например, на access env field offset 0x390)
- (d) Logging buffer issue (не вероятно — другие Android logs visible)

### 3. ART unwinder limit фундаментально

Tombstone cap'ит на 4 frames потому что unwinder упирается в `asmcgocall` Go bridge. Чтобы видеть Go-side stack нужно либо:
- Patch sing-box чтобы dump `runtime.Stack(buf, all=true)` перед LOG_FATAL
- Использовать GOTRACEBACK=all (но Go runtime не успевает dump до abort)
- Set custom signal handler before abort

Все три — non-trivial sing-box patches.

### 4. Go runtime version delta

| Source | Go version |
|---|---|
| SFA upstream `SFA-1.13.11-arm64-v8a.apk` (works stably) | 1.25.9 |
| JitPack singbox-android/libbox 1.13.11 (наш production prior) | 1.25.6 |
| Наш self-build (`/tmp/check-debug/libbox.so`) | 1.25.5 |

Это **самое подозрительное** unconfirmed delta. Не tested.

---

## Final architecture status

### F12.3 readWIFIState
- **Status**: deferred final (`return null`)
- **Reason**: Crash refnum 42 deterministic на нашем env (Android 15 OnePlus + libbox 1.13.11 + Go 1.25.5/6) при non-null implementation
- **Practical impact**: zero. Sing-box rules с `wifi_ssid:`/`wifi_bssid:` не используются ни в наших wizard configs, ни нашими юзерами.
- **Reactivation conditions**:
  - libbox upgrade на 1.14-alpha когда стабильный, ИЛИ
  - libbox rebuild с Go 1.25.9, ИЛИ
  - Юзер запросит wifi-rule support

### F22 writeDebugMessage drainer pattern
- **Status**: applied (commit `6e2dbf9`)
- **Code**: Single Runnable instance + LinkedBlockingQueue + AtomicBoolean schedule flag + @Synchronized
- **Effect**: Allocation reduction в hot path (no Lambda+Message per call). НЕ fix race (race в Go cproxy не Java side).

### F1 split + Phase H reference deltas
- **Status**: in production (commit `842df5c` merged in develop)
- F1 split: BoxVpnService (Android Service + PI) + BoxService (CSH only) — separate Java instances
- Application class registered (`android:name=".vpn.BoxApplication"`)
- `Seq.setContext(this)` removed — match reference
- `logMaxLines = 3000` в SetupOptions
- `Libbox.setMemoryLimit(true)` removed
- Result: production-stable, главный §049 fix (atomic CAS lifecycle) сохранён

---

## Artefacts

### On disk (диагностика, can be cleaned)
```
/tmp/libbox-build/sing-box/                  — sing-box v1.13.11 + replace gomobile
/tmp/gomobile-patched/                        — patched gomobile fork с REFMAP/SEQ logging
/tmp/check-debug/libbox.so                    — unstripped 88MB с DWARF
/tmp/sfa-fresh/sfa @ 3b3883e                  — SagerNet reference 1.13.11
/tmp/cfr.jar                                  — CFR Java decompiler 0.152
/tmp/lxbox-debug-libbox.apk                   — hot-patched APK с debug libbox
/tmp/sfa-app.apk                              — pulled SFA APK для Go version analysis
/tmp/test-fix.sh, /tmp/resolve-crash.sh      — helper scripts
```

### In repo (на ветке `diag/libbox-debug-build`)
```
docs/spec/tasks/050-libbox-debug-build/spec.md      — original task spec
docs/spec/tasks/050-libbox-debug-build/findings.md  — этот отчёт
app/android/app/libs/libbox-1.13.11-patched.aar     — patched + instrumented (88MB, gitignored?)
app/android/app/build.gradle.kts                    — modified to use local AAR
app/android/app/src/main/kotlin/.../PlatformInterfaceWrapper.kt — F12.3 enabled (для testing)
```

**Note**: ветка `diag/libbox-debug-build` — diagnostic artefact. **НЕ для merge**. Production хорошее состояние = `develop` HEAD.

---

## Recommendations going forward

1. **Closе F12.3 как permanently deferred** в LxBox roadmap. Документация в spec/049 + spec/050 уже на месте.

2. **Если хочется retry F12.3**:
   - Try Go 1.25.9 rebuild (30-60 min) — высокий potential, low effort
   - Try libbox 1.14-alpha upgrade — middle effort, breaking changes possible
   
3. **Не tracking F22 drainer как ongoing work** — applied as commit, done.

4. **Phase H baseline** — production-ready, главный §049 fix landed. §050 closed.
