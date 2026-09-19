# §491 — страж dart-ссылок реестра и отчёт для лаунчера

| | |
|---|---|
| **Статус** | **Реализовано** |
| **Дата** | 2026-09-19 |
| **Источник** | фича 480 (движок-маппер снял рукописные `*_mapper.dart`); зеркало `assets/contract` править в LxBox нельзя |
| **Связанные** | фича 460 (реестр в приложении), §476 (другие contract-стражи) |

## Проблема

У записей реестра поле `refs.dart` — список мест в коде LxBox, где исполняется
правило (путь к файлу, иногда с `:строка` или пояснением в скобках). После
снятия рукописных мапперов часть ссылок указывает на удалённые или переехавшие
файлы. Лаунчер не видит расхождение: реестр синхронизируется побайтно, а
проверки существования dart-путей не было.

## Решение

1. Тест `app/test/contract/registry_dart_refs_test.dart` обходит зеркало
   `assets/contract/registry/**/*.json`, собирает все `refs.dart`, нормализует
   путь относительно каталога `app/` и проверяет существование файла.
2. Протухшие ссылки не валят тест сразу — сверка с allowlist
   `app/test/contract/registry_dart_refs_known_stale.txt` (дословная строка из
   реестра на строку). Новая протухшая ссылка вне списка → красный; запись из
   списка, ставшая живой или исчезнувшая из реестра → красный (список
   самоочищается).
3. Прод-код и зеркало реестра не трогались.

Поле `dart` в `warnings.json` — имена классов предупреждений, не пути к
файлам; в страж не входит.

## Отчёт для лаунчера (правка `refs.dart`)

Состояние зеркала на 2026-09-19. «Куда переехало» — по grep по `app/lib` на
момент задачи.

| Файл реестра | Запись | Протухшая ссылка | Куда переехало |
|---|---|---|---|
| `registry/protocols/tailscale.json` | `(root).refs.dart` | `lib/screens/add_server_wizard/tailscale_bundle.dart` | `lib/models/tailscale_bundle.dart` — каноническая связка DNS/route узла Tailscale (§435/§437); импортируют `add_server_wizard_screen.dart`, `subscription_controller.dart` |
| `registry/protocols/group.json` | `(root).refs.dart` | `app/lib/services/parser/uri_parsers/auto_group_parser.dart:11` | Импорт sing-box `selector`/`urltest`: `lib/services/parser/singbox_config.dart` (`_groupToSpec`, ~639–719). Импорт Xray-балансировщика: `lib/services/parser/json_parsers.dart` (`_xrayAutoSelect`, ~344–435). Синтетический `autogroup://` в подписке снят — только миграция хранения `lib/services/storage_migration/legacy_autogroup.dart` (замороженный разбор текста члена папки) |

Остальные `refs.dart` (113 ссылок, 33 уникальных пути) на момент задачи
указывают на существующие файлы. Часть из них — наследие до движка
(`lib/services/parser/transport.dart`, `uri_parsers/*`, `json_parsers.dart`):
правила дублируются или перекрыты секциями `lib/services/parser/engine/`, но
файлы ещё на диске — страж по существованию файла их не помечает.

## Критерии приёмки

- [x] `registry_dart_refs_test.dart` зелёный на текущем зеркале.
- [x] `registry_dart_refs_known_stale.txt` содержит ровно текущие протухшие
      ссылки; лишних записей нет.
- [x] Таблица выше передана лаунчеру для правки `refs.dart` у источника.
- [x] `flutter analyze` без новых issue.
- [x] Прод-код и `app/assets/contract/**` не изменялись.

## Проверено

- `flutter analyze` (весь проект).
- `flutter test -j 2 test/contract/registry_dart_refs_test.dart`.
