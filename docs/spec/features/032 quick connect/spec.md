# 032 — Quick Connect (Quick Settings tile + App shortcut)

| Поле | Значение |
|------|----------|
| Статус | Draft |
| Дата | 2026-04-20 |
| Зависимости | `BoxVpnService` (native VPN lifecycle), `MainActivity`, AndroidManifest |

## Цель

Дать юзеру два пути включить/выключить VPN **без открытия приложения**:

1. **Quick Settings tile** — плитка в шторке (pull-down на статус-бар → правка плиток → перетянуть L×Box). Тап = toggle on/off. Состояние плитки (Active/Inactive) синхронизируется с реальным статусом сервиса.
2. **App shortcut** — long-press на иконку приложения на рабочем столе → меню "Toggle VPN" / "Connect" / "Disconnect" в зависимости от текущего состояния.

Обе фичи — закрытие фидбека пользователей: *"чтобы не было необходимости для подключения в приложение каждый раз заходить"*.

**Не в скопе:**
- Quick Settings tile с выбором группы / ноды (только глобальный toggle)
- Виджет на home screen (отдельная фича — динамический график трафика, выбор group, пр.)
- Wear OS / Android Auto — отдельно
- iOS — приложение Android-only

---

## Архитектура

### Общие соображения

#### VPN consent dance (важное ограничение)

`VpnService.prepare(context)` возвращает `Intent != null` если consent-диалога ещё не было — этот intent нужно стартовать через `startActivityForResult` из **Activity**. Из `TileService` или `BroadcastReceiver` запустить нельзя.

Логика:
- **Первый запуск** через tile/shortcut → consent ещё не был → открываем `MainActivity` с extras `{action: "connect"}` → activity дёргает `VpnService.prepare()` стандартным путём, после `RESULT_OK` стартует сервис.
- **После первого consent'а** → tile/shortcut могут стартовать сервис напрямую без UI (`BoxVpnService.start(context)` через `ContextCompat.startForegroundService`).

Способ детектить: `VpnService.prepare(applicationContext) == null` означает разрешение есть.

#### Status sync

И tile, и shortcut должны знать реальный статус VPN. Используем `BoxVpnService.currentStatus` (volatile mirror, уже добавлен в спеке `031 debug api`-сессии). Tile обновляется реактивно: при `setStatus(newStatus)` дёргаем `TileService.requestListeningState(...)` чтобы система перепросила tile state.

---

### Часть 1 — Quick Settings tile

#### Native: `LxBoxTileService`

Файл: `android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxTileService.kt`

```kotlin
class LxBoxTileService : TileService() {
  override fun onStartListening() {
    super.onStartListening()
    refreshTile()
  }

  override fun onClick() {
    super.onClick()
    when (BoxVpnService.currentStatus) {
      VpnStatus.Stopped -> connectOrPromptConsent()
      VpnStatus.Started -> BoxVpnService.stop(this)
      // Starting/Stopping — игнорим, чтобы не плодить race'ы
      else -> {}
    }
  }

  private fun connectOrPromptConsent() {
    val needConsent = VpnService.prepare(applicationContext) != null
    if (needConsent) {
      // Из tile activity не запустить просто так — Android требует
      // collapsePanel + явный intent. После consent'а MainActivity сама
      // стартанёт сервис.
      val intent = Intent(this, MainActivity::class.java).apply {
        putExtra("action", "connect")
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                 Intent.FLAG_ACTIVITY_CLEAR_TOP)
      }
      startActivityAndCollapse(intent)
    } else {
      BoxVpnService.start(this)
    }
  }

  private fun refreshTile() {
    val tile = qsTile ?: return
    when (BoxVpnService.currentStatus) {
      VpnStatus.Started -> {
        tile.state = Tile.STATE_ACTIVE
        tile.label = "L×Box"
        tile.subtitle = "Connected"
      }
      VpnStatus.Starting -> {
        tile.state = Tile.STATE_INACTIVE
        tile.label = "L×Box"
        tile.subtitle = "Connecting…"
      }
      VpnStatus.Stopping -> {
        tile.state = Tile.STATE_ACTIVE
        tile.label = "L×Box"
        tile.subtitle = "Stopping…"
      }
      VpnStatus.Stopped -> {
        tile.state = Tile.STATE_INACTIVE
        tile.label = "L×Box"
        tile.subtitle = "Disconnected"
      }
    }
    tile.updateTile()
  }
}
```

#### AndroidManifest

```xml
<service
  android:name=".vpn.LxBoxTileService"
  android:label="L×Box"
  android:icon="@mipmap/ic_launcher"
  android:permission="android.permission.BIND_QUICK_SETTINGS_TILE"
  android:exported="true">
  <intent-filter>
    <action android:name="android.service.quicksettings.action.QS_TILE" />
  </intent-filter>
</service>
```

#### Live update из BoxVpnService

В `setStatus(newStatus)` после `sendBroadcast(...)` добавить:

```kotlin
TileService.requestListeningState(
  applicationContext,
  ComponentName(applicationContext, LxBoxTileService::class.java)
)
```

Это попросит систему пере-bind'ить tile (она вызовет `onStartListening` если плитка видна) и тот пересчитает state.

---

### Часть 2 — App shortcut

#### Static shortcut: `res/xml/shortcuts.xml`

```xml
<shortcuts xmlns:android="http://schemas.android.com/apk/res/android">
  <shortcut
    android:shortcutId="toggle_vpn"
    android:enabled="true"
    android:icon="@mipmap/ic_launcher"
    android:shortcutShortLabel="@string/shortcut_toggle_short"
    android:shortcutLongLabel="@string/shortcut_toggle_long">
    <intent
      android:action="android.intent.action.VIEW"
      android:targetPackage="com.leadaxe.lxbox"
      android:targetClass="com.leadaxe.lxbox.MainActivity">
      <extra android:name="action" android:value="toggle" />
    </intent>
    <categories android:name="android.shortcut.conversation" />
  </shortcut>
</shortcuts>
```

`strings.xml`:
```xml
<string name="shortcut_toggle_short">Toggle VPN</string>
<string name="shortcut_toggle_long">Toggle VPN</string>
```

`AndroidManifest.xml` (внутри MainActivity):
```xml
<meta-data
  android:name="android.app.shortcuts"
  android:resource="@xml/shortcuts" />
```

#### MainActivity intent handling

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
  super.onCreate(savedInstanceState)
  handleQuickAction(intent)
}

override fun onNewIntent(intent: Intent) {
  super.onNewIntent(intent)
  setIntent(intent)
  handleQuickAction(intent)
}

private fun handleQuickAction(intent: Intent?) {
  val action = intent?.getStringExtra("action") ?: return
  when (action) {
    "connect" -> startVpnWithConsent()
    "disconnect" -> BoxVpnService.stop(applicationContext)
    "toggle" -> {
      if (BoxVpnService.currentStatus == VpnStatus.Started) {
        BoxVpnService.stop(applicationContext)
      } else {
        startVpnWithConsent()
      }
    }
  }
}

private fun startVpnWithConsent() {
  val prep = VpnService.prepare(applicationContext)
  if (prep != null) {
    startActivityForResult(prep, VPN_REQUEST_CODE_QUICK)
  } else {
    BoxVpnService.start(applicationContext)
  }
}

override fun onActivityResult(req: Int, res: Int, data: Intent?) {
  super.onActivityResult(req, res, data)
  if (req == VPN_REQUEST_CODE_QUICK && res == RESULT_OK) {
    BoxVpnService.start(applicationContext)
  }
}
```

#### Dynamic shortcut (опция MVP+1)

Через `ShortcutManager` обновляем shortcut'ы в зависимости от состояния:
- Если `Started` → "Disconnect" с extra `action=disconnect`
- Если `Stopped` → "Connect" с extra `action=connect`

Дёргается из `setStatus` (тот же hook что и QS tile). Long-press на иконку показывает контекстно-уместный label.

Для MVP достаточно одного статичного "Toggle".

---

## Edge cases

| Кейс | Ожидаемое поведение |
|------|---------------------|
| Tile тап, consent ещё не давали | `startActivityAndCollapse(MainActivity, action=connect)` → MainActivity открывается, диалог consent'а → start |
| Tile тап в момент `Starting` | Игнорим — нельзя начать второй start, нельзя стопнуть пока не установлено |
| Tile тап в момент `Stopping` | Игнорим — стоп уже идёт |
| Shortcut "toggle" без consent | MainActivity открывается, диалог consent'а → start (как и tile) |
| Shortcut во время `Starting`/`Stopping` | Тот же гейт что у tile — игнор |
| Сервис убит системой (OOM, low memory) | `currentStatus` сбрасывается в `Stopped` (он volatile в companion, переживает recreation сервиса). Tile отрисуется как Disconnected на следующем `onStartListening`. |
| Сервис умер но `currentStatus` остался `Started` (не успел сброситься) | Tile врёт. Защита: в `onDestroy` сервиса `currentStatus = VpnStatus.Stopped`. |
| Несколько tile-кликов подряд | `onClick` синхронно проверяет `currentStatus` — если уже не `Stopped`, второй клик игнорится |
| Юзер дал consent но tile ещё не пере-render'ился | Не критично — следующий `requestListeningState` обновит. |

---

## UI на home screen (внутри L×Box settings)

В `App Settings` добавить блок "Quick connect":

```
┌─────────────────────────────────────────┐
│  Quick connect                          │
│                                         │
│  📲 Quick Settings tile                 │
│  Add to Quick Settings panel  [Add]    │
│  (Android 7.0+ required)                │
│                                         │
│  📌 Home screen shortcut                │
│  Long-press the app icon on your        │
│  home screen for "Toggle VPN".          │
└─────────────────────────────────────────┘
```

`Add` button → `StatusBarManager.requestAddTileService(...)` (API 33+) запрашивает у системы добавление плитки. До API 33 — гайд "потяни шторку → редактирование → перетащи L×Box".

Shortcut'ы на home screen Android создаёт юзер сам (long-press → выбрать) — нашей UI помощь не нужна.

---

## Файлы (план реализации)

| Файл | Что |
|------|-----|
| `android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/LxBoxTileService.kt` | TileService класс |
| `android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt` | В `setStatus` дернуть `TileService.requestListeningState`; в `onDestroy` сбросить `currentStatus` |
| `android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt` | `handleQuickAction` + intent extras `connect/disconnect/toggle` |
| `android/app/src/main/AndroidManifest.xml` | Регистрация TileService + meta-data `android.app.shortcuts` |
| `android/app/src/main/res/xml/shortcuts.xml` | Static shortcut "Toggle VPN" |
| `android/app/src/main/res/values/strings.xml` | Локализованные label'ы |
| `lib/screens/app_settings_screen.dart` | Блок "Quick connect" с кнопкой Add (API 33+) |
| `lib/vpn/box_vpn_client.dart` | Wrapper `requestAddTile()` → MethodChannel метод |
| `android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt` | Handler `requestAddTile` → `StatusBarManager.requestAddTileService` |

---

## Acceptance

- [ ] Юзер тянет шторку → редактирование → видит L×Box tile, перетаскивает в активные.
- [ ] Тап на L×Box tile когда VPN off → запускается VPN (с consent-диалогом если первый раз).
- [ ] Тап на L×Box tile когда VPN on → выключается. Subtitle меняется на "Disconnected".
- [ ] Tile subtitle отражает live-статус: Connecting → Connected → Stopping → Disconnected.
- [ ] Тапы во время Starting/Stopping игнорятся (нет race'а).
- [ ] Long-press на иконку app'а на home screen показывает "Toggle VPN".
- [ ] Тап shortcut'а вызывает toggle: VPN включается / выключается без открытия UI (после первого consent'а).
- [ ] Первый shortcut-тап без consent → MainActivity открывается, после consent'а сервис стартует.
- [ ] App Settings → Quick connect показывает блок с кнопкой Add tile (на API 33+) и инструкцией для < 33.
- [ ] После убийства сервиса OOM → `currentStatus = Stopped`, tile показывает Disconnected.

---

## Риски

| Риск | Mitigation |
|------|-----------|
| `requestAddTileService` падает на разных OEM (MIUI, ColorOS) с молчанием | Fallback — текстовая инструкция "потяни шторку → редактирование плиток". Тестить на реальных Xiaomi/OnePlus. |
| Tile state desync если `setStatus` не вызвался (исключение, краш) | `onStartListening` всегда читает `currentStatus` — самокоррекция при следующем bind'е. |
| Shortcut открывает MainActivity и Flutter-engine долго грузится → consent-диалог появляется через 2-3 сек | Не критично, юзер уже привык к этому из обычного запуска. На MVP — никаких splash'ей. |
| Static shortcut запоминается launcher'ом — после удаления приложения может остаться "битой" иконкой | Системное поведение, не наша зона ответственности. |
| `TileService.requestListeningState` не делает ничего если tile не добавлена в active panel | Не баг — корректно: пока нет видимого tile'а, незачем перерисовывать. |

---

## Out of scope / future

- **Per-group shortcut'ы** — "Connect to vpn-1", "Connect to vpn-2" — динамические shortcut'ы с extras `{action: connect, group: vpn-2}`. Требует UI для выбора какие группы выставлять.
- **Виджет на home screen** с трафик-графиком + selector группы. Отдельный спек.
- **Tasker / automation integration** — broadcast intent'ы для внешних автоматизаций. Может пересечься с спекой `031 debug api` (action endpoints).
- **Wear OS companion** — отдельная история.
