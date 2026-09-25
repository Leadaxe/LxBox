# 553 — реестр разворачивает все ссылки при загрузке, как лаунчер

| Поле | Значение |
|------|----------|
| Статус | Done (ветка `task-553`, в develop не влита) |
| Дата старта | 2026-09-25 |
| Дата завершения | 2026-09-25 |
| Коммиты | `8550d673` refactor(553) — именованные ссылки; `c0f7c84e` refactor(553) — объектные ссылки и варианты транспорта; `7f42cb9f` refactor(553) — снятие особых случаев; `89a1f6c4` perf(553) — `order` разбирается один раз; отчёт — этот коммит |
| Связанные spec'ы | §552 (follow-up), §549 (кеши схем), §547 фаза B (нормы 1.1.56), §472 шаг 5, §481 (`absent_when`) |

## Проблема

`ContractRegistry._expand` при загрузке разворачивал только `ref` с
`inline: true`. Остальные ссылки оставались обёрткой `{type: ref, ref: …}`:
у `server`/`server_port`/`network` (→ `dialer.common`) и у
`masque.network_list` (→ `dialer.common.network`) `required`, `on_invalid`,
`normalize` жили в суб-схеме, и читатель схемы их не видел. Отсюда дефект
§552 (`server: ""` проходил гард) и особые случаи в санитайзере и генераторе
тел. Попутно: `masque.network_list` не проверялся вовсе — `sharedSchema`
не знал ссылки `dialer.common.network`, и значение уходило как есть.

## Диагностика

Лаунчер делает разворот при загрузке:
`singbox-launcher/core/config/registry/registry.go`, `resolveSection`
(~:860–915) — три ветки; `refAsObject` (~:917), `resolveNamedRef` (~:974),
`mergeRefAttrs` (~:1000). Здесь повторена та же норма.

## Решение

`_expand` (`app/lib/services/contract/registry.dart`) на каждое поле `order`:

1. не `ref` — как есть;
2. `ref` + `inline` — поля суб-схемы вливаются на место слота, без дублей
   (как было);
3. ссылка с точкой на плоскую суб-схему (`dialer.common`,
   `dialer.common.network`) — `_resolveNamedRef`: явное имя из третьей части
   ссылки → собственное имя поля → единственное поле с тем же `desc_en`
   (неоднозначность — не разрешено). Поверх — `_mergeRefAttrs`: обёртка
   ужесточает `required`, задаёт `code`, `forbidden_for`, `allowed_for`,
   `forbidden_codes`; правила значения — только суб-схемы. Отличие от
   лаунчера: `desc_en`/`desc_ru`/`impl` берутся у обёртки (текст про поле
   этой схемы: у `masque.network_list` он объясняет, почему поле не
   `network`). На санитайзер описание не влияет;
4. прочие (`tls`, `multiplex`, `dialer`, `transports`) — поле-объект
   (`_refAsObject`): `order`+`fields` суб-схемы, атрибуты обёртки,
   `absent_when` суб-схемы (если у обёртки нет своего). `transports` —
   объект с `discriminator: type` и `variants` (`_transportsAsObject`).

У каждого развёрнутого поля — `origin_ref` (`FieldSchema.originRef`). Не
разрешённая ссылка остаётся обёрткой: загрузка не падает, санитайзер отдаёт
значение как есть (ветка `case 'ref'`), тест реестра её ловит.

`FieldSchema`: новые `originRef`, `discriminator`, `variants`; `fields` и
`order` разбираются один раз (`late final`) — санитайзер спускается в `tls` на
каждом узле.

Санитайзер (`body_sanitizer.dart`) читает только развёрнутую схему:

- снят `_flatDialerField` (§552);
- снят `_sanitizeRef` целиком: ветка `dialer.common` (имя поля из хвоста
  пути), спуск в объектную ссылку через `sharedSchema`, транспорт через
  `transportVariant`;
- `absent_when` читается с поля, без `sharedSchema`;
- объект с вариантами — `_sanitizeVariantObject` (вариант из поля);
  объектная ссылка идёт через `_sanitizeObjectField`.

Вызовов `sharedSchema`/`transportVariant` в санитайзере нет. Сами методы и
кеши §549 остались: их читают `registry_warning`, `_expand` и тесты.

Генератор тел (`test/contract/body_field_generator.dart`): ветки `type == ref`
в `_collectPaths`, `forbiddenByRegistry`, `_value` сняты, спуск — по `fields`
и `variants` поля. `_relationWhenHolds` (§552) не тронут.

### Инвентарь читателей схемы

| Читатель | Что было | Что стало |
|---|---|---|
| `body_sanitizer.dart` | `_flatDialerField`, `_sanitizeRef`, `absent_when` через `sharedSchema` | развёрнутая схема, см. выше |
| `body_field_generator.dart` `_collectPaths`/`forbiddenByRegistry`/`_value` | свой обход `ref` | `fields`/`variants` поля |
| `body_field_generator.dart` `run`, `_nestedConflictLosers`, `_BuildCtx._nestedRivals` | `transportVariant(t)` | без изменений: это перебор каталога транспортов для осей тел, не обход ссылки схемы |
| `registry_warning.dart` `registryFieldPathIsSecret` | `sharedSchema(...)` по имени листа | без изменений: ищет флаг `secret` по имени поля во всех схемах, ссылки не обходит |
| `registry_load_test.dart` | ждал обёрток `.ref == 'tls'` | ждёт развёрнутых полей, плюс три новых теста |

## Риски и edge cases

- **Граница §472 шаг 5.** Раньше объектная ссылка шла через `_sanitizeRef`,
  теперь через `_sanitizeObjectField`; норма та же: `dropObject` гасится до
  спуска, не хватило `required` внутри — снимается объект, узел живёт.
  Отличие одно — после спуска проверяется `dropNode` (раньше это делал цикл
  выше), на исход не влияет.
- **Семантика §547 фазы B** не менялась: пути (`tls.reality.…`,
  `transport.…`) и базовый объект при спуске — те же; `relation.when`,
  `absent_values`, пустая строка работают над тем же `src`.
- **`masque.network_list`** теперь судится правилом `network`
  (`trim_lower`, `values: [tcp, udp]`, `on_invalid: drop` с
  `type_invalid`). Это изменение поведения, которого требует норма: раньше
  мусор проходил в ядро. Красные списки от него не сдвинулись.
- Обёртка задаёт `required: true` у `tls` (hysteria/hysteria2/tuic/naive/
  anytls) — поле-объект это сохраняет.

## Верификация

Списки красных до (develop `bdf8cafb`) и после (`7f42cb9f`) — по именам и по
тексту отказов совпали:

| Файл | До | После |
|---|---|---|
| `contract_test.dart` | −5 | −5 |
| `body_contract_test.dart` | −25 | −25 |
| `probe_test.dart`, `body_sanitizer_test.dart`, `body_fields_roundtrip_test.dart` | зелёные | зелёные |
| `registry_load_test.dart` | 8 зелёных | 11 зелёных (+3 теста §553) |
| `LX_CORPUS_PUBLIC=1 test/public_subscriptions` | зелёный | зелёный |

Тест реестра: каждая ссылка бандла разрешена (обёрток `type: ref` в схемах
протоколов, во вложенных объектах и вариантах нет); `server` у всех схем
несёт `required`, `on_invalid: drop_node`, `format: host`;
`masque.network_list` — правило `network`; `hysteria2.tls` — `required: true`
от обёртки, у `vless.tls` — нет.

Бенч гарда (`LX_PERF=1 LX_PERF_RUNS=3`, мкс/узел, столбец «гард»): машина
сегодня медленнее замеров §549, поэтому база снята здесь же на develop:
§546 vless 45,5 → 35,4, смешанный 74,4 (шумный прогон) → 45,8. Медленнее
не стало. `dart analyze` по изменённым файлам — чисто.

## Нерешённое / follow-up

- `_BuildCtx._defaultEnumValue` генератора не спускается в варианты
  транспорта (`transport.mode`); так было и до §553, на тела не влияет.
- Редактор и подсказки UI развёрнутую схему пока не читают — потребителя нет.
