# §592 — `/help` Debug API отстаёт от кода: догнать и закрепить тестом паритета

| Поле | Значение |
|------|----------|
| Тип | B (баг) |
| Статус | N (new) |
| Фича | [027-DEBUG_API](../features/027-DEBUG_API/FEATURE.ru.md), функция [debug-api](../features/027-DEBUG_API/FUNCTIONS/self-documentation.ru.md) |
| Дата | 2026-09-29 |
| Связанные | [`docs/api/debug-api-reference.md`](../../api/debug-api-reference.md) → «Синхронизация с `/help`» |

## Проблема

`GET /help` (text и `?format=json`) пишется руками в
`app/lib/services/debug/handlers/help.dart`; генератора из роутера нет. При
сверке `docs/api/debug-api-reference.md` с кодом (2026-09-29) нашлись места,
где `/help` отстал от хэндлеров: роуты есть в коде, но не в JSON-карте;
параметры и поля ответа описаны по-старому. Агенты и скрипты, которые строят
вызовы по `/help?format=json`, получают неполную или неверную карту.

Тест `app/test/services/debug/help_json_test.dart` проверяет только, что JSON
сериализуется, — на содержимое проверки нет.

## Что править в `handlers/help.dart`

### Пропуски в JSON-форме (`format=json`)

- `POST /settings/rebuild-config` — есть в text-форме и в
  `handlers/settings.dart` (alias `/action/rebuild-config`), в JSON нет.
- `GET /files/external` — legacy alias `/files/local`
  (`handlers/files.dart`); в JSON упомянут только в описании `/files/local`,
  отдельной записи нет.
- `POST /logs/clear` — параметр `source=app|core` есть в text-форме и в коде,
  в JSON `params` нет.
- `GET /files/oom` — в `file` перечислены `metadata.json|heap.pb|allocs.pb|go.log`;
  хэндлер отдаёт любой basename каталога снимка, в документе также
  `goroutine.pb`, `configuration.json`, `connections.json`. Дописать.
- Коды ошибок 413 (`payload_too_large`, тело больше `maxBodyBytes`), 502
  (`upstream_error`), 504 (`timeout`, handler не уложился в `requestTimeout`) —
  определены в `app/lib/services/debug/contract/errors.dart`, в `/help` их нет.

### Устаревшие описания

- `POST /subs/reorder` (text и JSON): «exactly the current ids» → элементы
  `order` — `source_key` общего списка (`id:<uuid>` / `chain:<tag>`, §524);
  голый uuid по-прежнему принимается (`handlers/subs.dart`, `_reorder`).
- `GET /subs`: «Alias /state/subs» неверно — `GET /subs` отдаёт общий список
  источников вместе с цепочками и полем `source_key`
  (`serializers/subs.dart`), а `/state/subs` — без цепочек.
- `/settings/enabled_groups`: снять «config-significant» — после §393 запись
  legacy, билдер читает её только при пустом `directions[]`; для GET/PUT
  указать «§125 legacy, фактически no-op», как в документе.
- `GET /subs/{id}?warnings=true`: в перечне полей предупреждения добавить
  `applied` (§577, `serializers/subs.dart`).
- Поля `skip_presets` (одиночный сервер и член папки, §578, read-only у члена)
  и `source_key` — упомянуть в описаниях `/subs` и `/folders`.
- `GET /diag/stderr` (text и JSON) и `/files/local`: «filesDir/stderr.log» →
  текущий краш-репорт ядра `CrashReport-lxbox.log` (через `StderrReader`,
  `app/lib/services/stderr_reader.dart`); `stderr.log` в белом списке
  `/files/local` — legacy, ядро после libbox 1.14 его не пишет.

### Вёрстка text-формы

- `POST /action/check-updates`: строки продолжения «Returns {kind, tag,
  html_url, …}» стоят после `POST /action/preview-empty-state` и читаются как
  его описание. Поставить `preview-empty-state` после блока `check-updates`.

## Тест паритета

Новый тест рядом с `app/test/services/debug/help_json_test.dart` (тот же
способ вызвать `helpHandler` с `format=json`):

- собрать все `path` из ответа `/help?format=json`;
- прочитать `docs/api/debug-api-reference.md` (путь от корня пакета `app/` —
  `../docs/api/debug-api-reference.md`);
- для каждого `path` проверить, что строка встречается в документе
  (с нормализацией плейсхолдеров `{id}`/`{tag}`/`{idx}` как есть — в документе
  те же обозначения); список отсутствующих — в `reason`.

Обратное направление (каждый путь документа есть в `/help`) не проверяется:
документ шире намеренно.

## Критерии приёмки

- Все пункты разделов «Пропуски» и «Устаревшие описания» отражены в JSON- и
  text-формах `/help`.
- Тест паритета зелёный; при удалении любой записи из документа или
  добавлении пути в `/help` без документа — красный.
- `help_json_test.dart` остаётся зелёным (JSON сериализуется, ключи — String).
- Поведение роутов не меняется: правка только `help.dart` и тестов.
- CI: `flutter analyze`, `flutter test test/services/debug/`.
