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
| `kt-ui-no-core` | файлы стороны окна не импортируют `io.nekohasekai.libbox`, не зовут `Libbox.` и `ensureLibbox` — ядро в `:ui` не грузится (§747, итерация 2) |
| `manifest-process` | каждый компонент исходного манифеста (кроме `activity-alias`) несёт `android:process` — `:ui` или `:bg` (§747) |
| `removed-fields` | удалённые поля состояния не возвращаются |

## Два процесса (§747 F)

Приложение — два именованных процесса: `:ui` (окно, Flutter) и `:bg` (всё
сервисное, включая ядро и оба его клиента). Память у них раздельная, поэтому
«дотянуться до объекта другой стороны» в коде компилируется, но в рантайме
даёт пустую копию. Сторож ловит это по именам.

Файлы стороны окна (всё, что исполняется в `:ui`): `MainActivity.kt`,
`LanTransferSender.kt`, `vpn/VpnPlugin.kt`, `vpn/UiLaunchRequests.kt`,
`vpn/AutomationBridge.kt`, `vpn/BgClient.kt`, `vpn/UiKeepAliveService.kt`,
`vpn/WifiNetworkObserver.kt`,
`vpn/WifiInfoReader.kt`, `vpn/WifiStateCache.kt`, `vpn/PermissionUtils.kt`,
`editor/`. Клиент ядра экрана, проба и нативные окна Taildrop и автоматизации
в список не входят: они живут в `:bg`.

- **`kt-ui-service-side`.** В файлах окна запрещены имена `CoreSession`,
  `ScreenCoreSession`, `ServiceCommandClient`, `BoxCommandClient`,
  `StreamSinks`, `ProbeSession`, `PProfClient`, `BootReceiver`, `NativeCache`,
  `AutomationCache`, `ConfigManager`, `BoxService`, `BgMethods`,
  `BgCcMethods`, `BgLifecycle`, `BgEventPipe`, `UiPresence`, `UiHold`,
  `UiCalls`, `AssistantCore`, `AssistantBridge`, `AppFunctionsGate`,
  `LxBoxAppFunctions` (§750 — ассистент целиком на сервисной стороне),
  `AutomationRelay`, `L10n` и обращения через точку к `Taildrop`,
  `TaildropClip`, `TaildropServiceFiles`. Из `BoxVpnService` разрешены только
  константы (`BROADCAST_STATUS`, `EXTRA_*`): имя члена целиком из заглавных
  букв, цифр и `_`; `BoxVpnService::class` и любой метод — нарушение. До
  сервиса окно дотягивается вызовом `BgClient.call` / `forward` (имя метода —
  строка) и файлом конфига (`ConfigFile`).
- **`kt-ui-no-core`** (итерация 2). Окно ядро не грузит: в его файлах нет
  `io.nekohasekai.libbox` (импорт или полное имя), нет обращений `Libbox.…` и
  вызова `ensureLibbox`. Один такой вызов — и в `:ui` загрузится `libbox.so`
  со второй средой Go. Общий для сторон `WifiInfoReader.kt` поэтому тоже в
  списке: тип ядра `WIFIState` собирает `PlatformInterfaceWrapper`.
- **`kt-automationbridge-ref`.** Сервисная сторона шлёт команду автоматизации
  через `AutomationRelay` (кадр канала событий); `AutomationBridge` держит
  канал Dart и живёт в окне.
- **`kt-eventsink-type`.** Тип `EventSink` называют только `StreamSinks.kt`
  (приёмники потоков данных окна в `:bg`), `BgEventPipe.kt` (приёмник,
  пишущий кадр), `CommandClientShared.kt` (эмиттеры) и `VpnPlugin.kt`
  (свой `statusSink`).
- **`manifest-process`.** Правило не построчное: читается
  `android/app/src/main/AndroidManifest.xml` целиком (комментарии XML
  срезаются), у каждого `<activity>`, `<service>`, `<receiver>`, `<provider>`
  должен стоять `android:process=":ui"` или `":bg"`. `<activity-alias>` не
  проверяется — атрибута у него нет, он живёт в процессе цели. Сюда входят и
  переобъявления компонентов библиотек (`tools:node="merge"`). Собранный
  манифест — с компонентами, которые приносит новый плагин, — проверяет сборка
  Android (`app/android/app/build.gradle.kts`, задача `process…Manifest`):
  компонент без процесса останавливает сборку.

Правила `kt-uicoresession-ref` и `kt-uisinks-member` (§745) сняты: держатель
клиента экрана и приёмники потоков переехали в `:bg` и для окна запрещены
общим правилом `kt-ui-service-side`.

## Исключения

Исключение — запись `файл → причина` в `allow` правила, прямо в чекере.
Допустимо только для существующего долга (с указанием задачи) или
осознанного единичного случая из спеки. Список не растёт «чтобы пройти CI»:
нарушение чинится кодом. Файл из замороженного списка, который перестал
нарушать правило, чекер выводит предупреждением — убери его из списка.

Самопроверка разбора: `flutter test test/tool/boundary_check_test.dart`.
