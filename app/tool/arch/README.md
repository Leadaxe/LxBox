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
| `removed-fields` | удалённые поля состояния не возвращаются |

## Исключения

Исключение — запись `файл → причина` в `allow` правила, прямо в чекере.
Допустимо только для существующего долга (с указанием задачи) или
осознанного единичного случая из спеки. Список не растёт «чтобы пройти CI»:
нарушение чинится кодом. Файл из замороженного списка, который перестал
нарушать правило, чекер выводит предупреждением — убери его из списка.

Самопроверка разбора: `flutter test test/tool/boundary_check_test.dart`.
