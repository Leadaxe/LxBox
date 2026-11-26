# 762 — Debug API: управление тестовым outbound `impair` на лету

| | |
|---|---|
| **Статус** | In progress — ветка `claude/762-debug-api-impair`, ждёт ядро `v1.14.4-lx.37-rc3`; Kotlin не собран |
| **Дата** | 2026-11-26 |
| **Повод** | Решение владельца 26.11: `impair` в интерфейсе не показывать, но управлять им из Debug API — для скриптовых тестов балансировки и отказов |
| **Связанные** | 208 / 209 / 759 (`/pool`, карантин пула), 613 (коды ошибок ядра `CcStatusError`), 750 (политика ассистента); ядро: SPEC 164, `docs-lx/lx-impair.md` (Keys, Sublinks, Schedule, Runtime control) |

## Docs to update

- `docs/api/debug-api-reference.md` — раздел `## Impair — /impair/*`, строка индекса.
- `app/lib/services/debug/handlers/help.dart` — три маршрута (текст и JSON);
  заодно устаревшее описание `/pool` (поля 759).
- `docs/KERNEL.md` — при бампе на rc3 (см. ниже), не в этой ветке.
- `CHANGELOG.md` (Unreleased).

## Problem

Ядро (SPEC 164) даёт тестовый outbound `impair`: задержки, потери, обрывы,
под-линии по сайту / порту / доле соединений, расписание. Для проверки
балансировщика (round_robin, карантин 759, failover) нужно менять линию узла
во время работы, не перезапуская ядро: перезапуск сбрасывает состояние групп.

Решение владельца:

- в интерфейсе `impair` нет: ни экрана, ни пункта меню, ни генератора, ни
  редактора, ни строк l10n;
- Debug API умеет управлять `impair`, который уже есть в работающем конфиге
  (вписан руками через `PUT /config` или миксином).

## Diagnosis

- Ручки ядра — три команды `StartedService`; в libbox пререлиза rc3 (сигнатуры
  прислало ядро, AAR ещё нет):
  `CommandClient.setImpair(tag, entry)`, `scheduleImpair(tag, entries, start,
  repeat)`, `getImpairStatus(tag)`, ответ — `ImpairStatus.getContent()`,
  JSON статуса `{"tag","link_params","counters","sublinks","schedule"}`.
- Ошибки ядра — gRPC-коды в тексте исключения gobind (`code = NotFound` и т. п.):
  NotFound (нет тега), InvalidArgument (не impair / неверный JSON; так же
  отвечает сборка без `with_lx_impair`), FailedPrecondition (сервис не запущен).
- В приложении тот же путь уже есть у `setEndpointEnabled`: `BoxCommandClient`
  разбирает код (`endpointToggleErrorCode`), `BgCcMethods` бросает
  `BgError(code, message)`, Dart получает `PlatformException.code` из
  `CcStatusError`.
- Пин сейчас `v1.14.4-lx.37-rc.2`; в его AAR методов нет, Kotlin этой ветки
  до бампа не компилируется.

## Solution

**Kotlin.**

- `BoxCommandClient`: `getImpairStatus`, `setImpair`, `scheduleImpair` через
  `ensurePingClient()`. Ответ в три состояния: `null` — клиента нет (туннель не
  поднят / пауза); `{"content": <JSON>}` — успех; `{"error": <код>, "message":
  <текст ядра>}` — отказ ядра. Код — `endpointToggleErrorCode` плюс
  `Unimplemented` → `unimplemented` (ядро без команд); общий разбор не
  меняется, чтобы не трогать `setEndpointEnabled`.
- `BgCcMethods`: `ccGetImpairStatus`, `ccSetImpair`, `ccScheduleImpair`. `null`
  отдаётся как есть (не `noClientError()`: тот превращает «нет клиента» в код
  `error`, и Dart не отличил бы его от сбоя ядра); ошибка — `BgError(код,
  текст)`; успех — строка `content`.
- `VpnPlugin`: три метода в списке долгих фоновых (`long = true`, рядом с
  `ccGetPool`) — блокирующий gRPC.

**Dart-канал** (`CcChannel`): `getImpairStatus(tag)`, `setImpair(tag,
entry)`, `scheduleImpair(tag, entries, {start, repeat})` →
`Map<String, dynamic>?`. `null` — клиент недоступен; иначе разобранный JSON
статуса без своей модели полей. Отказ ядра — `PlatformException` с кодом
`CcStatusError`, не глотается. Не-объект в `content` — `FormatException`.

**Debug API** (`handlers/impair.dart`, смонтирован как `/impair`):

| Маршрут | Тело | Ответ |
|---|---|---|
| `GET /impair/{tag}` | — | статус ядра как есть |
| `POST /impair/{tag}/set` | запись расписания без `at`: JSON-объект (`link_params`, `sublinks` или оба) | статус |
| `POST /impair/{tag}/schedule` | `{"entries": [...], "start": ""\|"now"\|"first_use", "repeat": ""\|"60s"}`; `entries: []` — стоп и сброс к конфигу | статус |

- Тег берётся из `uri.pathSegments` (уже раскодирован): тег с эмодзи или
  `/` передаётся URL-encoded.
- `set`: тело должно быть непустым JSON-объектом; в ядро уходит исходный текст
  тела без пересборки.
- `schedule`: `entries` обязателен и список (в ядро — `jsonEncode`); `start`
  и `repeat` необязательны, только строки, умолчание `""`. Значения не
  проверяются — это делает ядро.
- Ошибки: клиент недоступен (`null`) или нет нативного метода → 409
  `conflict`; `not_found` → 404; `invalid_argument` → 400;
  `failed_precondition`, `unavailable`, `unimplemented` → 409; прочее → 502
  `upstream_error`. Текст ядра — в `error.message`.
- Ассистент (§750): политика по умолчанию закрывает неизвестный префикс,
  `/impair/*` ему недоступен; закреплено тестом политики.

**Решения по умолчанию (приняты исполнителем, владелец не спрашивался).**

- Не-строковые `start` / `repeat` → 400; пустая строка = умолчание ядра.
- `set` с пустым телом или `{}` → 400 на стороне приложения (ядро `{}` тоже
  отвергает, но так ответ понятнее).
- `unimplemented` (ядро без команд) — 409, а не 501: отдельного класса ошибки
  в Debug API нет, а «повторить на другом ядре» ближе к pre-condition.
- Ответ `set` / `schedule` — статус ядра без обёртки, как `GET`.

## Шаги при бампе на rc3

1. `app/android/libbox.version` и `kCoreBuildTagsPin`
   (`app/lib/services/builder/core_chain_capability.dart`) → `v1.14.4-lx.37-rc3`
   (точное имя тега — по релизу ядра).
2. Релизный AAR: `javap -cp classes.jar io.nekohasekai.libbox.CommandClient
   io.nekohasekai.libbox.ImpairStatus` — три метода и `getContent()` с
   сигнатурами выше. Теги сборки AAR: `with_lx_impair` и `with_lx_command`
   (`cmd/internal/build_libbox/main.go`); без `with_lx_impair` любой вызов —
   InvalidArgument «not an impair outbound».
3. `docs/KERNEL.md` — пин, история версий, javap.
4. Проверить, что текст исключения gobind содержит `code = <Name>`: на нём
   держится разбор кодов 404 / 400 / 409.
5. Эмулятор (AVD `LxBox_a161`, CI `build-fast`): конфиг с round_robin из
   четырёх `impair` над узлами (рецепт ядра «Recipes for balancing tests»)
   через `PUT /config`; `GET /impair/{tag}` отдаёт статус;
   `POST /impair/{tag}/schedule` с `repeat: "2m"` и обрывом на 80 с —
   мигающий узел вычёркивается, возвращается и со второго вычёркивания уходит
   в карантин (`GET /pool` → `quarantined: true`); `entries: []` — линия
   снова по конфигу. Ошибки: неизвестный тег — 404, не-impair тег — 400,
   VPN выключен — 409.
6. Снять «не собрано» в статусе, влить ветку.

## Risks and edge cases

- Kotlin не компилируется до бампа пина: ветку нельзя вливать раньше AAR rc3.
- Код ошибки берётся из текста исключения; если gobind rc3 изменит формат,
  все отказы станут 502 с текстом ядра — функция не ломается, теряется
  только код.
- `impair` в конфиге приложение не создаёт и не показывает; узел `impair`,
  вписанный руками, в UI виден как обычный outbound в группах.

## Verification

- `test/services/debug/impair_handler_test.dart` — маршруты, тег с эмодзи,
  разбор тела, 400 на не-объект / не-список / не-строку, 409 при `null` и
  без плагина, проброс кодов ядра.
- `test/vpn/cc_impair_test.dart` — канал: аргументы, `null`, разбор JSON,
  `PlatformException` наружу.
- `test/services/debug/help_json_test.dart` — пути `/help` смонтированы,
  префикс `/impair` есть в JSON.
- `test/services/assistant/assistant_gateway_test.dart` — `/impair/*` закрыт.
- Kotlin не собран, на эмуляторе не проверено (ждёт rc3).

## Unresolved / follow-up

- Бамп на rc3 и проверка на эмуляторе (шаги выше).
