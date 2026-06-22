# 047 — Public Intent API (Tasker / automation integration)

| Поле | Значение |
|------|----------|
| Статус | **Implemented** (2026-06-21) — **Шаг 1** raw broadcast actions + emitter + bridge + вкладка Automation; **Шаг 2** Locale/Tasker plugin (`FIRE_SETTING` + `QUERY_CONDITION`) — L×Box виден в Tasker как Plugin (Action + State). Docs: [`docs/AUTOMATION.md`](../../../AUTOMATION.md). Health-события — future (§042). |
| Дата | 2026-05-10 (обновлено 2026-06-21 — Шаги 1 и 2 реализованы) |
| Зависимости | [`031 debug api`](../031%20debug%20api/spec.md) (action handlers переиспользуются) |
| Связано | [`032 quick connect`](../032%20quick%20connect/spec.md) (та же семантика toggle/switch, разные источники) |
| Issue | [#12 «Add ON and OFF actions in addition to toggle»](https://github.com/Leadaxe/LxBox/issues/12) — `START_VPN`/`STOP_VPN` покрывают запрос |
| Реализация | Native (Kotlin BroadcastReceiver) + Flutter UI-блок в App Settings (toggle приёма, галки emit-категорий, интент-строки с копированием) + `docs/AUTOMATION.md` |

> ⚠️ **Изменение (§157, 2026-06-22):** галка «Требовать пропуск»
> (`automation_require_permission`) и custom-permission
> `com.leadaxe.lxbox.permission.AUTOMATION` **удалены** — `checkCallingPermission`
> в broadcast-`onReceive` недетерминирован (broadcast не несёт caller-identity),
> реальной защиты не давал. Единственный барьер приёма — мастер-toggle (receiver
> `enabled=false` по умолчанию); outgoing-события идут открытым `sendBroadcast`.
> Разделы ниже с упоминанием «Требовать пропуск» / permission-gate описывают
> **прежнее** состояние — см. [`tasks/157`](../../tasks/157-automation-drop-require-permission.md).

---

## Цель и рамки

Дать external automation tools (**Tasker**, **Macrodroid**, **Llama**, **Automate**, IFTTT-like apps, shell-скрипты через `am broadcast`) возможность управлять L×Box через Android **broadcast intents**. Закрытие фидбека "хочу автоматически включать VPN на не-домашнем Wi-Fi", "switch на Russia-узел при запуске банковского app'а", "выключать ночью / по расписанию".

Сейчас управлять VPN снаружи можно только двумя путями:
1. **Quick Settings tile / shortcut** ([§032](../032%20quick%20connect/spec.md)) — но требует ручной тап юзера, не automation.
2. **Debug API** (`POST /action/*`) — мощно, но требует enabled токен + adb forward или WiFi reachable, не предназначен для automation tools на устройстве.

Tasker и аналогичные приложения умеют отправлять Android intents но **не умеют HTTP с Bearer auth** (есть, но громоздко). Native broadcast intents — стандартный для Android automation способ интеграции.

**В скопе:**
- **Incoming actions** — exported `BroadcastReceiver` принимающий 9 действий: `START_VPN`, `STOP_VPN`, `TOGGLE_VPN`, `SWITCH_NODE` (extra: `tag`), `SET_GROUP` (extra: `group`), `REBUILD_CONFIG`, `REFRESH_SUBS` (extra: `force`), `RESET_NETWORK`, `URLTEST_GROUP` (extra: `group`).
- **Outgoing events** — broadcasts от L×Box во внешний мир: `VPN_CONNECTED`, `VPN_DISCONNECTED` (extra: `reason`), `VPN_ERROR` (extras: `code`, `message`), `VPN_REVOKED`, `ACTIVE_NODE_CHANGED` (extras: `old_tag`, `new_tag`, `reason`), `ACTIVE_GROUP_CHANGED`, `SUB_REFRESH_FAILED` (extras: `sub_id`, `error`), плюс health-events когда §042 watchdog будет готов.
- **Symmetric request-response pattern** — Tasker может wait'ать на исходящий event как ответ на свой request (например `SWITCH_NODE` → `ACTIVE_NODE_CHANGED` или `VPN_ERROR`).
- Реализация переиспользует существующие action handlers из [`debug/handlers/action.dart`](../../../app/lib/services/debug/handlers/action.dart) (тот же business logic, разные транспорты).
- Documentation страница в App Settings → Automation API с примерами Tasker setup.
- **Granular opt-in toggles** — receiver и emitter управляются отдельно, по категориям событий. Default — все OFF. Юзер выбирает что разрешить.

**Не в скопе:**
- Kotlin/Java SDK для third-party app developers — over-engineering для нашего scale'а.
- Per-action permission scopes / signature verification — accept все intents если categorical toggle ON, иначе отказываем.
- Tasker plugin (separate APK с UI dropdown'ами для action/extras) — оставлено в "Будущие расширения".
- iOS — отсутствует (Android-only feature, как §032).

---

## Контекст

### Что такое Tasker (для тех кто не в курсе)

Android automation app. Юзер задаёт правила:

```
Profile: "Office Wi-Fi"
  Trigger: Wi-Fi connected = "MyOfficeNetwork"
  Action: Run task "Disable VPN"

Task: "Disable VPN"
  → Send Intent
      Action: com.leadaxe.lxbox.STOP_VPN
      Target: Broadcast Receiver
```

Tasker умеет тригериться от десятков event'ов: Wi-Fi, location (geofence), время, app launch, battery, headphone plug, notification arrival, Bluetooth pair, и т.д. **Power user'ы строят сложные сценарии** — типа "если Wi-Fi=Home AND time>22:00 AND app=Telegram → switch VPN на спец узел чтобы пустить через детский firewall". Без public intent API это всё делается через ADB+root scripts — недоступно массовому юзеру.

### Зачем broadcast, а не SDK / API

| Подход | Pros | Cons |
|---|---|---|
| **Public intents (этот spec)** | Стандарт Android, Tasker/etc понимают из коробки. Декларативно через Manifest. | Action names — public API surface, breaking change болезненный. |
| Kotlin SDK (jar/aar) | Type-safe для разработчиков | Tasker/Macrodroid не понимают — нужна обёртка. Maintenance heavy. |
| HTTP API (Debug API уже есть) | Универсально | Tasker через HTTP-плагины громоздко. Token management, auth, ports. |
| Accessibility API | Не требует от нас ничего | Юзеру нужно дать accessibility permission всему automation tool'у — privacy hell |

Победа — **public intents**.

### Безопасность — почему default OFF

Любая установленная app может отправить `Intent("com.leadaxe.lxbox.STOP_VPN")` через `sendBroadcast`. Если receiver `exported=true` всегда listening — потенциально malicious app может выключать VPN без юзера. Mitigation:

1. **Toggle в App Settings → Automation API** (default OFF). Receiver регистрируется только когда toggle ON.
2. **Юзер видит при включении** explainer dialog с warning "Любая app сможет управлять VPN. Включайте только если используете Tasker/Macrodroid".
3. Optionally — **package whitelist** в advanced settings (UI: "Allow only these apps to control VPN: [+]"). Для v2.

### Существующая инфраструктура которую переиспользуем

**Incoming** — все 9 actions **уже реализованы** как Debug API endpoints в [`debug/handlers/action.dart`](../../../app/lib/services/debug/handlers/action.dart):

| Intent action | Существующий handler | Notes |
|---|---|---|
| `START_VPN` | `_startVpn(ctx)` | Идемпотентен: noop если уже started |
| `STOP_VPN` | `_stopVpn(ctx)` | Блокирующий до Stopped |
| `TOGGLE_VPN` | `MainActivity.ACTION_TOGGLE` уже handle'ится | Already exists |
| `SWITCH_NODE` (extra: `tag`) | `_switchNode(req, ctx)` | Через `HomeController.switchNode` |
| `SET_GROUP` (extra: `group`) | `_setGroup(req, ctx)` | Active group selector |
| `REBUILD_CONFIG` | `_rebuildConfig(ctx)` | Config regen, respects §037 lock |
| `REFRESH_SUBS` (extra: `force`) | `_refreshSubs(req, ctx)` | Manual sub-refresh |
| `RESET_NETWORK` | `_resetNetwork(ctx)` | Light recovery: closeAll + DNS flush + dialer rebind. Tunnel must be up. |
| `URLTEST_GROUP` (extra: `group`) | `_urltest(req, ctx)` (`group=`-mode) | Force URLTest на группе. Полезно для periodic re-test'а через Tasker scheduler. |

**Outgoing** — events emit'ятся из существующих points в `HomeController` / `SubscriptionController` где уже есть `notifyListeners()`:

| Outgoing event | Источник | Trigger |
|---|---|---|
| `VPN_CONNECTED` | `HomeController._handleStatusEvent(connected)` | TunnelStatus.connected |
| `VPN_DISCONNECTED` | `HomeController._handleStatusEvent(disconnected)` | TunnelStatus.disconnected (extra `reason`: user/error/revoked/idle) |
| `VPN_ERROR` | `HomeController._handleStatusEvent` (где `event.errorReason != null`) | Любой error path |
| `VPN_REVOKED` | `HomeController._handleStatusEvent(revoked)` | TunnelStatus.revoked |
| `ACTIVE_NODE_CHANGED` | `HomeController.switchNode` + Clash API selector callback | Любое изменение активной ноды |
| `ACTIVE_GROUP_CHANGED` | `HomeController.setActiveGroup` | Изменение активной группы |
| `SUB_REFRESH_FAILED` | `SubscriptionController.refreshEntry` (failure path) | После 5 неудач или auth fail |

То есть **business-логику не пишем** — emitter хучнётся в существующие state-mutations.

---

## Архитектурное решение

### Manifest declaration

```xml
<application ...>
  ...
  <receiver
    android:name=".vpn.LxBoxIntentReceiver"
    android:exported="true"
    android:enabled="false">          <!-- runtime-toggled -->
    <intent-filter>
      <!-- Incoming control actions -->
      <action android:name="com.leadaxe.lxbox.START_VPN" />
      <action android:name="com.leadaxe.lxbox.STOP_VPN" />
      <action android:name="com.leadaxe.lxbox.TOGGLE_VPN" />
      <action android:name="com.leadaxe.lxbox.SWITCH_NODE" />
      <action android:name="com.leadaxe.lxbox.SET_GROUP" />
      <action android:name="com.leadaxe.lxbox.REBUILD_CONFIG" />
      <action android:name="com.leadaxe.lxbox.REFRESH_SUBS" />
      <action android:name="com.leadaxe.lxbox.RESET_NETWORK" />
      <action android:name="com.leadaxe.lxbox.URLTEST_GROUP" />
    </intent-filter>
  </receiver>

  <!-- Custom permission объявляется всегда (нужна когда юзер включил
       строгий режим), но к receiver статически НЕ привязана через
       `android:permission` — манифест-атрибут нельзя переключить
       рантаймом, а защита у нас опциональна (галка). Enforcement —
       в коде (`onReceive`), см. ниже. -->
  <permission
    android:name="com.leadaxe.lxbox.permission.AUTOMATION"
    android:protectionLevel="normal" />
</application>
```

**Notes:**
- `android:enabled="false"` — receiver выключен в манифесте по умолчанию. Включается через `PackageManager.setComponentEnabledSetting(...)` runtime когда юзер toggle'ит "Принимать команды автоматизации".
- **Permission НЕ задаётся через `android:permission` на receiver.** Защита пропуском — опциональна (галка «Требовать пропуск», default OFF), а манифест-атрибут статичен и рантаймом не переключается. Поэтому enforcement делается **в коде**: если галка включена, `onReceive` сам проверяет, что отправитель держит `com.leadaxe.lxbox.permission.AUTOMATION`, и иначе игнорит intent. Когда галка выключена — принимаем от любого caller'а (gate здесь — сам мастер-toggle, без него receiver вообще disabled).
- **Outgoing events** отправляются `sendBroadcast(intent, permission?)`: в строгом режиме — с `com.leadaxe.lxbox.permission.AUTOMATION` (получат только apps с granted permission), иначе — без permission (получит любой подписчик). Симметрично incoming-галке.

### LxBoxIntentReceiver.kt

```kotlin
class LxBoxIntentReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "LxBoxIntent"

        const val ACTION_START_VPN = "com.leadaxe.lxbox.START_VPN"
        const val ACTION_STOP_VPN = "com.leadaxe.lxbox.STOP_VPN"
        const val ACTION_TOGGLE_VPN = "com.leadaxe.lxbox.TOGGLE_VPN"
        const val ACTION_SWITCH_NODE = "com.leadaxe.lxbox.SWITCH_NODE"
        const val ACTION_SET_GROUP = "com.leadaxe.lxbox.SET_GROUP"
        const val ACTION_REBUILD_CONFIG = "com.leadaxe.lxbox.REBUILD_CONFIG"
        const val ACTION_REFRESH_SUBS = "com.leadaxe.lxbox.REFRESH_SUBS"
        const val ACTION_RESET_NETWORK = "com.leadaxe.lxbox.RESET_NETWORK"
        const val ACTION_URLTEST_GROUP = "com.leadaxe.lxbox.URLTEST_GROUP"

        const val EXTRA_TAG = "tag"
        const val EXTRA_GROUP = "group"
        const val EXTRA_FORCE = "force"

        const val PERMISSION_AUTOMATION = "com.leadaxe.lxbox.permission.AUTOMATION"

        /// Прокси к native-кешу галки «Требовать пропуск». Кеш —
        /// SharedPreferences-зеркало storage-key `automation_require_permission`
        /// (default false), синкается из Flutter в `setRequirePermission`.
        /// Читаем именно из prefs, а не через MethodChannel — onReceive обязан
        /// решить про permission синхронно, Flutter-engine может быть не запущен.
        private fun requirePermission(ctx: Context): Boolean =
            ctx.getSharedPreferences("lxbox_automation", Context.MODE_PRIVATE)
                .getBoolean("require_permission", false)

        /// Вызывается из Flutter при смене галки — пишет в native-кеш.
        fun setRequirePermission(ctx: Context, value: Boolean) {
            ctx.getSharedPreferences("lxbox_automation", Context.MODE_PRIVATE)
                .edit().putBoolean("require_permission", value).apply()
            Log.d(TAG, "require-permission set to $value")
        }

        fun setEnabled(ctx: Context, enabled: Boolean) {
            val pm = ctx.packageManager
            val component = ComponentName(ctx, LxBoxIntentReceiver::class.java)
            pm.setComponentEnabledSetting(
                component,
                if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
            Log.d(TAG, "automation API ${if (enabled) "enabled" else "disabled"}")
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val callerPkg = sentFromPackage(intent)  // best-effort attribution
        Log.d(TAG, "received ${intent.action} from $callerPkg")

        // Опциональный пропуск (галка «Требовать пропуск», default OFF).
        // Флаг читается синхронно из быстрого native-кеша (SharedPreferences
        // mirror, синкается из Flutter при смене галки). Если строгий режим
        // ON и caller не держит permission — тихо игнорим (логируем).
        // checkCallingPermission в receiver-контексте возвращает гранты
        // отправителя broadcast'а; для legacy-send без permission → DENIED.
        if (requirePermission(context)) {
            val granted = context.checkCallingPermission(PERMISSION_AUTOMATION) ==
                PackageManager.PERMISSION_GRANTED
            if (!granted) {
                Log.w(TAG, "rejected ${intent.action} from $callerPkg — permission required but not granted")
                // AppLog: [automation] rejected <action> from <pkg> → no permission
                return
            }
        }

        when (intent.action) {
            ACTION_START_VPN -> BoxVpnService.start(context)
            ACTION_STOP_VPN -> BoxVpnService.stop(context)
            ACTION_TOGGLE_VPN -> {
                if (BoxVpnService.currentStatus == VpnStatus.Started) {
                    BoxVpnService.stop(context)
                } else {
                    // VpnService.prepare requires Activity, so we open
                    // MainActivity for first-time consent. Subsequent
                    // toggles work directly.
                    if (VpnService.prepare(context.applicationContext) == null) {
                        BoxVpnService.start(context)
                    } else {
                        val launch = Intent(context, MainActivity::class.java).apply {
                            putExtra("action", "toggle")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        context.startActivity(launch)
                    }
                }
            }
            ACTION_SWITCH_NODE -> {
                val tag = intent.getStringExtra(EXTRA_TAG)
                if (tag.isNullOrEmpty()) {
                    Log.w(TAG, "SWITCH_NODE missing extra '$EXTRA_TAG'")
                    return
                }
                // Defer to Flutter side via MethodChannel or Debug API call.
                // Simplest: invoke same code path as POST /action/switch-node
                forwardToActionHandler(context, "switch-node", mapOf("tag" to tag))
            }
            ACTION_SET_GROUP -> {
                val group = intent.getStringExtra(EXTRA_GROUP)
                if (group.isNullOrEmpty()) {
                    Log.w(TAG, "SET_GROUP missing extra '$EXTRA_GROUP'")
                    return
                }
                forwardToActionHandler(context, "set-group", mapOf("group" to group))
            }
            ACTION_REBUILD_CONFIG -> {
                forwardToActionHandler(context, "rebuild-config", emptyMap())
            }
            ACTION_REFRESH_SUBS -> {
                val force = intent.getBooleanExtra(EXTRA_FORCE, false)
                forwardToActionHandler(context, "refresh-subs", mapOf("force" to force))
            }
            ACTION_RESET_NETWORK -> {
                forwardToActionHandler(context, "reset-network", emptyMap())
            }
            ACTION_URLTEST_GROUP -> {
                val group = intent.getStringExtra(EXTRA_GROUP)
                if (group.isNullOrEmpty()) {
                    Log.w(TAG, "URLTEST_GROUP missing extra '$EXTRA_GROUP'")
                    return
                }
                forwardToActionHandler(context, "urltest-group", mapOf("group" to group))
            }
            else -> Log.w(TAG, "unknown action ${intent.action}")
        }
    }

    /// Bridge native → Dart via plugin. `VpnPlugin` exposes `handleAction(name, args)`
    /// который вызывает соответствующий action handler из Debug API.
    private fun forwardToActionHandler(ctx: Context, name: String, args: Map<String, Any?>) {
        VpnPlugin.companion.handleAutomationAction(name, args)
    }

    private fun sentFromPackage(intent: Intent): String? = intent.`package` ?: "<unknown>"
}
```

### Bridge → Dart

В `VpnPlugin.kt` добавить companion-метод `handleAutomationAction(name, args)` который через cached `MethodChannel` дёргает Dart-side:

```kotlin
// VpnPlugin.kt
companion object {
    private var methodChannelRef: WeakReference<MethodChannel>? = null

    fun handleAutomationAction(name: String, args: Map<String, Any?>) {
        val channel = methodChannelRef?.get() ?: return  // Flutter не активна — silently skip
        Handler(Looper.getMainLooper()).post {
            channel.invokeMethod("automationAction", mapOf("name" to name, "args" to args))
        }
    }
}
```

Dart side — handler в `BoxVpnClient` slушает `automationAction` и роутит на существующие action handlers:

```dart
// box_vpn_client.dart, в init Bridge:
_methods.setMethodCallHandler((call) async {
  if (call.method == 'automationAction') {
    final name = call.arguments['name'] as String;
    final args = Map<String, dynamic>.from(call.arguments['args']);
    await _handleAutomationAction(name, args);
  }
  // ... другие existing handlers
});

Future<void> _handleAutomationAction(String name, Map<String, dynamic> args) async {
  // Reuse existing action handlers from debug/handlers/action.dart
  // (нужен publicly accessible alias — extract logic в shared module)
  final ctx = AutomationContext.fromGlobals();
  switch (name) {
    case 'switch-node':
      await actionSwitchNode(args['tag'], ctx);
    case 'set-group':
      await actionSetGroup(args['group'], ctx);
    case 'rebuild-config':
      await actionRebuildConfig(ctx);
    case 'refresh-subs':
      await actionRefreshSubs(args['force'] ?? false, ctx);
    case 'reset-network':
      await actionResetNetwork(ctx);
    case 'urltest-group':
      await actionUrltestGroup(args['group'], ctx);
  }
}
```

**Refactor нужен** — текущие action handlers в `debug/handlers/action.dart` принимают `DebugRequest` / `DebugContext`. Извлечь pure-business функции (`actionSwitchNode(tag, ctx)`, и т.д.) в shared module, обёртку `Debug API → handler` оставить там, **новую обёртку `Automation → handler`** добавить.

---

## Outgoing events

Симметрично incoming actions — L×Box **отправляет** broadcasts о собственных state changes. Tasker может подписаться через `Profile → Event → Intent Received` с фильтром на наш action.

### Полный список событий

| Event action | Extras | Когда emit'ится | Use case |
|---|---|---|---|
| `com.leadaxe.lxbox.event.VPN_CONNECTED` | — | `HomeController._handleStatusEvent(connected)` | "Vibe телефона", "пометить notification зелёным", запуск cron task проверки IP |
| `com.leadaxe.lxbox.event.VPN_DISCONNECTED` | `reason: "user"\|"error"\|"revoked"\|"idle"` | TunnelStatus.disconnected | Notification на часы если непланово |
| `com.leadaxe.lxbox.event.VPN_ERROR` | `code: String`, `message: String` | Любой error path в `_handleStatusEvent` или `_startInternal/_stopInternal` | **Главное** — Tasker ждёт ERROR после своего START_VPN и реагирует (notification, retry, switch profile, SMS) |
| `com.leadaxe.lxbox.event.VPN_REVOKED` | — | TunnelStatus.revoked | Notification "другая VPN-app перехватила" |
| `com.leadaxe.lxbox.event.ACTIVE_NODE_CHANGED` | `old_tag: String?`, `new_tag: String`, `group: String`, `reason: "user"\|"urltest"\|"automation"` | `HomeController.switchNode` + Clash callback | "Лог в Google Sheet когда меняется нода"; "уведомить если автомат переключился на нежелательный регион" |
| `com.leadaxe.lxbox.event.ACTIVE_GROUP_CHANGED` | `old_group: String?`, `new_group: String`, `reason: String` | `HomeController.setActiveGroup` | Аналогично |
| `com.leadaxe.lxbox.event.SUB_REFRESHED` | `sub_id: String`, `nodes_count: Int`, `delta_count: Int` | `SubscriptionController.refreshEntry` (success path) | Notification если в подписке появились новые сервера |
| `com.leadaxe.lxbox.event.SUB_REFRESH_FAILED` | `sub_id: String`, `error: String` | `SubscriptionController.refreshEntry` (failure path, после 5 fails) | Подписки fail тихо, через 5 неудач юзер узнаёт только из лога — этим event'ом можно поднять системную нотификацию |
| `com.leadaxe.lxbox.event.UPDATE_AVAILABLE` | `version: String`, `url: String` | После `UpdateChecker` обнаружения новой версии | "Сообщить через Tasker канал в Telegram" |
| `com.leadaxe.lxbox.event.PERMISSION_NEEDED` | `permission: String` | После §050 wifi-rules → требуется `NEARBY_WIFI_DEVICES` | Vibe + notification |

### Future events (когда §042 health watchdog)

Не в первоначальной поставке, но место зарезервировано в namespace:

| Event action | Когда |
|---|---|
| `com.leadaxe.lxbox.event.HEARTBEAT_FAILED` | После N consecutive heartbeat fails |
| `com.leadaxe.lxbox.event.LATENCY_DEGRADED` | Когда активная нода стала >500ms baseline-relative |
| `com.leadaxe.lxbox.event.UNATTRIBUTED_BURST` | §044 banner active (DPI режет attribution) |

### Эмиттер — где и как

В `HomeController` / `SubscriptionController` / `AppLog` — точки где уже есть `notifyListeners()` или `setState`. Добавляем тонкий emitter:

```dart
// app/lib/services/automation/event_emitter.dart
class AutomationEventEmitter {
  static final I = AutomationEventEmitter._();
  AutomationEventEmitter._();

  // Granular gating — каждый toggle проверяется отдельно. Если категория OFF —
  // emit silently no-op'ит. Это по спеке security default.
  bool _lifecycleEnabled = false;
  bool _stateEnabled = false;
  bool _subsEnabled = false;
  bool _healthEnabled = false;

  Future<void> reload() async {
    _lifecycleEnabled = await SettingsStorage.getAutomationEmitLifecycle();
    _stateEnabled = await SettingsStorage.getAutomationEmitState();
    _subsEnabled = await SettingsStorage.getAutomationEmitSubs();
    _healthEnabled = await SettingsStorage.getAutomationEmitHealth();
  }

  void emitVpnConnected() => _emit('VPN_CONNECTED', {}, _lifecycleEnabled);
  void emitVpnDisconnected(String reason) =>
      _emit('VPN_DISCONNECTED', {'reason': reason}, _lifecycleEnabled);
  void emitVpnError(String code, String message) =>
      _emit('VPN_ERROR', {'code': code, 'message': message}, _lifecycleEnabled);
  void emitVpnRevoked() => _emit('VPN_REVOKED', {}, _lifecycleEnabled);

  void emitNodeChanged(String? old, String now, String group, String reason) =>
      _emit('ACTIVE_NODE_CHANGED',
          {'old_tag': old, 'new_tag': now, 'group': group, 'reason': reason},
          _stateEnabled);
  void emitGroupChanged(String? old, String now, String reason) =>
      _emit('ACTIVE_GROUP_CHANGED',
          {'old_group': old, 'new_group': now, 'reason': reason},
          _stateEnabled);

  void emitSubRefreshed(String id, int count, int delta) =>
      _emit('SUB_REFRESHED', {'sub_id': id, 'nodes_count': count, 'delta_count': delta},
          _subsEnabled);
  void emitSubRefreshFailed(String id, String error) =>
      _emit('SUB_REFRESH_FAILED', {'sub_id': id, 'error': error}, _subsEnabled);

  void emitUpdateAvailable(String version, String url) =>
      _emit('UPDATE_AVAILABLE', {'version': version, 'url': url}, _lifecycleEnabled);
  void emitPermissionNeeded(String permission) =>
      _emit('PERMISSION_NEEDED', {'permission': permission}, _lifecycleEnabled);

  void _emit(String name, Map<String, Object?> extras, bool gateEnabled) {
    if (!gateEnabled) return;
    BoxVpnClient.I.sendAutomationBroadcast(name, extras);
  }
}
```

И на native стороне `BoxVpnClient` форвардит в `VpnPlugin.sendAutomationBroadcast(action, extras)`:

```kotlin
// VpnPlugin.kt — handler "sendAutomationBroadcast"
fun sendAutomationBroadcast(ctx: Context, action: String, extras: Bundle) {
    val intent = Intent("com.leadaxe.lxbox.event.$action").apply {
        putExtras(extras)
        // setPackage намеренно не выставляем — broadcast открыт всем
        // подписчикам. Если юзер задал whitelist (future v2) —
        // фильтрация на уровне sendBroadcast'а.
    }
    // Permission-gated send симметричен incoming-галке: если «Требовать
    // пропуск» ON — событие получат только apps с granted permission;
    // иначе шлём без permission (любой подписчик). Читаем тот же
    // native-кеш, что и receiver.
    val requirePerm = ctx.getSharedPreferences("lxbox_automation", Context.MODE_PRIVATE)
        .getBoolean("require_permission", false)
    if (requirePerm) {
        ctx.sendBroadcast(intent, LxBoxIntentReceiver.PERMISSION_AUTOMATION)
    } else {
        ctx.sendBroadcast(intent)
    }
    Log.d(TAG, "emit $action with ${extras.size()} extras (perm=$requirePerm)")
}
```

### Symmetric request-response pattern

Главная сила outgoing events — Tasker может **wait'ать** на исходящий event как ответ на свой incoming request:

```
Tasker recipe — "Switch to Russia node with confirmation":
  1. Send broadcast: SWITCH_NODE extra(tag="🇷🇺Россия")
  2. Wait Event: ACTIVE_NODE_CHANGED extra-condition(new_tag matches "🇷🇺.*")
                 OR
                 VPN_ERROR
                 (timeout: 10s)
  3. Branch:
     If ACTIVE_NODE_CHANGED → Vibrate(50ms) + Notify("✅ Russia active")
     If VPN_ERROR → Notify("❌ %code: %message")
     If timeout → Notify("⚠️ VPN не отвечает")
```

Это намного reliable чем "fire-and-forget" — recipe знает что произошло, может реагировать.

### Throttling / spam prevention

| Event | Throttle policy |
|---|---|
| Lifecycle (`VPN_CONNECTED` etc) | Без throttle — natural rate низкий (один раз на toggle) |
| `ACTIVE_NODE_CHANGED` | Без throttle — natural rate низкий |
| `SUB_REFRESH_FAILED` | Cap 1/min на sub_id (предотвращает spam при network outage) |
| `LATENCY_DEGRADED` (future) | Cap 1/5min на tag |
| `UNATTRIBUTED_BURST` (future) | Cap 1/30s |

Throttle implementation — простой `Map<String, DateTime> _lastEmitAt` per event-type в `AutomationEventEmitter`.

### Logging для outgoing

Каждый emit логируется в AppLog с префиксом `[automation]` симметрично incoming:
```
[automation] emit VPN_CONNECTED → ok
[automation] emit ACTIVE_NODE_CHANGED new=🇷🇺Россия old=✨auto reason=user → ok
[automation] emit SUB_REFRESH_FAILED id=sub-1 error="HTTP 401" → throttled (last 30s ago)
```

Dev может фильтровать `q=automation` и видеть полную картину "Tasker послал → реакция наша → emit обратно".

### UI — App Settings → Automation API

Granular toggles — каждая категория управляется отдельно. Default — **все OFF**:

```
┌─────────────────────────────────────────────┐
│  Automation API                             │
│                                             │
│  Integrate L×Box with Tasker / Macrodroid / │
│  Llama and other automation apps via Android│
│  broadcast intents.                         │
│                                             │
│  ── Master ─────────────────────────────    │
│  [○] Принимать команды автоматизации        │
│      (Start/Stop/Toggle/Switch/Refresh/...) │
│      ▸ default OFF. Включает receiver        │
│        (setComponentEnabledSetting).         │
│                                             │
│  [○] Требовать пропуск (рекоменд. для         │
│      безопасности)                          │
│      ▸ default OFF. Команды/события только   │
│        от приложений с пропуском.            │
│      ┌── виден только когда галка ON ──┐     │
│      │ com.leadaxe.lxbox.permission.    │ 📋  │
│      │ AUTOMATION                       │     │
│      │ Впишите этот пропуск в           │     │
│      │ permissions вашего Tasker.       │     │
│      └─────────────────────────────────┘     │
│                                             │
│  ── Команды (intent actions) ───────────    │
│  Скопируйте в «Send Intent» вашего          │
│  automation-приложения. Target: Broadcast.  │
│   • com.leadaxe.lxbox.START_VPN        📋   │
│   • com.leadaxe.lxbox.STOP_VPN         📋   │
│   • com.leadaxe.lxbox.TOGGLE_VPN       📋   │
│   • …SWITCH_NODE (extra tag)           📋   │
│   • …SET_GROUP (extra group)          📋   │
│   • …REBUILD_CONFIG · REFRESH_SUBS ·  📋   │
│     RESET_NETWORK · URLTEST_GROUP          │
│                                             │
│  ── Emit (события наружу) ───────────────    │
│  [○] Lifecycle events                       │
│      VPN_CONNECTED · DISCONNECTED ·         │
│      ERROR · REVOKED · UPDATE_AVAILABLE ·   │
│      PERMISSION_NEEDED                      │
│                                             │
│  [○] State events                           │
│      ACTIVE_NODE_CHANGED ·                  │
│      ACTIVE_GROUP_CHANGED                   │
│                                             │
│  [○] Subscription events                    │
│      SUB_REFRESHED · SUB_REFRESH_FAILED     │
│                                             │
│  [○] Health events (when §042 ready)        │
│      HEARTBEAT_FAILED · LATENCY_DEGRADED ·  │
│      UNATTRIBUTED_BURST                     │
│                                             │
│  ──────────────────────────────────────     │
│  [📖 Show documentation & Tasker recipes]   │
└─────────────────────────────────────────────┘
```

**Поведение галки «Требовать пропуск»:**
- **OFF (default)** — receiver принимает команды от любого приложения; события emit'ятся без permission. Gate здесь — сам мастер-toggle (без него receiver disabled). Работает «из коробки», ничего настраивать в Tasker не нужно.
- **ON** — `onReceive` проверяет, что отправитель держит `com.leadaxe.lxbox.permission.AUTOMATION`, иначе игнорит (лог `[automation] rejected … no permission`). Outgoing-события шлются permission-gated. Юзеру нужно один раз вписать строку пропуска (показана с кнопкой 📋) в permissions своего Tasker/Macrodroid.
- Переключение галки вызывает `LxBoxIntentReceiver.setRequirePermission(ctx, value)` → пишет в native-кеш (`lxbox_automation` SharedPreferences), который синхронно читают и receiver, и emitter.
- Строка пропуска и кнопка 📋 видны только когда галка ON (когда OFF — пропуск не нужен, не путаем юзера).

**Explainer dialog при включении любой категории** (показывается один раз на категорию, помечается флагом `automation_explainer_shown_v1`):

> ⚠️ Включение этой категории позволит другим приложениям получать события L×Box (при включённой галке «Требовать пропуск» — только приложениям с пропуском). Включайте только если вы используете Tasker / Macrodroid и понимаете последствия.
>
> События НЕ содержат секретных данных подписок / config'а — только лейблы (tags / group names / status).
>
> [Continue] [Cancel]

Кнопка `Show documentation & Tasker recipes` — линк на `docs/AUTOMATION.md` (через external browser).

### Documentation

Новая страница `docs/AUTOMATION.md` со следующей структурой:

```markdown
# L×Box Automation API

## Quick reference
- Incoming actions table (9 actions, extras, examples)
- Outgoing events table (10 events MVP + 3 future, extras, throttle policy)
- Permission setup для caller'а

## Setup (Tasker example)
1. Tasker → Properties → Permissions → Add → declare
   `com.leadaxe.lxbox.permission.AUTOMATION`
2. L×Box → App Settings → Automation API → enable
   нужные категории (incoming + emit)
3. Restart Tasker (некоторые версии cache permissions)
4. Verify: send test broadcast через Tasker → check L×Box debug log

## Common recipes (с готовыми Tasker XML import'ами)

### Recipe 1: Auto-disable VPN на домашнем Wi-Fi
Profile: Wi-Fi connected = "MyHomeWiFi"
Task: Send Intent (com.leadaxe.lxbox.STOP_VPN)

### Recipe 2: Auto-enable на любом другом Wi-Fi
Profile: Wi-Fi connected = NOT "MyHomeWiFi" AND NOT mobile
Task: Send Intent (com.leadaxe.lxbox.START_VPN)

### Recipe 3: Switch на Russia-node при запуске банка (с подтверждением)
Profile: App launched = "ru.banki.app"
Task:
  1. Send Intent (com.leadaxe.lxbox.SWITCH_NODE, extra tag="🇷🇺Россия")
  2. Wait Event: ACTIVE_NODE_CHANGED matches new_tag="🇷🇺.*" OR VPN_ERROR
     timeout 10s
  3. If matched → Vibrate(50ms), else → Notify error

### Recipe 4: Уведомление при падении подписки
Profile: Event Received com.leadaxe.lxbox.event.SUB_REFRESH_FAILED
Task: Notify("📡 Sub %sub_id failed: %error")

### Recipe 5: Periodic mass-ping каждые 30 минут
Profile: Time = every 30 minutes
Task: Send Intent (com.leadaxe.lxbox.URLTEST_GROUP, extra group="vpn-1")

### Recipe 6: Auto-resetNetwork если ping узла > 1s
Profile: Variable %CURR_PING > 1000  (set externally, e.g. by /clash polling)
Task: Send Intent (com.leadaxe.lxbox.RESET_NETWORK)

### Recipe 7: Notification на часы при VPN падении
Profile: Event Received com.leadaxe.lxbox.event.VPN_ERROR
Task: Notify Wear "❌ VPN: %code — %message"

## Troubleshooting
- Send Intent не доходит → check permission declared, automation API toggle ON
- Event не emit'ится → проверить категорию в settings, throttle policy
```

Полный гайд с XML import'ами и screenshots vivendi отдельно после реализации.

---

## Алгоритм

### Setup flow (юзер)

```
1. App Settings → Automation API
2. Toggle ON → explainer dialog warning о security
3. Юзер confirms → setEnabled(ctx, true) активирует receiver
4. Открывает Tasker → Configure permission + Add intent action
5. Тестирует Tasker action → broadcast прилетает → action отрабатывает
```

### Runtime flow (broadcast)

```
[Tasker / external app]
  sendBroadcast(Intent("com.leadaxe.lxbox.SWITCH_NODE")
                .setPackage("com.leadaxe.lxbox")        ← обязательно для security
                .putExtra("tag", "🇷🇺Россия"))
  ↓
[Android system]
  Если automation permission granted у caller'а →
  doStartActivity / send to receiver
  ↓
[LxBoxIntentReceiver.onReceive]
  Validate action + extras
  ↓ (для START/STOP — direct call)
[BoxVpnService.start/stop]
  ↓ (для switch-node/set-group/etc)
[VpnPlugin.handleAutomationAction → MethodChannel → BoxVpnClient]
  ↓
[Dart action handler — reused from debug/handlers/action.dart]
  HomeController.switchNode(tag) → emit new state → UI updates
```

### Failure modes

| Симптом | Причина | Что делать |
|---|---|---|
| Tasker action sent но ничего не происходит | Automation API toggle OFF | Включить в App Settings |
| Тоже но toggle ON | Галка «Требовать пропуск» ON, а Tasker не declare'ил permission | Либо выключить галку, либо добавить `com.leadaxe.lxbox.permission.AUTOMATION` в permissions Tasker (лог: `[automation] rejected … no permission`) |
| `SWITCH_NODE` отрабатывает, но другая нода не выбирается | Tag не существует или typo | Check log в App Settings → Diagnostics → log filter "automation" |
| `START_VPN` не работает первый раз | VPN consent ещё не давали | Юзер должен один раз запустить из app, дальше automation работает |

### Logging

Каждый received intent + emitted event логируется в AppLog с префиксом `[automation]`:
```
[automation] received SWITCH_NODE from net.dinglisch.android.taskerm tag=🇷🇺Россия → ok
[automation] received START_VPN from <unknown> → already started, noop
[automation] received SWITCH_NODE from com.example.app tag=missing → ERROR tag not found
[automation] emit ACTIVE_NODE_CHANGED new=🇷🇺Россия old=✨auto reason=automation → ok
[automation] emit VPN_CONNECTED → ok
[automation] emit SUB_REFRESH_FAILED id=sub-1 → throttled (last 30s ago)
```

Юзер может фильтровать `q=automation` в Debug screen — видеть полный двусторонний обмен "Tasker → нас → emit назад".

---

## Тесты

- **Unit (Dart) — incoming**: refactored action handlers (`actionSwitchNode`, `actionSetGroup`, `actionRebuildConfig`, `actionRefreshSubs`, `actionResetNetwork`, `actionUrltestGroup`) работают с in-memory test fixtures, отдельно от Debug API request/response wrapping.
- **Unit (Dart) — outgoing**: `AutomationEventEmitter` — gate-toggles работают (lifecycle/state/subs/health), throttle policy не пропускает события чаще лимита, log entries формируются.
- **Unit (Dart) — symmetric**: `actionSwitchNode` → triggers `emitNodeChanged` → AutomationEventEmitter mock получает correct extras.
- **Integration (Kotlin) — incoming**: `LxBoxIntentReceiver` тест через `Robolectric`/instrumentation: подаём `Intent`, проверяем что `BoxVpnService.start` вызвался / `VpnPlugin.handleAutomationAction` cached call.
- **Integration (Kotlin) — permission gate**: при `require_permission=true` в native-кеше и caller'е без granted permission `onReceive` НЕ дёргает action (раннее `return`, лог `rejected`); при `false` — дёргает независимо от permission.
- **Integration (Kotlin) — outgoing**: `VpnPlugin.sendAutomationBroadcast` — при `require_permission=true` вызывается `sendBroadcast(intent, PERMISSION_AUTOMATION)`, при `false` — `sendBroadcast(intent)` без permission. Правильный action + extras в обоих случаях.
- **Manual (on-device)** — все 7 Tasker recipes из `docs/AUTOMATION.md`:
  - Recipe 1-2: Wi-Fi auto-toggle (incoming)
  - Recipe 3: Symmetric SWITCH_NODE + wait ACTIVE_NODE_CHANGED
  - Recipe 4: SUB_REFRESH_FAILED notification (outgoing-only)
  - Recipe 5: Time-based URLTEST_GROUP (incoming)
  - Recipe 6: RESET_NETWORK на ping spike (incoming)
  - Recipe 7: VPN_ERROR notification на часы (outgoing-only)

  Проверить что каждый сценарий работает stable неделю.

---

## Ограничения и риски

| # | Риск | Mitigation |
|---|---|---|
| 1 | При выключенной галке «Требовать пропуск» любое приложение может слать команды, пока мастер-toggle ON | (a) Мастер-toggle default OFF — без явного включения receiver disabled; (b) explainer dialog при включении; (c) галка «Требовать пропуск» закрывает дыру для тех, кому важно; (d) future v2: package whitelist |
| 2 | Malicious app угадает permission name + declare'ит → в строгом режиме сможет управлять VPN | protectionLevel `normal` — пропуск даёт только барьер «знать имя + declare», не криптозащиту. Для сильной модели — package whitelist (future v2). Acceptable для opt-in feature. |
| 3 | `SWITCH_NODE` с несуществующим tag → silent ignore | Логируется в AppLog с `[automation]` префиксом. Юзер может проверить. Не throw'аем — иначе Tasker может зависнуть на retry'ах. |
| 4 | Action names — public API; rename ломает чужие automation rules | Document'ом фиксируем как stable. **Никогда не переименовывать**, deprecate'ить + alias на год минимум. |
| 5 | Юзер включил «Требовать пропуск», но не вписал permission в Tasker → команды молча не доходят | UI показывает строку пропуска с 📋 ровно когда галка ON; docs описывают setup; лог `[automation] rejected … no permission` диагностирует. Default галки OFF — большинство не столкнётся. |
| 6 | На некоторых OEM (MIUI / ColorOS) auto-start restrictions блокируют receivers даже в `exported=true` | Документируем — юзеру нужно дать L×Box в "Auto-start" список в системных settings того OEM. То же что для §032. |
| 7 | `START_VPN` без consent dialog → fail. Tasker не сможет first-time enable | Документируем. Юзер должен один раз нажать Connect в app, дальше automation работает без UI. |

---

## Файлы (план реализации)

| Файл | Что |
|------|-----|
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxIntentReceiver.kt` | **Новый** — receiver класс с onReceive switch (9 incoming actions) + setEnabled helper + опциональная permission-проверка (`requirePermission`/`setRequirePermission`, native-кеш `lxbox_automation` prefs) |
| `app/android/app/src/main/AndroidManifest.xml` | `<receiver>` declaration с 9 actions (БЕЗ `android:permission` — enforcement в коде) + custom `<permission>` declaration |
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt` | `handleAutomationAction` companion-метод (incoming bridge) + `sendAutomationBroadcast` (outgoing emitter, permission-gated условно по галке) + MethodChannel handlers `setAutomationEnabled` / `setAutomationRequirePermission` (синк галок в native) + cached MethodChannel ref |
| `app/lib/vpn/box_vpn_client.dart` | MethodChannel handler `automationAction` (incoming) + `sendAutomationBroadcast(action, extras)` API (outgoing) |
| `app/lib/services/automation/handlers.dart` | **Новый** — extracted pure-business handlers: `actionSwitchNode`, `actionSetGroup`, `actionRebuildConfig`, `actionRefreshSubs`, `actionResetNetwork`, `actionUrltestGroup` |
| `app/lib/services/automation/event_emitter.dart` | **Новый** — `AutomationEventEmitter` singleton с granular gates + throttle policy + log entries |
| `app/lib/services/debug/handlers/action.dart` | Refactor — Debug API endpoints стали thin wrappers вокруг `automation/handlers.dart` |
| `app/lib/controllers/home_controller.dart` | Hook'и в `_handleStatusEvent` / `switchNode` / `setActiveGroup` → `AutomationEventEmitter.I.emit*` |
| `app/lib/controllers/subscription_controller.dart` | Hook'и в `refreshEntry` (success/failure) → emit |
| `app/lib/services/update_checker.dart` | Hook на новую версию → emit `UPDATE_AVAILABLE` |
| `app/lib/screens/app_settings_screen/widgets/automation_tab.dart` | **Новый** — вкладка "Automation": мастер-toggle приёма + галка «Требовать пропуск» (с условной строкой permission + copy) + 4 Emit-категории + интент-строки команд с кнопкой копирования + explainer dialog + docs link |
| `app/lib/screens/app_settings_screen.dart` | Регистрация 4-й вкладки `Automation` рядом с General/Subscriptions/Diagnostics (`DefaultTabController(length: 4)`, `Tab(text: 'Automation')`, `_buildAutomationTab`, `initialIndex.clamp(0, 3)`) |
| `app/lib/services/settings_storage.dart` | New keys: `automation_receive_enabled`, `automation_require_permission`, `automation_emit_lifecycle`, `automation_emit_state`, `automation_emit_subs`, `automation_emit_health` (все default false) + getters/setters + `automation_explainer_shown_v1` flag. Смена `automation_require_permission` синкается в native-кеш через `LxBoxIntentReceiver.setRequirePermission` (читается receiver'ом/emitter'ом синхронно). |
| `docs/AUTOMATION.md` | **Новый** — user-facing docs: incoming actions table + outgoing events table + setup guide + 7 recipes с XML import'ами |
| `app/lib/CLAUDE.md` / `docs/ARCHITECTURE.md` | Linkов на AUTOMATION.md |
| `test/services/automation/handlers_test.dart` | Unit для extracted incoming handlers |
| `test/services/automation/event_emitter_test.dart` | Unit для outgoing emitter (gates / throttle / log) |

Estimated work: **~3 дня** (manifest + receiver + bridge + emitter + 5 controller hooks + UI toggles + docs + refactor action handlers + tests).

---

## Критерии приёмки

### Incoming (9 actions)

- [ ] App Settings → Automation API блок: мастер-toggle "Принимать команды автоматизации" (default OFF) + explainer.
- [ ] Включение мастер-toggle активирует receiver через `PackageManager.setComponentEnabledSetting`. Выключение — обратно.
- [ ] Галка "Требовать пропуск" (default OFF) под мастер-toggle. При ON показывается строка `com.leadaxe.lxbox.permission.AUTOMATION` с кнопкой копирования; при OFF — скрыта.
- [ ] При галке OFF — команды принимаются от любого caller'а (gate = мастер-toggle).
- [ ] При галке ON — caller без granted `com.leadaxe.lxbox.permission.AUTOMATION` отклоняется в `onReceive` (лог `[automation] rejected … no permission`), action не выполняется.
- [ ] Смена галки синкается в native-кеш (`LxBoxIntentReceiver.setRequirePermission`); receiver и emitter читают его синхронно.
- [ ] Tasker (или `am broadcast` через ADB) с правильным action → VPN реагирует:
  - [ ] `START_VPN` → VPN connect (если не already up)
  - [ ] `STOP_VPN` → VPN disconnect
  - [ ] `TOGGLE_VPN` → toggle relative current state
  - [ ] `SWITCH_NODE` extra `tag` → активная нода меняется
  - [ ] `SET_GROUP` extra `group` → активная группа меняется
  - [ ] `REBUILD_CONFIG` → config регенерируется (respects §037 lock)
  - [ ] `REFRESH_SUBS` extra `force` → subs обновляются
  - [ ] `RESET_NETWORK` → closeAll + DNS flush + dialer rebind
  - [ ] `URLTEST_GROUP` extra `group` → urltest группы запускается
- [ ] Полученные intents логируются в AppLog с префиксом `[automation] received` + caller package.
- [ ] При выключенном мастер-toggle automation intents игнорируются (`receiver disabled`).

### Outgoing (10 events MVP)

- [ ] App Settings → Automation API блок: 4 toggle категории (Lifecycle / State / Subscription / Health) — default все OFF.
- [ ] Включение каждой категории первый раз → explainer dialog с warning о data leak (потом запоминается через `automation_explainer_shown_v1`).
- [ ] Lifecycle ON → emit'ятся `VPN_CONNECTED`, `VPN_DISCONNECTED` (с reason), `VPN_ERROR` (с code/message), `VPN_REVOKED`, `UPDATE_AVAILABLE`, `PERMISSION_NEEDED`.
- [ ] State ON → emit'ятся `ACTIVE_NODE_CHANGED` (с old/new/reason), `ACTIVE_GROUP_CHANGED`.
- [ ] Subscription ON → emit'ятся `SUB_REFRESHED` (с counts), `SUB_REFRESH_FAILED` (с throttle 1/min на sub_id).
- [ ] При галке "Требовать пропуск" ON — outgoing broadcasts отправляются permission-gated (`sendBroadcast(intent, PERMISSION_AUTOMATION)`), подписчик без permission не получает; при OFF — без permission, получает любой подписчик.
- [ ] Emit'ed events логируются в AppLog с префиксом `[automation] emit` + extras.
- [ ] Throttle policy работает — лог показывает `→ throttled` когда event пришёл быстрее лимита.

### Symmetric (request → response)

- [ ] Tasker recipe "Switch Russia + wait response" работает: `SWITCH_NODE tag=🇷🇺Россия` → emit `ACTIVE_NODE_CHANGED new_tag=🇷🇺Россия` arrives к Tasker waiter.
- [ ] Failure path: `SWITCH_NODE tag=invalid` → emit `VPN_ERROR code=node_not_found` arrives.

### Documentation

- [ ] `docs/AUTOMATION.md` существует со всеми 9 incoming actions + 10 outgoing events + 7 recipes.
- [ ] Tasker user может настроить любой recipe из docs за 5-10 минут.

---

## Шаг 2 — Locale / Tasker plugin-стандарт (`FIRE_SETTING` + `QUERY_CONDITION`)

> **Статус:** Implemented (2026-06-21) — `LocaleApi` + setting/condition receiver'ы + 2 нативных edit-Activity + manifest (2 activity + 2 receiver, enabled=false) + active-state mirror в native-кеш. Добавлено **поверх** Шага 1, ничего не выкидывая.

### Зачем — чего не хватает Шагу 1

Шаг 1 даёт **raw broadcast actions** (`com.leadaxe.lxbox.START_VPN` и т.д.). Их минус: юзер должен руками настроить «Send Intent» и знать строку action. L×Box **не появляется** в списке плагинов Tasker/Macrodroid.

Locale plugin-стандарт ([twofortyfouram](https://github.com/twofortyfouram/android-plugin-api-for-locale)) — де-факто протокол, который Tasker / Macrodroid / Llama понимают из коробки. Реализовав его, L×Box попадает в **Tasker → Action → Plugin → L×Box** (для действий) и **Profile → State → Plugin → L×Box** (для условий) с **нативным экраном выбора** — массовый юзер кликает, а не пишет интенты руками.

**Сосуществование (важно):** оба пути живут параллельно.

| | Шаг 1 — raw actions | Шаг 2 — Locale plugin |
|---|---|---|
| Транспорт | `com.leadaxe.lxbox.START_VPN` broadcast | `…FIRE_SETTING` + `EXTRA_BUNDLE` |
| Настройка | руками Send Intent | UI плагина в Tasker (Spinner) |
| Видимость в Tasker | нет (raw) | да (список плагинов) |
| Для кого | `am broadcast`, shell, ADB, не-Locale-apps | массовый юзер через UI |
| Бизнес-логика | **общий** `services/automation/handlers.dart` | **тот же** слой |

Один бизнес-слой, теперь **четыре** транспорта: Debug API, raw broadcast (Шаг 1), Locale setting (Шаг 2a), Locale condition (Шаг 2b).

### Стандарт — точный контракт (из spec twofortyfouram)

**Setting plugin (действие):**
- **Edit Activity** — `intent-filter` `com.twofortyfouram.locale.intent.action.EDIT_SETTING`, `exported=true`, label+icon. На Save возвращает `RESULT_OK` + `EXTRA_BUNDLE` (стейт плагина, <**25 KB** base-10) + `EXTRA_STRING_BLURB` (короткая человекочитаемая строка, напр. `"Switch node → 🇷🇺Россия"`).
- **Fire Receiver** — `intent-filter` `com.twofortyfouram.locale.intent.action.FIRE_SETTING`, `exported=true`, **БЕЗ** `android:permission` (хост сам проверяет, что вправе слать). Получает `EXTRA_BUNDLE` → исполняет команду. Result code ordered-broadcast'а **не используется** (зарезервирован стандартом).

**Condition plugin (состояние):**
- **Edit Activity** — `…action.EDIT_CONDITION`, аналогично setting'у (выбор: «что проверять» — VPN up/down, активная нода/группа).
- **Query Receiver** — `…action.QUERY_CONDITION`, `exported=true`. Получает `EXTRA_BUNDLE`, отвечает **через ordered-broadcast result code**: `RESULT_CONDITION_SATISFIED` (16) / `RESULT_CONDITION_UNSATISFIED` (17) / `RESULT_CONDITION_UNKNOWN` (18). Хост опрашивает периодически.

**Bundle-конвенция:** один ключ-String внутри `EXTRA_BUNDLE` с валидным JSON (наш формат — см. ниже). Бандл должен переживать сериализацию хостом и быть версионируемым.

### Константы стандарта (Kotlin)

```kotlin
object LocaleApi {
    const val ACTION_EDIT_SETTING = "com.twofortyfouram.locale.intent.action.EDIT_SETTING"
    const val ACTION_FIRE_SETTING = "com.twofortyfouram.locale.intent.action.FIRE_SETTING"
    const val ACTION_EDIT_CONDITION = "com.twofortyfouram.locale.intent.action.EDIT_CONDITION"
    const val ACTION_QUERY_CONDITION = "com.twofortyfouram.locale.intent.action.QUERY_CONDITION"

    const val EXTRA_BUNDLE = "com.twofortyfouram.locale.intent.extra.BUNDLE"
    const val EXTRA_STRING_BLURB = "com.twofortyfouram.locale.intent.extra.BLURB"

    const val RESULT_CONDITION_SATISFIED = 16
    const val RESULT_CONDITION_UNSATISFIED = 17
    const val RESULT_CONDITION_UNKNOWN = 18

    const val BUNDLE_MAX_BYTES = 25_000   // base-10, по стандарту
}
```

### Формат нашего bundle

`EXTRA_BUNDLE` содержит один ключ `com.leadaxe.lxbox.plugin.CONFIG` (String) с JSON:

**Setting:**
```json
{ "v": 1, "cmd": "switch-node", "args": { "tag": "🇷🇺Россия" } }
```
`cmd` — одно из имён shared-handlers (`start-vpn`, `stop-vpn`, `toggle-vpn`, `switch-node`, `set-group`, `rebuild-config`, `refresh-subs`, `reset-network`, `urltest-group`). `args` — extras команды.

**Condition:**
```json
{ "v": 1, "check": "vpn-up" }
{ "v": 1, "check": "active-node", "equals": "🇷🇺Россия" }
{ "v": 1, "check": "active-group", "equals": "vpn-1" }
```

`v` — версия bundle (миграции при будущих изменениях формата). Невалидный/неизвестный bundle: setting → no-op + лог; condition → `RESULT_CONDITION_UNKNOWN`.

### Архитектура

```
[Tasker] ── EDIT_SETTING ──▶ [LocaleSettingEditActivity (Kotlin)]
                                   Spinner(команда) + EditText(extra) + Save
                                   └─ setResult(OK, EXTRA_BUNDLE=json, EXTRA_STRING_BLURB)
[Tasker] ── FIRE_SETTING (bundle) ──▶ [LocaleSettingReceiver]
                                   parse bundle → VpnPlugin.handleAutomationAction(cmd, args)
                                   └─ (тот же путь, что raw SWITCH_NODE) → shared handlers

[Tasker] ── EDIT_CONDITION ──▶ [LocaleConditionEditActivity]
                                   Spinner(что проверять) + (опц.) EditText(значение)
[Tasker] ── QUERY_CONDITION (bundle) ──▶ [LocaleConditionReceiver]
                                   читает BoxVpnService.currentStatus / активную ноду
                                   └─ setResultCode(SATISFIED | UNSATISFIED | UNKNOWN)
```

- **Fire/setting** переиспользует `VpnPlugin.handleAutomationAction` (Шаг 1 bridge) → `services/automation/handlers.dart`. Никакой новой бизнес-логики.
- **Query/condition** читается синхронно из native (`BoxVpnService.currentStatus`) — VPN up/down доступно без Flutter-engine. Активная нода/группа — из native-кеша (новый mirror в `lxbox_automation` prefs, который Dart обновляет при смене ноды; QUERY обязан ответить синхронно, Flutter может спать).
- **Gating:** plugin-receiver'ы (как и raw-receiver Шага 1) включаются тем же мастер-toggle «Принимать команды автоматизации». Они exported по стандарту (permission нельзя — хост проверяет сам), но компонент `enabled=false` пока toggle OFF.

### Native-кеш активного состояния (для QUERY_CONDITION)

QUERY должен ответить синхронно. VPN up/down — `BoxVpnService.currentStatus` (уже есть). Активная нода/группа живут в Dart (`HomeController`), Flutter может быть не запущен → зеркалим в `lxbox_automation` prefs:
- ключи `active_node`, `active_group` (String, обновляются из `HomeController.switchNode`/`applyGroup`/`setSelectedGroup` через новый MethodChannel `setAutomationActiveState`).
- `LocaleConditionReceiver` читает их синхронно.

### UI edit-Activity (нативный Kotlin)

Минимальный Android-экран (не Flutter — изоляция от движка, быстрый cold-start из Tasker):
- **Setting:** `Spinner` со списком 9 команд → при выборе команды с extra (`switch-node`/`set-group`/`urltest-group`/`refresh-subs`) показывается `EditText` для значения; кнопка Save.
- **Condition:** `Spinner` (`VPN включён`, `Активная нода =`, `Активная группа =`) → условный `EditText`; Save.
- Тема — наследует app theme (`@style/LaunchTheme`), label «L×Box».
- Save → собирает JSON, кладёт в bundle, формирует blurb, `setResult`.

### Manifest (добавочно к Шагу 1)

```xml
<!-- Setting plugin -->
<activity android:name=".automation.LocaleSettingEditActivity"
    android:exported="true" android:label="L×Box" android:icon="@mipmap/ic_launcher"
    android:theme="@style/LaunchTheme">
  <intent-filter><action android:name="com.twofortyfouram.locale.intent.action.EDIT_SETTING"/></intent-filter>
</activity>
<receiver android:name=".automation.LocaleSettingReceiver"
    android:exported="true" android:enabled="false">
  <intent-filter><action android:name="com.twofortyfouram.locale.intent.action.FIRE_SETTING"/></intent-filter>
</receiver>

<!-- Condition plugin -->
<activity android:name=".automation.LocaleConditionEditActivity"
    android:exported="true" android:label="L×Box" android:icon="@mipmap/ic_launcher"
    android:theme="@style/LaunchTheme">
  <intent-filter><action android:name="com.twofortyfouram.locale.intent.action.EDIT_CONDITION"/></intent-filter>
</activity>
<receiver android:name=".automation.LocaleConditionReceiver"
    android:exported="true" android:enabled="false">
  <intent-filter><action android:name="com.twofortyfouram.locale.intent.action.QUERY_CONDITION"/></intent-filter>
</receiver>
```

> **NB:** на receiver'ах `android:permission` НЕ ставим — стандарт это запрещает (хост проверяет права сам). Поэтому галка «Требовать пропуск» Шага 1 на Locale-путь **не распространяется**: gating — только мастер-toggle (компонент `enabled=false`). Это документируем как осознанный trade-off (стандарт-совместимость > строгий режим для plugin-пути; кто хочет строгий режим — использует raw-actions Шага 1).

### Файлы (Шаг 2)

| Файл | Что |
|------|-----|
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/automation/LocaleApi.kt` | **Новый** — константы стандарта + JSON bundle (de)serialize helpers |
| `…/automation/LocaleSettingReceiver.kt` | **Новый** — FIRE_SETTING → parse → `VpnPlugin.handleAutomationAction` |
| `…/automation/LocaleSettingEditActivity.kt` | **Новый** — Spinner команд + extra + Save → bundle/blurb |
| `…/automation/LocaleConditionReceiver.kt` | **Новый** — QUERY_CONDITION → currentStatus/active-кеш → setResultCode |
| `…/automation/LocaleConditionEditActivity.kt` | **Новый** — Spinner проверок + значение + Save |
| `app/android/app/src/main/res/layout/locale_edit_*.xml` | **Новые** — простые layout'ы edit-Activity |
| `AndroidManifest.xml` | +2 activity +2 receiver (enabled=false) |
| `VpnPlugin.kt` | +MethodChannel `setAutomationActiveState` (Dart→native mirror ноды/группы) + `setEnabled` расширить на Locale-компоненты |
| `LxBoxIntentReceiver.kt` (Шаг 1) | `setEnabled` уже есть — добавить enable/disable Locale-компонентов в той же транзакции |
| `app/lib/vpn/box_vpn_client.dart` | `setAutomationActiveState(node, group)` |
| `app/lib/controllers/home_controller.dart` | вызвать mirror при switchNode/applyGroup/setSelectedGroup |
| `docs/AUTOMATION.md` | секция «Tasker plugin (рекомендуемый способ)» + скриншоты flow |

### Тесты (Шаг 2)

- **Unit (Kotlin)** — `LocaleApi` bundle round-trip (serialize→deserialize, версия, невалидный JSON).
- **Integration (Kotlin)** — `LocaleSettingReceiver`: подаём FIRE_SETTING с bundle → проверяем вызов `handleAutomationAction(cmd, args)`. `LocaleConditionReceiver`: статус Started + check=vpn-up → `setResultCode(SATISFIED)`; пустой active-кеш + active-node → `UNKNOWN`.
- **Manual (on-device)** — добавить L×Box как Plugin-action в Tasker: выбрать `switch-node tag=…` через наш экран → fire → нода меняется. Добавить Plugin-condition `vpn-up` → profile активируется при connect.

### Критерии приёмки (Шаг 2)

- [ ] L×Box виден в Tasker: **Action → Plugin → L×Box** и **State → Plugin → L×Box**.
- [ ] Setting edit-Activity: Spinner 9 команд, условный extra-input, Save формирует bundle + non-empty blurb.
- [ ] FIRE_SETTING исполняет команду через **те же** shared handlers (switch-node реально меняет ноду).
- [ ] Condition edit-Activity: выбор vpn-up / active-node= / active-group=.
- [ ] QUERY_CONDITION отвечает корректным result code (SATISFIED/UNSATISFIED/UNKNOWN), profile в Tasker реагирует.
- [ ] Bundle round-trip переживает host-сериализацию; версия `v` присутствует.
- [ ] Plugin-receiver'ы включаются мастер-toggle'ом (enabled=false пока OFF); галка «Требовать пропуск» к ним не применяется (документировано).
- [ ] `docs/AUTOMATION.md` описывает plugin-flow как рекомендуемый для не-технических юзеров.

---

## Будущие расширения (вне §047)

- **Package whitelist** — UI list "Allow only these apps to control VPN: [+]" вместо "open to all who claim permission". Granular control. Реализуемо через `intent.package` check в receiver и `setPackage` на outgoing broadcasts.
- **Health events implementation** — `HEARTBEAT_FAILED` / `LATENCY_DEGRADED` / `UNATTRIBUTED_BURST` — после §042 health watchdog (там этот namespace уже зарезервирован, нужны source points).
- **Action: SET_VAR** — изменить произвольный template var через intent (`extra: name`, `extra: value`). Связан с Debug API `PUT /settings/vars/{key}`.
- **Action: EXCLUDE_NODE / INCLUDE_NODE** — toggle exclusion из auto-pool без UI, по tag.
- **Action: OPEN_PROFILER** — запустить per-app trace (§044) для package extra. "Когда падает банк-app → start profiler для post-mortem".
- **Action: APPLY_PROFILE** — если когда-нибудь будут multi-profile (см. ARCHITECTURE → Reusable layers → potential idea), automation сможет переключать профили.

---

## Ссылки

- [Android BroadcastReceiver guide](https://developer.android.com/develop/background-work/background-tasks/broadcasts)
- [Custom permissions documentation](https://developer.android.com/guide/topics/permissions/defining)
- [Tasker — Send Intent action](https://tasker.joaoapps.com/userguide/en/help/ah_send_intent.html)
- [Locale plugin API for Android](https://github.com/twofortyfouram/android-plugin-api-for-locale) — стандарт `FIRE_SETTING` / `QUERY_CONDITION` (Шаг 2)
- [Plug-in API Specification](https://github.com/twofortyfouram/android-monorepo/blob/master/docs/Plug-in%20API%20Specification.md) — точный контракт edit-Activity / fire-receiver / bundle 25 KB
- [§031 — Debug API](../031%20debug%20api/spec.md) — action handlers переиспользуются
- [§032 — Quick Connect](../032%20quick%20connect/spec.md) — same actions, разные транспорты (tile/shortcut vs broadcast)
