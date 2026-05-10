# 047 — Public Intent API (Tasker / automation integration)

| Поле | Значение |
|------|----------|
| Статус | **Draft** — spec only, не реализовано |
| Дата | 2026-05-10 |
| Зависимости | [`031 debug api`](../031%20debug%20api/spec.md) (action handlers переиспользуются) |
| Связано | [`032 quick connect`](../032%20quick%20connect/spec.md) (та же семантика toggle/switch, разные источники) |
| Реализация | Native (Kotlin BroadcastReceiver), без Flutter UI кроме docs/help страницы |

---

## Цель и рамки

Дать external automation tools (**Tasker**, **Macrodroid**, **Llama**, **Automate**, IFTTT-like apps, shell-скрипты через `am broadcast`) возможность управлять L×Box через Android **broadcast intents**. Закрытие фидбека "хочу автоматически включать VPN на не-домашнем Wi-Fi", "switch на Russia-узел при запуске банковского app'а", "выключать ночью / по расписанию".

Сейчас управлять VPN снаружи можно только двумя путями:
1. **Quick Settings tile / shortcut** ([§032](../032%20quick%20connect/spec.md)) — но требует ручной тап юзера, не automation.
2. **Debug API** (`POST /action/*`) — мощно, но требует enabled токен + adb forward или WiFi reachable, не предназначен для automation tools на устройстве.

Tasker и аналогичные приложения умеют отправлять Android intents но **не умеют HTTP с Bearer auth** (есть, но громоздко). Native broadcast intents — стандартный для Android automation способ интеграции.

**В скопе:**
- Exported `BroadcastReceiver` слушающий `com.leadaxe.lxbox.{START_VPN, STOP_VPN, TOGGLE_VPN, SWITCH_NODE, SET_GROUP, REBUILD_CONFIG, REFRESH_SUBS}`.
- Param-extras для actions с параметрами (`SWITCH_NODE` extra `tag`, `SET_GROUP` extra `group`, и т.д.).
- Реализация переиспользует существующие action handlers из [`debug/handlers/action.dart`](../../../app/lib/services/debug/handlers/action.dart) (тот же business logic, разные транспорты).
- Documentation страница в App Settings → Diagnostics → "Automation API" с примерами Tasker setup.
- Permission gate — toggle "Enable automation API" в App Settings (default OFF). Иначе любая app на устройстве может управлять VPN.

**Не в скопе:**
- Result intents (отправлять статус назад в Tasker) — сложнее и редко нужно. Можно через Tasker watchers на UI (notification text).
- Kotlin/Java SDK для third-party app developers — over-engineering для нашего scale'а.
- Per-action permissions / signature verification — accept все intents если global toggle ON, иначе отказываем.
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

1. **Toggle в App Settings → Diagnostics → "Automation API"** (default OFF). Receiver регистрируется только когда toggle ON.
2. **Юзер видит при включении** explainer dialog с warning "Любая app сможет управлять VPN. Включайте только если используете Tasker/Macrodroid".
3. Optionally — **package whitelist** в advanced settings (UI: "Allow only these apps to control VPN: [+]"). Для v2.

### Существующая инфраструктура которую переиспользуем

Все нужные actions **уже реализованы** как Debug API endpoints в [`debug/handlers/action.dart`](../../../app/lib/services/debug/handlers/action.dart):

| Intent action | Существующий handler | Notes |
|---|---|---|
| `START_VPN` | `_startVpn(ctx)` | Идемпотентен: noop если уже started |
| `STOP_VPN` | `_stopVpn(ctx)` | Блокирующий до Stopped |
| `TOGGLE_VPN` | `MainActivity.ACTION_TOGGLE` уже handle'ится | Already exists |
| `SWITCH_NODE` (extra: `tag`) | `_switchNode(req, ctx)` | Через `HomeController.switchNode` |
| `SET_GROUP` (extra: `group`) | `_setGroup(req, ctx)` | Active group selector |
| `REBUILD_CONFIG` | `_rebuildConfig(ctx)` | Config regen, respects §037 lock |
| `REFRESH_SUBS` (extra: `force`) | `_refreshSubs(req, ctx)` | Manual sub-refresh |

То есть **business-логику не пишем** — обёртка вокруг них.

---

## Архитектурное решение

### Manifest declaration

```xml
<application ...>
  ...
  <receiver
    android:name=".vpn.LxBoxIntentReceiver"
    android:exported="true"
    android:enabled="false"           <!-- runtime-toggled -->
    android:permission="com.leadaxe.lxbox.permission.AUTOMATION">
    <intent-filter>
      <action android:name="com.leadaxe.lxbox.START_VPN" />
      <action android:name="com.leadaxe.lxbox.STOP_VPN" />
      <action android:name="com.leadaxe.lxbox.TOGGLE_VPN" />
      <action android:name="com.leadaxe.lxbox.SWITCH_NODE" />
      <action android:name="com.leadaxe.lxbox.SET_GROUP" />
      <action android:name="com.leadaxe.lxbox.REBUILD_CONFIG" />
      <action android:name="com.leadaxe.lxbox.REFRESH_SUBS" />
    </intent-filter>
  </receiver>

  <!-- Custom permission, **opt-in для caller'а**: Tasker должен явно
       declare'ить <uses-permission> чтобы intent дошёл. -->
  <permission
    android:name="com.leadaxe.lxbox.permission.AUTOMATION"
    android:protectionLevel="normal" />
</application>
```

**Notes:**
- `android:enabled="false"` — receiver выключен в манифесте по умолчанию. Включается через `PackageManager.setComponentEnabledSetting(...)` runtime когда юзер toggle'ит "Enable automation API".
- `android:permission="com.leadaxe.lxbox.permission.AUTOMATION"` — кастомная Android-permission. Для Tasker это означает ровно одну строку в его манифесте (он умеет declare'ить arbitrary permissions через UI). Для случайной malicious app — небольшой барьер (нужно знать имя permission и declare'ить).

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

        const val EXTRA_TAG = "tag"
        const val EXTRA_GROUP = "group"
        const val EXTRA_FORCE = "force"

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
  }
}
```

**Refactor нужен** — текущие action handlers в `debug/handlers/action.dart` принимают `DebugRequest` / `DebugContext`. Извлечь pure-business функции (`actionSwitchNode(tag, ctx)`, и т.д.) в shared module, обёртку `Debug API → handler` оставить там, **новую обёртку `Automation → handler`** добавить.

### UI — App Settings → Diagnostics → Automation API

Новый блок:

```
┌─────────────────────────────────────────┐
│  Automation API                         │
│                                         │
│  Allow other apps (Tasker, Macrodroid)  │
│  to control L×Box via Android intents.  │
│                                         │
│  [○] Enable automation API              │
│                                         │
│  When enabled, any app that has the     │
│  com.leadaxe.lxbox.permission.AUTOMATION│
│  permission may send broadcasts to:     │
│  • Start / Stop / Toggle VPN            │
│  • Switch node or group                 │
│  • Refresh subscriptions / rebuild      │
│                                         │
│  [Show example Tasker setup]            │
└─────────────────────────────────────────┘
```

`Show example Tasker setup` — модалка / линк на docs страницу с пошаговым гайдом.

### Documentation

Новая страница `docs/AUTOMATION.md`:

```markdown
# L×Box Automation API

Полный список broadcast intents...

## Setup (Tasker)
1. Add Tasker permission `com.leadaxe.lxbox.permission.AUTOMATION`
   (Tasker → Properties → Permissions → Add)
2. Create Profile with desired trigger (Wi-Fi, time, app, ...)
3. Create linked Task with action "Send Intent":
   - Action: com.leadaxe.lxbox.STOP_VPN
   - Target: Broadcast Receiver
4. Test profile

## Common recipes
### Auto-disable VPN on home Wi-Fi
...

### Switch to Russia-node when banking app launches
...
```

---

## Алгоритм

### Setup flow (юзер)

```
1. App Settings → Diagnostics → Automation API
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
| Тоже но toggle ON | Tasker не declare'ил permission | Add `com.leadaxe.lxbox.permission.AUTOMATION` в Tasker permissions |
| `SWITCH_NODE` отрабатывает, но другая нода не выбирается | Tag не существует или typo | Check log в App Settings → Diagnostics → log filter "automation" |
| `START_VPN` не работает первый раз | VPN consent ещё не давали | Юзер должен один раз запустить из app, дальше automation работает |

### Logging

Каждый received intent логируется в AppLog:
```
[automation] received SWITCH_NODE from net.dinglisch.android.taskerm tag=🇷🇺Россия → ok
[automation] received START_VPN from <unknown> → already started, noop
[automation] received SWITCH_NODE from com.example.app tag=missing → ERROR tag not found
```

Юзер может фильтровать `q=automation` в Debug screen — видеть кто и что дёргал.

---

## Тесты

- **Unit (Dart)** — refactored action handlers (`actionSwitchNode`, `actionSetGroup`, `actionRebuildConfig`, `actionRefreshSubs`) работают с in-memory test fixtures, отдельно от Debug API request/response wrapping.
- **Integration (Kotlin)** — `LxBoxIntentReceiver` тест: подаём `Intent` через `Robolectric` или instrumentation, проверяем что `BoxVpnService.start` вызвался / `VpnPlugin.handleAutomationAction` cached call.
- **Manual (on-device)** — Tasker recipes:
  - Wi-Fi connect → STOP_VPN
  - App launch → SWITCH_NODE
  - Time-based → SET_GROUP
  Проверить что каждый сценарий работает stable неделю.

---

## Ограничения и риски

| # | Риск | Mitigation |
|---|---|---|
| 1 | Malicious app угадает permission name + declare'ит → сможет управлять VPN | (a) Default OFF toggle; (b) explainer dialog при включении; (c) future v2: package whitelist |
| 2 | Receiver `exported=true` уязвимость поверхностная — broadcast не auth-ed | Custom permission снижает поверхность. Юзеры читают warning перед enable. Acceptable для opt-in feature. |
| 3 | `SWITCH_NODE` с несуществующим tag → silent ignore | Логируется в AppLog с `[automation]` префиксом. Юзер может проверить. Не throw'аем — иначе Tasker может зависнуть на retry'ах. |
| 4 | Action names — public API; rename ломает чужие automation rules | Document'ом фиксируем как stable. **Никогда не переименовывать**, deprecate'ить + alias на год минимум. |
| 5 | Tasker (free) ограничен в количестве permissions — может не declare наш permission | Workaround: уменьшить protectionLevel до "normal" (так и сделано). Tasker умеет normal-level permissions. |
| 6 | На некоторых OEM (MIUI / ColorOS) auto-start restrictions блокируют receivers даже в `exported=true` | Документируем — юзеру нужно дать L×Box в "Auto-start" список в системных settings того OEM. То же что для §032. |
| 7 | `START_VPN` без consent dialog → fail. Tasker не сможет first-time enable | Документируем. Юзер должен один раз нажать Connect в app, дальше automation работает без UI. |

---

## Файлы (план реализации)

| Файл | Что |
|------|-----|
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxIntentReceiver.kt` | **Новый** — receiver класс с onReceive switch + setEnabled helper |
| `app/android/app/src/main/AndroidManifest.xml` | `<receiver>` declaration + custom `<permission>` |
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt` | `handleAutomationAction` companion-метод + cached MethodChannel ref |
| `app/lib/vpn/box_vpn_client.dart` | MethodChannel handler `automationAction` → роутит на shared action handlers |
| `app/lib/services/automation/handlers.dart` | **Новый** — extract'нутые pure-business handlers (`actionSwitchNode` / `actionSetGroup` / `actionRebuildConfig` / `actionRefreshSubs`) |
| `app/lib/services/debug/handlers/action.dart` | Refactor — Debug API endpoints стали thin wrappers вокруг `automation/handlers.dart` |
| `app/lib/screens/app_settings_screen.dart` | UI блок "Automation API" + toggle + explainer dialog + "Show example Tasker setup" link |
| `app/lib/services/settings_storage.dart` | New key `automation_enabled: bool` (default false) + getter/setter |
| `docs/AUTOMATION.md` | **Новый** — user-facing docs со списком intents и Tasker recipes |
| `app/lib/CLAUDE.md` / `docs/ARCHITECTURE.md` | Linkов на AUTOMATION.md |
| `test/services/automation/handlers_test.dart` | Unit для extracted handlers |

Estimated work: **~2 дня** (manifest + receiver + bridge + UI toggle + docs + refactor action handlers + tests).

---

## Критерии приёмки

- [ ] App Settings → Diagnostics → "Automation API" блок с toggle (default OFF) + explainer.
- [ ] Включение toggle активирует receiver через `PackageManager.setComponentEnabledSetting`. Выключение — обратно.
- [ ] Tasker (или `am broadcast` через ADB) с правильным action → VPN реагирует:
  - [ ] `START_VPN` → VPN connect (если не already up)
  - [ ] `STOP_VPN` → VPN disconnect
  - [ ] `TOGGLE_VPN` → toggle relative current state
  - [ ] `SWITCH_NODE` extra `tag` → активная нода меняется
  - [ ] `SET_GROUP` extra `group` → активная группа меняется
  - [ ] `REBUILD_CONFIG` → config регенерируется (respects §037 lock)
  - [ ] `REFRESH_SUBS` extra `force` → subs обновляются
- [ ] Получаемые intents логируются в AppLog с префиксом `[automation]` + caller package.
- [ ] При выключенной toggle automation intents игнорируются (`receiver disabled`).
- [ ] Caller без `com.leadaxe.lxbox.permission.AUTOMATION` permission получает SecurityException на `sendBroadcast` (Android system enforce'ит).
- [ ] `docs/AUTOMATION.md` существует с полной таблицей actions + 3+ Tasker recipe'ами.
- [ ] Tasker user может настроить "auto-disable VPN on home Wi-Fi" сценарий за 5 минут по нашему гайду.

---

## Будущие расширения (вне §047)

- **Package whitelist** — UI list "Allow only these apps to control VPN: [+]" вместо "open to all who claim permission". Granular control. Реализуемо через `intent.package` check в receiver.
- **Result intents** — отправка результата команды обратно caller'у (Tasker может wait'ать на response). Сложнее, мало кому нужно.
- **Action: SET_VAR** — изменить произвольный template var через intent (`extra: name`, `extra: value`). Связан с Debug API `PUT /settings/vars/{key}`.
- **Action: APPLY_PROFILE** — если когда-нибудь будут multi-profile (см. ARCHITECTURE → Reusable layers → potential idea), automation сможет переключать профили.
- **Tasker plugin** — отдельный official Tasker plugin app, который declare'ит permission + предоставляет UI dropdown'ы для action/extras. Полировка UX, но maintenance overhead.

---

## Ссылки

- [Android BroadcastReceiver guide](https://developer.android.com/develop/background-work/background-tasks/broadcasts)
- [Custom permissions documentation](https://developer.android.com/guide/topics/permissions/defining)
- [Tasker — Send Intent action](https://tasker.joaoapps.com/userguide/en/help/ah_send_intent.html)
- [§031 — Debug API](../031%20debug%20api/spec.md) — action handlers переиспользуются
- [§032 — Quick Connect](../032%20quick%20connect/spec.md) — same actions, разные транспорты (tile/shortcut vs broadcast)
