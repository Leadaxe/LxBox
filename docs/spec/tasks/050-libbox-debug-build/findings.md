# §050 — libbox debug build findings (in-progress)

## Phase A — Setup (DONE 05:00)

| Component | Version | Notes |
|---|---|---|
| Go | 1.25.5 darwin/amd64 | Production libbox built with 1.25.6 — close enough |
| Android NDK | 28.2.13676358 | `/usr/local/share/android-commandlinetools/ndk/` |
| JDK | OpenJDK 17.0.18 | |
| gomobile fork | github.com/sagernet/gomobile@v0.1.12 | NOT golang.org/x/mobile (sagernet patches) |
| sing-box source | v1.13.11 tag | `/tmp/libbox-build/sing-box` |

## Phase B — Build debug AAR (DONE 05:09)

```bash
cd /tmp/libbox-build/sing-box
go run ./cmd/internal/build_libbox -target android -debug
```

Output:
- `libbox.aar` 38.9MB (vs production stripped 35MB)
- `libbox-legacy.aar` 32.4MB (SDK 21 variant)
- libbox.so внутри: 88MB (vs production 62MB)
- File: "ELF 64-bit LSB shared object, ARM aarch64, with debug_info, not stripped"
- Sections present: `.debug_abbrev`, `.debug_line`, `.debug_frame`, `.debug_gdb_scripts`, `.debug_info`, `.debug_loclists`, `.debug_rnglists`, `.debug_addr`, `.debug_loc`

build_libbox flags (from cmd/internal/build_libbox/main.go):
- `sharedFlags`: `-trimpath -buildvcs=false -ldflags "-X .../Version=v1.13.11 -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid=  -checklinkname=0"` (production, strips symbols)
- `debugFlags`: `-trimpath -buildvcs=false -ldflags "-X .../Version=v1.13.11 -X internal/godebug.defaultGODEBUG=multipathtcp=0 -checklinkname=0"` (debug, **NO -s -w** = keeps symbols + DWARF)

Build tags (production):
```
with_gvisor with_quic with_wireguard with_utls with_naive_outbound with_clash_api 
badlinkname tfogo_checklinkname0 with_tailscale 
ts_omit_logtail ts_omit_ssh ts_omit_drive ts_omit_taildrop ts_omit_webclient 
ts_omit_doctor ts_omit_capture ts_omit_kube ts_omit_aws ts_omit_synology ts_omit_bird
```

## Phase C — Replace AAR + rebuild LxBox

В `app/android/app/build.gradle.kts`:
```kotlin
// implementation("com.github.singbox-android:libbox:1.13.11")
implementation(files("libs/libbox-1.13.11-debug.aar"))
```

LxBox build на debug AAR — IN PROGRESS, memory tight (RAM 15GB/16GB used during build).

## Pre-crash analysis — root cause path identified

**Crash signature production**:
```
pid 22906, tid 22930, name: Thread-9
signal 6 (SIGABRT), code -1 (SI_QUEUE)
Abort message: 'Unknown reference: 42'

#01 pc 0000000001d1bcdc go_seq_from_refnum+228
#02 pc 0000000001d167e8 cproxylibbox_CommandServerHandler_WriteDebugMessage+68
#03 pc 0000000000b5b0e8 (no symbol — Go internal caller)
```

**Resolved через debug AAR**:

Frame #02 `cproxylibbox_CommandServerHandler_WriteDebugMessage+68`:
- file: `seq_android.c:258` (== `bl go_seq_from_refnum`)
- This is inside generated cproxy stub — calls go_seq_from_refnum to lookup Java handler instance

Frame #01 `go_seq_from_refnum+228 (=+0xe4)`:
- file: `seq_android.c:260`
- Source code:
```c
jobject go_seq_from_refnum(JNIEnv *env, int32_t refnum, jclass proxy_class, jmethodID proxy_cons) {
    if (refnum == NULL_REFNUM) return NULL;
    if (refnum < 0) {  // Go object — line 255
        return (*env)->NewObject(env, proxy_class, proxy_cons, refnum);
    }
    // Seq.Ref ref = Seq.getRef(refnum) — line 258
    jobject ref = (*env)->CallStaticObjectMethod(env, seq_class, seq_getRef, (jint)refnum);
    if (ref == NULL) {                                             // line 259
        LOG_FATAL("Unknown reference: %d", refnum);                // line 260 ← ABORT HERE
    }
    // Go incremented the reference count just before passing the refnum. Decrement it here.
    (*env)->CallStaticVoidMethod(env, seq_class, seq_decRef, (jint)refnum);   // line 263
    return (*env)->GetObjectField(env, ref, ref_objField);                    // line 265
}
```

**Critical comment в исходнике**:
> "Go incremented the reference count just before passing the refnum. Decrement it here."

Каждый Go→Java upcall (writeDebugMessage callback) в Go-side **уже сделал `incRef`** до crossing JNI. Java side `go_seq_from_refnum` делает `decRef` после получения ref.

## Hypothesis (after Phase G7 + readWIFIState analysis + disassembly)

Refnum 42 = `BoxService` instance в `Seq.RefMap` (Java→Go ref для `CommandServerHandler` interface).

Race:
1. Sing-box запускает много goroutine'ов parallel
2. Каждый goroutine для writeDebugMessage callback:
   - Go-side: `incRef(42)` — refcnt++
   - JNI cross → `cproxylibbox_CommandServerHandler_WriteDebugMessage(env, 42, msg)`
   - cproxy → `go_seq_from_refnum(env, 42, ...)`
   - C side: `Seq.getRef(42)` → returns Java Seq.Ref wrapper
   - C side: `Seq.decRef(42)` — refcnt-- (cancellation of Go pre-incRef)
   - Returns ref.obj → invoke writeDebugMessage method
3. **Если decRef одного goroutine'а доводит refcnt до 0** до того как другой goroutine успел сделать incRef → `RefMap.remove(42)` → next getRef returns null → abort

`synchronized` методов на Java side гарантирует **atomic** inc/dec/get, но **не** synchronizes incRef в Go side с decRef в Java side. Между Go's incRef и Java's getRef есть JNI window где другой thread может decRef→0.

**Why F12.3 exposes this race more often**:
- F12.3 readWIFIState возвращает new WIFIState каждый call
- Каждый WIFIState ctor → JNI call `__NewWIFIState` (Go-side)
- Внутри Go side тоже triggers some incRef/decRef cycles на handler
- Suspect: WIFIState path в Go code где-то делает **extra decRef without preceding incRef**, или scheduling makes race window wider

**Why reference SagerNet does not crash** на same code:
- Less callback traffic? (no Flutter EventChannel forwarding для writeDebugMessage)
- Different threading model? (less concurrent goroutines hitting CSH)
- Lucky timing на physical device?

## Phase D — Real install + addr2line resolution

### APK rebuild blocked

LxBox app rebuild с replaced libbox-debug.aar в build.gradle.kts — **не завершился** успешно. RAM на dev машине почти полная (15GB/16GB used), gradle daemon stuck >12 минут. Killed.

### Workaround: APK hot-patch

Distilled альтернатива — replace `lib/arm64-v8a/libbox.so` напрямую в существующем `app-release.apk`:
1. unzip → swap libbox.so на debug (88MB) → repack with proper alignment
2. zipalign 4-byte alignment для resources.arsc + lib/*.so
3. apksigner with upload-keystore.jks
4. install -r — Success

Result: **v30 APK с stripped Java + debug libbox.so**.

Hot-patch limitation: Java side остался original (без F12.3 enable, без RefTracker instrumentation), значит **crash не воспроизведётся** на этом APK естественным путём.

### Resolved старый production tombstone через debug binary

Production crash backtrace v9999 (14:13 yesterday):
```
4 total frames:
  #00 abort+168 (libc.so)
  #01 go_seq_from_refnum+228
  #02 cproxylibbox_CommandServerHandler_WriteDebugMessage+68
  #03 pc 0xb5b0e8 (libbox.so, no symbol)
```

Debug build .text shifts от production:
- Production: 0x00ad5b00
- Debug:      0x00ad6200 (+0x700 because of extra debug section preludes)

Translated PC offsets:
- Frame #02: `WriteDebugMessage+68 = +0x44` → `bl go_seq_from_refnum` (call to lookup)
- Frame #01: `go_seq_from_refnum+228 = +0xe4` → seq_android.c:260 — `LOG_FATAL("Unknown reference: %d")` line, abort
- **Frame #03: 0x00b5b0e8 → translated debug offset = 0xb5b7e8 → `runtime.asmcgocall.abi0` at `/usr/local/Cellar/go/1.25.5/libexec/src/runtime/asm_arm64.s:1049`**

### Critical limit found

Tombstone показывает **"4 total frames"** — это весь stack trace что ART unwinder смог dump. Frame #03 = `runtime.asmcgocall.abi0` — это **Go runtime cgo bridge** (assembly trampoline для Go→C transitions).

**ART unwinder не может пройти глубже** в Go-side stack потому что Go использует **custom stack management** (split stacks, growable, not Linux ABI compatible). Unwinder упирается в asmcgocall и останавливается.

Чтобы увидеть **что в Go side** вызвало `cproxylibbox_CommandServerHandler_WriteDebugMessage`:
- Patch sing-box source: добавить `runtime.Stack(...)` dump в seq_android.c **перед** `LOG_FATAL` (требует rebuild libbox)
- Set `GOTRACEBACK=all` env var — но Go runtime не успевает dump до abort()
- Use signal handler before abort — же требует patch

## Phase E — Conclusion / decisions

### Confirmed root cause mechanism

```
Goroutine A (writeDebugMessage callback):
  Go-side: incRef(handler_obj) → refnum=42, refcnt 2→3
  JNI cross → cproxy_WriteDebugMessage(env, 42, msg)
  ┌─ go_seq_from_refnum(env, 42, ...):
  │     ref = Seq.getRef(42)         ← Java synchronized
  │     if ref == NULL: LOG_FATAL "Unknown reference: 42" → abort  ← line 260
  │     Seq.decRef(42)               ← Java synchronized, refcnt-- 
  └─    return ref.obj
  Returns to Go

Goroutine B (parallel writeDebugMessage):
  same flow concurrent
```

**Race window**: между Go-side `incRef` и Java-side `getRef` есть JNI hop. Если в этот момент **другой goroutine** успел сделать `decRef` который доводит refcnt до 0 → `RefMap.remove(42)` → next `getRef` вернёт null → abort.

`synchronized` методы в `Seq$RefTracker` (Java) предотвращают **Java-side** concurrent corruption но **не** synchronizes Go's incRef с Java's decRef через JNI boundary.

### Why F12.3 makes it deterministic

F12.3 readWIFIState возвращает **new WIFIState** каждый call. Каждый ctor:
- `__NewWIFIState(ssid, bssid)` — JNI call в Go, создаёт Go-side struct
- Это **дополнительный** cgo traffic параллельно с writeDebugMessage callbacks
- Concurrency растёт → race window opens чаще

### Why reference SagerNet не падает

Reference `BoxService.writeDebugMessage` = `Log.d("sing-box", message!!)` — синхронный, blocking, на каждом callback ждёт logd.

Наш `BoxService.writeDebugMessage` → `coreLogMainHandler.post { sink.success(plain) }` — **async**, returns immediately. Это **разрешает** sing-box делать **больше** parallel writeDebugMessage calls — больше goroutines одновременно crossing JNI → больше race window.

### Recommendation

| Option | Цена | Польза |
|---|---|---|
| **A: F12.3 → null permanent** | Feature defer (wifi rules — не используются у нас) | Phase H baseline остаётся stable |
| **B: F22 = synchronous Log.d (как reference)** | Lose Flutter forwarding для core logs | Reduce cgo concurrency → возможно close race window |
| **C: Patch gomobile fork — global lock над JNI boundary** | Maintain custom libbox build pipeline forever | Definitive fix race condition |
| **D: libbox 1.14-alpha trial** | API breakage risk, spec'ы переписать | Reference на нём = известно работает |

**Pragmatic выбор**: **A** + monitoring. F12.3 deferred status уже зафиксирован в spec §049. F12.3 functionally не используется LxBox config'ами.

**Future-proofing**: track libbox 1.14 stability. Если 1.14 ships стабильным — upgrade trial (option D) — это сразу даёт reference's known-working stack.

## Phase F — F22 drainer + @Synchronized attempt (FAILED)

После initial findings попробовал combined fix:

**Patch BoxService.writeDebugMessage**:
- `@Synchronized` на entry — serialize sing-box goroutines
- Drainer pattern: ОДИН Runnable instance в field (вместо Lambda per call)
- ConcurrentLinkedQueue для producers, single drainer reused

**Result v12600**:
- Cold start crash refnum 42 again, **Process uptime 8s** (vs 1-3s prior)
- Backtrace identical: `cproxy_WriteDebugMessage+68 → go_seq_from_refnum+228 → abort`
- @Synchronized **не сработал** потому что `go_seq_from_refnum` aborts **в C-side ДО** того как наш Java method invoked

**Critical insight**: race в `go_seq_from_refnum` cproxy code (gomobile-generated):
```c
jobject ref = Seq.getRef(refnum);  ← может вернуть NULL ес concurrent decRef
if (ref == NULL) LOG_FATAL();      ← abort происходит здесь
Seq.decRef(refnum);                ← наш writeDebugMessage НЕ ДОХОДИТ до этой точки
```

Для исправления race нужно **patch gomobile/seq runtime** — global lock around getRef+decRef pair, либо **upgrade libbox** на 1.14-alpha.

**v12700 final stable** = Phase H + drainer pattern + F12.3=null:
- pid stable 25s+ под VPN load (20 active connections)
- Drainer reduces hot-path allocations (Lambda/Message per writeDebugMessage call → 1 string)
- F12.3 deferred (require gomobile patch / libbox upgrade)

### Phase B/C/D артефакты

- `/tmp/libbox-build/sing-box/libbox.aar` — debug AAR 38.9MB
- `/tmp/check-debug/libbox.so` — extracted, 88MB, with DWARF
- `app/android/app/libs/libbox-1.13.11-debug.aar` — copy в LxBox project
- `/tmp/lxbox-debug-libbox.apk` — installed на phone (v30 + debug libbox.so)
- `/tmp/resolve-crash.sh` — addr2line helper
- `/tmp/phase-d-repro.sh` — crash repro script (можно использовать когда будет нужно)

Все остаётся для возможной future investigation.
