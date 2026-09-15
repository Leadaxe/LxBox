# 442 — urltest: `interval` больше `idle_timeout` роняет старт ядра

| Поле | Значение |
|------|----------|
| Статус | Done. Device-verify не проводился: проверка ядра живёт в конструкторе группы, эталон лаунчера подтвердил «до FATAL / после стартует» на ядре 1.14.0-lx.33 |
| Дата | 2026-09-15 |
| Коммиты | `fix(442)` 57d1051f — правило и хелпер; `test(442)` 92d436aa; `feat(442)` eb6ccc25 — подсказка в редакторе Направления; `docs(442)` — эта таска, CHANGELOG |
| Норма | SPEC 128 лаунчера — [`128-B-C-URLTEST_INTERVAL_PAIR/SPEC.md`](../../../../singbox-launcher/SPECS/128-B-C-URLTEST_INTERVAL_PAIR/SPEC.md), эталон `core/build/outbound_graph_urltest.go` |
| Связанные | [§393](../features/393%20directions/spec.md) A4 (графовый санитайзер), [§208](208-urltest-balancer-round-robin.md) (round_robin), [§322](../features/322%20balancer-node/spec.md) (Xray-балансер) |

## Проблема

Ядро (`protocol/group/urltest.go`, `NewURLTestGroup`) подставляет нулевым
`interval` и `idle_timeout` умолчания 3m и 30m, затем падает на
`interval must be less or equal than idle_timeout`. Проверка в конструкторе
группы, поэтому `sing-box check` конфиг принимает, а `run` — нет: VPN не
поднимается. `round_robin` форка lx идёт тем же `Start()` → `NewURLTestGroup`,
балансировщик цепляется после проверки (сверено по `sing-box-lx` v1.14.0-lx.39).

Входы LxBox, где пара расходится:

| Вход | Место | Что происходит |
|---|---|---|
| Xray-балансер | `parser/json_parsers.dart` `_xrayAutoSelect` | `interval` из `burstObservatory.pingConfig`, `idle_timeout` всегда 30m: `3h` у провайдера = фатал |
| Группа sing-box подписки / вставки | `parser/singbox_config.dart` `_groupToSpec` | `interval` переносится, отсутствующий `idle_timeout` становится 30m |
| Направление | `models/direction.dart` `DirectionAuto`, редактор | поля независимы; редактор только предупреждал, сохранить можно |
| Узел автовыбора | `models/auto_select.dart` `AutoSelectParams` | поля независимы |

## Решения владельца (15.09.2026)

- Поднимать `idle_timeout` до `interval` (×1). `interval` не менять никогда:
  это частота проб всех узлов группы, замена `3h` на `5m` — в 36 раз больше
  нагрузки на провайдера.
- Правило в одной точке — финальном графовом санитайзере сборки.
- Валидные пары байт-в-байт. Нераспознанный `interval` не подменять.
  `selector` не трогать. Каждое вмешательство — warning с обеими величинами.
- Длительности по правилам ядра, включая `d`.
- Редактор Направления: красное предупреждение заменить серой подсказкой
  «Idle timeout will be raised to %s when the config is built».

## Решение

- `app/lib/services/core_duration.dart` — `parseCoreDurationNanos`, порт
  `sing/common/json/badoption/internal/my_time.ParseDuration`: `d`, дроби,
  составные записи, отказ на пробелах, числе без единицы и переполнении.
  Готового общего разбора в проекте не было: `_goDurationMs` (Xray `maxRTT`),
  `_parseReloadInterval` (подписки) и парсер редактора — регэкспы под свои
  форматы.
- `app/lib/services/builder/post_steps/sanitize_urltest_timings.dart` —
  правило 8 санитайзера, вызов из `sanitizeOutboundGraph` одним проходом по
  выжившим записям после фикспойнта. Отсутствие ключа и `0` — умолчание ядра;
  не строка, мусор и отрицательные значения — не трогаются.
- Строка в `docs/GUARDS.md` §4.1.
- Редактор Направления (`direction_edit_screen.dart`): подсказка вместо
  предупреждения, условие считается тем же хелпером по значениям, которые
  уйдут в хранение (пустое поле — умолчание формы `5m`/`30m`).

### Расхождения с эталоном лаунчера

| Случай | Лаунчер | LxBox |
|---|---|---|
| `interval` нет, `idle_timeout` меньше 3m (`1m`) | не трогает — ядро падает | `idle_timeout` → `3m` |
| `idle_timeout: "0"`, `interval: "1h"` | не трогает (`idle <= 0`) — ядро берёт 30m и падает | `idle_timeout` → `1h` |
| Пробелы вокруг значения | `TrimSpace`, затем разбор | как ядро: ` 1h` не распознан, не трогается |

Первые две строки — тот же класс фатала, что и основной случай. Лаунчеру
предложить выровнять.

## Верификация

- `test/builder/urltest_interval_idle_pair_test.dart`: разбор (`1d`, `1d12h`,
  `0.5d`, отказы ядра); ветки правила — поднятие без и с `idle_timeout`, `1d`,
  умолчание `interval`, `round_robin`; байт-в-байт для короткого `interval`
  и сходящейся пары; мусор; `selector`. Сквозные сборки: Xray-балансер
  `interval: 3h` → `idle_timeout: 3h` и warning; группа sing-box `1d` → `1d`;
  Направление из хранения `2h`/`30m` → `2h`.
- `test/screens/direction_edit_idle_raise_hint_test.dart`: показ подсказки.
- Golden `test/storage_migration/`: расходящихся пар в фикстурах нет
  (`avd_v0`, `rich_v0`: 5m–15m при 30m), эталоны не менялись.
- `flutter analyze` 0; полный `flutter test` — 4644 passed, 14 skipped, 0 failed; `ui_check`, `hardcoded_check`, `template_check`, `parity_check` (--strict) — 0.

## Нерешённое

- `idle_timeout` в редакторе узла автовыбора (`auto_group_edit_screen.dart`)
  без подсказки — санитайзер лечит и там, UI не трогался.
