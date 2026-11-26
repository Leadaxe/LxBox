# 762 — Debug API: управление тестовым outbound `impair` на лету

| | |
|---|---|
| **Статус** | Done — в develop с пином `v1.14.4-lx.37-rc.3` (`58dae7a9`, CI зелёный на `8a4c8f99`); эмулятор проверен 26.11; на телефоне не проверено |
| **Дата** | 2026-11-26 |
| **Повод** | Решение владельца 26.11: `impair` в интерфейсе не показывать, но весь тест с ним вести скриптом через Debug API — создание узла, detour, линия на ходу, замеры, удаление |
| **Связанные** | 208 / 209 / 759 (`/pool`, карантин пула), 613 (коды ошибок ядра `CcStatusError`), 750 (политика ассистента); ядро: SPEC 164, `docs-lx/lx-impair.md` (Keys, Sublinks, Schedule, Runtime control) |

## Docs to update

- `docs/api/debug-api-reference.md` — раздел `## Impair — /impair/*` со
  сценарием, строка индекса, `PATCH /nodes/{tag}`, `tags` в ответе `POST /subs`.
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
  редактора, ни строк l10n; единственная пометка — подпись протокола в строке
  узла `☠ impair`;
- узел `impair` заводится как любой свой сервер (`POST /subs` с JSON
  outbound), тег не трогается (эмодзи по умолчанию не дописывается);
- весь тест — скриптом через Debug API: создать, поставить в путь трафика,
  менять линию на ходу, снимать замеры, снять, удалить.

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
- Создание: `POST /subs` с JSON outbound уже работает на rc2 (эмулятор 26.11):
  тип вне реестра из своего источника идёт в конфиг как есть
  (`UnknownTypeSpec`), но при создании получал эмодзи `⚡` (`_autoEmoji`), а
  ответ не называл итоговый тег — скрипту не на что ссылаться.
- Detour: у одиночного сервера — `override_detour` записи (`PATCH /subs/{id}`,
  по id), у члена папки — `detour` члена (`/folders/{id}/members/{idx}`, по
  индексу); по тегу узла маршрута не было. У узла подписки своего detour нет —
  только общий у подписки.
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

**Debug API: `/impair`** (`handlers/impair.dart`). Пути, тела и коды — один в
один с Debug API лаунчера (его спека 190-F-C-IMPAIR_DEBUG_API, develop
e16014bb); конверт ошибки свой, `{"error":{"code","message"}}`.

| Маршрут | Тело | Ответ |
|---|---|---|
| `GET /impair/{tag}` | — | статус ядра как есть |
| `POST /impair/{tag}/set` | запись расписания без `at`: JSON-объект (`link_params`, `sublinks` или оба) | статус |
| `POST /impair/{tag}/schedule` | `{"entries": [...], "start": ""\|"now"\|"first_use", "repeat": ""\|"60s"}`; `entries: []` — стоп и сброс к конфигу | статус |

- Тег берётся из `uri.pathSegments` (уже раскодирован): тег с эмодзи или
  `/` передаётся URL-encoded.
- `set`: тело — непустой JSON-объект; в ядро уходит компактным JSON.
- `schedule`: `entries` обязателен и список (в ядро — `jsonEncode`); `start`
  — `""` / `now` / `first_use`, иначе 400; `repeat` — строка как есть
  (значение проверяет ядро); оба необязательны, умолчание `""`.
- Ошибки: неверное тело → 400 до ядра; клиент недоступен (`null`) или нет
  нативного метода → 409 `conflict`; `not_found` → 404; `invalid_argument` →
  400; `failed_precondition`, `unavailable` → 409; `unimplemented` (ядро без
  ручки) → 501 `not_implemented` (новый класс `NotImplemented`); прочее → 502
  `upstream_error`. Текст ядра — в `error.message`.

**Узел `impair` скриптом.**

- `POST /subs` отдаёт `tags` — итоговые теги созданных узлов в конфиге:
  после сборки — ключ карты последней сборки (`lastEmittedTagMap`, по `id`
  узла), до сборки — `TagResolver.displayTag(префикс, тег)`.
- Тег `impair` не трогается: `keepsTagAsWritten` (`node_emoji.dart`) —
  `UnknownTypeSpec` с типом `impair`; `_autoEmoji` и `withDefaultEmoji` его
  пропускают. Прочие узлы получают эмодзи по-прежнему.
- `PATCH /nodes/{tag}` `{"detour": "<tag>" | {folder_id?, tag} | null}` —
  detour узла по тегу (как в конфиге или голый, URL-encoded), тем же путём,
  что экран узла: одиночный сервер — `override_detour` записи, член папки —
  `setMemberDetour` (self / цикл → 400). Узел подписки → 409 с подсказкой
  `PATCH /subs/{id}` (detour общий у подписки). Узла нет → 404. Ответ
  `{ok, tag, entry_id, kind, detour}`, `?rebuild=true`. Прочие методы на
  `/nodes/{tag}` — 404, как раньше.
- Подпись протокола в строке узла (`protoLabel`): `impair` → `☠ impair`.
- Ассистенту (§750) `/impair/*` и `PATCH /nodes/*` закрыты (политика по
  умолчанию), закреплено тестом.

**Решения по умолчанию (приняты исполнителем, владелец не спрашивался).**

- Не-строковый `repeat` → 400; пустая строка = умолчание ядра.
- `set` с пустым телом или `{}` → 400 на стороне приложения (ядро `{}` тоже
  отвергает).
- Ответ `set` / `schedule` — статус ядра без обёртки, как `GET`.
- `PATCH /nodes/{tag}` правит только detour; узел подписки не получает
  личного detour (модель хранения не менялась).

## Соответствие маршрутам лаунчера

Наши пути не переименовываются; для сценария — аналоги:

| Шаг | LxBox | Лаунчер |
|---|---|---|
| Создать узел | `POST /subs` `{"input": "<JSON outbound>"}` → `tags` | `POST /state/servers` |
| Detour узла | `PATCH /nodes/{tag}` `{"detour"}`; запись — `PATCH /subs/{id}` `override_detour` | `PATCH /state/servers?tag=` |
| Проба узла | `POST /action/urltest?tag=` | `POST /proxies/delay` |
| Пул | `GET /pool?tag=<направление>-auto` | `GET /pool?group=` |
| Конфиг узла | `GET /config/running` (весь), `GET /nodes/link?tag=` (ссылка) | `GET /outbounds/{tag}/config` |
| Линия impair | `GET /impair/{tag}`, `POST /impair/{tag}/set`, `POST /impair/{tag}/schedule` | те же |

## Сценарий

Полный скрипт с curl — `docs/api/debug-api-reference.md` → «Сценарий теста
целиком». Шаги и ожидаемые ответы:

1. `POST /subs` `{"input": "{\"type\":\"impair\",\"tag\":\"imp-test\",
   \"seed\":1,\"link_params\":{\"delay\":\"30ms\"}}"}` → 201 `{"id", "kind":
   "UserServer", "tags": ["imp-test"]}`; в конфиге outbound `imp-test` как
   передан. Ключ `detour` в самом JSON разбор отвергает («No valid outbounds»:
   ссылка на узел вне документа) — detour ставится отдельно:
   `PATCH /nodes/imp-test?rebuild=true` `{"detour": "⚡ Alpha"}` →
   `{"ok": true, "kind": "UserServer", "detour": {"tag": "⚡ Alpha"}}`; в
   конфиге у `imp-test` `detour: "⚡ Alpha"`. Impair над узлом видит домены и
   гасит одиночные сайты.
2. Либо impair под узлом: `PATCH /nodes/imp-test` `{"detour": null}`, затем
   `PATCH /nodes/⚡%20Alpha?rebuild=true` `{"detour": "imp-test"}` → в конфиге
   у Alpha `detour: "imp-test"`.
3. `POST /directions?rebuild=true` `{"tag": "imp-lab", "node_filter": "^imp-",
   "auto": {"mode": "round_robin", "balancer": {"pool": 3}}}` → 201;
   `POST /action/reload-vpn`; `GET /pool?tag=imp-lab-auto` → слоты.
4. `POST /impair/imp-test/schedule` `{"start": "now", "repeat": "2m",
   "entries": [{"at": "0s", "link_params": {"outage": false}}, {"at": "80s",
   "link_params": {"outage": true}}]}` → статус с `schedule.entries: 2`.
   `POST /impair/imp-test/set` `{"sublinks": [{"match": {"domain_suffix":
   "example.org"}, "link_params": {"outage": true, "reset": true}}]}` → статус.
5. Замеры: `GET /impair/imp-test` (линия, счётчики по направлениям,
   под-линии, раунд расписания); `GET /pool?tag=imp-lab-auto` (`delay`,
   `quarantined`, `confirmedFailures`, `shiftedKeys`, `frozen`);
   `POST /action/urltest?tag=imp-test` и `GET /state` (`delay_by_direction`,
   `last_delay`, `traffic`).
6. `POST /impair/imp-test/schedule` `{"entries": []}` → статус, линия по
   конфигу; `PATCH /nodes/⚡%20Alpha` `{"detour": null}` → `detour: null`;
   `DELETE /subs/{id}?rebuild=true` → `{"action": "subs-delete"}`.

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

- Тег в `tags` до сборки — расчётный; при совпадении тегов сборка разводит
  дубли, точный тег — после `?rebuild=true`.

- Kotlin не компилируется до бампа пина: ветку нельзя вливать раньше AAR rc3.
- Код ошибки берётся из текста исключения; если gobind rc3 изменит формат,
  все отказы станут 502 с текстом ядра — функция не ломается, теряется
  только код.
- `impair` в конфиге приложение не создаёт и не показывает; узел `impair`,
  вписанный руками, в UI виден как обычный outbound в группах.

## Verification

- `test/services/debug/impair_handler_test.dart` — маршруты, тег с эмодзи,
  компактный JSON `set`, 400 на не-объект / не-список / не-строку / чужой
  `start`, 409 при `null` и без плагина, коды ядра (501 на unimplemented).
- `test/services/debug/impair_node_scenario_test.dart` — `POST /subs` impair
  → тег `imp-test` в записи и в `tags`, обычный узел с эмодзи; `PATCH` и
  `DELETE /subs/{id}`; `PATCH /nodes/{tag}` у одиночного сервера (поставить,
  снять) и члена папки, 400 / 404; `protoLabel('impair')` = `☠ impair`.
  Сборкой (`generateConfig`): outbound `imp-test` с `link_params` и `seed`
  как переданы, detour impair → Alpha и Alpha → impair, impair без адреса
  входит в Направление и его `-auto` по `node_filter: "^imp-"`.
- `test/vpn/cc_impair_test.dart` — канал: аргументы, `null`, разбор JSON,
  `PlatformException` наружу.
- `test/services/debug/help_json_test.dart` — пути `/help` смонтированы,
  префикс `/impair` есть в JSON.
- `test/services/assistant/assistant_gateway_test.dart` — `/impair/*` и
  `PATCH /nodes/*` закрыты.
- Kotlin не собран, на эмуляторе не проверено (ждёт rc3).

### Эмулятор, ядро rc3 (26.11)

AVD `LxBox_a161`, CI build-fast `b897415d` (`libbox.so` — `1.14.4-lx.37-rc.3`), всё
скриптом через Debug API, без UI:
- `POST /subs` × 5 (`imp-1`…`imp-5`) → `tags` ровно как переданы, без префикса;
  `POST /directions` `imp-lab` (round_robin, пул 3, sticky по домену); правило
  `/rules` (тестовые домены → `imp-lab`) — без него трафик по умолчанию идёт в
  `vpn-1`.
- Коды: VPN выключен → 409, неизвестный тег → 404 (`NotFound`), не-impair
  (`imp-lab-auto`) → 400 (`InvalidArgument`), `entries` не массив / `start`
  вне трёх значений → 400 до ядра. Текст gobind содержит `code = <Name>` —
  разбор кодов подтверждён.
- `GET /impair/imp-1` — линия по направлениям, счётчики, подлинии с `matched`;
  `POST /impair/imp-2/set` (подлиния `share 50%`, `outage+reset`) и
  `POST /impair/imp-3/schedule` (круг 2 мин, обрыв на 80 с) → 200 со статусом.
  `reload-vpn` сбрасывает изменения на лету — их надо ставить заново.
- Карантин (не получен на rc2): с одними и теми же 20 сайтами `imp-2` набрал 2
  засчитанных отказа и 3 сдвига ключей — дальше новые соединения на него не шли.
  С новыми ключами каждый раунд (`r<N>x<i>.1.1.1.1.nip.io`) — 2 отказа на 4
  соединениях после первого раунда, затем `quarantined: true`, следующим шагом
  слот занял `imp-4` из запаса. `imp-3` по расписанию вычеркнут, слот занял `imp-4`.
- `PATCH /nodes/imp-d` `{"detour":"⚡ J1"}` → у `imp-d` `detour: ⚡ J1`;
  `PATCH /nodes/⚡%20J1` `{"detour":"imp-d"}` → у J1 `detour: imp-d`; `null` снимает.
- Сброс: `schedule {"entries":[]}`, `set {"sublinks":false}` → 200; удаление
  правила, Направления и узлов, `rebuild-config` — конфиг как до теста.
- Не сделано: снимок View pool в момент карантина (UI не входил в задачу);
  соединения по узлу через `/profiler/live` в этом прогоне не снимались.

## Unresolved / follow-up

- Бамп на rc3 и проверка на эмуляторе (шаги выше и сценарий).
- Соединения по узлу — профайлер: `POST /profiler/live/start`, затем
  `GET /profiler/live?seconds=N` — события `tcpOpen`/`tcpClose`/`udp*` с
  `outbound_chain` (фактический узел `round_robin` — задача 759), `up_bytes`,
  `down_bytes`, `duration_ms`, `issues` (обрыв); отбор по узлу — на стороне
  скрипта по `outbound_chain`. Серверного фильтра `?outbound=` нет — при
  нужде добавить.
- Личный detour узла подписки — модели нет (detour общий у подписки);
  обход — перенести узел в папку.
