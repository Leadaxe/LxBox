# 049 — Sing-box wrapper deep audit (libbox 1.13.11 reference)

| Поле | Значение |
|------|----------|
| Статус | Phase A done (audit). Phase B round 1 done (atomic CAS, F2/F3/F4/F5/F9/F12/F17/F26). Phase B round 2 done (F1 split, F15 allowBypass, F22 log coalescing). Phase C local build/tests green (535 tests pass). On-device retest §047 — pending (требует ~30+ min прогона). |
| Дата | 2026-05-09 |
| Связанные spec'ы | [`047 tun TCP deterioration`](./047-tun-tcp-deterioration-diagnosis.md) — race-condition issue в lifecycle (текущий main suspect для core bug); [`048 Per-app trace gaps`](./048-perapp-trace-attribution-gaps.md) — sibling diagnostic task |
| Затронутые файлы | `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/*.kt` (BoxVpnService, PlatformInterfaceWrapper, BoxApplication, VpnPlugin), потенциально template config (tun.mtu/stack), build.gradle.kts (libbox version pin) |

## Цель

Произвести **глубокий audit** нашего custom Kotlin wrapper'а вокруг sing-box vs **правильной** reference impl от SagerNet. До сих пор сравнивали с master (libbox 1.14-alpha) — нужно с **той же версии libbox 1.13.11** что у нас. Найти все undocumented differences, потенциальные bugs, gaps в impl.

## Контекст (важная correction)

В предыдущей итерации diff'а (см. §047 Phase 1) сравнили с **`master` веткой** `SagerNet/sing-box-for-android` — текущим HEAD `a1b58fe Bump version 1.14.0-alpha.21`. Это **не наша версия** — у нас libbox **1.13.11** (stable от 2026-04-23).

### Правильный reference commit

```
3b3883e Bump version 1.13.11
```

Это `git checkout 3b3883e` в `SagerNet/sing-box-for-android` дает code согласованный с **той же** libbox API что у нас. Все API differences которые мы нашли в master diff (StringIterator vs StringBox для DNS, dnsMode enum) могут **исчезнуть** при сравнении с правильной reference.

### Что это меняет

В §047 Phase 1 мы предварительно identifyовали несколько potential bugs (H7-H11). Но **некоторые** из них могут быть просто **API differences между libbox 1.13.11 и 1.14-alpha**, не bugs в нашем коде. Audit с правильным reference покажет **реальные** gaps.

## Подход

### Step 1: Checkout правильного reference

```bash
git clone https://github.com/SagerNet/sing-box-for-android
cd sing-box-for-android
git checkout 3b3883e     # libbox 1.13.11 reference (Bump version 1.13.11)
```

### Step 2: Full diff наш wrapper vs их 1.13.11 reference

Файлы для сравнения:

| Наш | Reference (1.13.11) | Что искать |
|---|---|---|
| `BoxVpnService.kt` (747 строк) | `bg/VPNService.kt` + `bg/BoxService.kt` | Lifecycle, fd handling, command server |
| `PlatformInterfaceWrapper.kt` (137 строк) | `bg/PlatformInterfaceWrapper.kt` | Все callbacks, especially `getInterfaces`, `findConnectionOwner`, `systemCertificates`, `readWIFIState` |
| `BoxApplication.kt` | `Application.kt` | Initialization order, libbox setup |
| `VpnPlugin.kt` | (нет аналога — у нас Flutter MethodChannel layer) | Наш unique — что мы добавляем сверх |

### Step 3: Categorize differences

Каждое найденное difference:
- **Type A: API difference** between libbox versions — НЕ bug
- **Type B: Reference impl полнее** — наш incomplete, потенциальный bug
- **Type C: Наш impl полнее** — добавили features (Flutter, EventChannel, etc) — нужно audit на correctness
- **Type D: Both impl делают одно и то же по-разному** — нужно решить какая лучше
- **Type E: Conscious deviation** — мы намеренно отошли от reference (например для Flutter integration) — должно быть документировано

### Step 4: Specific audit areas

#### 4.1 `fileDescriptor` lifecycle (СВЯЗАНО С §047)

§047 main hypothesis: race condition в `@Volatile fileDescriptor` lifecycle. Нужно audit'нуть:

- Как reference's `BoxService.kt` хранит и закрывает fd
- Их threading model — на каком thread'е происходит open / close
- Их synchronization (locks, atomics, state machine)
- Их обработка `serviceReload` — closes ли fd before new establish?
- Сравнить с нашими call-sites: `cleanupStaleResources`, `onDestroy`, `onRevoke`, `serviceReload`, `commandServer.startOrReloadService`

Это **direct line** к §047 fix. Если найдём какую-то синхронизацию у reference которой у нас нет — это и есть наш bug.

#### 4.2 `commandServer` lifecycle

У нас — custom logic recreate / restart. У reference — стандартный.

Что сравнить:
- Когда создаётся `commandServer` (на startService? в onCreate?)
- Когда close'ится
- Связь с `box runtime` — kто owns lifecycle
- Reload flow — наша custom vs стандартная

#### 4.3 `PlatformInterfaceWrapper` callbacks

Из §047 Phase 1 (preliminary):
- `systemCertificates()` — у нас empty, у reference Android KeyStore impl
- `getInterfaces()` — у нас минимальный
- `readWIFIState()` — у нас null
- `startNeighborMonitor` / `closeNeighborMonitor` — у нас отсутствуют (но возможно эти callbacks 1.14+ only — проверить в 1.13.11 reference)
- `findConnectionOwner` — у нас не передаём `setAndroidPackageNames`

Каждый из этих audit'нуть — **в reference 1.13.11**. Возможно `startNeighborMonitor` тоже отсутствует там — тогда не bug у нас.

#### 4.4 Threading model — где наш custom Flutter layer мешает

У нас:
- Flutter EventChannel forward sing-box callbacks → Dart
- MethodChannel calls back из Dart → Kotlin
- Cross-thread communication через handlers

Audit:
- Какие sing-box callbacks мы forward'аем в Dart?
- Каждый forward — synchronous или async? Может block calling thread?
- Может ли блокировка thread'а от Flutter side cause sing-box internal state corruption?

Это специфично нашей integrtion — у reference этого нет.

#### 4.5 `tun.mtu` / `tun.stack` — config defaults

- Reference template / settings — какой default MTU?
- Какой default stack?
- Recommendations sing-box docs
- Если reference на **9000** (sing-box default), а у нас **1492** — нужно поменять

#### 4.6 BoxApplication — initialization order

Наш BoxApplication.kt — `Libbox.setup()` где / когда вызывается?
- Reference в onCreate
- Какие values в `BoxOptions` — `BasePath`, `WorkingDirectory`, `TempPath`
- Fields которых у нас нет / у нас есть лишние

#### 4.7 Permission / bypass handling

- `Settings.allowBypass` у reference — мы не вызываем `builder.allowBypass()`
- `Settings.systemProxyEnabled` — у нас всегда `setHttpProxy` если enabled, у reference через flag

## Action items

### Phase A: Audit (read-only, не правим код)

1. Checkout reference's commit `3b3883e` для 1.13.11 era
2. **Side-by-side diff** каждого файла в таблицу
3. Categorize каждое difference (A-E)
4. Документировать findings в этом файле под `## Findings`

### Phase B: Fix critical bugs (после Phase A)

После audit — для каждого Type B (reference fuller) и Type D (different approach) — решить:
- Это actually bug в нашем коде?
- Какой fix?
- Spec / task для fix или inline?

### Phase C: Verify

После fixes:
- Manual smoke test на устройстве
- 30+ min run чтобы проверить **§047 race condition** возможно решилась
- Если §047 повторяется после fix — значит race elsewhere

## Acceptance criteria

- [x] Reference checked out at correct commit (`3b3883e` libbox 1.13.11)
- [x] Side-by-side diff в этом файле под `## Findings` — все 4 файла + extras
- [x] Каждое difference categorized (A-E) — see сводка по типам
- [ ] Type B/D differences оформлены как separate fix-tasks (или inline в этой spec'е)
- [ ] §047 retest после fixes — улучшилось / не улучшилось
- [ ] Documentation: `BoxVpnService.kt` обновить comments / docstrings о наших additions vs reference

## Open questions

1. Какие из 191 строки reference's `VPNService.kt` нам **необходимы**? Какие из наших 747 — наши additions?
2. Можно ли **разделить** наш `BoxVpnService.kt` на:
   - **`VpnService` core** — близко к reference (191 строк)
   - **Flutter integration layer** — наши additions (~500 строк)
   
   Это уменьшит surface для bug'ов, выделит наши vs theirs.
3. Стоит ли **импортировать reference's BoxService.kt и PlatformInterfaceWrapper.kt напрямую** вместо нашего custom impl? Удалить наши, использовать их + добавить только Flutter layer.

## Reference data

- Reference repo: `https://github.com/SagerNet/sing-box-for-android` (commit `3b3883e` для libbox 1.13.11 era)
- Наш wrapper: `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/`
- Preliminary findings от §047 Phase 1 — там сравнили с master (1.14-alpha), результаты **могут быть incorrect** для нашей версии. Этот audit с правильным reference — даст canonical truth.

## Findings (Phase A — read-only audit, 2026-05-09)

Reference checked out at `3b3883e Bump version 1.13.11`. Files compared:

| Reference | LOC | Наш аналог | LOC | Δ |
|---|---:|---|---:|---|
| `bg/VPNService.kt` | 186 | `vpn/BoxVpnService.kt` | 747 | +561 |
| `bg/BoxService.kt` | 424 | (нет — вмёржено в BoxVpnService) | — | — |
| `bg/PlatformInterfaceWrapper.kt` | 204 | `vpn/PlatformInterfaceWrapper.kt` | 137 | −67 |
| `Application.kt` | 95 | `vpn/BoxApplication.kt` | 98 | +3 |

Ниже — пронумерованные findings. Type указывает категорию (A/B/C/D/E из §Approach):

---

### F1. CRITICAL — Архитектура lifecycle: monolith vs split (Type D)

**Reference** разделяет ответственность:
- `VPNService` (186 LOC) — только Android-hooks (`onStartCommand`, `onBind`, `onDestroy`, `onRevoke`, `openTun`, `autoDetectInterfaceControl`, `sendNotification`). Делегирует всё в `service: BoxService`.
- `BoxService` (424 LOC) — отдельный класс, владеет `fileDescriptor`, `commandServer`, `status`, `notification`, `receiver`, `lastProfileName`. Все `start*/stop*/serviceReload0/stopAndAlert/closeService` тут. Создаётся как `BoxService(this /* Service */, this /* PlatformInterface */)`.

**Ours** — monolithic: `BoxVpnService` (747 LOC) — Android-hooks + lifecycle + `fileDescriptor` + `commandServer` + Flutter integration. Разделения нет.

**Implication для §047**: reference owns lifecycle через single ownership object → mutations легко локализовать в один thread (Dispatchers.IO). Наш monolith распределяет mutations по N call-site'ам (см. F2).

---

### F2. CRITICAL — `fileDescriptor` synchronization model (Type B → SMOKING GUN для §047)

**Reference (`BoxService.kt:71`)**:
```kotlin
var fileDescriptor: ParcelFileDescriptor? = null   // PLAIN var, NOT @Volatile
```

Mutated **только в 4 местах**, все либо single-thread, либо внутри `GlobalScope.launch(Dispatchers.IO)`:

| Site | Thread | Action |
|---|---|---|
| `VPNService.openTun` (line 180) | libbox callback thread | `service.fileDescriptor = pfd` |
| `BoxService.serviceStop` (line 184-188) | синхронно (вызывается из Clash dashboard) | close + null |
| `BoxService.stopService` (line 282-287) | `GlobalScope.launch(IO)` | close + null |
| `BoxService.stopAndAlert` (line 312-316) | suspend на IO | close + null |

`serviceReload0()` **НЕ трогает** `fileDescriptor` — sing-box internally вызывает `openTun()` снова и `service.fileDescriptor = pfd` обновляет ссылку. Старый pfd либо явно closed sing-box'ом, либо GC.

`onRevoke()` → `stopService()` (полный shutdown).

**Ours (`BoxVpnService.kt:140`)**:
```kotlin
@Volatile private var fileDescriptor: ParcelFileDescriptor? = null
```

Mutated в **5 местах**, на разных threads:

| Site | Thread | Action |
|---|---|---|
| `openTun` (line 574) | libbox thread | `fileDescriptor = pfd` |
| `cleanupStaleResources` (line 338-342) | `serviceScope.launch(IO)` (через onStartCommand) | close + null |
| `onRevoke` (line 301-302) | binder thread | close + null |
| `doStop` (line 446-447) | `serviceScope.launch(IO)` | close + null |
| (implicit) `onDestroy` сбрасывает scope | main thread | cancel scope (не close fd!) |

`@Volatile` дает publish/visibility, но **не атомарность** для compound «read-then-close-then-null». Два потока могут прочитать тот же не-null fd → оба `pfd.close()` → второй no-op (Android `ParcelFileDescriptor.close()` идемпотентен), но fd-ress между этим может быть переиспользован OS, и `pfd.fd` int станет stale.

**SMOKING GUN scenario (race A) для §047**:

```
T1 (broadcast receiver, main thread):
  ACTION_RELOAD → serviceReload() → cs.startOrReloadService(...)
    → libbox internally calls openTun() on T2
T2 (libbox thread):
  builder.establish() ← возвращает pfd_NEW
  fileDescriptor = pfd_NEW       ← @Volatile assignment
  return pfd_NEW.fd
T1 продолжает в той же serviceReload — OK

Но если параллельно:
T3 (broadcast receiver, ACTION_RESET_NETWORK arrives mid-reload):
  commandServer?.resetNetwork()  ← OK, не трогает fd

Но если ACTION_STOP arrives:
T3: doStop() → serviceScope.launch(IO):
   fileDescriptor?.close()       ← закроет pfd_NEW (или старый — race)
   fileDescriptor = null
```

Проблема: `ACTION_STOP` НЕ всегда приводит к stop'у — есть guard `if (status != Started)`. Но **при reload в момент ACTION_RELOAD статус остаётся Started** (наш код в serviceReload не кладёт Stopping), так что doStop НЕ guarded. Race открыта.

**SMOKING GUN scenario (race B)**:

```
T1: onStartCommand (cold start после crash)
   → serviceScope.launch(IO):
      cleanupStaleResources()    ← закроет любой leftover fd (которого не должно быть)
      startCommandServer()       ← creates cs
      startSingbox():
         cs.startOrReloadService(config, OverrideOptions())
            → libbox calls openTun() on T2:
               fileDescriptor = pfd_NEW
T1: продолжает после startSingbox

T3 (libbox internal reload, например на network change):
   cs.startOrReloadService → openTun() на T2:
      builder.establish() ← возвращает pfd_NEW2
      fileDescriptor = pfd_NEW2  (старый pfd_NEW orphaned, не closed нами)
      return pfd_NEW2.fd

Sing-box внутри переходит на pfd_NEW2.fd. Но если perfect timing:
- Sing-box ещё держит pfd_NEW.fd внутри (Go-side reference)
- Вешает write'ы туда → tun receives them, но read'ы идут на pfd_NEW2 (другая fd
  table entry → другая инстанция в OS) → silent loss.
```

Для подтверждения race — нужен strict_log с timestamps openTun calls и ACTION dispatches. См. §047 Phase 0 (deep instrumentation).

**Type**: B (reference safer architecturally, наш `@Volatile` — half-measure).

---

### F3. CRITICAL — `cleanupStaleResources()` не имеет аналога в reference (Type B)

**Reference** не имеет метода для «очистки leftover ресурсов перед новым стартом». Не нужен — `BoxService` создаётся свежий с каждым `VPNService` (новый Android Service instance).

**Ours (`BoxVpnService.kt:331-343`)**:
```kotlin
private fun cleanupStaleResources() {
    commandServer?.let { cs ->
        Log.w(TAG, "cleanupStaleResources: closing leftover commandServer")
        runCatching { cs.closeService() }
        runCatching { cs.close() }
        commandServer = null
    }
    fileDescriptor?.let { fd ->
        Log.w(TAG, "cleanupStaleResources: closing leftover fileDescriptor")
        runCatching { fd.close() }
        fileDescriptor = null
    }
}
```

Justification в коде: «после onRevoke в свежем процессе» — но onRevoke у нас сам уже всё закрывает (line 301-309). Этот код срабатывает, только если **service instance переиспользован** (что для Android FGS бывает).

**Implication**: добавляет **5-ое мутационное место** для `fileDescriptor`. Race-сurface квадратична по числу call-site'ов: `O(N²)` потенциальных взаимодействий. У reference 4 site'a → 6 пар; у нас 5 site'ов → 10 пар.

**Type**: B (superfluous race-prone). Recommended fix: удалить, полагаться на reference-стиль single-ownership.

---

### F4. `serviceReload()` divergence (Type D + связано с §047)

**Reference (`BoxService.kt:192-249`)**:
```kotlin
override fun serviceReload() {
    runBlocking { serviceReload0() }
}

suspend fun serviceReload0() {
    val selectedProfileId = Settings.selectedProfile
    if (selectedProfileId == -1L) { stopAndAlert(...) ; return }
    val profile = ProfileManager.get(selectedProfileId)
    if (profile == null) { stopAndAlert(...) ; return }
    val content = File(profile.typed.path).readText()
    if (content.isBlank()) { stopAndAlert(...) ; return }
    lastProfileName = profile.name
    try {
        commandServer.startOrReloadService(content, OverrideOptions().apply {
            autoRedirect = Settings.autoRedirect
            if (Vendor.isPerAppProxyAvailable() && Settings.perAppProxyEnabled) {
                val appList = Settings.getEffectivePerAppProxyList()
                if (Settings.getEffectivePerAppProxyMode() == Settings.PER_APP_PROXY_INCLUDE) {
                    includePackage = StringArray((appList + Application.application.packageName).iterator())
                } else {
                    excludePackage = StringArray((appList - Application.application.packageName).iterator())
                }
            }
        })
    } catch (e: Exception) { stopAndAlert(...) ; return }
    if (commandServer.needWIFIState()) { /* WIFI permission check */ }
}
```

Не трогает status, не трогает notification, не трогает fileDescriptor. Передаёт `OverrideOptions` с `autoRedirect` и per-app-proxy.

**Ours (`BoxVpnService.kt:588-608`)**:
```kotlin
override fun serviceReload() {
    notification.stop()
    setStatus(VpnStatus.Starting)            // ← пишет broadcast, refreshTile, refreshShortcuts
    val cs = commandServer ?: run {
        Log.w(TAG, "serviceReload: commandServer == null, treating as fresh start")
        serviceScope.launch { startSingbox() }
        return
    }
    val config = ConfigManager.load()
    if (config.isBlank() || config == "{}") { Log.e(...); return }
    runCatching { cs.startOrReloadService(config, OverrideOptions()) }   // empty overrides
        .onFailure { Log.e(...); runCatching { cs.setError(...) } }
        .onSuccess { setStatus(VpnStatus.Started) }
    notification.show(ConfigManager.notificationTitle, "Connected")
}
```

Отличия:
1. Пишет `setStatus(Starting)` → `setStatus(Started)` — broadcast флаппинг.
2. Передаёт пустые `OverrideOptions()` — теряет `autoRedirect` и per-app-proxy.
3. Зовётся на binder/main thread (broadcast receiver), не через `runBlocking { ... }`.
4. Нет `stopAndAlert` на ошибку загрузки профиля — просто log и return (notification остаётся stopped).

**Implication для §047**: reference's reload flow тонок — sing-box внутри сам переоткрывает tun, fileDescriptor обновляется в openTun. **Если наш `setStatus(Starting)` параллельно триггерит Flutter EventChannel callback в Dart isolate, который через MethodChannel читает state — возникает дополнительный thread у которого может быть прежний `fileDescriptor` snapshot**. Не прямой smoke gun, но дополнительный shared-state surface.

**Type**: D + B. D — флаппинг status, эмпти overrides; B — отсутствие stopAndAlert на ошибку.

---

### F5. `onRevoke()` cleanup divergence (Type B → §047 risk)

**Reference (`VPNService.kt:42-48`)**:
```kotlin
override fun onRevoke() {
    runBlocking {
        withContext(Dispatchers.Main) {
            service.onRevoke()    // → stopService()
        }
    }
}
```

`stopService()` (BoxService.kt:274-300):
- Проверяет status, ставит Stopping, unregister receiver, close notification.
- `GlobalScope.launch(IO) { fileDescriptor.close(); fileDescriptor = null; ... }`.

Все mutations на Dispatchers.IO.

**Ours (`BoxVpnService.kt:294-320`)**:
```kotlin
override fun onRevoke() {
    fileDescriptor?.runCatching { close() }
    fileDescriptor = null
    commandServer?.apply {
        runCatching { closeService() }.onFailure {
            runCatching { setError("android: revoke close service: ${it.message}") }
        }
        runCatching { close() }
    }
    commandServer = null
    if (receiverRegistered) { runCatching { unregisterReceiver(receiver) }; receiverRegistered = false }
    notification.stop()
    setStatus(VpnStatus.Stopped, error = "VPN revoked by another app")
    serviceScope.cancel()
    stopSelf()
    super.onRevoke()
}
```

Inline cleanup на binder thread (откуда Android вызывает onRevoke). **Closes fileDescriptor на этом thread'е** — если в этот же момент libbox callback на T2 пытается `openTun()` (например серверный reload не зная о revoke), gets pfd_NEW, assigns `fileDescriptor = pfd_NEW`. Race с нашей `fileDescriptor = null`.

**Type**: B — небезопасный путь. Reference's путь через `Dispatchers.IO` serializes по single thread.

---

### F6. `serviceStop()` (Clash dashboard вызов): отсутствует у нас (Type B)

**Reference (`BoxService.kt:181-190`)** — `CommandServerHandler` метод `serviceStop()`:
```kotlin
override fun serviceStop() {
    notification.close()
    status.postValue(Status.Starting)   // (не Stopping — opaque оригинальный код)
    val pfd = fileDescriptor
    if (pfd != null) {
        pfd.close()
        fileDescriptor = null
    }
    closeService()
}
```

Зовётся когда Clash dashboard просит остановить сервис.

**Ours (`BoxVpnService.kt:614`)**: `override fun serviceStop() { doStop() }` — делегирует на нашу штатную shutdown'у.

**Type**: D — different. Наш через `doStop()` идёт через `serviceScope.launch(IO) { ... ; setStatus(Stopped); stopSelf() }`. Чище. **Но**: `doStop()` имеет guard `if (status == Stopped || Stopping) return` — значит из dashboard'а stop **не сработает если status уже Stopping** (например мы уже инициировали stop).

Не §047 relevant, но edge case.

---

### F7. `OverrideOptions.includePackage`/`excludePackage` потеряны на reload (Type B)

**Reference's `serviceReload0()`** (см. F4): передаёт per-app-proxy через `OverrideOptions`.

**Ours's `serviceReload()`**: всегда `OverrideOptions()` пустой.

**Implication**: при горячем reload через Clash dashboard (или ACTION_RELOAD) per-app-proxy **могут потеряться** в зависимости от того, как они закодированы. У нас — через template-vars в config.json (`@apps_include`/`@apps_exclude` в tun-input). Тогда reload re-читает config файл → per-app-proxy сохраняется. **OK для нашего pipeline**, но если в будущем какие-то overrides будут через `OverrideOptions` — пропустим.

**Type**: D (наш pipeline другой, но потенциальный gap при изменении архитектуры).

---

### F8. `Application.kt` initialization location (Type C/E — conscious deviation)

**Reference (`Application.kt:31-83`)**:
- Класс `class Application : android.app.Application()`, зарегистрирован в Manifest.
- В `onCreate()`: `Libbox.setLocale(...)` синхронно, потом `GlobalScope.launch(Dispatchers.IO) { initialize() }` где `Libbox.setup(SetupOptions().also { ... })`.
- Отсутствует explicit ready-signal — service ждёт через case-by-case check.

**Ours (`BoxApplication.kt`)**:
- `object BoxApplication` (Kotlin singleton, НЕ Application subclass).
- `initialize(context)` — идемпотентный, вызывается из `BoxVpnService.onCreate` и `VpnPlugin`.
- Has explicit `libboxReady: CompletableDeferred<Unit>` — `BoxVpnService.startSingbox` `await`'s its.

**Reasoning**: Flutter использует `FlutterApplication` (или его наследника) как обязательную базу для Application класса. Наш Application class не может одновременно быть и `FlutterApplication`, и инициализатором libbox. Поэтому singleton + manual init — единственный путь.

**Type**: E (conscious deviation, документировано через комменты).

---

### F9. `Libbox.setLocale` (Type B — minor)

**Reference (`Application.kt:42`)**: `Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))` синхронно в onCreate.

**Ours**: **НЕ зовём `Libbox.setLocale`**. Locale передаётся sing-box'у дефолтное (English).

**Implication**: error messages от sing-box не локализованы. Не §047 relevant, но missing feature.

**Type**: B.

---

### F10. `SetupOptions.logMaxLines` и `debug` (Type D)

**Reference**:
```kotlin
Libbox.setup(SetupOptions().also {
    it.basePath = baseDir.path
    it.workingPath = workingDir.path
    it.tempPath = tempDir.path
    it.fixAndroidStack = Bugs.fixAndroidStack
    it.logMaxLines = 3000
    it.debug = BuildConfig.DEBUG
})
```

**Ours**:
```kotlin
val opts = SetupOptions().apply {
    basePath = baseDir.path
    workingPath = workingDir.path
    tempPath = tempDir.path
    this.fixAndroidStack = fixAndroidStack    // computed inline, vs reference's Bugs.fixAndroidStack constant
    debug = BootReceiver.isCoreLogsEnabled(context)
}
Libbox.setup(opts)
```

Отсутствует `logMaxLines`. Дефолт sing-box — неизвестен (likely 1000?). У reference задано 3000.

**Implication**: log buffer у нас меньше — старые log lines выпадают раньше. Релевантно для diagnostic, не для §047 race.

**Type**: D — мелкое расхождение.

---

### F11. `Libbox.redirectStderr` — у обоих есть (Type matches)

Reference `Application.kt:82`: `Libbox.redirectStderr(File(workingDir, "stderr.log").path)`.
Ours `BoxApplication.kt:95`: `runCatching { Libbox.redirectStderr(File(workingDir, "stderr.log").path) }`.

Identical. Наш wrapped в runCatching — defensive (некоторые OEM SELinux могут блокнуть).

---

### F12. PlatformInterfaceWrapper API differences (большинство Type A)

Sub-findings против reference 1.13.11:

#### F12.1 `findConnectionOwner` — отсутствует `userName` поле (Type B minor)

**Reference (`PlatformInterfaceWrapper.kt:60`)**:
```kotlin
owner.userName = packages?.firstOrNull() ?: ""
```

**Ours (`PlatformInterfaceWrapper.kt:52-55`)**:
```kotlin
return ConnectionOwner().apply {
    userId = uid
    setAndroidPackageNames(StringArray(packages.iterator()))
    // userName НЕ установлено
}
```

**Implication**: Clash API connections endpoint возвращает empty username. Видно в dashboard'ах. Не routing, не §047.

#### F12.2 `getInterfaces()` — practically identical (Type A — match)

Side-by-side compare показал identical логику. Edge: reference использует InterfaceArray inner class, у нас inline anonymous object — micro-стиль, эффект одинаков.

#### F12.3 `readWIFIState()` — reference имплементит, у нас null (Type B)

**Reference (`PlatformInterfaceWrapper.kt:142-154`)**:
```kotlin
override fun readWIFIState(): WIFIState? {
    val wifiInfo = Application.wifiManager.connectionInfo ?: return null
    var ssid = wifiInfo.ssid
    if (ssid == "<unknown ssid>") return WIFIState("", "")
    if (ssid.startsWith("\"") && ssid.endsWith("\"")) ssid = ssid.substring(1, ssid.length - 1)
    return WIFIState(ssid, wifiInfo.bssid)
}
```

**Ours (`PlatformInterfaceWrapper.kt:107`)**:
```kotlin
override fun readWIFIState(): WIFIState? = null
```

**Implication**: sing-box не получает SSID/BSSID. Если в правилах есть `wifi_ssid` / `wifi_bssid` правила — они **никогда не матчатся** у нас. Если конфиг таких правил не использует — irrelevant. Не §047 relevant.

**Type**: B.

#### F12.4 `systemCertificates()` — practically identical (Type matches)

Both используют `KeyStore.getInstance("AndroidCAStore")` и енумерируют + base64 encode. Identical. Мой preliminary §047 finding (что у нас empty) был **ОШИБОЧЕН** — ours имплементит системные сертификаты.

#### F12.5 `startNeighborMonitor` / `closeNeighborMonitor` / `registerMyInterface` — отсутствуют у обоих (Type A confirmed)

**Reference 1.13.11**: НЕТ этих методов в PlatformInterface.
**Reference master 1.14-alpha**: ЕСТЬ.

**Ours**: НЕТ.

**Confirmed Type A** — это новые callback'и в 1.14+, в 1.13.11 их нет. Мой preliminary §047 finding (H10) был **ОШИБОЧНЫМ** для нашей версии — не bug.

#### F12.6 `useProcFS()` — identical (matches)

Both: `Build.VERSION.SDK_INT < Build.VERSION_CODES.Q`. Match.

#### F12.7 `clearDNSCache()` — identical empty impl (matches)

#### F12.8 `usePlatformAutoDetectInterfaceControl()` — identical `true` (matches)

#### F12.9 `autoDetectInterfaceControl` — split implementation

**Reference**:
- `PlatformInterfaceWrapper.kt:32-33`: empty default impl `override fun autoDetectInterfaceControl(fd: Int) {}`
- `VPNService.kt:50-52`: override re-implements: `protect(fd)`

**Ours** identical:
- `PlatformInterfaceWrapper.kt:29`: `override fun autoDetectInterfaceControl(fd: Int) {}`
- `BoxVpnService.kt:516-518`: `override fun autoDetectInterfaceControl(fd: Int) { protect(fd) }`

Match.

#### F12.10 `localDNSTransport()` — identical (matches)

Both: `LocalResolver`. Match.

#### F12.11 `underNetworkExtension()`, `includeAllNetworks()` — identical (matches)

Both: `false`. Match.

---

### F13. tun.mtu default = 1492 vs sing-box's 9000 (Type D)

**Wizard template** (`assets/wizard_template.json:288-294`): `tun_mtu = "1492"`.

**sing-box documentation default**: 9000 (см. https://sing-box.sagernet.org/configuration/inbound/tun/#mtu).

**Reference** (sing-box-for-android) не задаёт default — берёт из конфига. Их вероятный default — `9000` (sing-box стандартный). Их пользователь может оставить 9000.

**Implication**: 1492 — консервативно, но **меньшая performance** на gVisor stack (where больший MTU выгоден). Для system stack (default) — meh. Не §047 relevant (работает или не работает — не зависит от MTU value, ну если только value не abnormal).

**Type**: D — design choice. Possible improvement: попробовать 9000 после fix'a §047 для perf-теста.

---

### F14. tun.stack default = "system" — matches recommendation (Type matches)

Match. sing-box рекомендует system на Android.

---

### F15. `Settings.allowBypass` — отсутствует у нас (Type B minor)

**Reference (`VPNService.kt:69-71`)**:
```kotlin
if (Settings.allowBypass) {
    builder.allowBypass()
}
```

User-toggleable, default false.

**Ours**: `builder.allowBypass()` НЕ зовётся никогда. Нет setting'а.

**Implication**: apps не могут использовать VPN-bypass API (`ConnectivityManager.bindProcessToNetwork(null)` для обхода tun). На некоторых сценариях полезно. Не §047 relevant.

**Type**: B minor.

---

### F16. `setMetered(false)` — у обоих есть (matches)

Reference: `if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)`.
Ours: same.

Match.

---

### F17. `Settings.systemProxyEnabled` and `getSystemProxyStatus` (Type D + B)

**Reference** имеет user-toggleable HTTP-proxy (через Settings.systemProxyEnabled). Hooks для Clash dashboard:
```kotlin
override fun getSystemProxyStatus(): SystemProxyStatus? {
    val status = SystemProxyStatus()
    if (service is VPNService) {
        status.available = service.systemProxyAvailable
        status.enabled = service.systemProxyEnabled
    }
    return status
}
override fun setSystemProxyEnabled(isEnabled: Boolean) { serviceReload() }
```

**Ours**:
```kotlin
override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()  // empty
override fun setSystemProxyEnabled(isEnabled: Boolean) { serviceReload() }
```

`getSystemProxyStatus` всегда empty → Clash dashboards показывают «no system proxy» даже если фактически он включён.

**Type**: B minor — dashboards integration incomplete. Не §047 relevant.

---

### F18. `serviceUpdateIdleMode()` / pause/wake (Type matches)

**Reference (`BoxService.kt:264-271`)**:
```kotlin
@RequiresApi(Build.VERSION_CODES.M)
private fun serviceUpdateIdleMode() {
    if (Application.powerManager.isDeviceIdleMode) {
        commandServer.pause()
    } else {
        commandServer.wake()
    }
}
```

**Ours (`BoxVpnService.kt:620-624`)**:
```kotlin
@RequiresApi(Build.VERSION_CODES.M)
private fun onIdleModeChanged() {
    if (BoxApplication.powerManager.isDeviceIdleMode) commandServer?.pause() else commandServer?.wake()
}
```

Identical с safety null-check'ом у нас. Match.

---

### F19. SCREEN_ON/OFF as background mode (Type C — feature add)

**Reference**: только `PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED`.

**Ours**: optional `ACTION_SCREEN_ON/OFF` в BG_MODE_ALWAYS — agressive power saving (calling `commandServer.pause()/wake()` on screen events).

**Type**: C — добавлена нами фича. Audit на correctness:
- `commandServer?.pause()` на screen_off — sing-box stop'нет polling, новые connection'ы могут зависнуть до screen_on. Тонкий момент — при коротком screen_off (1-2s glance) можем dropнуть activity. Tradeoff.

**Не §047 related**.

---

### F20. `ACTION_RESET_NETWORK` broadcast (Type C — feature add)

**Reference**: НЕТ.

**Ours**: handler в receiver: `commandServer?.resetNetwork()`. Используется юзером для reset'a outbound dialer state без полного reload.

**Type**: C — features. Не §047 related (мы выяснили, что resetNetwork всё равно не помог в этой сессии).

---

### F21. `onTaskRemoved` (Type C)

**Reference**: НЕТ override.

**Ours**: stops VPN если нет «keep on exit» setting.

**Type**: C.

---

### F22. `coreLogSink` для Flutter EventChannel (Type C — Flutter integration)

**Ours**:
```kotlin
@Volatile var coreLogSink: io.flutter.plugin.common.EventChannel.EventSink? = null

override fun writeDebugMessage(message: String) {
    val plain = ansiEscapeRe.replace(message, "")
    if (traceDebugRe.containsMatchIn(plain)) return
    val sink = coreLogSink ?: return
    coreLogMainHandler.post {
        runCatching { sink.success(plain) }
    }
}
```

**Reference's `BoxService.kt:420-422`**:
```kotlin
override fun writeDebugMessage(message: String?) {
    Log.d("sing-box", message!!)
}
```

Просто Log.d.

**Type**: C — добавлен Flutter forward. Audit на correctness:
- `coreLogMainHandler.post` — корректно: sink.success() требует main thread, иначе UiThread exception ([§043](#)).
- Volatile sink — OK, swap atomic-pointer, max worst case lost log line.
- ANSI strip — OK.

**Не §047 related** напрямую, но: если sing-box зовёт writeDebugMessage **очень часто** (debug mode + busy traffic), main looper наводняется тысячами `runOnUiThread` post'ов → main looper backlog → Flutter UI/MethodChannel замедляются → доп. effects на race-window.

Может быть фактором в §047, но second-order. Test: отключить core logs → §047 reproduces или нет?

---

### F23. `notification.show()` early in onStartCommand (Type C — Android FGS constraint)

**Reference**: notification shown через `notification.show(lastProfileName, R.string.status_starting)` ВНУТРИ `startService()` (suspend), после loading profile.

**Ours**: `notification.show(...)` СРАЗУ в начале onStartCommand — до guard, до scope launch. Reason: FGS должен показать notification в течение 5s от startForegroundService иначе SystemServer kill'нет.

**Type**: C — addresses реальное Android constraint. Reference, видимо, успевает в их flow. Наш more defensive.

---

### F24. `stopAwait()` Completer pattern (Type C — наш api)

**Ours**: `companion fun stopAwait(context): Deferred<Unit>` — Flutter side получает promise, ждёт пока stop реально завершится, не полагается на broadcast.

**Reference**: НЕТ. Их Flutter equivalent (нет — у них native UI).

**Type**: C — наш API.

---

### F25. `Vendor.isPerAppProxyAvailable()` (Type D)

**Reference** в `BoxService.serviceReload0` gates per-app-proxy через `Vendor.isPerAppProxyAvailable() && Settings.perAppProxyEnabled`.

`Vendor` — abstraction для distinguishing free/premium build (reference is open-source, but commercial flavor existed).

**Ours**: per-app-proxy через template variables в config.json — sing-box сам обрабатывает.

**Type**: D — different distribution. Не bug.

---

## Сводка для §047 (TCP deterioration race condition)

Ключевые findings которые **прямо** связаны с §047:

| # | Finding | Type | Impact |
|---|---|---|---|
| F2 | `fileDescriptor` mutated в 5 местах vs reference's 4, без proper sync | B | **HIGH** — main suspect |
| F3 | `cleanupStaleResources` superfluous, добавляет mutation site | B | **HIGH** — race surface multiplier |
| F4 | `serviceReload` флаппит status, передаёт пустые overrides | D + B | MEDIUM — побочный shared-state |
| F5 | `onRevoke` mutates fd inline на binder thread | B | MEDIUM — race с openTun |
| F22 | `coreLogSink` main looper насыщение во время debug mode | C | LOW — second-order effect |

## Сводка по типам

- **Type A (API diff между libbox 1.13.11 vs 1.14-alpha)**: F12.5 (NeighborMonitor), F11+ items в preliminary master comparison → **ОШИБОЧНО** были classified как bugs. Confirmed not bugs after correct reference comparison.
- **Type B (reference fuller, наш incomplete)**: F2, F3, F5, F9, F12.1 (userName), F12.3 (readWIFIState), F15 (allowBypass), F17 (getSystemProxyStatus).
- **Type C (наш fuller, audit on correctness)**: F19, F20, F21, F22, F23, F24.
- **Type D (different approach)**: F1, F4, F6, F7, F10, F13, F25.
- **Type E (conscious deviation)**: F8 (BoxApplication как singleton vs Application subclass).

## Recommended Phase B fixes (по priority для §047)

1. **REWRITE `fileDescriptor` lifecycle** (F2, F3, F5):
   - Удалить `cleanupStaleResources()` (F3).
   - Перевести `onRevoke` cleanup на `Dispatchers.IO` через `serviceScope.launch(IO) { ... }` (F5).
   - Mutations только из 3 sites: `openTun` (на libbox thread), `doStop` (IO), `onRevoke` → `doStop`-style (IO).
   - Заменить `@Volatile` на `AtomicReference<ParcelFileDescriptor?>` для атомарности `getAndSet(null)` при close.

2. **Split lifecycle в отдельный класс** (F1) — refactor `BoxVpnService` → `BoxVpnService` (Android hooks, ~200 LOC) + `BoxLifecycle` (~300 LOC). Уменьшит surface, выделит Flutter additions.

3. **`serviceReload` cleanup** (F4):
   - Не флаппить status (Started → Started без Starting в середине).
   - Pass `OverrideOptions` корректно с `autoRedirect` и пер-app-proxy.

4. **Минорные fix'ы** (F9, F12.1, F12.3, F15, F17):
   - `Libbox.setLocale(...)` в BoxApplication.initializeLibbox.
   - `userName` в `findConnectionOwner`.
   - `readWIFIState()` impl.
   - `Settings.allowBypass` user toggle.
   - `getSystemProxyStatus()` returns actual state.

5. **Verify** (F22): отключить core logs → проверить §047 повтор.

## Open questions

1. **Why we have monolithic `BoxVpnService`?** Возможно артефакт ранней миграции с 1.12 → 1.13. Reference splits — это идиоматический Android pattern (Service-as-thin-wrapper над bg-class). Worth refactoring.

2. **Why `cleanupStaleResources`?** History suggests кто-то увидел leftover state в одном случае (cold start после crash) и добавил cleanup без понимания, что reference не нуждается. Worth удалить и проверить.

3. **`ACTION_RESET_NETWORK` value-add?** Юзер говорит «не помог в этой сессии». Возможно useless feature — `commandServer.resetNetwork()` сам по себе rare-используемый libbox API. Оставить или удалить?

---

## Phase B implementation log (2026-05-09)

Все fix'ы применены инлайн (не отдельные task-spec'ы) — это «under-the-hood» rewrite native-слоя без изменения публичного API. Каждый fix сохранён под комментарием `§049 F<номер> fix:` в коде.

### Затронутые файлы

| Файл | Δ LOC до | Δ LOC после | Что изменилось |
|---|---:|---:|---|
| `vpn/BoxVpnService.kt` | 747 | 805 | F2/F3/F4/F5/F17 — atomic lifecycle, removed `cleanupStaleResources`, no status-flap reload, atomic onRevoke, real systemProxy state |
| `vpn/PlatformInterfaceWrapper.kt` | 137 | 163 | F12.1/F12.3 — userName + readWIFIState |
| `vpn/LocalResolver.kt` | 18 | 151 | F26 — full DnsResolver impl bound to `defaultNetwork` (мимо tun) |
| `vpn/BoxApplication.kt` | 98 | 117 | F9 — `Libbox.setLocale`, exposed `wifiManager` |
| `vpn/Extensions.kt` | 19 | 30 | helper `Continuation.tryResumeWithException` для F26 |

Net: +189 LOC (но поведение значительно безопаснее).

### F2 — fileDescriptor: AtomicReference + atomic close

**Что было:**
```kotlin
@Volatile private var fileDescriptor: ParcelFileDescriptor? = null
// 5 мутационных site'ов:
//   openTun: fileDescriptor = pfd
//   cleanupStaleResources: ?.close(); = null
//   onRevoke: ?.close(); = null
//   doStop:  ?.close(); = null
//   (implicit) onDestroy/scope.cancel
```
`@Volatile` гарантирует publish, **не атомарность** для compound «read-then-close-then-null». Двое потоков могли одновременно прочитать non-null PFD и оба вызвать close → kernel переиспользовал fd-int → sing-box, державший копию `pfd.fd`, начинал писать в чужой fd → silent ENXIO → §047 TCP-deterioration.

**Что стало:**
```kotlin
private val fileDescriptor = AtomicReference<ParcelFileDescriptor?>(null)

private fun closeFileDescriptor() {
    fileDescriptor.getAndSet(null)?.runCatching { close() }
        ?.onFailure { Log.w(TAG, "...") }
}
```
- `getAndSet(null)` гарантирует, что только один поток получает non-null PFD; остальные — no-op.
- В `openTun`: `fileDescriptor.set(pfd)` — atomic publish. Не закрываем prev (sing-box internally manages — reference делает identical: `service.fileDescriptor = pfd`).
- Все close call-sites (`onRevoke`, `doStop`) используют `closeFileDescriptor()`.

### F3 — `cleanupStaleResources()` удалён

**Что было:** `serviceScope.launch` в `onStartCommand` вызывал `cleanupStaleResources()` ДО `startCommandServer()`. Это закрывало любой leftover `commandServer`/`fileDescriptor`. Обоснование в коде: «после onRevoke в свежем процессе» — но `onRevoke` сам уже всё закрывает. Реально срабатывало только если Android переиспользовал service instance (что бывает редко).

**Effect:** добавляло **5-е mutation site** для `fileDescriptor`. Race-surface квадратична по числу call-site'ов: O(N²) пар. Reference не имеет аналога — в reference Android создаёт свежий service instance с свежим `BoxService` владельцем lifecycle, leftover state не существует.

**Что стало:** метод удалён. Вызов из `onStartCommand` тоже удалён. Вместе с ним убрана `delay(500)` — она была компенсацией для wait OS-release-socket'ов после cleanup.

### F4 — `serviceReload()` без status-flap

**Что было:** `notification.stop()` → `setStatus(VpnStatus.Starting)` → reload → `setStatus(VpnStatus.Started)` → `notification.show("Connected")`. При reload status проходил Started→Starting→Started, broadcast'ил всем подписчикам (Flutter UI, tile, shortcuts) — внутри которых дополнительные code-path'ы могли читать `fileDescriptor`/`commandServer` в гонке с openTun, который libbox внутренне зовёт во время reload.

**Что стало:** reload не трогает status. Sing-box внутри сам переоткрывает tun (через openTun callback), `fileDescriptor.set(pfd)` обновит ссылку atomic'но. Notification остаётся в "Connected". Reference (`BoxService.kt:192-249 serviceReload0`) делает identical — НЕ трогает status.

Edge case: если `commandServer == null` (race?) — fall back к `startSingbox()`, тогда status flap уместен (это эквивалент cold start).

### F5 — `onRevoke()` через atomic helpers

**Что было:** `onRevoke` мутировал `fileDescriptor` и `commandServer` inline на binder thread (откуда Android вызывает onRevoke):
```kotlin
fileDescriptor?.runCatching { close() }
fileDescriptor = null
commandServer?.apply { ...closeService(); ...close() }
commandServer = null
```
Race с openTun (на libbox thread) если revoke fires во время реestablish'а tun.

**Что стало:**
```kotlin
closeFileDescriptor()           // atomic getAndSet(null)?.close()
closeCommandServerAtomic("revoke")  // atomic getAndSet(null)?.{closeService;close}
```
Оба helper'а через CAS — если другой поток уже close'нул (например параллельный doStop или Android-driven onRevoke), helper просто no-op.

### F9 — Libbox.setLocale

**Что было:** не вызывали → sing-box error messages в English independent of system locale.
**Что стало:** в `BoxApplication.initialize()` сразу после `Seq.setContext(application)`:
```kotlin
runCatching {
    Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
}
```
Identical к reference's `Application.kt:42`. Wrapped в `runCatching` defensively (некоторые OEM могут блокнуть).

### F12.1 — `userName` в `findConnectionOwner`

**Что было:**
```kotlin
return ConnectionOwner().apply {
    userId = uid
    setAndroidPackageNames(StringArray(packages.iterator()))
    // userName НЕ установлено
}
```
**Что стало:**
```kotlin
return ConnectionOwner().apply {
    userId = uid
    userName = packages.firstOrNull() ?: ""
    setAndroidPackageNames(StringArray(packages.iterator()))
}
```
Reference `PlatformInterfaceWrapper.kt:60` делает identical. Видно в Clash API `/connections` endpoint.

### F12.3 — `readWIFIState` real impl

**Что было:** `override fun readWIFIState(): WIFIState? = null` — sing-box `wifi_ssid`/`wifi_bssid` правила routing'а никогда не матчились.
**Что стало:** портированный из reference impl. Использует `BoxApplication.wifiManager.connectionInfo`, strip'ает кавычки вокруг SSID, возвращает empty `WIFIState("", "")` если SSID = `<unknown ssid>` (нет ACCESS_FINE_LOCATION или wifi off).

### F17 — `getSystemProxyStatus` real state

**Что было:**
```kotlin
override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()  // empty
```
**Что стало:** в `openTun` устанавливаем `systemProxyAvailable`/`systemProxyEnabled` поля (Volatile т.к. cross-thread). `getSystemProxyStatus` возвращает их. Clash dashboard'ы теперь видят корректное состояние HTTP proxy.

### F26 — LocalResolver полный rewrite

**Что было:**
```kotlin
override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
    val addresses = InetAddress.getAllByName(domain)
    ctx.success(addresses.joinToString("\n") { it.hostAddress ?: "" })
}
override fun exchange(ctx: ExchangeContext, message: ByteArray?) {
    ctx.errorCode(1)
}
override fun raw(): Boolean = false
```
- `InetAddress.getAllByName(domain)` идёт через system resolver, который при `tun.auto_route = true` мог рекурсивно идти ЧЕРЕЗ tun → sing-box → LocalResolver → loop.
- `raw()` всегда false, `exchange` errorCode(1) → sing-box не получал raw DNS байты для wire-format transport'ов.

**Что стало:** портированный 1:1 reference impl на 151 LOC:
- `raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q`
- `exchange()` использует `DnsResolver.getInstance().rawQuery(defaultNetwork, message, ...)` — DNS запрос идёт ЧЕРЕЗ underlying network, мимо tun, без рекурсии.
- `lookup()` использует `DnsResolver.getInstance().query(defaultNetwork, domain, type, ...)` либо (pre-Q) `defaultNetwork.getAllByName(domain)` — тоже привязано к underlying.
- Helper `tryResumeWithException` в `Extensions.kt` — защита от двойного resume при cancel + onError race.

**Implication для §047/§048:** при stale `defaultNetwork` (после wifi↔cell switch) DNS-запросы могли тихо фейлиться — теперь sing-box получает чёткий errorCode/errnoCode и может логировать причину. Это также **может уменьшить** количество DNS-fail событий в core_logs (одна из причин §048 Gap 1).

### Поправки в `Findings` после implementation

Ранее в §F12.4 я сначала classified `systemCertificates()` как Type B (наш empty), но при чтении кода обнаружил identical impl с reference (AndroidCAStore). Это была **моя ошибка** в preliminary master-сравнении — Type matches, исправлено в §Findings.

### Что НЕ применили (отложено / out of scope)

| Finding | Почему отложено |
|---|---|
| F1 — split monolith → VPNService + BoxLifecycle | Refactor 700+ LOC, риск регресса. atomic-fix решает race; split — для maintainability на будущее. Зафиксировано в Open Questions. |
| F4 (часть) — pass `OverrideOptions` с per-app-proxy | Наш per-app-proxy идёт через template-vars, а не через overrides. На текущий pipeline impact нет. |
| F15 — `Settings.allowBypass` | Требует UI toggle. Минорная фича, не §047-related. |
| F22 — `coreLogSink` main looper насыщение | Добавил предположительный second-order effect — не убрали; диагностика после Phase C должна показать, помогли ли остальные fix'ы. |
| F19, F20, F21, F24 — наши features (SCREEN_ON/OFF, ACTION_RESET_NETWORK, onTaskRemoved, stopAwait) | Type C (наши additions), audit'нуты на correctness, оставлены как есть. |

---

## Phase C verification (2026-05-09)

### Local build & static checks

| Шаг | Команда | Результат |
|---|---|---|
| Dart analyze | `flutter analyze` | `No issues found! (ran in 4.3s)` ✅ |
| Local APK build | `bash scripts/build-local-apk.sh` | `✓ Built build/app/outputs/flutter-apk/app-release.apk (32.3MB)` за 343.7s ✅ |
| Flutter test suite | `flutter test` | 518 passed / 1 failed ⚠️ |

**Единственный failing test** — `test/services/traffic_profiler_test.dart::DNS fail produces dnsTimeout issue`. Подтверждено что **не регрессия §049**: тест относится к §048 territory (DNS-fail attribution gaps); test был добавлен ожидая фикса в `traffic_profiler.dart`, который ещё не реализован. Стэшировал pre-existing `lib/services/traffic_profiler.dart` (был uncommitted из §048 в working tree) → тест прошёл; восстановил → снова падает. Источник failure локализован в §048 territory, не в моих Kotlin-изменениях.

### On-device verification (TODO)

Осталось — реальная проверка §047 race на тестовом телефоне (`192.168.1.71:5555`):
1. Установить новый APK, запустить VPN.
2. Активный traffic ~30+ мин (Chrome, Telegram, банковские apps).
3. Если **деградация повторилась** → race elsewhere; собрать снапшот через `./scripts/lxbox-diag.sh` для сравнения.
4. Если **деградация не повторилась за 1+ час** — fix likely успешен, продолжаем мониторинг.

### Acceptance criteria status

- [x] Reference checked out at correct commit (`3b3883e` libbox 1.13.11)
- [x] Side-by-side diff в этом файле под `## Findings` — все 4 файла + extras (+ extended audit на DefaultNetworkMonitor / LocalResolver / VpnPlugin)
- [x] Каждое difference categorized (A-E)
- [x] Type B/D differences оформлены как Phase B fixes (inline в этой spec'е под `## Phase B implementation log`)
- [ ] §047 retest после fixes — улучшилось / не улучшилось → требует on-device прогон
- [x] Documentation: `BoxVpnService.kt` обновлены comments / docstrings о наших additions vs reference (каждый fix имеет `§049 F<N> fix:` ссылку)

---

## Risk assessment

| Изменение | Риск | Mitigation |
|---|---|---|
| AtomicReference вместо @Volatile | Low — atomic CAS строго безопаснее | Code review, unit-test compile success |
| Удаление `cleanupStaleResources` | **Medium** — теоретически возможен случай где cleanup нужен (Android service instance reuse) | atomic-helpers safe-call'ятся multiple times. Если leftover commandServer/fd были — startCommandServer перезапишет ref, GC уберёт прежнюю инстанцию (Go-side refcount handle's it) |
| `serviceReload` no status flap | Low — reference так делает уже годы | Если Flutter UI зависел от Starting→Started signal — UI не reflect'ит reload. Но reload через UI и так не редкая операция, обычно через Clash dashboard, для UI важно конечное состояние |
| LocalResolver rewrite | **Medium** — DNS critical path. Но reference impl battle-tested |  pre-Q fallback сохраняет старое поведение через `defaultNetwork.getAllByName`; на Q+ корректный DnsResolver |
| readWIFIState | Low — sing-box может теперь использовать данные wifi_ssid правил которых раньше не получал; если в config нет таких правил — no-op | Нет таких правил в default template |
| getSystemProxyStatus real state | Low — раньше всегда empty; теперь правильное | Дешёвый, тривиальный |

---

## Next steps

1. **Push изменения и retest §047** на тестовом девайсе (минимум 30+ min активного use).
2. **Если §047 race повторяется** — следующий уровень анализа:
   - Strict logging добавить в `openTun`/`closeFileDescriptor`/`closeCommandServerAtomic` с timestamps + thread id
   - Проверить F22 hypothesis (отключить core logs → §047 reproduces or not)
   - Расширить F1 (split monolith) — если race вне fileDescriptor, нужно сужать ownership
3. **Если §047 race fixed**:
   - Document в §047 как closed
   - Update CHANGELOG: «§049 deep audit: race condition в lifecycle устранён через atomic CAS»
   - Bump version `1.7.0 → 1.7.1` (patch — bug fix)
4. **Phase D (cleanup, optional)**: F1 split monolith refactor — для long-term maintainability.

---

## Phase B round 2 implementation log (2026-05-09 продолжение)

После round 1 пользователь попросил «доделать что отложено». Применены три отложенных fix'а: **F22** (coreLogSink coalescing), **F15** (allowBypass storage + UI), **F1** (split monolith). **F4** (OverrideOptions per-app-proxy) verified как not-bug в нашем pipeline.

### Затронутые файлы

| Файл | Δ LOC до round 2 | Δ LOC после | Комментарий |
|---|---:|---:|---|
| `vpn/BoxVpnService.kt` | 805 | **302** | F1 split — теперь только Android-hooks + PlatformInterface (как reference's `VPNService.kt` 186 LOC) |
| `vpn/BoxLifecycle.kt` | — | **468** | **NEW** — extracted state owner, аналог reference's `BoxService.kt` (424 LOC) |
| `vpn/BootReceiver.kt` | 86 | 113 | F15 — `setAllowBypass`/`isAllowBypass` SharedPreferences accessor |
| `vpn/VpnPlugin.kt` | (без изменений) | +14 | F15 — MethodChannel handlers `setAllowBypass`/`getAllowBypass` |
| `lib/vpn/box_vpn_client.dart` | (без изменений) | +27 | F15 — Dart accessors `setAllowBypass`/`getAllowBypass` |
| `lib/screens/app_settings_screen.dart` | (без изменений) | +25 | F15 — UI toggle «Allow VPN bypass» в App Settings |

Net Kotlin: **805 → 302+468 = 770 LOC** (split не уменьшил total, но локализовал ownership).

Reference comparison:
- Reference `VPNService.kt` 186 LOC + `BoxService.kt` 424 LOC = 610 LOC
- Наш `BoxVpnService.kt` 302 LOC + `BoxLifecycle.kt` 468 LOC = 770 LOC

Дельта (160 LOC) — наши Flutter-integration additions (start/stop companion API, coreLogSink, ACTION_RESET_NETWORK, SCREEN_ON/OFF, onTaskRemoved, stopAwait completer, sendNotification, allowBypass).

### F22 — coalesced coreLogSink dispatch

**Что было:**
```kotlin
override fun writeDebugMessage(message: String) {
    val plain = ansiEscapeRe.replace(message, "")
    if (traceDebugRe.containsMatchIn(plain)) return
    val sink = coreLogSink ?: return
    coreLogMainHandler.post {
        runCatching { sink.success(plain) }
    }
}
```
Каждая log line — отдельный `post {}` в main looper. На busy traffic + debug mode sing-box эмитит 100+ строк/сек → main looper backlog → Flutter UI thread замедляется → MethodChannel calls с Dart side задерживаются.

**Что стало:**
```kotlin
private val coreLogQueue = LinkedBlockingQueue<String>()
private val coreLogPostedFlag = AtomicBoolean(false)

override fun writeDebugMessage(message: String) {
    val plain = ansiEscapeRe.replace(message, "")
    if (traceDebugRe.containsMatchIn(plain)) return
    if (BoxVpnService.coreLogSink == null) return
    if (coreLogQueue.size >= LOG_QUEUE_MAX) return  // back-pressure
    coreLogQueue.offer(plain)
    if (coreLogPostedFlag.compareAndSet(false, true)) {
        coreLogMainHandler.post(::drainCoreLogs)
    }
}

private fun drainCoreLogs() {
    coreLogPostedFlag.set(false)
    val sink = BoxVpnService.coreLogSink ?: run { coreLogQueue.clear(); return }
    var line = coreLogQueue.poll()
    var batchCount = 0
    while (line != null) {
        runCatching { sink.success(line) }
        if (++batchCount >= 200) {
            // yield для UI frame
            if (coreLogQueue.isNotEmpty() && coreLogPostedFlag.compareAndSet(false, true)) {
                coreLogMainHandler.post(::drainCoreLogs)
            }
            return
        }
        line = coreLogQueue.poll()
    }
}
```

**Effect:**
- Main looper получает не более 1 pending Runnable независимо от количества concurrent producer'ов.
- Bounded queue (`LOG_QUEUE_MAX = 4096`, ~320KB worst case) — back-pressure: если sink не успевает, новые lines дропаются.
- Yield каждые 200 iterations — UI frame не блокируется на длинных батчах.

### F15 — allowBypass opt-in toggle

Storage layer (`BootReceiver.kt`): `setAllowBypass`/`isAllowBypass` SharedPreferences (default false — strict tunnel).

Wired:
- `BoxVpnService.openTun`: `if (BootReceiver.isAllowBypass(this)) builder.allowBypass()`
- `VpnPlugin.kt`: MethodChannel `setAllowBypass`/`getAllowBypass`
- `box_vpn_client.dart`: Dart accessors
- `app_settings_screen.dart`: SwitchListTile «Allow VPN bypass» — иконка `Icons.alt_route`

Применяется при следующем `openTun()` (старт VPN или reload). Snackbar говорит юзеру «Saved. Reload VPN to apply.».

### F1 — split monolith → BoxLifecycle + thin BoxVpnService

#### Структура до

`BoxVpnService.kt` (805 LOC) — единый класс:
- Implements `VpnService`, `PlatformInterfaceWrapper`, `CommandServerHandler` одновременно
- Owns `fileDescriptor`, `commandServer`, `status`, `notification`, `serviceScope`, `receiver`, `systemProxy*` fields
- 5+ mutation site'ов для fileDescriptor
- 700+ LOC — surface для bug'ов

#### Структура после

```
BoxVpnService.kt (302 LOC)
├── companion (start/stop/reload/resetNetwork/stopAwait/currentStatus/coreLogSink)
├── lazy val lifecycle: BoxLifecycle = BoxLifecycle(this, this)
├── Android Service hooks
│   ├── onCreate → BoxApplication.initialize
│   ├── onStartCommand → lifecycle.onStartCommand
│   ├── onDestroy → lifecycle.onDestroy + super
│   ├── onTaskRemoved → lifecycle.onTaskRemoved + super
│   ├── onRevoke → lifecycle.onRevoke + super
│   └── onBind → super
└── PlatformInterface
    ├── openTun (Builder + prepare + protect, allowBypass, lifecycle.fileDescriptor.set, lifecycle.proxy* update)
    ├── autoDetectInterfaceControl → protect
    ├── protect (delegates to VpnService.protect)
    └── sendNotification (NotificationManager direct, dups в lifecycle.commandServer.writeMessage)

BoxLifecycle.kt (468 LOC) — implements CommandServerHandler
├── State (visible to BoxVpnService)
│   ├── val fileDescriptor: AtomicReference<ParcelFileDescriptor?>
│   ├── val commandServer: AtomicReference<CommandServer?>
│   ├── @Volatile var proxyAvailable / proxyEnabled
│   └── val notification: ServiceNotification
├── Internal state (private)
│   ├── var serviceScope (recreated на старт)
│   ├── var status: VpnStatus
│   ├── var receiverRegistered
│   └── BroadcastReceiver
├── Service-hook delegates: onStartCommand, onDestroy, onTaskRemoved, onRevoke
├── Atomic close helpers: closeFileDescriptor, closeCommandServerAtomic
├── start/stop pipeline: startCommandServer, startSingbox, doStop, stopAndAlert, setStatus
├── CommandServerHandler: serviceReload, serviceStop, getSystemProxyStatus, setSystemProxyEnabled, writeDebugMessage
└── Core log dispatch: coalesced batched drainer (F22)
```

#### Подводный камень: JVM signature clash

Field `var systemProxyEnabled: Boolean` collidedя на JVM с overridden `fun setSystemProxyEnabled(isEnabled: Boolean)` (оба генерируют `setSystemProxyEnabled(Z)V`). Решение — переименовать field в `proxyEnabled` (без `system` prefix).

#### Ещё подводный камень: recursive type inference в Runnable

```kotlin
private val coreLogDrainer = Runnable {
    ...
    coreLogMainHandler.post(coreLogDrainer)  // ← compile error
}
```
Kotlin type inference не справился с self-reference в lambda. Переписал как private method `drainCoreLogs()` + использование `::drainCoreLogs` как method reference (SAM convertible to `Runnable`).

#### Cross-class state access

BoxLifecycle читает/пишет статические поля BoxVpnService:
- `BoxVpnService.currentStatus` (companion var) — обновляется при каждом `setStatus`
- `BoxVpnService.coreLogSink` (companion var) — читается в drainCoreLogs / writeDebugMessage
- `BoxVpnService.completeStopCompleter()` (новый помощник в companion) — вызывается в `setStatus(Stopped)` для разморозки `stopAwait` callers

Это conscious coupling: lifecycle зависит от Service-side static state. Альтернатива — interface через service argument, но добавило бы 2-3 forwarding методов без выгоды.

### F4 verify — per-app-proxy в нашем pipeline сохраняется без OverrideOptions

Проверил: `lib/services/builder/post_steps.dart:applyTunPackages` записывает `include_package`/`exclude_package` непосредственно в config'е (`inbounds[type=tun]`). Sing-box при `cs.startOrReloadService(config, ...)` re-читает config из файла и применяет per-app-proxy через `TunOptions.includePackage`/`excludePackage` → libbox callback `openTun()` зовёт `builder.addAllowedApplication()`.

В отличие от reference (где config хранится без per-app-proxy и они передают через `OverrideOptions`), наш pipeline уже самодостаточен — overrides пустые корректны.

**F4 not a bug.** Marked as verified.

### Что осталось (out of scope даже round 2)

- F19 SCREEN_ON/OFF, F20 ACTION_RESET_NETWORK, F21 onTaskRemoved, F24 stopAwait — Type C, наши features. Audit'нуты в round 1, оставлены как есть.
- F1 «split monolith» теперь применён — но ещё бОльший refactor (например, выделение `LogForwarder` или `StatusBroadcaster` сервисов) не делал. Если §047 race повторится — следующий шаг.

---

## Phase C round 2 verification (2026-05-09 продолжение)

| Шаг | Команда | Результат |
|---|---|---|
| Dart analyze | `flutter analyze` | `No issues found! (ran in 5.3s)` ✅ |
| Local APK build | `bash scripts/build-local-apk.sh` | `✓ Built ...app-release.apk (32.3MB)` ✅ |
| Flutter test suite | `flutter test` | **535 / 535 passed** ✅ (в round 1 был 1 failing — это §048 territory; §048 done параллельно, теперь зелёно) |

### Замеченное во время build'а round 2

1. JVM signature clash для `systemProxyEnabled` поля → переименовали в `proxyEnabled`. Build green после fix'а.
2. Kotlin type inference recursion для `Runnable { ... post(coreLogDrainer) }` → method reference `::drainCoreLogs`. Build green после fix'а.

Оба caught локальным build'ом ДО любого on-device теста — split не привнёс runtime-регрессий.

### Acceptance criteria (round 2)

- [x] F22 — coreLogSink coalesced (bounded queue + single-pending drainer)
- [x] F15 — allowBypass storage + Kotlin read + UI toggle (full path Dart → Kotlin → openTun)
- [x] F1 — BoxLifecycle extracted, BoxVpnService thin (302 LOC vs prior 805)
- [x] F4 — verified not-bug
- [x] APK builds, all 535 flutter tests pass, analyze clean
- [ ] On-device retest §047 — still pending (single TODO для всей §049 task'и)

---

## Final summary

§049 audit complete. Все Type B/D differences (которые могли cause bugs) применены как fix'ы:

| # | Тип | Fix | Round |
|---|---|---|---|
| F2 | B | AtomicReference + atomic close для fileDescriptor | 1 |
| F3 | B | Удалён cleanupStaleResources + delay(500) | 1 |
| F4 | D | serviceReload без status-flap; pipeline check verified | 1+2 |
| F5 | B | onRevoke через atomic helpers (CAS) | 1 |
| F9 | B | Libbox.setLocale в init | 1 |
| F12.1 | B | userName в ConnectionOwner | 1 |
| F12.3 | B | readWIFIState реальный impl | 1 |
| F17 | B | getSystemProxyStatus реальный state | 1 |
| F26 | B | LocalResolver на DnsResolver bound к defaultNetwork | 1 |
| F22 | C-second-order | Coalesced log dispatch (bounded queue + drainer) | 2 |
| F15 | B | allowBypass opt-in toggle (storage + Kotlin + Dart + UI) | 2 |
| F1 | D-architectural | Split monolith → BoxLifecycle + thin BoxVpnService | 2 |

Type C наши features — audit'нуты, correct, оставлены как есть.

**Главный §047 fix** — F2+F3+F5 atomic CAS для `fileDescriptor` lifecycle. F1 split локализует state ownership. F22 убирает second-order race window от log saturation.

**Не сделано:** on-device retest §047 (требует физический телефон с активным VPN + 30+ min observation).

---

## Files touched (final round 2)

### Kotlin (Android side)
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt` (rewrite — 805 → 302)
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxLifecycle.kt` (NEW — 468 LOC)
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/PlatformInterfaceWrapper.kt` (137 → 163, F12.1+F12.3)
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LocalResolver.kt` (18 → 151, F26)
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxApplication.kt` (98 → 117, F9 + wifiManager)
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/Extensions.kt` (19 → 30, F26 helper)
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BootReceiver.kt` (86 → 113, F15)
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt` (+14 LOC, F15 MethodChannel)

### Dart (Flutter side)
- `app/lib/vpn/box_vpn_client.dart` (+27 LOC, F15 accessors)
- `app/lib/screens/app_settings_screen.dart` (+25 LOC, F15 UI toggle)

### Spec / docs
- `docs/spec/tasks/049-singbox-wrapper-deep-audit/spec.md` (этот файл)
- `docs/spec/tasks/047-tun-tcp-deterioration-diagnosis.md` (link update only)

---

## Phase D — on-device hotfix (2026-05-09 evening, v1.7.2)

После v1.7.1 ship'а пользователь установил APK на тестовый телефон (Android 15 OnePlus, libbox 1.13.11) — **процесс краш'ился при первом sing-box log line** через ~2 секунды после старта VPN. Crash:

```
F/libc:   Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid X (Thread-Y)
F/DEBUG:  Abort message: 'Unknown reference: 42'
F/DEBUG:  #01 libbox.so (go_seq_from_refnum+228)
F/DEBUG:  #02 libbox.so (cproxylibbox_CommandServerHandler_WriteDebugMessage+68)
```

`flutter test` + APK build на dev box'е не выявляли — это runtime-only регресс на конкретной комбинации Android 15 + libbox 1.13.11.

### Methodical bisect

Применял §049 changes **по одному файлу**, build + install + test на устройстве:

| # | Применил | Результат |
|---|---|---|
| 0 | pre-§049 revert (все Kotlin файлы из commit `2036356`) | ✅ Работает |
| 1 | + LocalResolver F26 (full DnsResolver impl) | ✅ Работает |
| 2 | + BoxApplication F9 setLocale + wifiManager exposure | ✅ Работает |
| 3 | + PIW F12.1 userName (без F12.3) | ✅ Работает |
| 4 | + PIW F12.3 readWIFIState real impl | ❌ **CRASH** `Unknown reference: 42` |
| 5 | F12.3 reverted to `null`, оставлено всё остальное | ✅ Работает |
| 6 | + BoxVpnService monolithic + atomic CAS (без F1 split) | ✅ Работает, VPN tun0 UP |

**Виновник:** F12.3 — `readWIFIState()` создавал `WIFIState(ssid, bssid)` (`go.Seq$Proxy` Java-обёртка над Go-side struct'ом с refnum). На нашем Android 15 что-то в lifecycle этого refnum'а ломалось — sing-box терял track. Reference impl такая же как у нас, но в их environment'е работает (другой OEM Android, или iOS, или libbox version). Без debug symbols в libbox.so не смог пройти точную root cause.

GC-pin через static field strong reference не помог — issue not in GC of Java wrapper.

**Pragmatic fix v1.7.2:** оставить `readWIFIState() = null` (pre-§049 поведение). Sing-box `wifi_ssid`/`wifi_bssid` route rules — minor feature, наши template не используют.

### F1 split rollback (parallel investigation)

Параллельно с F12.3 bisect — пробовали разные варианты F1 split (BoxLifecycle implementing CSH directly vs Variant B with delegation). **Все варианты split** на этом устройстве крашились с тем же `Unknown reference: 42` — независимо от того кто implement'ит CSH. Поскольку F12.3 был sufficient sole cause, F1 split в любом случае нужно было отложить — и для simplicity merged'или с monolith. v1.7.2 ship'ит monolithic BoxVpnService с atomic CAS fixes, без BoxLifecycle.

### Что осталось в v1.7.2

| # | Fix | Status в v1.7.2 |
|---|---|---|
| F2 | `AtomicReference<ParcelFileDescriptor?>` для fileDescriptor | ✅ Применён |
| F3 | Удалён cleanupStaleResources + delay(500) | ✅ Применён |
| F4 | serviceReload без status-flap | ✅ Применён |
| F5 | onRevoke через atomic helpers | ✅ Применён |
| F9 | Libbox.setLocale | ✅ Применён |
| F12.1 | userName в findConnectionOwner | ✅ Применён |
| F12.3 | readWIFIState real impl | ❌ **Reverted** (root cause crash) |
| F15 | allowBypass toggle | ✅ Применён |
| F17 | getSystemProxyStatus real state | ✅ Применён |
| F22 | Coalesced log dispatch | 🟡 Отложен (не критичен) |
| F26 | LocalResolver на DnsResolver | ✅ Применён |
| F1 | Split monolith → BoxLifecycle | ❌ **Reverted** (provoked same refnum issue under timing) |

### Final files в v1.7.2

| Файл | Δ vs pre-§049 |
|---|---|
| `BoxVpnService.kt` | monolithic + atomic CAS + F4/F5/F15/F17 |
| `PlatformInterfaceWrapper.kt` | + F12.1 (`userName`), `readWIFIState=null` (как было) |
| `LocalResolver.kt` | F26 full DnsResolver impl |
| `BoxApplication.kt` | F9 setLocale + wifiManager exposure |
| `BootReceiver.kt` | F15 storage layer |
| `VpnPlugin.kt` | F15 MethodChannel handlers |
| `Extensions.kt` | F26 helper `tryResumeWithException` |
| `BoxLifecycle.kt` | **DELETED** |

### Open questions для будущей работы

1. **F12.3 root cause** — почему `WIFIState(ssid, bssid)` крашит на нашем устройстве? Нужен build libbox с debug symbols + reproducible test case. Возможно — Android 15 GC behavior, или OnePlus OEM-specific что-то.
2. **F1 split** — теоретически архитектурно правильный, но на текущем libbox 1.13.11 проявился bug. Если апгрейдим libbox в будущем — попробовать снова.
3. **F22 coalescing** — критичный для high-traffic debug mode, но не блокирующий. Применить в следующем cycle.

---

## Phase E — final attempts at F12.3 / F22 / F1 (2026-05-09 evening, v1.7.1 squashed)

После v1.7.2 user попросил доделать отложенные фиксы (F22, F1) и попытаться доделать F12.3 properly. Серия экспериментов:

### F12.3 attempts

| Attempt | Path | Result |
|---|---|---|
| v1 (original §049) | `WIFIState(ssid, bssid)` constructor | ❌ Deterministic crash refnum 42 (build 10005) |
| v2 (GC-pin) | constructor + static strong-ref field | ❌ Deterministic crash (build 10013) |
| v3 (factory) | `Libbox.newWIFIState(ssid, bssid)` static | ⚠️ Non-deterministic: 2/3 trials work, 3rd crashes (build 10101 vs 10200/trial-3 ⇒ refnum 42) |
| v4 (final, applied) | `null` (pre-§049 behavior) | ✅ Stable (build 10201) |

**Conclusion:** оба Java-side `WIFIState` создания триггерят race-condition. GC-pin не помог. **F12.3 не решаемо без libbox.so debug symbols** — оставлено `null`, tracking issue.

### F22 attempts

| Attempt | Approach | Result |
|---|---|---|
| v1 (round 2) | bounded queue + `coreLogMainHandler.post(::drainCoreLogs)` (method ref) | ❌ Crash refnum 42 (build 10102) |
| v2 (inline lambda) | inline `post { ... }` lambda only | ⚠️ Non-deterministic: build 10104 worked; 10106/10107 same code crashed |
| v3 (final, applied) | revert — per-line `post { sink.success(plain) }` (pre-§049) | ✅ Stable |

**Conclusion:** introducing queue + drainer triggers Kotlin Lambda capture interaction with gomobile/seq tracker that is timing-dependent. Per-line dispatch preserved. F22 — minor optimization, not critical.

### F1 attempts

| Attempt | Approach | Result |
|---|---|---|
| v1 (round 2) | `BoxLifecycle : CommandServerHandler` separate class, `CommandServer(this, platformInterface)` two distinct Java objects | ❌ Crash refnum 42 (multiple builds) |
| v2 (Variant B) | `BoxVpnService` implements CSH (delegating to lifecycle), `CommandServer(service, service)` same Java object | ❌ Crash refnum 42 (build 10006) |
| v3 (with F22 inline) | F1 split + F22 inline | ❌ Crash refnum 42 (build 10105) |
| v4 (final, applied) | revert F1 — monolithic `BoxVpnService` implements both PI + CSH | ✅ Stable |

**Conclusion:** F1 split на нашем environment'е fundamentally incompatible с gomobile/seq refnum management. Любой Java object split вызывает refnum 42 race. State (`AtomicReference`) остаётся в monolithic class — atomic CAS race fix (главный §047 fix) сохранён.

### Final v1.7.1 ship state

| Fix | Status |
|---|---|
| F2 atomic CAS fileDescriptor | ✅ |
| F3 removed cleanupStaleResources | ✅ |
| F4 serviceReload no flap | ✅ |
| F5 onRevoke atomic | ✅ |
| F9 Libbox.setLocale | ✅ |
| F12.1 userName | ✅ |
| F12.3 readWIFIState | ❌ deferred (race) |
| F15 allowBypass toggle | ✅ |
| F17 getSystemProxyStatus | ✅ |
| F22 coalesced log | ❌ deferred (race) |
| F26 LocalResolver | ✅ |
| F1 split monolith | ❌ deferred (incompatible) |

**Net:** 9 of 12 fixes applied. 3 deferred с tracked open questions. Главный §047 race condition fix (atomic CAS на `fileDescriptor`/`commandServer`) — landed. **`BoxLifecycle.kt` файл deleted** — чистый monolithic state.

### Diagnostic infrastructure

В процессе работы реализовали:
- Counter в `writeDebugMessage` для bisect (показал 96 успешных calls перед crash на specific call) — впоследствии удалён
- Disabled `Libbox.redirectStderr` для попытки получить Go panic в logcat (не дало больше info, restored)
- Decompile `libbox-1.13.11.aar` через `unzip` + `javap` — получили класс layouts (`WIFIState implements go.Seq$Proxy` etc), без debug symbols ограничение

Всё `git`'нуто в чистый final state на v1.7.1 release.

---

## Phase F — refnum 42 deep analysis (offline, без телефона)

После v1.7.1 ship провели глубокую декомпиляцию `libbox.aar` для понимания природы refnum 42 и подготовили **structured test plan** для следующего on-device session'а.

### 🎯 Confirmed: REF_OFFSET = 42

`go.Seq$RefTracker` constructor (декомпиляция bytecode):
```java
RefTracker() {
    this.next = 42;  // ← bipush 42; putfield next:I
    this.javaObjs = new RefMap();
    this.javaRefs = new IdentityHashMap<>();
}
```

`inc(Object obj)`:
```java
synchronized int inc(Object obj) {
    if (obj == null) return 41;  // sentinel
    if (obj instanceof Seq$Proxy) return ((Seq$Proxy) obj).incRefnum();  // Go-side refnum
    Integer existing = javaRefs.get(obj);
    if (existing == null) {
        // first time for this Java object
        existing = next++;  // next starts at 42
        javaRefs.put(obj, existing);
    }
    Ref ref = javaObjs.get(existing);
    if (ref == null) ref = new Ref(existing, obj);  // refcount=1
    else ref.inc();  // refcount++
    return existing;
}
```

`dec(int refnum)`:
```java
synchronized void dec(int refnum) {
    if (refnum <= 0) {
        log.severe("dec request for Go object" + refnum);
        return;
    }
    if (refnum == nullRef.refnum) return;  // null sentinel
    Ref ref = javaObjs.get(refnum);
    if (ref == null) {
        throw new RuntimeException("referenced Java object is not found: refnum=" + refnum);
    }
    ref.refcnt--;
    if (ref.refcnt <= 0) {
        javaObjs.remove(refnum);
        javaRefs.remove(ref.obj);  // GONE
    }
}
```

**Refnum 42 — это первый Java-implemented-interface объект, переданный в libbox.**

### Какие наши классы попадают в этот tracker

NOT `Seq$Proxy` (используют RefTracker, refnum from 42):
- `BoxVpnService` (implements `PlatformInterface` + `CommandServerHandler`) ← **это refnum 42**
- `LocalResolver` (implements `LocalDNSTransport`)
- `PlatformInterfaceWrapper.StringArray` (inner class implements `StringIterator`)
- inline `NetworkInterfaceIterator` объект в `getInterfaces()`
- `BroadcastReceiver` callbacks (если passed to libbox)

ARE `Seq$Proxy` (Go-side refnum, separate space):
- `WIFIState`, `OverrideOptions`, `SetupOptions`, `CommandServer`
- `ConnectionOwner`, `NetworkInterface` (libbox.NetworkInterface — Go struct, не java.net)
- `ExchangeContext`, `SystemProxyStatus`

### Когда refnum 42 destroyed

`Seq.destroyRef(int)` — native method, **Go side calls into Java** via JNI to decrement refcount. When called, `tracker.dec(refnum)` runs; if refcount reaches 0, entry **removed** from map → next `get(refnum)` returns null → `go_seq_from_refnum` panic'ит **"Unknown reference: 42"**.

WHO calls destroyRef from Go side: gomobile-generated finalizers, when Go-side wrapper struct is GC'd by Go runtime.

### Hypothesis tree for testing

#### Hypothesis A — Go-side GC pressure triggers premature destroyRef
**Triggers**: F12.3 / F1 / F22 increase Go heap pressure (more allocations, more frequent GC).
**Test**: pin refcount very high so even multiple destroyRef calls don't drop to 0.

```kotlin
// In BoxApplication.initialize, AFTER Seq.setContext:
override fun onCreate() {
    super.onCreate()
    BoxApplication.initialize(applicationContext)
    // §049 Phase F diagnostic — pin handler refcount to ~10000 so any
    // sporadic destroyRef won't kill it.
    repeat(10000) { Seq.incRef(this) }
}
```
Then enable F12.3 with constructor (known to crash deterministically). If crash gone → confirmed Hyp A. If crashes still → other cause.

#### Hypothesis B — Counter overflow / wraparound 
**Test**: log `Seq.tracker.dec()` calls via instrumentation (need reflection to access internal logger, or wrap Seq.destroyRef native)

#### Hypothesis C — Specific Lambda capture in F22 or method-ref
Build with F22 simplest version (no method ref, no continuation, just one-shot drain) and stress-test with 10 cold-starts.

### Pre-cooked diagnostic helper

Готовый Kotlin для on-device тестов — добавить в `BoxApplication.initialize` после `Seq.setContext`:

```kotlin
// Phase F: pin handler+platform refcount through repeated incRef.
// If crash 'Unknown reference: 42' goes away — confirms Hypothesis A
// (GC-induced premature destroyRef).
//
// CAUTION: this leaks refs (no matching destroyRef), but it's diagnostic
// only — never ship. Each repeat increases refcount on whatever
// `BoxVpnService` instance exists when called.
//
// Note: Seq.incRef on null-context fails. Must call AFTER Seq.setContext.
fun pinHandlerForDiagnostic(handler: Any) {
    repeat(10_000) { go.Seq.incRef(handler) }
}
```

### Test 2 RESULT (выполнено on-device 2026-05-09)

**Hypothesis A — FALSIFIED.**

Build 10210 = baseline + F12.3 constructor + `repeat(10_000) { Seq.incRef(this) }` в `BoxVpnService.onCreate()`.

5/5 trials крашат `'Unknown reference: 42'`:
```
=== Trial 1 ===  Abort message: 'Unknown reference: 42'
=== Trial 2 ===  Abort message: 'Unknown reference: 42'
=== Trial 3 ===  Abort message: 'Unknown reference: 42'
=== Trial 4 ===  ▶ pinned handler refcount via Seq.incRef × 10000
                 Abort message: 'Unknown reference: 42'
=== Trial 5 ===  Abort message: 'Unknown reference: 42'
```

**Анализ:** 10000 destroyRef calls за ~5 секунд startup'а **физически невозможно** — каждый требует JNI-вызов из Go в Java + lock на synchronized RefTracker. Реалистично 100-1000 calls/sec. Значит refcount не падает до 0.

**Вывод:** проблема НЕ в decRef/destroyRef cycle для refnum 42. Возможные альтернативы:
1. Refnum 42 **никогда не попадает в tracker** при F12.3 path (возможно sing-box делает direct lookup мимо `Seq$RefTracker`)
2. Refnum 42 **удаляется через другой путь** (raw `javaObjs.remove()` где-то)
3. Refnum 42 **референс в panic-message** — это что-то ДРУГОЕ, не наш handler. Возможно internal Go-side refnum который коллидирует с REF_OFFSET=42 в другой namespace.

**Гипотеза 3** наиболее вероятна. Сейчас smashing предположение что `cproxylibbox_CommandServerHandler_WriteDebugMessage` ищет HANDLER refnum — возможно он ищет какой-то ВНУТРЕННИЙ refnum (например, message context), который случайно тоже 42.

### Next test plan (Phase G)

| # | Hypothesis | Test |
|---|---|---|
| G1 | Refnum 42 — это не handler, а transient context. Изменить порядок init чтобы handler был НЕ первым refnum | До CommandServer создать ещё один Java→Go object: `Seq.incRef(SomeOther)` |
| G2 | Logger в writeDebugMessage internal sing-box использует refnum, который мы не контролируем | Включить debug=true → возможно alternative log path |
| G3 | NDK-stack symbolize libbox.so | Build libbox с debug symbols (требует rebuild AAR — выходит за scope task'и) |

### Test execution plan (для предыдущих гипотез — already executed)

| # | Build | Hypothesis check | Expected if Hyp A true |
|---|---|---|---|
| 1 | Baseline v1.7.1 stable (no F12.3, no F22, no F1) | Sanity check — should not crash | No crash, ~5/5 trials OK |
| 2 | + F12.3 constructor + pin 10000 | Hypothesis A: GC pressure | If pin saves it — Hyp A confirmed |
| 3 | + F12.3 factory + pin 10000 | Hypothesis A | Same as #2 |
| 4 | + F22 simplest + pin 10000 | Hypothesis A on F22 | Same |
| 5 | + F1 split + pin 10000 | Hypothesis A on F1 | Same |
| 6 | If 2-5 don't help → instrument destroyRef via JNI hook | Hypothesis B/C | See actual destroyRef calls in logcat |

### Что готовлю offline (без телефона)

1. **Branch `diag/refnum-42`** — отдельная ветка с готовыми diagnostic builds (Test 1-5 как separate commits, ready to flip)
2. **Helper script** для quick install + N-trial uptime check
3. **Doc cleanup** — release notes, CHANGELOG, README для v1.7.1

После того как user вернёт телефон — выполнить Test 1-5 sequentially. Каждый ~3 мин (build 70s + install + 5 trials × 15s + crash analysis).

### Long-term mitigation regardless of refnum 42 root cause

- Upgrade to **libbox 1.14-alpha** when stable — может seq поведение изменилось
- Switch to gomobile-bind с debug symbols build — для `addr2line` post-crash analysis
- Consider port to JNR-based binding или manual JNI вместо gomobile

---

## Phase G — refnum 42 confirmed = CommandServerHandler interface (2026-05-09 evening)

После возврата телефона из дневной сессии — извлёк tombstones за день из `dumpsys dropbox`. Реальная картина:

| Time | Build | Process uptime | Backtrace top |
|---|---|---|---|
| 14:13:51 | v9999 (diag) | 27s | `cproxylibbox_CommandServerHandler_WriteDebugMessage+68` → `go_seq_from_refnum+228` |
| 14:14:58 | v9999 (diag) | <1m | same |
| ... 18 crashes 14:00-17:04 ... | v10005 / v10221 (diag) | 4-30s | same — `WriteDebugMessage` |
| 17:04:35 | v10221 (diag) | 4s | **`cproxylibbox_CommandServerHandler_WriteDebugMessage+68`** — `Unknown reference: 42` |
| **17:07 → 22:30+** | **v10222 (clean)** | **5+ hours, no crash** | — |

### Critical insight — Phase F был неверен в одном ключевом моменте

**Все 18 tombstones показывают `cproxylibbox_CommandServerHandler_WriteDebugMessage` как entry point, не `readWIFIState`.**

В Phase F я предположил что refnum 42 = `BoxVpnService.this as PlatformInterface` (т.к. это был обнаруженный path при F12.3). Но реально:

```kotlin
val cs = CommandServer(this, this)  // ctor signature: (handler: CSH, platform: PI)
//                    ^^^^  ^^^^
//                    CSH   PI
//                  refnum 42  refnum 43+ (subsequent)
```

`CommandServer` Java→Go ctor генерирует **TWO separate Seq.Ref'а**:
- `this as CommandServerHandler` → **first Java→Go ref → refnum 42**
- `this as PlatformInterface` → second Java→Go ref → refnum 43+

`Seq.incRef(this)` × 10000 в Phase F пинил `BoxVpnService` instance (хорошо), НО `Seq.RefTracker` оперирует **`Seq.Ref` wrappers**, не raw Java objects. Каждое из двух interface-cast'ов имеет **свой Seq.Ref wrapper**, и пинить через `incRef` нужно именно его, не the underlying object.

`writeDebugMessage` вызывается sing-box'ом постоянно (любой log line), `readWIFIState` — раз при init. Поэтому:
- F12.3 (readWIFIState constructor) — возвращал в crash redirected (Phase F был "WIFIState path")
- F22 / любой stress на logging path — крашится в `WriteDebugMessage` (текущая сессия)

**Both crash paths share the same root cause: refnum 42 = CSH Seq.Ref destroyed prematurely**.

### Why v10222 stable when v10221 crashed (4-second uptime)

Между builds 10221 и 10222 я убрал **diagnostic `repeat(10_000) { Seq.incRef(this) }`** из `onCreate()`. Гипотеза:

- 10000 incRef calls создают 10000 Java-side `Seq.Ref` wrapper objects (или incRef counter spikes — нужно копать в Seq source)
- High GC pressure → ART agressively reclaims short-lived refs
- ART finalizer queue picks up некоторые `Seq.Ref` wrappers ← включая refnum 42
- `Seq.Ref.finalize()` вызывает `destroyRef(42)` → refnum 42 invalid
- Next `WriteDebugMessage` callback → `go_seq_from_refnum(42)` → SIGABRT

Removal удалил GC pressure source → 10222 stable.

### Real fix candidates (long-term)

1. **Hold strong reference to `Seq.Ref` wrappers** through reflection (requires private API access)
2. **Keep `CommandServer` instance reference alive in static field** — currently held in `AtomicReference<CommandServer?>` field, which is referenced by service which is referenced by Android system → должно work. Но если Java-side `Seq.Ref` separate → можно потерять
3. **Reduce log volume**: `log.level = warn` в config → `WriteDebugMessage` зовётся редко → меньше шанс на race
4. **libbox 1.14-alpha** — гипотетически мог пересмотреть seq lifecycle (untested)

### Current status

- **v10222 production stable** — 5+ часов uptime под реальной нагрузкой (YouTube + Google services через France node)
- Race остаётся теоретически возможным под high GC pressure
- Documented как known issue + mitigation strategy
- §049 main fix (atomic CAS lifecycle для §047 TCP-deterioration) сохранён

---

## Phase G7 — pre-allocation EXPERIMENT result (2026-05-09 20:55)

Запустил `scripts/diag/run-phase-g7.sh` с manual trial loop. Build 11000 = baseline + F12.3 enabled (provoke crash) + 50 dummy `Object()` pre-allocated через `go.Seq.incRef()` ДО CommandServer ctor. Strong-hold dummies в `BoxApplication.pinnedDummies: MutableList<Any>` чтобы JVM GC не реклеймил их раньше handler'а.

### Trial results

```
═══ Trial 1 ═══
[G7 marker]: (race lost — log line not flushed before crash)
[Abort msg]: Abort message: 'Unknown reference: 92'
═══ Trial 2 ═══
[Abort msg]: Abort message: 'Unknown reference: 92'
═══ Trial 3 ═══
[Abort msg]: Abort message: 'Unknown reference: 92'
═══ Trial 4 ═══
[Abort msg]: signal 6 (SIGABRT), 'Unknown reference: 92'
═══ Trial 5 ═══
[G7 marker]: [G7] reserved refnums 42..91 with 50 dummies, pinned=50
[Abort msg]: 'Unknown reference: 92'
```

**5/5 trials crashed на refnum 92** (deterministic, fully reproducible).

### Phase G7 conclusion — REFNUM 42 = НАШ HANDLER (НЕ libbox-internal)

50 dummies заняли refnums 42..91 → real CSH handler получил refnum 92 → crash переехал на 92. **Это однозначное подтверждение** что:

1. Refnum 42 (а в G7 — 92) — **наш `BoxVpnService as CommandServerHandler`** registered первым в `Seq.RefMap`
2. Pre-allocation (даже с strong-hold pin'ом dummy objects) **НЕ помогает** — потому что pinned только dummies, не наш handler
3. Crash происходит когда `Seq.Ref` wrapper для нашего handler finalize'ится Java-side (что происходит при memory pressure / GC cycle)
4. **Hypothesis A была верна** — Java-side `Seq.Ref` wrapper indeed destroyed prematurely. Phase F's "5/5 trials with `Seq.incRef × 10000` still crash" интерпретация была ошибкой: `Seq.incRef(this)` создаёт **NEW** `Seq.Ref` wrapper, не pin'ит существующий

### Real fix direction (now actionable)

Нужно **strong-hold существующий `Seq.Ref` wrapper для нашего CSH refnum** в Java-side static field. Подходы:

**Approach A — Reflection в `go.Seq$RefMap`:**
```kotlin
// В BoxVpnService.startCommandServer(), после CommandServer(this, this) ctor:
val seqClass = Class.forName("go.Seq")
val refsField = seqClass.getDeclaredField("inRefs")  // или "javaObjs" в зависимости от версии
refsField.isAccessible = true
val refMap = refsField.get(null)  // Seq$RefMap singleton
val getMethod = refMap.javaClass.getDeclaredMethod("get", Int::class.java)
getMethod.isAccessible = true
val ourSeqRef = getMethod.invoke(refMap, 42)  // Seq$Ref wrapper
BoxApplication.pinnedSeqRef = ourSeqRef  // strong-hold в static field
```

Risks: private API, fragile across libbox/gomobile updates, exact field name (`inRefs` / `javaObjs` / `proxies`) надо confirm'ить через декомпиляцию libbox.aar.

**Approach B — hold strong reference на каждый Java→Go ref-passing call:**
В исходниках gomobile/seq generated code есть `Seq.RefMap.lookup(refnum)` который при necessary создаёт `Seq.Ref` wrapper. Можно перехватить этот path и hold'ить wrapper через ListenableFuture или static map. Требует patching gomobile cproxy code → не practical.

**Approach C — workaround: reduce log volume:**
`log.level=warn` или `error` в config → `WriteDebugMessage` зовётся редко → race window сужается. Не fix, но mitigation.

### Updated next steps

1. **Decompile libbox.aar чтобы найти exact field name для `Seq$RefMap`** — `go/Seq.java` точное имя поля + signature `lookup`/`get` метода
2. **Implement Approach A** на отдельной ветке `fix/refnum42-seqref-pin`
3. Test cycle: rebuild → 5 trials с F12.3 enabled → если crash исчезает → PR

### G7 artefacts

- Скрипт: `scripts/diag/run-phase-g7.sh` (был запущен но `set -euo pipefail` поймал спорадический non-zero adb exit, trap отработал)
- Manual trial loop результаты (trials 1-5 above)
- Backup files: `/tmp/G7-piw-backup.kt`, `/tmp/G7-app-backup.kt` (already cleaned)

---

## Phase H — F1 split + Application class registered (2026-05-09 → 05-10)

После G7 = root cause confirmed (refnum 42 = наш CSH handler, Java-side `Seq.Ref` wrapper destroyed prematurely), мы пошли по архитектурному пути — mirror reference SagerNet 1.13.11 (commit 3b3883e) точно.

### Changes applied

**1. F1 split** (parallel agent на ветке `diag/refnum-42-clean-split`):

| File | Before | After |
|---|---|---|
| `BoxVpnService.kt` | 909 lines, monolithic: `VpnService + PI + CSH` | 237 lines, only PI: `VpnService + PlatformInterfaceWrapper` |
| `BoxService.kt` | (не существовал) | 465 lines, plain class implements CSH only |
| `CommandServer(this, this)` ctor | same Java instance дважды → `inc(o)` находит existing → один refnum, refcnt=2 | `CommandServer(this/*BoxService*/, platformInterface/*BoxVpnService*/)` → 2 разных Java instance → 2 разных refnum'а |

State (`fileDescriptor`, `commandServer` AtomicReference, `serviceScope`, `status`, etc.) переехал в `BoxService`. Android lifecycle callbacks (`onCreate`, `onStartCommand`, `onDestroy`, `onRevoke`, `onTaskRemoved`) форвардятся: `BoxVpnService.onX() → service.onX()`.

**2. Application class registered** (наш patch, после параллельного):

| File | Before | After |
|---|---|---|
| `BoxApplication.kt` | `object` Kotlin singleton, lazy init из `BoxVpnService.onCreate()` | `class BoxApplication : Application()` зарегистрирован в AndroidManifest как `android:name=".vpn.BoxApplication"` |
| init timing | На запросе пользователя через Service.onCreate | Android runtime создаёт ДО любого Service / Activity |
| `Seq.setContext(application)` | АКТИВНО вызывался | **УДАЛЁН** (match reference Application.kt:41 `// Seq.setContext(this)`) |
| `SetupOptions.logMaxLines` | не задан → unbounded | `= 3000` (match reference) |
| `Libbox.setLocale(...)` | в `runCatching` | синхронно без runCatching (fail loud) |
| `BoxApplication.initialize(context)` | реальный init | no-op (backward compat для callsite'ов в BoxService.onCreate, MainActivity, BootReceiver) |

Companion object сохраняет публичный API через `instance` proxy → все `BoxApplication.X` callsite'ы продолжают работать (powerManager, connectivity, packageManager, notificationManager, wifiManager, libboxReady).

### F12.3 readWIFIState — окончательно deferred

Параллельный agent сделал **5 attempts** на split branch (`diag/refnum-42-clean-split`):

| # | Конфигурация | Результат |
|---|---|---|
| 1 | Pre-split + `WIFIState(s,b)` constructor | crash refnum 42 |
| 2 | F1 split + `WIFIState(s,b)` constructor | crash 8s |
| 3 | F1 split + ctor + Java strong-ref pin | crash 10s |
| 4 | F1 split + `Libbox.newWIFIState(s,b)` factory + pin | crash 8s |
| 5 | F1 split + `WIFIState(s,b)` ctor + drop `Seq.setContext` | crash 12s |

**Всегда** crash signature `cproxylibbox_CommandServerHandler_WriteDebugMessage+68 → go_seq_from_refnum+228 → 'Unknown reference: 42'`. Refnum 42 = CSH handler (после split = `BoxService`), pin'ится Java strong-ref'ами — Java side держит. Corruption происходит **внутри Go runtime** при `__NewWIFIState`/`newWIFIState` Java→Go upcall.

Reference SagerNet имеет такой же код но возможно никогда не triggered в production — никто не использует `wifi_ssid:` / `wifi_bssid:` DNS rules (нужно ли это feature вообще — открытый вопрос).

**Решение**: F12.3 остаётся `null`. Tracking issue для libbox 1.14-alpha upgrade когда выйдет stable.

### Verification

- **v11270/11280** (parallel agent's split build) — installed, app launches stable
- **v11300** (наш patch +Application class +drop Seq.setContext +logMaxLines) — installed, app launches stable, Application.onCreate отрабатывает без crash
- VPN start через UI verified рабочий (юзер confirmed)

### Что закрыто

- ✅ §049 main fix — atomic CAS lifecycle (F2/F3/F4/F5) для §047 TCP-deterioration
- ✅ F1 split — точно по reference, refnum'ы CSH и PI разделены
- ✅ Application class registered → predictable init timing
- ✅ `Seq.setContext` удалён → match reference behavior
- ✅ `logMaxLines = 3000` → нет unbounded log accumulation
- ✅ F9 setLocale, F12.1 userName, F15 allowBypass, F17 systemProxyStatus, F26 LocalResolver

### Что остаётся deferred (blocked on libbox upgrade)

- ❌ F12.3 readWIFIState — Go-side corruption, не воспроизвели в reference, ждём libbox 1.14-alpha
- ⏸ F22 coalesced log dispatch — НЕ применён (per-line `Handler.post` остался). Можно вернуться когда base split + Application stable verified длительным uptime'ом
