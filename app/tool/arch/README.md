# tool/arch — сторож архитектурных границ (§742 C)

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
| `kt-ui-boxservice` | UI-файлы не ходят в `BoxService.` напрямую |
| `kt-vpnplugin-coresession` | `VpnPlugin.kt` ходит в `CoreSession.client` только за openconnect и не знает типа `ServiceCommandClient` (§745) |
| `kt-uicoresession-ref` | `UiCoreSession` упоминают только сам держатель, `VpnPlugin.kt` и `BoxApplication.kt` (§745) |
| `kt-uisinks-member` | кто к каким полям `UiSinks` обращается: сервисная сторона — только `coreLogSink` (`BoxService.kt`) и `ccOpenConnectSink` (`ServiceCommandClient.kt`) (§745) |
| `removed-fields` | удалённые поля состояния не возвращаются |

## Два клиента ядра (§745 C)

- **`kt-vpnplugin-coresession`.** Обращение к `CoreSession.client` в
  `VpnPlugin.kt` допустимо только в строке, где есть слово `openConnect`
  (регистр не важен). Признак живёт в самой строке, поэтому правило не зависит
  от номеров строк и не требует списка. Сейчас такая строка одна — аксессор
  `openConnectControl()`, он отдаёт узкий интерфейс `OpenConnectControl` (пять
  вызовов openconnect); пять обработчиков `cc*OpenConnect*` ходят через него.
  Тип `ServiceCommandClient` в `VpnPlugin.kt` запрещён целиком — чтобы
  аксессор нельзя было расширить до всего сервисного клиента. Хвостовой
  комментарий `// openconnect` правило не обходит: комментарии срезаются до
  проверки.
- **`kt-uicoresession-ref`.** Сервисной стороной считается всё, кроме трёх
  файлов из списка правила. `BoxApplication.kt` в нём как точка сборки
  (`initUiSide`): регистрирует слушателя «перед закрытием» и отдаёт клиенту UI
  приёмник журнала.
- **`kt-uisinks-member`.** Таблица «файл → поля» задана в чекере
  (`_uiSinksUsers`). Новому файлу сервисной стороны доступ к `UiSinks` не
  выдаётся.
- **`kt-eventsink-type`.** Тип `EventSink` из клиентов ядра знает только
  `CommandClientShared.kt` (эмиттеры, общие для двух клиентов);
  `ServiceCommandClient.kt` и `BoxCommandClient.kt` его не называют.
- **`kt-ui-boxservice`.** В список UI-файлов добавлены `BoxCommandClient.kt` и
  `UiCoreSession.kt`.

## Исключения

Исключение — запись `файл → причина` в `allow` правила, прямо в чекере.
Допустимо только для существующего долга (с указанием задачи) или
осознанного единичного случая из спеки. Список не растёт «чтобы пройти CI»:
нарушение чинится кодом. Файл из замороженного списка, который перестал
нарушать правило, чекер выводит предупреждением — убери его из списка.

Самопроверка разбора: `flutter test test/tool/boundary_check_test.dart`.
