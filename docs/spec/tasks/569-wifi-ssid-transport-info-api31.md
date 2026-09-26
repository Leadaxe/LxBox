# 569 — Чтение SSID на Android 12+ через NetworkCapabilities.transportInfo

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-09-26 |
| Дата завершения | — |
| Коммиты | — |
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

## Нерешённое / follow-up

- Заполняется исполнителем по результатам.
