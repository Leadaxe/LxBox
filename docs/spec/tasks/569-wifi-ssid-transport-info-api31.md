# 569 — Чтение SSID на Android 12+ через NetworkCapabilities.transportInfo

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-09-26 |
| Дата завершения | 2026-09-26 |
| Коммиты | aead1935, d8c29dc3, 8f31adc0, + коммит закрытия ТЗ |
| Связанные spec'ы | tasks/567 (preflight и диагностика), tasks/050, tasks/051, docs/features/wifi-aware-routing.md, docs/DIAGNOSTICS.md |

## Проблема

`WifiInfoReader.read` берёт SSID/BSSID через `WifiManager.getConnectionInfo()`.
Метод deprecated с API 31: Google переводит приложения на
`ConnectivityManager` + `NetworkCallback`, зарегистрированный с
`FLAG_INCLUDE_LOCATION_INFO`, где `WifiInfo` приходит в
`NetworkCapabilities.transportInfo`. Старый путь на новых прошивках ведёт себя
всё хуже (редактирование SSID по своим правилам, OEM-особенности), и
пользовательские жалобы «раньше работало» (4PDA, 26.09.2026) частично могут быть
следствием именно этого. Задача 567 починила диагностику, но источник данных
остался старым.

## Диагностика

Как устроено сейчас (после 567):

- `WifiInfoReader.read(ctx)` — единая точка: preflight разрешений и геолокации,
  затем `BoxApplication.wifiManager.connectionInfo`, нормализация `<unknown ssid>`
  и BSSID-заглушки `02:00:00:00:00:00`.
- Три потребителя: `PlatformInterfaceWrapper.readWIFIState()` (ядро sing-box,
  синхронный вызов из Go при старте и смене сети), `MainActivity.getCurrentWifiInfoMap()`
  (кнопка Add current), `WifiNetworkObserver` (авто-история, свой `NetworkCallback`
  без флага, дёргает `read()` на `onCapabilitiesChanged`).

Особенности нового API, которые определяют дизайн:

- SSID в `transportInfo` присутствует **только** у колбэка, зарегистрированного
  с `FLAG_INCLUDE_LOCATION_INFO`; синхронный `cm.getNetworkCapabilities(net)`
  отдаёт `WifiInfo` с вырезанным SSID. Значит, читать надо из кэша, который
  наполняет колбэк.
- Флаг требует `ACCESS_FINE_LOCATION` на момент регистрации и включённую
  геолокацию; без них `WifiInfo` приходит с `<unknown ssid>`. При смене состояния
  разрешений колбэк надо перерегистрировать.
- Регистрация колбэка сразу доставляет `onCapabilitiesChanged` для текущей сети,
  но асинхронно. Первый синхронный `read()` после регистрации может застать пустой
  кэш.

## Решение (ТЗ исполнителю)

### 1. Кэш состояния Wi-Fi: `WifiStateCache` (новый файл `vpn/WifiStateCache.kt`)

Process-scoped синглтон, создаётся в `BoxApplication.onCreate` рядом с
`wifiObserver`. Только для API 31+; на API < 31 объект существует, но
`start()` — no-op.

- `start()`: если preflight 567 (`WifiInfoReader` — вынести проверку разрешений и
  геолокации в публичную функцию, возвращающую причину) проходит, регистрирует
  `ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO)` на
  `NetworkRequest` с `TRANSPORT_WIFI`. Запоминает снимок разрешений, при котором
  зарегистрирован. Исключения (`SecurityException`, `RuntimeException`,
  `TooManyRequestsException`) ловить, писать `Log.w`, считать «не запущен».
- `onCapabilitiesChanged`: `caps.transportInfo as? WifiInfo` → нормализация как
  в `read()` (кавычки, `<unknown ssid>`, заглушка BSSID) → `@Volatile` поле
  `latest: WifiSnapshot?` (`ssid`, `bssid`, `network`, `atMillis`). `onLost` для
  этой сети → `latest = null`.
- `ensureCurrent()`: вызывается из `read()`. Если снимок разрешений изменился с
  момента регистрации — `stop()` + `start()` (перерегистрация обновляет
  редактирование SSID). Если не зарегистрирован и preflight проходит — `start()`.
- `stop()`: `unregisterNetworkCallback`, `latest = null`.
- Регистрация без `wifiObserver`-логики: это отдельный колбэк, `WifiNetworkObserver`
  не трогать кроме п. 3.

### 2. `WifiInfoReader.read` на API 31+

Порядок после preflight:

1. `WifiStateCache.ensureCurrent()`.
2. Если `latest != null` — вернуть `Success(ssid, bssid)` или `UnknownSsid`, если
   SSID пуст после нормализации.
3. Если `latest == null` (колбэк ещё не доставил или Wi-Fi нет) — **fallback** на
   существующий путь `getConnectionInfo()` с тем же разбором. В лог `Log.d`
   пометить `source=cache` / `source=legacy`, чтобы в logcat было видно, какой путь
   сработал.

API < 31: поведение без изменений (только `getConnectionInfo()`).
`readAsState` не менять: контракт с ядром прежний (`null` на любую нештатную ветку,
`WIFIState("", "")` на `UnknownSsid`).

### 3. `WifiNetworkObserver`

Оставить свой колбэк (он без флага, регистрируется только при включённой
авто-истории). Внутри `readWifi()` ничего не менять — он уже идёт через
`WifiInfoReader.read`, и на 31+ получит данные из кэша. Убедиться, что два
колбэка не мешают друг другу (разные объекты, разный lifecycle).

### 4. Ядро

`PlatformInterfaceWrapper.readWIFIState()` без изменений по логике. Проверить
сценарий: VPN стартует с правилом `wifi_ssid`, `needWIFIState()` = true, Go
вызывает `readWIFIState()` синхронно — первый вызов может попасть в fallback
(кэш пуст), это допустимо. Смена сети Wi-Fi↔LTE и обратно: BoxService на
смену интерфейса дёргает `resetNetwork()`, ядро перечитывает состояние — к этому
моменту кэш уже обновлён колбэком (доставка колбэка раньше `resetNetwork`, так
как оба идут от ConnectivityManager; если на AVD окажется иначе — зафиксировать
в «Нерешённое», не чинить в этой задаче).

### 5. Документация

- `docs/features/wifi-aware-routing.md`: абзац «Как читается SSID»: два пути
  (кэш колбэка на 31+, `getConnectionInfo()` как fallback и на < 31), требования
  к разрешениям те же.
- `docs/DIAGNOSTICS.md`, раздел про `<unknown ssid>`: строки лога с `source=`.
- `docs/ARCHITECTURE.md`: если там перечислены синглтоны `BoxApplication` —
  добавить `WifiStateCache`; иначе не трогать.

### 6. Вне объёма

- Preflight, коды ошибок, UI редактора — сделано в 567, не менять.
- Проверка точного местоположения при сохранении правила — отдельный follow-up
  из 567, сюда не брать.
- `neverForLocation` у `NEARBY_WIFI_DEVICES` не трогать.
- API < 31 — без изменений.

### Что сделано (исполнитель)

- **`vpn/WifiStateCache.kt`** (новый): класс, синглтон `BoxApplication.wifiStateCache`
  создаётся в `onCreate` рядом с `wifiObserver` (плюс `wifiStateCacheOrNull` на случай
  чтения до `onCreate`). Регистрация **ленивая** — не в `onCreate`, а из
  `ensureCurrent()` при первом `read()` с пройденным preflight: пользователь без
  Wi-Fi-правил колбэк с location-флагом не получает. `ensureCurrent` / `start` / `stop`
  `@Synchronized`, `latest` — `@Volatile`. Снимок разрешений — строка
  `nearby=… fine=… bg=… loc=…` (`WifiInfoReader.permissionSnapshot`), в него входит и
  тумблер геолокации. `onCapabilitiesChanged` берёт только `transportInfo as? WifiInfo`
  (VPN-сеть и не-WifiInfo игнорируются, кэш не трогается), `onLost` чистит кэш только
  для сети из `latest`. Ошибки регистрации — `Log.w`, колбэк считается не запущенным.
- **`WifiInfoReader`**: публичные `preflight(ctx): Result?` (без логирования),
  `permissionSnapshot`, `normalizeSsid`, `normalizeBssid`; старое чтение вынесено в
  `readLegacy`. На провале preflight на API 31+ кэш снимается (`stop()`), после
  восстановления `ensureCurrent` регистрирует заново. На API 31+: `ensureCurrent()` →
  кэш с непустым SSID → `Success`, `source=cache`; иначе fallback на
  `getConnectionInfo()`, `source=legacy`.
- **Отступление от п. 2:** кэш с пустым (вырезанным) SSID не возвращает сразу
  `UnknownSsid`, а тоже уходит в fallback — так результат гарантированно не хуже, чем
  до задачи; если и legacy не дал SSID, `UnknownSsid` с пометкой `(cache also unknown)`.
  Кэш с SSID и пустым BSSID считается успехом (BSSID пустой допустим, как в legacy при
  `bssid=null`).
- **Дополнение (сценарий 4):** при выключенном Wi-Fi `getConnectionInfo()` не `null`,
  а `<unknown ssid>` / `bssid=null`, и Add current показывал совет про разрешения
  «Precise / Allow all the time» (так было и до задачи). На API 31+, когда у кэша нет
  Wi-Fi сети и legacy отдаёт `<unknown ssid>` с `bssid=null`, теперь `NoWifi` →
  «Not connected to Wi-Fi.». Для ядра без изменений: libbox
  (`experimental/libbox/service.go`, `ReadWIFIState`) сводит `nil` к пустому
  `adapter.WIFIState{}`, то есть `null` и `WIFIState("", "")` равнозначны.
  API < 31 не затронут.
- `readAsState`, `PlatformInterfaceWrapper.readWIFIState`, `WifiNetworkObserver`,
  `MainActivity` — без изменений. Колбэки `WifiNetworkObserver` и `WifiStateCache` —
  разные объекты с разным lifecycle; observer через `read()` на 31+ получает данные
  из кэша.
- Документация: `docs/features/wifi-aware-routing.md` (раздел «Как читается SSID»),
  `docs/DIAGNOSTICS.md` (строки `source=`, лог `WifiStateCache`, grep с новым тегом),
  `docs/ARCHITECTURE.md` (дерево файлов и блок синглтонов `BoxApplication`).
  Запись в `CHANGELOG.md` → Unreleased → Fixed.

## Риски и edge cases

- `registerNetworkCallback` имеет лимит 100 колбэков на процесс
  (`TooManyRequestsException`); регистрировать один раз, перерегистрацию делать
  только при реальной смене снимка разрешений.
- После `stop()`/`start()` кэш пуст до первого `onCapabilitiesChanged` — fallback
  обязателен, иначе регресс против 567.
- `transportInfo` на некоторых OEM может быть не `WifiInfo` — `as?` и fallback.
- Колбэк приходит не на main thread — поле `@Volatile`, без блокировок.
- Утечка: колбэк живёт весь процесс, это намеренно (как `wifiObserver`);
  `stop()` только при перерегистрации.

## Верификация

- Kotlin компилируется в `scripts/build-local-apk.sh` (полный SDK локально
  отсутствует, компилятор — только через сборку) и в CI job `android`, если он
  запускается на develop; если нет — достаточно локальной сборки.
- Dart-тесты не затрагиваются; ничего не гонять.
- Ручная проверка на AVD `LxBox_test` (API 34, emulator-5554, приложение стоит,
  разрешения выданы, геолокация включена). Сценарии, каждый — строка logcat
  `WifiInfoReader` с `source=`:
  1. Холодный старт приложения → Add current: чип `AndroidWifi`; в логе первый
     вызов может быть `source=legacy`, повторный — `source=cache`.
  2. Отозвать `ACCESS_FINE_LOCATION` → Add current: диалог 567 (preflight), кэш
     остановлен; вернуть FINE → Add current работает, в логе перерегистрация.
  3. Геолокация off → on: аналогично п. 2.
  4. `adb shell svc wifi disable` → Add current: «Not connected to Wi-Fi»;
     `svc wifi enable`, подождать подключения → чип снова, `source=cache`.
  5. VPN с правилом `wifi_ssid: AndroidWifi` (создать custom-правило через
     редактор, направление любое) → старт → `adb logcat -d | grep PIW` показывает
     `ssid='AndroidWifi'`; `svc wifi disable/enable` → после восстановления
     PIW снова с SSID (может потребоваться пауза 5–10 с).
- Критерии приёмки: все пять сценариев дают ожидаемое; ни один не хуже, чем
  до задачи; сборка проходит.

### Результат проверки на AVD (LxBox_test, API 34, 26.09.2026)

Сборка `scripts/build-local-apk.sh` — зелёная, предупреждений Kotlin по затронутым
файлам нет. Скриншоты — в scratchpad сессии (`569-*.png`).

| # | Сценарий | Результат | Строки logcat |
|---|---|---|---|
| 1 | Холодный старт → Add current (дважды) | чип `AndroidWifi · 00:13:10:85:fe:01` | `WifiStateCache: started (perms=nearby=1 fine=1 bg=1 loc=1)` → `WifiInfoReader: cache empty (registered=true), falling back: source=legacy` → `ok: source=legacy ssid='AndroidWifi'` → `WifiStateCache: update: ssid='AndroidWifi' … net=101`; повторный: `ok: source=cache ssid='AndroidWifi'` |
| 2 | `pm revoke ACCESS_FINE_LOCATION` → Add current; `pm grant` → Add current | диалог «Wi-Fi rules need permissions» (567); после grant чип | `W permission missing: android.permission.ACCESS_FINE_LOCATION` (кэш в новом процессе не запускался — Android убивает процесс при revoke); после grant: `started` → `source=legacy` → `update` → `source=cache` ×2 |
| 3 | `location_mode 0` → Add current; `location_mode 3` → Add current ×2 | SnackBar «Location is turned off…» + Settings; после включения чип | `W location disabled: system location toggle is off` → `WifiStateCache: stopped`; после включения `started` → `source=legacy` → `update` → `source=cache` |
| 4 | `svc wifi disable` → Add current; `svc wifi enable` → Add current | «Not connected to Wi-Fi.»; после включения чип | `WifiStateCache: lost: net=101`; `cache empty (registered=true), falling back: source=legacy` → `W no wifi: not connected (cache has no wifi network, connectionInfo bssid=null)`; после включения `update … net=103` → `ok: source=cache` |
| 5 | Custom-правило `wifi_ssid: AndroidWifi` → direct, старт VPN; `svc wifi disable/enable` | VPN Connected; ядро получает SSID, после выключения — пусто, после включения снова SSID | старт: `ok: source=cache` → `PIW: readWIFIState: ssid='AndroidWifi'`; disable: `lost: net=103` → `W no wifi: not connected …` → `PIW: readWIFIState: null (…)`; enable: `update … net=105` (11:43:46.552) → `ok: source=cache` → `PIW: readWIFIState: ssid='AndroidWifi'` (11:43:47.852) |

До правки `fix(569)` сценарий 4 давал `W unknown ssid: android returned ssid=<unknown ssid> bssid=null`
и SnackBar «Android did not report the network name. Check that Location permission…» —
поведение, унаследованное от старого пути; исправлено вторым коммитом.

Сценарий 5, порядок доставки: колбэк кэша приходит раньше, чем ядро перечитывает
состояние после `resetNetwork` (~1,3 с на AVD), так что после смены сети ядро
читает из кэша. Эмулятор возвращён в норму: разрешения выданы, геолокация
включена, Wi-Fi включён, VPN остановлен, тестовое правило удалено.

## Нерешённое / follow-up

- Сценарий 2 «кэш остановлен» при отзыве разрешения в живом процессе на AVD не
  воспроизводится: Android убивает процесс при `pm revoke`. Путь `stop()` на провале
  preflight проверен сценарием 3 (геолокация). Перерегистрация по смене снимка
  (`permissions changed … re-registering`) в живую не наблюдалась: без провала
  preflight между чтениями снимок на практике не меняется.
- Не проверено на реальном устройстве Android 12+ (телефон по правилам не трогали) и на
  API 31–32, где нет `NEARBY_WIFI_DEVICES`.
- CI job `android` — по факту push-а.
