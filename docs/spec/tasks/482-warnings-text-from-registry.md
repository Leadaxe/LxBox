# §482 — тексты четырёх предупреждений взяты из реестра, классы сняты

| | |
|---|---|
| **Статус** | **Released в v2.25.0** (20.09.2026, ядро `v1.14.1-lx.8`). **Реализовано, `flutter analyze` чист, затронутые тесты зелёные** |
| **Дата** | 2026-09-19 |
| **Источник** | решение владельца: «предупреждения делать из реестра» |
| **Связанные** | фича 460 (реестр контракта в приложении), фича 480 (движок-маппер), §474 (страж текстов реестра), §320 (`ech_ignored`), §303 (`ws_early_data_converted`), D-105 (`naive_extra_headers_invalid`) |

## Проблема

`NodeWarning.byCode` — единственное место, где код реестра превращается в
предупреждение узла. Почти для всех кодов ответ один: `RegistryWarning` с
текстом из `contract/registry/warnings.json`. Шесть кодов из этого правила
выпадали и получали рукописный класс с текстом в коде приложения.

Текст в коде — вторая таблица рядом с нормативной. Она не обязана совпадать с
реестром и расходится с ним молча: правка у лаунчера доезжает до Go и не
доезжает до нас. Заодно такой класс тянет за собой строку в словарях всех
языков, свою `severity` константой и запись в `kWarningCodes`.

## Решение

Четыре кода переведены на реестр, два оставлены.

| Код | Было | Стало |
|---|---|---|
| `ech_ignored` | `EchIgnoredWarning` | `RegistryWarning`, `params: {query_name: <имя параметра>}` |
| `ws_early_data_converted` | `WsEarlyDataConvertedWarning` | `RegistryWarning`, `params: {max_early_data: <значение>}` |
| `naive_padding_ignored` | `NaivePaddingIgnoredWarning` | `RegistryWarning` без своих `params` |
| `naive_extra_headers_invalid` | `NaiveExtraHeadersInvalidWarning` | `RegistryWarning`, `params: {entry: <пара>}` |
| `awg_header_invalid` | `AwgHeaderInvalidWarning` | без изменений |
| `awg3_field_invalid` | `Awg3FieldInvalidWarning` | без изменений |

### Почему два кода AWG остаются

Текст реестра у них называет поле и значение (`{field}`, `{value}`), но не
объясняет последствия: «ядро откатится на обычный заголовок WireGuard, и
рукопожатие может не сойтись» в шаблоне не выражено. Запись реестра даёт
«AmneziaWG: field h1 removed» — человеку этого мало. Переводить их нужно
вместе с правкой текстов у лаунчера, и комментарий в `byCode` теперь говорит
именно это.

### Именованные параметры

Тексты реестра подставляют `{path}` и `{value}` всегда
(`text_params_implicit`), остальное — под именем, которое код объявил в
`params`. Движок-маппер знает о предупреждении ровно путь и значение: записи
секции называют `on_present`/`on_invalid` одной строкой-кодом. Перекладывание
«путь/значение → именованный параметр» живёт в `byCode`, рядом со списком
исключений, и в него попадает только код, чей текст зовёт своё имя.

`query_name` у `ech_ignored` — **имя параметра ссылки** (`ech`), а не значение:
так решил лаунчер (контракт 1.1.15, ответ на сверку `TASKS_LXBOX §24.26` п. 4),
и запись `tls.blocks.uri.ech` объявляет ровно это.

### Severity

У всех четырёх кодов реестр объявляет `info` — тот же уровень, что был у
снятых классов. Расхождений нет.

### Хранение

Миграции не потребовалось. `NodeSpec.warnings` не персистится вовсе — узел
разбирается заново при каждой загрузке (`parse_all.dart`). Хранимая форма
одна, `StoredWarning` (`models/core_reject_verdict.dart`), и она с самого
начала описана кодом и `params`, а не типом класса; кладётся в неё только
вердикт `core_rejected` (CANON §9.4). Узел, сохранённый до этой задачи,
читается без изменений, и повторный разбор даёт то же одно предупреждение:
дедуп в `parse_warnings.dart` идёт по паре `(code, path)`.

## Что изменилось

- `app/lib/models/node_warning.dart` — четыре класса сняты, `byCode` отдаёт
  `RegistryWarning` с именованными параметрами.
- `app/lib/services/contract/warning_codes.dart` — четыре записи убраны из
  `kWarningCodes`.
- `app/lib/services/parser/transport.dart`,
  `app/lib/services/parser/uri_parsers/naive_parser.dart` — производители
  зовут `NodeWarning.byCode`. Обе функции вне рабочего пути: `warnEchIgnored`
  и `parseTransport` в `lib/` больше никто не зовёт (коды ставит движок
  реестра), их держат тесты.
- `app/assets/l10n/{ru,zh}/ui.json` — четыре ключа сняты, больше нигде не
  используются. Все четыре чекера `tool/l10n` зелёные.
- Тесты: проверки идут по коду, а не по классу
  (`ech_import_test`, `uri_naive_test`, `naive_pipeline_invariants_test`,
  `mapper_rules_coverage_test`, `node_warning_test`). Добавлено два стража —
  `byCode` заполняет объявленные параметры (`node_warning_test`), и реестр
  держит для этих кодов `info` с тем же именем параметра
  (`warning_text_render_test`).

Снимки identity/golden/emit не трогались: предупреждения в них по коду.

## Проверено

- `flutter analyze` (весь проект) — чисто.
- `flutter test` по затронутым файлам — зелено.
- Восемь красных кейсов `contract_test.dart` (`naive/empty_host_rejected`,
  `naive/unknown_query_ignored`, `trojan/echfq_not_read`,
  `vless/reality_tcp_no_flow`, четыре `wireguard/*`) — **до** этой задачи и
  после неё одни и те же: корпус лаунчера впереди `develop`.
