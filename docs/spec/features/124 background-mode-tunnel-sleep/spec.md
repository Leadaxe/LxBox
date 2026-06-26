# 124 — Tunnel sleep mode (background mode)

| Поле | Значение |
|------|----------|
| Тип | Feature (жизненный цикл туннеля в фоне: батарея vs надёжность) |
| Статус | Реализовано (default `never` с v1.5.0) |
| Связано | [122 commandclient-migration](../122%20commandclient-migration/spec.md), [123 subscription-model](../123%20subscription-model/spec.md), [task 086 stale-connections-network-change-doze](../../tasks/086-stale-connections-network-change-doze.md), [task 031 reset-network-api](../../tasks/031-reset-network-api.md) |

Настройка **App Settings → Background → «Tunnel sleep mode»** управляет тем, **когда приостанавливать VPN-туннель в фоне ради экономии батареи**. Это не опция конфига sing-box: значение управляет жизненным циклом туннеля через libbox `CommandServer.pause()` / `.wake()`, реагируя на системные события экрана и Doze.

Единый референс на случай вопросов «что делает каждый режим», «не утекает ли трафик мимо VPN на паузе», «накапливаются ли пакеты» — чтобы поведение не пере-выводилось каждый раз из кода.

---

## 1. Три режима

Wire-protocol с native — строки `never | lazy | always`; парсинг/сериализация инкапсулированы в `BackgroundMode` ([app/lib/models/background_mode.dart](../../../../app/lib/models/background_mode.dart)).

| Режим | Когда `pause()` | Батарея | Надёжность |
|-------|-----------------|---------|------------|
| **`never`** (default) | Никогда — туннель работает 24/7, pause/wake не вызываются | Максимальный расход (+1–3% за ночь) | Максимум: пуши/keep-alive (Telegram MTProto, APNs, SIP) не рвутся |
| **`lazy`** | При глубоком Doze (≈30+ мин полной неактивности экрана); `wake()` мгновенно при касании / выходе из Doze | Экономит в ночном простое | Компромисс |
| **`always`** | Сразу при `SCREEN_OFF`; `wake()` при `SCREEN_ON` | Максимум экономии | Низкая: фоновые keep-alive рвутся при каждом гашении экрана |

**Default = `never`** с v1.5.0 (раньше был `lazy`). Старый дефолт паузил на deep Doze, что рвало долгие TCP-сокеты и ломало push-уведомления — см. [releases/v1.5.0.md](../../../releases/v1.5.0.md).

---

## 2. Где живёт значение

- **Хранилище:** SharedPreferences `boxvpn_boot`, ключ `background_mode` (String), fallback `"never"`.
  `BootReceiver.getBackgroundMode()` / `setBackgroundMode()` — [BootReceiver.kt](../../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BootReceiver.kt). Документация ключа — [STORAGE.md](../../../STORAGE.md).
- **UI:** App Settings → Background → «Tunnel sleep mode» (`Icons.bedtime_outlined`), подпись *«When to pause the tunnel to save battery. Takes effect on next VPN connect.»* — [settings_screen.dart](../../../../app/lib/screens/settings_screen.dart).
- **Мост Dart↔native:** `BoxVpnClient.getBackgroundMode()` / `setBackgroundMode()` → platform-методы `VpnPlugin` → `BootReceiver`.
- **Debug API:** `GET|PUT /settings/vpn/background_mode`; текущее значение видно в `GET /state/vpn`.

**Применяется на следующем подключении VPN** — receiver регистрируется один раз в `onStartCommand`, смена режима на лету не подхватывается (нужен reconnect; UI помечает `markConfigChangedNeedRestart`).

---

## 3. Механика pause/wake

Режим читается **один раз** при старте сервиса и определяет, на какие системные события подписан `BroadcastReceiver` ([BoxService.kt onStartCommand](../../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt)):

- `never` → не регистрирует ни Doze, ни screen-события → `pause()`/`wake()` не вызываются никогда.
- `lazy` → `ACTION_DEVICE_IDLE_MODE_CHANGED` → `onIdleModeChanged()`: `if (powerManager.isDeviceIdleMode) cs.pause() else cs.wake()`.
- `always` → `ACTION_SCREEN_OFF` → `cs.pause()`, `ACTION_SCREEN_ON` → `cs.wake()`.

Что физически делает `pause()` (через libbox `CommandServer`):

- **`pause()` зовёт в ядре `Router().ResetNetwork()` → закрывает ВСЕ TCP-соединения** (приложения получают обрыв/RST). Это «двойной меч»: в `always` гашение экрана рвёт keep-alive — ровно та регрессия, из-за которой дефолт сменили на `never`. См. ROOT CAUSE #2 в [task 086](../../tasks/086-stale-connections-network-change-doze.md).
- **`wake()`** — снова перебиндивает диалеры; приложения сами пересоздают соединения по необходимости.

---

## 4. Утечки трафика при паузе — НЕТ (инвариант)

**Инвариант: на паузе трафик НЕ идёт мимо VPN.** При `pause()`:

- **tun-интерфейс остаётся поднятым.** `ParcelFileDescriptor` не закрывается, `Builder.establish()` заново не вызывается. Весь трафик приложений по-прежнему заворачивается в `tun0`. Ср. [task 031](../../tasks/031-reset-network-api.md): про `resetNetwork()` явно зафиксировано «TUN fd остаётся… тот же TUN-inbound продолжает принимать пакеты» — `pause()` тоже не трогает физический интерфейс.
- **Закрываются только логические соединения** (TCP через `ResetNetwork().CloseAll()`), не сам интерфейс.

Отсюда два следствия для пользователя:

1. **Утечки нет.** Пакеты захвачены в `tun0` и не могут пройти напрямую. Реальный IP не светится даже на паузе. Утечка была бы возможна, только если бы интерфейс снимали — этого не происходит ни в одном режиме.
2. **Пакеты НЕ накапливаются на доставку.** Пока туннель спит, входящие пакеты дропаются (обрабатывать некому), приложение видит «сети нет» (таймаут / `EHOSTUNREACH`). При `wake()` зависшие данные **не доставляются задним числом** — приложения переоткрывают соединения. Поэтому в `always` пуши приходят пачкой **в момент разблокировки экрана** — не из буфера, а потому что приложение тогда заново забирает их с сервера.

Это контролируемая заморозка с обрывом и переподключением, а не очередь и не обход туннеля.

---

## 5. Критерии готовности

- [x] Три режима `never/lazy/always`, дефолт `never`.
- [x] Смена режима применяется на следующем connect (не на лету).
- [x] `never` не регистрирует Doze/screen receiver'ы (ноль pause/wake-оверхеда).
- [x] На паузе tun остаётся поднят → нет утечки мимо VPN (инвариант §4).
- [x] Управление через App Settings + Debug API + backup (`vpn_settings.background_mode`).

## 6. Известные ограничения

- На паузе keep-alive рвутся (по дизайну `ResetNetwork`); `lazy`/`always` — осознанный размен надёжности на батарею.
- «Накопления» фоновых данных нет: разорванные соединения восстанавливаются только после `wake()`.
