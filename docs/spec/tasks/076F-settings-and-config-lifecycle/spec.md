# 076 — Settings and config lifecycle

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.0 |
| Дата | 2026-06-06 |
| Зависимости | §030 (HomeController + saveParsedConfig), §046 (tun_apps + applyTunPackages), §047 (subscriptionController.generateConfig), §061 (DNS rules first-class refactor), §069 (runtime-vs-storage tracking pattern), §072 (atomic SettingsStorage writes). |
| Затрагивает | `app/lib/main.dart`, `app/lib/services/settings_storage.dart`, `app/lib/services/config_dirty_check.dart` (NEW), `app/lib/services/nav/home_return_observer.dart` (NEW), `app/lib/models/home_state.dart`, `app/lib/controllers/home_controller.dart`, `app/lib/controllers/subscription_controller.dart`, `app/lib/screens/{tun_apps_tab, routing_screen, dns_settings_screen, settings_screen, home_screen}.dart`, `app/lib/services/debug/serializers/home_state.dart`, `app/lib/services/debug/handlers/state.dart`. |

## Цель

Прозрачный и единый lifecycle для UI настроек, persistent storage
(`lxbox_settings.json`), собранного sing-box config (`singbox_config.json`)
и running VPN tunnel. Изменение настройки **гарантированно** доходит до
running tunnel через цепочку storage → config → restart с минимумом
disk writes и без race-условий.

## Не в скопе

- Изменение post-step builder'ов (`applyTunPackages`, `applyRoutingRules`,
  `applyDnsRules`, etc.) — они работают корректно, проблемы были в trigger'ах.
- Native side (BoxVpnService.kt, libbox) — без изменений; читает saved
  `singbox_config.json` как раньше.
- Backup/restore format — schema `lxbox_settings.json` не меняется.
- Debug API endpoints — поведение неизменно, добавляется только computed
  `config_dirty` поле в `/state` для диагностики.

---

## Архитектура

### Три слоя состояния

```
┌──────────────────────────────────────┐
│ in-memory                            │   ← editing screens (_State.setState)
│ • UI editor буфер                    │     ChangeNotifier'ы (HomeController, SubscriptionController)
│ • subController.configDirty: bool    │     HomeState.configChangedNeedRestart: bool
│ • HomeState.configChangedNeedRestart │
└──────────────────────────────────────┘
                  │ flush on exit (write-on-exit pattern)
                  │ или immediate write (eager pattern)
                  ▼
┌──────────────────────────────────────┐
│ on disk: lxbox_settings.json         │   ← SettingsStorage._cache + _save()
│ • tun_apps / route_final / dns_*     │     §072 atomic write (tmp + rename + .bak)
│ • server_lists / custom_rules / vars │
└──────────────────────────────────────┘
                  │ генерация: subController.generateConfig
                  │ применение: HomeController.saveParsedConfig
                  ▼
┌──────────────────────────────────────┐
│ on disk: singbox_config.json         │   ← VpnPlugin.saveConfig
│ • outbounds / endpoints / route /    │     §072 atomic write
│   dns / inbounds[tun] / experimental │
└──────────────────────────────────────┘
                  │ native start: VpnService.Builder.establish()
                  ▼
┌──────────────────────────────────────┐
│ running tunnel (sing-box process)    │   ← native domain; immutable до stop()
│ • snapshot saved config на момент    │
│   establish()                        │
└──────────────────────────────────────┘
```

### Два флага рассинхронизации

| Флаг | Локация | Persistent | Значение |
|---|---|---|---|
| `subController.configDirty: bool` | in-memory только | **нет** (на launch восстанавливается через mtime compare) | Storage обновлён, но saved config ещё не пересобран с этими изменениями. |
| `HomeState.configChangedNeedRestart: bool` | in-memory только (sticky до next start) | **нет** (после start = false by definition) | Saved config обновлён во время работающего tunnel, running config устарел, нужен restart. |

**Восстановление `configDirty` на launch — file mtime compare:**

```dart
// ConfigDirtyCheck.isDirty():
final settings_mtime = stat(lxbox_settings.json).mtime;  // null если нет
final config_mtime   = stat(singbox_config.json).mtime;  // null если нет

if (settings_mtime == null) return false;        // fresh install
if (config_mtime == null)   return true;         // settings есть, config нет
return settings_mtime > config_mtime;            // settings новее
```

`SubscriptionController.init()` зовёт `ConfigDirtyCheck.isDirty()` и
выставляет `configDirty` соответственно. `home_screen._initSubsAndAutoUpdate`
триггерит bootstrap rebuild если флаг true.

### Home banner — единый source-of-truth для restart UX

**Условия видимости** (mutually exclusive — два banner'а одновременно не появляются):

- **Синий** «Settings changed — tap to rebuild config»:
  `configDirty == true && !subController.busy`. Показывается **всегда**,
  независимо от tunnel state — юзер видит pending changes даже когда VPN off.

- **Розовый** «Config changed — restart VPN»:
  `tunnelUp == true && configChangedNeedRestart == true && configDirty == false`.
  Только после rebuild (configDirty cleared) и при работающем tunnel.

**Логика tap'а:**
- Tap по синему → `_rebuildAndClearDirty` → `generateConfig` +
  `saveParsedConfig` → `configDirty = false`. Если `tunnelUp` —
  `configChangedNeedRestart` становится `true` (sticky), синий гаснет,
  розовый появляется.
- Tap по розовому → confirm dialog → `stop + start` → на successful
  start `configChangedNeedRestart = false`, розовый гаснет.

### Global NavigatorObserver — auto-rebuild на возврат к home

`HomeReturnObserver extends NavigatorObserver`, singleton зарегистрирован
в `MaterialApp.navigatorObservers`. Срабатывает на любой `didPop` когда
**root route** (home) становится `previousRoute` (top after pop).

```dart
@override
void didPop(Route route, Route? previousRoute) {
  super.didPop(route, previousRoute);
  if (previousRoute?.isFirst == true) {
    _handler?.call();
  }
}
```

`home_screen._HomeScreenState` регистрирует handler в `initState`:

```dart
homeReturnObserver.setHandler(_onReturnToHome);

void _onReturnToHome() {
  if (!mounted) return;
  if (!_subController.configDirty) return;
  if (_subController.busy) return;
  unawaited(() async {
    final val = await SettingsStorage.getVar('auto_rebuild', 'true');
    _autoRebuild = val == 'true';
    if (!mounted) return;
    if (_autoRebuild) {
      await _rebuildAndClearDirty();   // auto rebuild on return
    } else {
      setState(() {});                 // только refresh banner, юзер тапает сам
    }
  }());
}
```

**Свойства механизма:**
- Не привязан к конкретному callsite — срабатывает на **любом** способе
  возврата (drawer pop, system back, swipe-back, programmatic
  `Navigator.pop`, `popUntil`).
- Cross-navigation (home → Stats → VPN Settings → pop pop): срабатывает
  ровно когда home становится top (после последнего pop'а), не на
  промежуточных pop'ах внутри stack.
- Setting **«Auto-rebuild config»** в App Settings (`auto_rebuild` var,
  default `true`) re-read'ится на каждое срабатывание — юзер может
  переключить behavior без рестарта app'а. **[§107: настройка удалена —
  rebuild на возврате всегда автоматический; свежесть конфига на старте
  гарантирует гейт в `_startWithAutoRefresh`.]**

### External restart marker — `markConfigChangedNeedRestart`

Для настроек применяемых **вне** config pipeline (native VpnService.Builder
toggles: `allow_bypass` / `keep_on_exit` / `background_mode`) нужен путь
напрямую mark'нуть `HomeState.configChangedNeedRestart` без rebuild'а:

```dart
// HomeController
void markConfigChangedNeedRestart() {
  if (_state.tunnelUp) {
    _emit(_state.copyWith(configChangedNeedRestart: true));
  }
}
```

Gated on `tunnelUp` — если tunnel down, новое значение подхватится на
следующем `start()` без restart'а; banner не нужен. `settings_screen`
зовёт этот метод после `_vpn.setAllowBypass` / `setKeepOnExit` /
`setBackgroundMode`.

---

## Lifecycle

### Цепочка событий: edit → applied to running tunnel

```
[Юзер открывает editing screen (tun_apps / routing / dns / vpn settings)]
   _load() читает _cache → _State
   pendingChanges = false

[Юзер toggle'ит / меняет value]
   setState(() { _cfg = новое значение })  ← только in-memory
   _markDirty():
     _pendingChanges = true                     ← локальный флаг screen'а
     subController.configDirty = true           ← глобальный sync (race-safe)
   НЕТ disk write, НЕТ rebuild

[Юзер delает ещё N изменений]
   Тот же flow: только in-memory обновления

[Exit editing screen]
  одно из событий:
  • Navigator.pop  → dispose()              ┐
  • App backgrounded → onPaused()           ├─→ _persist():
                                            │     SettingsStorage.setX(_cfg)  ← atomic §072 write
                                            │     _pendingChanges = false
                                            │   ─ subController.configDirty уже true (set в _markDirty)
                                            └─

[Юзер вернулся на home (любой способ: pop / popUntil / system back / swipe)]
   homeReturnObserver.didPop fires (previousRoute.isFirst == true)
   → home._onReturnToHome handler:
     if subController.configDirty:
       if auto_rebuild setting == true:
         _rebuildAndClearDirty():
           config = await subController.generateConfig()  ← reads fresh _cache
           await homeController.saveParsedConfig(config)   ← atomic write
           subController.configDirty = false              ← in-memory clear
           if tunnelUp:
             HomeState.configChangedNeedRestart = true    ← in-memory sticky
       else:
         setState  ← juзер сам тапает синий banner
   
   Home banner re-evaluated:
     • если configChangedNeedRestart && tunnelUp && !configDirty: розовый banner
     • если configDirty: синий banner
     • иначе: nothing

[Юзер tap'ает розовый banner «Restart VPN»]
   _confirmStop → stop + start → _startInternal:
     await native.startVPN()    ← native читает свежий saved config
     configChangedNeedRestart = false
   Banner гаснет, running tunnel = saved config.
```

### Self-healing после kill mid-edit

```
[App killed mid-edit (OOM / process kill)]
   in-memory state lost.
   lxbox_settings.json содержит изменения сделанные до последнего dispose/pause flush.
   singbox_config.json устарел (rebuild не успел).

[Next app launch]
   subController.init():
     entries = await SettingsStorage.getServerLists()
     configDirty = await ConfigDirtyCheck.isDirty()   ← stat both files, compare mtime
   
   if configDirty: AppLog «configDirty=true via mtime compare»

   home._initSubsAndAutoUpdate():
     if entries.notEmpty && (configRaw.isEmpty || subController.configDirty):
       config = await subController.generateConfig()
       await homeController.saveParsedConfig(config)
       subController.configDirty = false
       setState
```

Юзер на home — banner не показывается. Все settings которые успели до
kill'а сохраниться, применены в config'е тихо до того как юзер успел
открыть UI.

---

## Два паттерна persist'а

В §076 предусмотрены **два паттерна**. Каждый editing screen выбирает
свой осознанно — это design choice, исходя из характера user
interaction'а и того, влияют ли изменения на sing-box config.

### Lazy pattern (write-on-exit)

**Когда применяется:**
- Editing screen где юзер делает **много мелких изменений подряд**
  (toggle-flood: чекбоксы, переключатели mode, var sliders).
- Изменения **влияют на sing-box config** — нужен rebuild.

**Механика:**

1. Mutation → setState (in-memory только).
2. `_markDirty()` синхронно:
   - `_pendingChanges = true` — локальный флаг для idempotent flush.
   - `subController.configDirty = true` — глобальный флаг (sync — race-safe
     для `homeReturnObserver` который читает его сразу после dispose).
3. `_persist()` flush'ит storage **только** на exit screen'а:
   - `dispose()` — Navigator.pop с этого screen'а. Async flush через
     `unawaited(_persist())`.
   - `didChangeAppLifecycleState(paused)` — app backgrounded (Home button,
     app switcher, incoming call). Только `paused`; `inactive` слишком
     часто (notification panel pull, transient overlays) и привёл бы к
     spurious writes.
4. Rebuild не происходит inline в `_persist`. Срабатывает lazy:
   - `homeReturnObserver` — на возврате на home (если `configDirty`) через
     `home._onReturnToHome` handler (см. секцию «Global NavigatorObserver»).
   - launch bootstrap — `home._initSubsAndAutoUpdate` если `configDirty`
     восстановился через mtime compare.
   - `auto_rebuild` setting в App Settings контролирует поведение: ON →
     auto-rebuild на return; OFF → только banner, ручной tap.
5. После rebuild при работающем tunnel ставится
   `configChangedNeedRestart=true`, banner показывает «Restart VPN».

**Преимущества:**

| Метрика | Значение |
|---|---|
| Storage writes per editing session | **1** (один atomic flush на dispose) |
| Config writes per editing session | **1** (один rebuild на возврате home) |
| Disk activity during active editing | **0** (всё in-memory) |
| Banner UX | Единый home banner — не разбросанные снэкбары |
| Edit session атомарность | Все изменения applied вместе, на kill — coherent inconsistency, fixable mtime compare |

### Eager pattern (immediate-write)

**Когда применяется:**
- **Discrete event** screen: explicit Save/Apply button или add/remove
  list item. Каждое действие = один user intent, не toggle-flood.
- ИЛИ изменения **не влияют** на sing-box config — UI prefs.

**Механика:**

1. User action (tap Save / Add subscription / toggle haptic) → inline:
   - `SettingsStorage.setX` или `saveX` (atomic §072 write).
   - Если влияет на config: `subController.generateConfig` +
     `homeController.saveParsedConfig`.
2. Snackbar immediate feedback («Added: 42 nodes», «Saved», etc.).

**Когда выбираем eager:**
- **Explicit Save button** (custom_rule_edit, node_filter): юзер
  осознанно фиксирует edit session. Lazy здесь добавляет лишний шаг —
  exit без явного «Save» не очевиден.
- **Discrete event** (subscriptions add/remove/fetch): не toggle-flood,
  immediate UX feedback нужен («Added: X nodes»).
- **Config-independent settings** (app prefs: haptic, auto_rebuild flag,
  debug port): rebuild не нужен совсем — lazy mechanism overkill.

**Преимущества:**

| Метрика | Значение |
|---|---|
| UX feedback | Immediate snackbar — critical для discrete actions |
| Код | Простой: без `WidgetsBindingObserver`, без `_markDirty`/`_pendingChanges` |
| Frequency match | Action rate низкий by nature события → write rate низкий |

### Migration matrix

| Screen | Pattern | Обоснование |
|---|---|---|
| `tun_apps_tab.dart` | **Lazy** | Add/remove apps в чек-листе = toggle-flood. Влияет на `tun.exclude_package`. |
| `routing_screen.dart` | **Lazy** | Rule toggles + var sliders = toggle-flood. Влияет на routing rules. |
| `dns_settings_screen.dart` | **Lazy** | DNS rules / server config — toggle-flood на big list. Влияет на dns секцию. |
| `settings_screen.dart` (Core VPN tab) | **Lazy** для template vars | Template var changes (TLS fragment, ECH) — toggle-flood. Pending vars в `_pendingVars` map, flush на dispose/paused. |
| `settings_screen.dart` (System VPN tab native toggles) | **Immediate + markRestart** | `allow_bypass` / `keep_on_exit` / `background_mode` идут через `_vpn.setX` (native SharedPreferences, не lxbox_settings.json). После save вызывают `homeController.markConfigChangedNeedRestart()` → home banner показывает «Restart VPN» если tunnelUp. Не config rebuild — settings применяются только на следующем `establish()`. |
| `subscriptions_screen.dart` | **Eager** | Add/remove subscription = discrete event. Юзер ожидает «Added: 42 nodes» immediate как confirmation. |
| `app_settings_screen.dart` | **Eager** | UI prefs (haptic, auto_rebuild, debug toggles) **не влияют** на sing-box config. Каждый toggle = discrete event. |
| `custom_rule_edit_screen.dart` | **Eager** | Edit modal с explicit **Save** button. Юзер сам фиксирует session. |
| `node_filter_screen.dart` | **Eager** | Checkbox list + explicit **Apply** button (active только если `_dirty`). Юзер сам фиксирует. |

---

## Lazy pattern: реализация в State

Все lazy-pattern screens follow same shape:

```dart
class _SomeEditScreenState extends State<SomeEditScreen>
    with WidgetsBindingObserver {

  /// Локальные in-memory state поля
  SomeConfig _cfg = ...;
  bool _pendingChanges = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // write-on-exit: Navigator.pop → flush pending.
    if (_pendingChanges) unawaited(_persist());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // safety net: app backgrounded → flush. Только `paused`.
    if (state == AppLifecycleState.paused && _pendingChanges) {
      unawaited(_persist());
    }
  }

  /// Mutation → синхронно отметить флаги. configDirty должен быть видим
  /// homeReturnObserver handler'у до того как он начнёт проверять —
  /// иначе race: дисковая запись (в _persist) ещё не завершилась, флаг
  /// false, rebuild не fires.
  void _markDirty() {
    _pendingChanges = true;
    widget.subController.configDirty = true;  // sync race-safe
  }

  /// Atomic flush. Не рестартует VPN, не пересобирает config. configDirty
  /// **не трогаем** тут — он уже sync set'нут в _markDirty. Повторный
  /// set ПОСЛЕ await'ов конфликтует с rebuild который мог уже cleared
  /// его (race window).
  Future<void> _persist() async {
    if (!_pendingChanges) return;  // idempotent
    _pendingChanges = false;
    await SettingsStorage.setSomeKey(_cfg);
  }

  /// UI handlers вызывают только setState + _markDirty.
  void _onSomeToggle(bool v) {
    setState(() => _cfg = _cfg.copyWith(value: v));
    _markDirty();
  }
}
```

Ключевые свойства:

- `_persist` идемпотентен — повторный вызов после `_pendingChanges=false`
  no-op.
- `_markDirty` синхронный, без await — race-safe для `homeReturnObserver`.
- `_persist` **не set'ит configDirty** после await'ов — это создавало
  бы race (rebuild мог уже сbросить флаг между dispose и завершением
  storage write'а).
- ~~Race window между dispose's `unawaited(_persist())` и
  `homeReturnObserver` handler'ом: … handler видит fresh state и
  триггерит lazy rebuild корректно~~ — **анализ был неверен (§107)**:
  handler стреляет синхронно в момент pop'а, а dispose (и flush) —
  только после exit-анимации, ~300 мс позже. Rebuild детерминированно
  читал несфлашенный storage; конфиг отставал на один визит экрана.
  Исправлено в §107: мутация сразу stage'ится в `SettingsStorage._cache`
  (`stageChanges`), на dispose остаётся только дисковый
  `flushToDisk()`.

---

## Storage write accounting

Сравнение типичных сценариев. Считается на 5-toggle session в editing screen.

| Сценарий | Disk writes |
|---|---|
| Lazy (§076): 5 toggle'ов → exit → home rebuild | 1 settings + 1 config = **2 writes** |
| Lazy: 50 rapid toggle'ов → exit → home rebuild | 1 settings + 1 config = **2 writes** |
| Lazy: kill mid-edit → next launch | 1 config (bootstrap rebuild) = **1 write** |
| Lazy: clean launch (no pending) | **0 writes** |
| Eager: 5 toggle'ов в subscriptions (event-driven) | 1 settings + 1 config per event × 5 = **до 10 writes** |
| Eager (app_settings): 1 toggle haptic | 1 settings = **1 write** (rebuild не нужен) |
| Eager (node_filter): Apply button | 1 settings + 1 config = **2 writes** |
| Tap «Restart VPN» banner | 0 writes (stop + start, native читает saved config) |

Lazy паттерн снимает disk pressure с hot-path editing UX в сценариях
toggle-flood. Eager оставлен для discrete events где он естественен.

---

## Edge cases

| Сценарий | Поведение |
|---|---|
| User toggle'ит, тут же back-navigate | `dispose()` зовёт `_persist()` через `unawaited`. Storage write фиксирует все изменения. Возврат на home → `homeReturnObserver` → handler → rebuild (если `auto_rebuild` ON). |
| User toggle'ит, phone call → app paused | `didChangeAppLifecycleState(paused)` → flush. На resume — state восстанавливается из storage. |
| User backgrounded мid-edit → app killed в background | Last flush на pause сохранил изменения. Config stale. Next launch → mtime compare → dirty → bootstrap rebuild. |
| User OOM-killed в foreground мid-edit | Foreground app редко kill'ится. Если случилось — теряются только in-memory changes после последнего lifecycle event (typically 0). |
| Fresh install — `singbox_config.json` отсутствует | `stat` returns null. `ConfigDirtyCheck.isDirty()` returns true if settings exist. Bootstrap rebuild сработает на launch. |
| §072 corruption recovery (`main` corrupted, `.bak` ok) | After recovery main file mtime = .bak's mtime. Comparison с config mtime может показать stale → bootstrap rebuild. Self-heal. |
| Two writes within same second на FS с 1-sec mtime granularity | mtime может совпасть → `>` returns false → missed dirty. **Mitigation**: lazy write-on-exit pattern = 1 write per session exit; sub-second collision rare. На современных Android FS (ext4/f2fs) nanosecond resolution — не проблема. |
| Native `PUT /config` через Debug API | config.json mtime обновляется → settings_mtime <= config_mtime → не dirty. Корректно. |
| Tap по home banner (configDirty + tunnelUp) | `_rebuildAndClearDirty` → after success `configDirty=false`, `configChangedNeedRestart=true` (sticky) → синий banner гаснет, розовый появляется. Юзер видит prompt для restart. |
| User кликает Restart button в banner | `_confirmStop` → stop + start. `_startInternal` reset'ит `configChangedNeedRestart=false`. |
| Routing screen открыт, user navigates через drawer (не pop) | drawer обычно `Navigator.push` — RoutingScreen unmount'ится → dispose fires → flush. |
| Race: `homeReturnObserver` стартует пока dispose `_persist` ещё пишет на диск | ~~Race безопасен~~ — **неверно (§107)**: handler срабатывает на pop, dispose-flush — после exit-анимации; `generateConfig` читал stale `_cache`. Исправлено staging'ом в §107 (см. tasks/107). |
| Cross-navigation (home → Stats → VPN Settings → toggle → pop pop → home) | Каждое intermediate pop проверяет `previousRoute.isFirst`. Pop VPN Settings → previousRoute=Stats (не first) → handler не fires. Pop Stats → previousRoute=home (isFirst) → handler fires → rebuild. |
| Native VPN System toggle (Allow Bypass / Keep on Exit / Background Mode) при tunnelUp | `_vpn.setX` пишет в native SharedPreferences. После — `homeController.markConfigChangedNeedRestart()` set'ит флаг. Home banner показывает «Restart VPN». На tap restart применяет новое значение через `VpnService.Builder` на свежем `establish()`. |
| Native VPN System toggle при tunnel down | `markConfigChangedNeedRestart` gated на `tunnelUp` → не set'ит флаг. Значение применится на следующем start без restart prompt. |

---

## Файлы

### Новые

- `app/lib/services/config_dirty_check.dart` — file mtime compare helper:
  - `settingsModifiedTime()` / `configModifiedTime()` — null-safe stat.
  - `isDirty()` — boolean: settings newer than config (или config absent).

- `app/lib/services/nav/home_return_observer.dart` — global
  `HomeReturnObserver extends NavigatorObserver`:
  - Singleton `homeReturnObserver`, регистрируется в
    `MaterialApp.navigatorObservers`.
  - `didPop` срабатывает когда `previousRoute.isFirst == true` (home
    стал top после pop'а).
  - `setHandler(VoidCallback)` / `clearHandler()` — для регистрации из
    `home_screen.initState/dispose`.

### Изменённые

- `app/lib/main.dart` — добавлен `navigatorObservers: [homeReturnObserver]`
  в `MaterialApp` constructor.

- `app/lib/models/home_state.dart` — field rename `configStaleSinceStart`
  → `configChangedNeedRestart` + docstring пояснение sticky-семантики.

- `app/lib/controllers/home_controller.dart` — rename references, local
  var `stale` → `needRestart`, log keys `stale_before` →
  `need_restart_before`. **Новый method `markConfigChangedNeedRestart()`** —
  external mark флага для настроек применяемых вне config pipeline
  (native VPN toggles). Gated на `tunnelUp`.

- `app/lib/controllers/subscription_controller.dart`:
  - `configDirty` остаётся public bool field.
  - В `init()` после загрузки entries — `configDirty =
    await ConfigDirtyCheck.isDirty();`.

- `app/lib/screens/tun_apps_tab.dart` — миграция на lazy pattern.
  Удалены: `_appliedCfg`, `_isModified`, `_listEq`, `_restartVpn`,
  локальный «Restart needed» banner + button, `_saveTimer` +
  `_scheduleSave`. Добавлены: `WidgetsBindingObserver` mixin,
  `_pendingChanges` field, `_markDirty()`, `_persist()`.

- `app/lib/screens/routing_screen.dart` — миграция на lazy pattern.
  Удалены: `_saveTimer`, `_scheduleSave`, inline `generateConfig +
  saveParsedConfig` из `_apply`, snackbar'ы. `_apply` переименован в
  `_persist`. Все mutation handlers вызывают `_markDirty()` вместо
  `_scheduleSave()`.

- `app/lib/screens/dns_settings_screen.dart` — миграция на lazy pattern.
  `_save` rename to `_persist`. Inline rebuild + snackbar удалены.
  `_scheduleSave` → `_markDirty`.

- `app/lib/screens/settings_screen.dart`:
  - **Core VPN tab** — template var changes мигрированы на lazy.
    `_pendingVars` map собирает pending var changes, `_persist` flush'ит
    их на dispose / lifecycle.paused.
  - **System VPN tab** — native toggles (`_toggleAllowBypass`,
    `_toggleKeepOnExit`, `_applyBackgroundMode`) после `_vpn.setX`
    вызывают `widget.homeController.markConfigChangedNeedRestart()`.
    Локальный snackbar «Saved. Reload VPN to apply.» удалён — единый
    home banner.

- `app/lib/screens/home_screen.dart`:
  - Banner gate переписан: синий показывается **всегда** при
    `configDirty=true` (без `tunnelUp` gate). Розовый показывается
    при `tunnelUp && configChangedNeedRestart && !configDirty`
    (mutually exclusive с синим).
  - `_pushRoute` упрощён — `.then()` callback удалён (rebuild trigger
    переехал в `homeReturnObserver`). Метод теперь просто `pop drawer +
    push screen`.
  - `homeReturnObserver.setHandler(_onReturnToHome)` в `initState`,
    `clearHandler()` в `dispose`.
  - `_onReturnToHome` — handler читает `auto_rebuild` setting и либо
    `_rebuildAndClearDirty` либо `setState` (только banner update).
  - `_initSubsAndAutoUpdate` расширен: bootstrap rebuild если
    `entries.notEmpty && (configRaw.isEmpty || subController.configDirty)`.

- `app/lib/services/debug/serializers/home_state.dart` — JSON key rename
  `config_stale_since_start` → `config_changed_need_restart` (breaking
  для external consumers Debug API, документировано в release notes).

- `app/lib/services/debug/handlers/state.dart` — `/state` response
  добавляет computed `config_dirty: bool` из `subController.configDirty`
  (read-only диагностика).

---

## Tests

```
app/test/services/config_dirty_check_test.dart (NEW)
  - settings_modified_after_config → true
  - config_newer_than_settings → false
  - fresh install (both absent) → false
  - settings absent → false
  - config absent → true

app/test/services/nav/home_return_observer_test.dart (NEW)
  - didPop с previousRoute.isFirst=true → handler fires
  - didPop с previousRoute.isFirst=false → handler не fires
  - didPop с previousRoute=null → handler не fires
  - setHandler / clearHandler идемпотентны

app/test/screens/lazy_pattern_lifecycle_test.dart (NEW, widget test)
  - mutation → setState only, no SettingsStorage write
  - dispose → _persist invokes setX once
  - lifecycle.paused → _persist invokes setX once
  - idempotent: second _persist no-op

app/test/models/home_state_test.dart (UPDATE)
  - field rename references
  - configChangedNeedRestart sticky on subsequent saveParsedConfig calls

app/test/controllers/home_controller_test.dart (UPDATE)
  - markConfigChangedNeedRestart: tunnelUp=true → флаг set'ится
  - markConfigChangedNeedRestart: tunnelUp=false → no-op

app/test/services/subscription_controller_init_test.dart (NEW)
  - init с dirty mtime compare → configDirty=true
  - init clean → configDirty=false
```

---

## Storage migration / API compatibility

- **`lxbox_settings.json` schema**: без изменений. Старые backup'ы load'ятся
  1:1. `config_dirty` не пишется на диск.
- **Debug API**: JSON key `config_stale_since_start` →
  `config_changed_need_restart` — **breaking** для external консьюмеров.
  Документировано в release notes. Добавлен computed `config_dirty: bool`.
- **In-memory state field**: `HomeState.configStaleSinceStart` →
  `configChangedNeedRestart`. Sweep across home_controller, home_screen,
  debug serializer.

---

## Acceptance criteria

- [x] Lazy screen (tun_apps_tab / routing_screen / dns_settings /
      settings_screen Core tab): editing → exit → возврат на home
      пересобирает config автоматически, banner correct.
- [x] Native VPN System toggle (allow_bypass / keep_on_exit /
      background_mode) при tunnelUp → home banner «Restart VPN».
- [x] Edit + smahn'ул app → re-resume → state восстанавливается из
      storage (lifecycle.paused flush сработал).
- [x] App killed мid-edit → next launch → bootstrap rebuild через mtime
      compare → tunnel запускается со свежим config'ом.
- [x] Home banner показывается при `configDirty=true` независимо от
      tunnel state.
- [x] Два banner'а одновременно не показываются: configDirty → синий,
      configChangedNeedRestart+tunnelUp+!configDirty → розовый.
- [x] Tap по синему banner: rebuild + clear flag; если tunnelUp — розовый
      появляется автоматически.
- [x] Cross-navigation (home → Stats → VPN Settings → toggle → pop pop →
      home): `homeReturnObserver` triggers rebuild ровно на финальном pop.
- [x] Long-press на Nodes header → Routing screen → toggle → pop: rebuild
      срабатывает (раньше `.then()` callback отсутствовал, баг).
- [x] Storage writes per 5-toggle session ≤ 2 (для lazy screens).
- [x] `configStaleSinceStart` ↔ `configChangedNeedRestart` sweep clean —
      нет stale references.
- [x] Auto-rebuild config toggle (App Settings → `auto_rebuild` var) —
      ON триггерит auto-rebuild на возврат; OFF только показывает banner.
      **[§107: toggle и OFF-режим удалены.]**
- [x] Existing 687+ tests pass.
- [x] Eager screens (subscriptions / app_settings / custom_rule_edit /
      node_filter) поведение НЕ меняется — immediate save + snackbar как
      было.

## Open Qs (для возможных follow-up)

- Manual «Force rebuild» button где-то ещё (за пределами banner tap)?
  Сейчас нет — banner и lazy на возврате home покрывают все случаи.
- Sub-second mtime collision detection на старых FS — не критично на
  baseline Android 14, отложено.
- AppLifecycleState — следить за future Android-versions если `hidden`
  станет caller'ом чаще `paused`.

---

## §107 addendum (2026-06-10)

Field report (4PDA, v2.0.x) выявил, что race-анализ lazy pattern'а в этой
спеке был неверен: `didPop` срабатывает синхронно в момент pop'а, а
dispose-flush экрана — после exit-анимации (~300 мс позже), поэтому
rebuild на возврате к home читал состояние «до последней правки» — конфиг
хронически отставал на один визит editing-экрана, и рестарт туннеля не
лечил.

Исправление (staging мутаций в `SettingsStorage._cache` + гейт пересборки
на Start + single-flight rebuild), а также удаление настройки
`auto_rebuild` со всей логикой OFF-режима — в
[`tasks/107-lazy-persist-stale-read-race.md`](../../tasks/107-lazy-persist-stale-read-race.md).
