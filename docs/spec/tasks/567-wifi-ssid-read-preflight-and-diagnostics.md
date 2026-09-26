# 567 — Чтение SSID: точное местоположение, геолокация и честная диагностика

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-09-26 |
| Дата завершения | — |
| Коммиты | — |
| Связанные spec'ы | tasks/050, tasks/051 (Wi-Fi-условия custom-правил), docs/features/wifi-aware-routing.md, docs/DIAGNOSTICS.md |

## Проблема

Пользователи (4PDA, 26.09.2026, и владелец на своём телефоне) сообщают: правила с
условием `wifi_ssid` перестали срабатывать, кнопка **Add current** в редакторе
custom-правила пишет «Cannot read Wi-Fi info — try toggling Wi-Fi off/on». При
этом в системных настройках разрешения «Местоположение» и «Устройства
поблизости» выданы. Раньше работало. Замечено «как минимум на всех 2.25.x».

## Диагностика

Код чтения SSID не менялся с мая 2026 (`WifiInfoReader.kt`, blame 7c2d32b9),
targetSdk 36 с v2.21.0, манифест под Google Play не менялся. Регрессии в
репозитории нет.

Воспроизведено на AVD `LxBox_test` (API 34), сборка 2.25.5-dev.87:

| Вариант | Add current |
|---|---|
| Всё выдано, геолокация включена | чип `AndroidWifi`, работает |
| Системный тумблер геолокации выключен | «Cannot read Wi-Fi info — try toggling Wi-Fi off/on» |
| `ACCESS_FINE_LOCATION` отозван, COARSE + BACKGROUND + NEARBY выданы | то же сообщение |
| FINE выдан обратно | снова работает |

Корень: `WifiInfoReader.hasWifiInfoPermissions` на API 29+ проверяет только
`ACCESS_BACKGROUND_LOCATION` (и `NEARBY_WIFI_DEVICES` на 33+). Наличие
`ACCESS_FINE_LOCATION` и включённость геолокации (`LocationManager.isLocationEnabled()`)
не проверяются. Android в этих случаях не бросает `SecurityException`, а тихо
возвращает `<unknown ssid>` и BSSID-заглушку `02:00:00:00:00:00` → ветка
`UnknownSsid` → пользователь получает совет переключить Wi-Fi, который не помогает.
С Android 12 в диалоге разрешения есть переключатель «Точное местоположение»;
при выборе «Приблизительное» FINE не выдан, BACKGROUND при этом может быть выдан.
Сброс разрешений при обновлении системы или для «неиспользуемых» приложений
даёт ту же картину, отсюда «раньше работало».

Дополнительно: `WifiInfoReader` ничего не пишет в logcat, поэтому в дампах
пользователей сбой невидим; подсказка «Needs Location + Nearby Wi-Fi permissions.
Tap to manage.» в секции Wi-Fi показывается всегда, независимо от состояния.

Правила `wifi_ssid` в ядре не срабатывают по той же причине: `readWIFIState` в
`PlatformInterfaceWrapper` берёт данные через `WifiInfoReader.readAsState`, тот
при `UnknownSsid` возвращает пустой SSID.

## Решение (ТЗ исполнителю)

### 1. Preflight в `WifiInfoReader.kt`

Заменить булев `hasWifiInfoPermissions` на проверку, возвращающую конкретную
причину. Порядок проверок и коды причин (строки кодов — контракт с Dart):

1. API 33+ и нет `NEARBY_WIFI_DEVICES` → `Result.PermissionMissing(listOf("android.permission.NEARBY_WIFI_DEVICES"))`.
2. Нет `ACCESS_FINE_LOCATION` (любой API) → `PermissionMissing(listOf("android.permission.ACCESS_FINE_LOCATION"))`. Код причины для Dart: `fine_location_missing`.
3. API 29+ и нет `ACCESS_BACKGROUND_LOCATION` → `PermissionMissing(listOf("android.permission.ACCESS_BACKGROUND_LOCATION"))`. Код: `permission_missing` (как сейчас).
4. `LocationManager.isLocationEnabled()` == false (API 28+; ниже — `Settings.Secure.LOCATION_MODE != LOCATION_MODE_OFF`) → новый `Result.LocationDisabled`. Код: `location_disabled`.
5. Далее как сейчас: `connectionInfo`, `<unknown ssid>` → `UnknownSsid`.

Несколько отсутствующих разрешений собирать в один список `PermissionMissing(missing: List<String>)`, Dart получает `error` = первый код по приоритету выше плюс поле `missing` (список полных имён).

`readAsState` (путь ядра) поведение не меняет: любая нештатная ветка → `null`,
`UnknownSsid` → `WIFIState("", "")`. Это контракт с sing-box, не трогать.

### 2. Логирование

В `WifiInfoReader.read` на каждую нештатную ветку одна строка `Log.w(TAG, ...)`
с тегом `WifiInfoReader`: какая проверка не прошла и, для `UnknownSsid`, что
именно вернул Android (ssid как есть, bssid как есть). Успех — `Log.d`. Строки
не должны попадать в диагностический экспорт как ошибки VPN, только logcat.
Обновить `docs/DIAGNOSTICS.md` раздел «`<unknown ssid>` in Wi-Fi rules»: сейчас
там написано, что причина только в NEARBY_WIFI_DEVICES; добавить точное
местоположение и системную геолокацию, привести строки лога.

### 3. `MainActivity.getCurrentWifiInfoMap` и Dart-обёртка

- Map для `PermissionMissing`: `{"error": "<код>", "missing": "<имена через запятую>"}`. Для `LocationDisabled`: `{"error": "location_disabled"}`.
- `UrlLauncher.getCurrentWifiInfo` (`app/lib/services/url_launcher.dart`): `WifiInfoError` получает опциональное поле `missing: List<String>`; коды пополняются `fine_location_missing`, `location_disabled`. Комментарии-перечни кодов обновить.
- Новый метод канала `openLocationSettings` → `Settings.ACTION_LOCATION_SOURCE_SETTINGS` (Dart-обёртка рядом с существующими `openAppSettings`-подобными).

### 4. UI редактора (`custom_rule_edit_screen.dart`, `wifi_permission_dialog.dart`, `wifi_section.dart`)

- `_addCurrentWifi`: `permission_missing` и `fine_location_missing` → `WifiPermissionDialog.show(missing: <из ответа>)`; `location_disabled` → SnackBar «Location is turned off. Turn it on in system settings.» с action «Settings» → `openLocationSettings`; `unknown_ssid` → текст заменить на «Android did not report the network name. Check that Location permission is set to "Precise" and "Allow all the time".» (совет про переключение Wi-Fi убрать).
- `WifiPermissionDialog`: ветка для `ACCESS_FINE_LOCATION` — текст «Precise location is required. Open Settings → Permissions → Location and enable "Use precise location".», кнопка «Open Settings» (та же, что для BACKGROUND). Текст диалога сейчас начинается с «Your sing-box config uses…» — оставить.
- Подсказка в `wifi_section.dart`: показывать только когда реальное состояние нештатно. Экран при открытии секции один раз вызывает `getCurrentWifiInfo` (дёшево, тот же preflight) и по результату выбирает текст: всё в порядке → подсказку не рисовать; иначе одна строка по причине («Precise location permission missing», «Background location missing», «Nearby Wi-Fi permission missing», «Location is turned off»), tap ведёт в соответствующее место. `no_wifi` и `unknown_ssid` подсказку не показывают.
- Все пользовательские строки только английские, через `getLocalText.s`, добавить в l10n согласно `docs/l10n.md` (гейт per-language, см. §452).

### 5. Экран Diagnostics (`diagnostics_tab.dart`)

Если там уже есть строка состояния Wi-Fi-разрешений — расширить теми же
причинами. Если нет — не добавлять, вне объёма.

### 6. Вне объёма (не делать)

- Переход на `NetworkCapabilities.transportInfo` + `FLAG_INCLUDE_LOCATION_INFO` на API 31+ — отдельная задача, см. «Нерешённое».
- Автоматический запрос `ACCESS_FINE_LOCATION` через runtime prompt — приложение сознательно не запрашивает местоположение само (комментарий в манифесте), только ведёт в Settings. Не менять.
- Флаг `neverForLocation` у `NEARBY_WIFI_DEVICES` не трогать; на AVD с ним SSID читается.

## Риски и edge cases

- API 24–27: `isLocationEnabled` отсутствует, использовать `Settings.Secure.LOCATION_MODE`; при исключении считать, что геолокация включена (не блокировать чтение из-за проверки).
- Ветка ядра (`readAsState`) не должна начать возвращать иное, чем раньше: тест или ручная проверка, что при `LocationDisabled` возвращается `null`, как раньше при `PermissionMissing`.
- Подсказка в секции не должна дёргать канал на каждом rebuild: один вызов на открытие экрана и после возврата из диалога разрешений.

## Верификация

- Kotlin-часть локально не собирается без полного SDK (см. память), проверка компиляции — CI `android`.
- Dart: точечно один тест на разбор Map в `UrlLauncher.getCurrentWifiInfo` (новые коды, `missing`), если есть существующий тест-файл для url_launcher — дополнить его, полный прогон не гонять.
- Ручная проверка на AVD `LxBox_test` (API 34, эмулятор уже запущен, разрешения выданы): четыре варианта из таблицы диагностики + пятый: отозвать FINE → Add current показывает диалог с «Precise location…», подсказка в секции показывает «Precise location permission missing»; вернуть FINE → подсказка исчезает. Каждый вариант — строка в logcat `WifiInfoReader`.
- Критерии приёмки: ни один из четырёх сценариев не показывает старый совет «toggling Wi-Fi off/on»; в logcat по каждому сценарию есть причина; CI зелёный.

## Нерешённое / follow-up

- Отдельная задача: чтение SSID на API 31+ через `ConnectivityManager` + `NetworkCallback(FLAG_INCLUDE_LOCATION_INFO)` / `NetworkCapabilities.transportInfo`, `getConnectionInfo()` как fallback. `getConnectionInfo()` deprecated с API 31; на новых прошивках поведение может ужесточаться.
- Ответ на 4PDA: после релиза с этим фиксом, сейчас пользователю достаточно проверить «Точное местоположение» и системную геолокацию.
