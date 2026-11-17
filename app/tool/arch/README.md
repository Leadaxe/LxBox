# tool/arch — сторож архитектурных границ (§742 C, §747 F)

Запускается из `app/`. CI гоняет в job `checks` (шаг «Architecture boundaries»)
с `--strict`.

```
dart run tool/arch/boundary_check.dart [--strict]
```

Построчный разбор `import`/`export`/`part` (Dart) и ссылок (Kotlin);
комментарии не считаются. Печатает `путь:строка [id правила] текст` и итог по
правилам; код возврата 1 при нарушениях только под `--strict`.

Правила (id → смысл) заданы объектами в `boundary_check.dart`:

| id | граница |
|---|---|
| `dart-layer-core` / `-vpn` / `-controllers` | слои `lib/` не импортируют вышележащие (`screens/`, `widgets/`, `controllers/`) |
| `dart-channel-literal` | имена платформенных каналов — только в `vpn/platform_channels.dart` |
| `dart-ui-bridge-frozen` | список UI-файлов, ходящих в `box_vpn_client`/`cc_channel`, заморожен |
| `kt-vpnplugin-ref`, `kt-eventsink-type`, `kt-sharedprefs` | кто в Kotlin может знать `VpnPlugin`, `EventSink`, `getSharedPreferences(` |
| `kt-ui-service-side` | файлы стороны окна (процесс `:ui`) не трогают объекты сервисной стороны (процесс `:bg`); из `BoxVpnService` — только константы (§747) |
| `kt-automationbridge-ref` | `AutomationBridge` (канал Dart) упоминают только `AutomationBridge.kt` и `VpnPlugin.kt` (§747) |
| `kt-uicoresession-ref` | `UiCoreSession` упоминают только сам держатель, `VpnPlugin.kt` и `BoxApplication.kt` (§745) |
| `kt-uisinks-member` | кто к каким полям `UiSinks` обращается: сервисная сторона — ни к каким (§747) |
| `manifest-process` | каждый компонент исходного манифеста (кроме `activity-alias`) несёт `android:process` — `:ui` или `:bg` (§747) |
| `removed-fields` | удалённые поля состояния не возвращаются |

## Два процесса (§747 F)

Приложение — два именованных процесса: `:ui` (окно, Flutter) и `:bg` (всё
сервисное). Память у них раздельная, поэтому «дотянуться до объекта другой
стороны» в коде компилируется, но в рантайме даёт пустую копию. Сторож ловит
это по именам.

- **`kt-ui-service-side`.** Файлы стороны окна: `MainActivity.kt`,
  `LanTransferSender.kt`, `vpn/VpnPlugin.kt`, `vpn/BoxCommandClient.kt`,
  `vpn/UiCoreSession.kt`, `vpn/UiSinks.kt`, `vpn/UiLaunchRequests.kt`,
  `vpn/BgClient.kt`, `vpn/WifiNetworkObserver.kt`, `editor/`. В них запрещены
  имена `CoreSession`, `ServiceCommandClient`, `BootReceiver`, `NativeCache`,
  `AutomationCache`, `ConfigManager`, `BoxService`, `BgMethods`, `BgLifecycle`,
  `BgLogPipe`, `UiPresence`, `ProbeGate`, `AutomationRelay` и обращения через
  точку к `Taildrop`, `TaildropClip`, `TaildropServiceFiles` (типы libbox
  `TaildropInbox…` клиент окна использует законно — они не совпадают). Из
  `BoxVpnService` разрешены только константы (`BROADCAST_STATUS`, `EXTRA_*`):
  имя члена целиком из заглавных букв, цифр и `_`; `BoxVpnService::class` и
  любой метод — нарушение. До сервиса окно дотягивается вызовом
  `BgClient.call` / `forward` (имя метода `BgMethods` — строка) и файлом
  конфига (`ConfigFile`). Нативные окна Taildrop и автоматизации в список не
  входят: они живут в `:bg`.
- **`kt-uisinks-member`.** Таблица «файл → поля» задана в чекере
  (`_uiSinksUsers`): `VpnPlugin.kt` и `BoxCommandClient.kt` — любые поля,
  `BoxApplication.kt` — только `appLogWarning` (`initUiSide` отдаёт клиенту
  окна приёмник журнала). Сервисная сторона к `UiSinks` не обращается: лог
  идёт через pipe (`BgLogPipe`), состояние openconnect — событием без данных.
- **`kt-automationbridge-ref`.** Сервисная сторона шлёт команду автоматизации
  через `AutomationRelay` (broadcast внутри пакета); `AutomationBridge` держит
  канал Dart и живёт в окне.
- **`kt-uicoresession-ref`.** Сервисной стороной считается всё, кроме трёх
  файлов из списка правила. `BoxApplication.kt` в нём как точка сборки
  (`initUiSide`): отдаёт клиенту UI приёмник журнала.
- **`kt-eventsink-type`.** Тип `EventSink` из клиентов ядра знает только
  `CommandClientShared.kt` (эмиттеры); `ServiceCommandClient.kt` и
  `BoxCommandClient.kt` его не называют.
- **`manifest-process`.** Правило не построчное: читается
  `android/app/src/main/AndroidManifest.xml` целиком (комментарии XML
  срезаются), у каждого `<activity>`, `<service>`, `<receiver>`, `<provider>`
  должен стоять `android:process=":ui"` или `":bg"`. `<activity-alias>` не
  проверяется — атрибута у него нет, он живёт в процессе цели. Сюда входят и
  переобъявления компонентов библиотек (`tools:node="merge"`). Собранный
  манифест — с компонентами, которые приносит новый плагин, — проверяет сборка
  Android (`app/android/app/build.gradle.kts`, задача `process…Manifest`):
  компонент без процесса останавливает сборку.

## Исключения

Исключение — запись `файл → причина` в `allow` правила, прямо в чекере.
Допустимо только для существующего долга (с указанием задачи) или
осознанного единичного случая из спеки. Список не растёт «чтобы пройти CI»:
нарушение чинится кодом. Файл из замороженного списка, который перестал
нарушать правило, чекер выводит предупреждением — убери его из списка.

Самопроверка разбора: `flutter test test/tool/boundary_check_test.dart`.
