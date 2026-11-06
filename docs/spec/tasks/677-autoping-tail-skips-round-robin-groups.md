# 677 — Хвост автопинга не делает force-URLTest групп `round_robin`

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата начала | 2026-10-23 |
| Дата конца | 2026-10-23 |
| Коммиты | см. `git log --grep 677` |
| Связанные спеки | [308](308-group-urltest-wrong-rpc-no-reselect.md) — групповой URLTest после массового пинга; [208](208-urltest-balancer-round-robin.md) — балансировщик; [features/006-DETOUR_AND_BALANCE/FUNCTIONS/balancing.md](../features/006-DETOUR_AND_BALANCE/FUNCTIONS/balancing.md); [features/009-NODE_HEALTH](../features/009-NODE_HEALTH/FEATURE.md) (ping on start, urltest-group) |

## Проблема

GitHub issue #171 п.16: «is it intended that when load balancer is picked, the
first run still tests every node, even with pool size = 3 and pool tolerance = 0?»

Ядро ведёт себя по своей документации (`sing-box-lx/docs/configuration/outbound/urltest.md`,
раздел `balancer`): после старта `round_robin` с `pool_tolerance: 0` сажает в
пул первые `pool` узлов без тестов (`seedPool`, `urltest.go:449-458, 996-1033`),
затем тестирует только членов пула, остальные трогает лишь при дырках
(`balancePoolFirstLive`, `:822-922`). Upstream `tolerance`, которое LxBox пишет
рядом с `balancer`, даёт только предупреждение в лог (`urltest_balance_lx.go:64-66`).

Все узлы тестирует приложение. Галка «Auto ping on start» (по умолчанию
включена) через 5 с после подключения запускает `runMassUrltest` по каждому
узлу активной группы (`ping_orchestration.dart:218-233`), а в хвосте
`_runAllUrltestGroups` делает групповой **force**-URLTest по каждой
urltest-группе (`:386-411`, `cc_channel.dart:448` → `URLTest()` ядра →
`urlTest(ctx, true)`): ядро тестирует всех членов и пересобирает пул
(`rebuildPool`, `urltest.go:605-609`).

## Диагностика

Хвост §308 придуман для Fastest (`least_test`): после массового пинга группа
перевыбирает самый быстрый узел. Для `round_robin` с `pool_tolerance: 0`
задержка не ранжируется, force-тест всех членов ничем не помогает и сводит на
нет «дешёвый режим для больших списков», ради которого балансировщик делался
(§208). Для `round_robin` с `pool_tolerance > 0` ядро и так тестирует всех
каждый интервал, лишний force тоже не нужен. `failover` держит узел до отказа,
force-тест ему тоже чужой (по доке ядра ручной URLTest перевыбирает самый
быстрый, то есть ломает «hold»). Решение владельца 23.10.2026: хвост снимаем
для `round_robin`; про `failover` — см. «Открытые вопросы».

## Решение

- `_runAllUrltestGroups` (`ping_orchestration.dart`) пропускает группы с
  `mode: round_robin`. Режим группы брать из того, что уже знает приложение о
  составе конфига (`AutoSelectSpec`/запись направления с `balancer`), а не из
  ядра; если в орекестрации пинга такого знания нет — взять из собранного
  конфига (`lastEmitted*`, карта §675 `groupByEmittedTag` для узлов автовыбора,
  запись направления для `<tag>-auto`). Не делать новых RPC к ядру.
- Кнопка «Run URLTest» в меню группы, «спасение» при падении выбранного узла
  (`ping_orchestration.dart:101-110`) и automation (`handlers.dart:123,143`) —
  без изменений: там force осознанный.
- Массовый пинг по узлам для показа задержек не трогать: это дело галки «Auto
  ping on start», не балансировщика.

### Сделано

- `app/lib/controllers/home_controller/ping_orchestration.dart:401-434` —
  `_runAllUrltestGroups` собирает список тегов, пропуская группы с
  `activeModel[tag].raw['mode'] == 'round_robin'` (строка 413), с записью
  `Group URLTest skipped: <tag> (round_robin, core tests the pool)` в журнал.
  Режим — из `HomeState.activeModel` (§311): срез работающего конфига при
  живом туннеле, иначе собранный `configRaw`; оба уже лежат в state, RPC к ядру
  не добавлено. `mode: round_robin` эмитится всегда вместе с `balancer{}`
  (`AutoSelectSpec.toJson`, `source_replace_build.dart:166`), тот же признак
  режима, что у `autoModeOf` в `node_list_presenter.dart`. Комментарий хвоста —
  строка 396.
- `app/lib/controllers/home_controller.dart:779-783` — `debugSetCcGroups`
  (`@visibleForTesting`) для теста.
- «Спасение» (`_rescueGroupsSelecting`), `runGroupUrltest`, automation и UI не
  тронуты.
- Дополнение 23.10 (хвост только для `least_test`):
  `ping_orchestration.dart:401-440` — условие инвертировано (строка 416:
  `mode != null && mode != 'least_test'` → пропуск), строка журнала
  `Group URLTest skipped: <tag> (<mode>, …)` (строки 417-421: `round_robin` —
  «core tests the pool», `failover` — «no reselect outside failure»),
  комментарий — строки 396 и 404-411. Тест: `ccUrlTestGroup` ровно `['fast']`
  в обоих случаях. Доки: `balancing`, `node-ping`, `urltest-group` (EN+RU) —
  «только для Fastest (least_test)»; USER_GUIDE (EN+RU) — строка Hold until
  failure; 308 — «Семантика»; CHANGELOG `[Unreleased]` — строка 677.

## Документация (обязательная часть задачи)

Владелец: «убедись, что документация полна и актуальна по данному вопросу».
Сейчас по-русски описаны только поля, механизм — только в доке ядра на
английском. Дописать:

- `features/006-DETOUR_AND_BALANCE/FUNCTIONS/balancing.md` и `.ru.md`: абзац
  «Как заполняется и проверяется пул»: первые `pool` узлов без тестов → тесты
  только членов пула → остальные при дырках; `pool_tolerance > 0` — тестируются
  все, пул из самых быстрых с гистерезисом; ручной URLTest тестирует всех;
  автопинг на старте пингует все узлы для показа задержек, а групповой
  force-тест после него для `round_robin` не делается (§677). Ссылка на доку
  ядра `docs/configuration/outbound/urltest.md#balancer`.
- `features/009-NODE_HEALTH/FUNCTIONS/node-ping.md`/`.ru.md` (или где описан
  «ping on start» и хвост §308): исключение для `round_robin`.
- `docs/USER_GUIDE.md`/`.ru.md`, строка про Load balance: одно предложение про
  то, что проверяется только пул, а задержки всех узлов в списке — от автопинга.
- `docs/KERNEL.md`: если про первый прогон ничего нет — одна строка с
  ссылкой на доку ядра.
- `308-group-urltest-after-mass-ping.md`: пометка про исключение (§677).
- CHANGELOG `[Unreleased]`.

Сделано: `balancing.md`/`.ru.md` — подраздел «How the pool is filled and
checked» / «Как заполняется и проверяется пул» + ревизия 12; `node-ping.md`/
`.ru.md` — Outputs/Выходы и правило «No group test for Load balance after a
run» + ревизия 13; `urltest-group.md`/`.ru.md` — «Automatic reselection» +
ревизия 10; `USER_GUIDE.md`/`.ru.md` — строка Load balance; `KERNEL.md:635` —
«First run of a `round_robin` pool»; 308 — исключение в «Семантике»;
CHANGELOG `[Unreleased]` → Fixed. Факты сверены с ядром: `seedPool`
(`urltest.go:996-1033`, сначала узлы с историей по задержке, затем порядок
конфига), `balancePoolFirstLive` (`:822-922`), `balancePoolTolerant`
(`:925`), `URLTest()` (`:581-586`, force + `rebuildPool`).

## Проверка

- Unit: `_runAllUrltestGroups` с группами `least_test`, `round_robin`,
  `failover` → вызов `ccUrlTestGroup` только для не-`round_robin` (мок канала,
  как в соседних тестах `ping_orchestration`).
  Сделано: `app/test/controllers/mass_ping_group_tail_round_robin_test.dart` —
  `runMassUrltest` → хвост, `ccUrlTestGroup` ровно `['fast']` (до дополнения
  23.10 — `['fast', 'hold']`); два
  случая: режим из снапшота ядра и из собранного конфига (туннель без
  снапшота). All tests passed.
- Ручная (владелец): направление Load balance, pool 3, tolerance 0, ≥10 узлов,
  Auto ping on start включена → после подключения в журнале ядра один URLTest
  по трём узлам, а не по всем; задержки в списке есть (от пинга по узлам).


## Дополнение 23.10.2026 (решение владельца): хвост только для `least_test`

Анализ по `failover` («Hold until failure»): force-тест группы = ручной URLTest
по доке ядра = полный прогон и перевыбор самого быстрого, то есть смена
удерживаемого узла по причине, не связанной с отказом, — нарушение контракта
режима (§612). Пользы нет: перевыбор нужен только Fastest. Вред: лишний переезд
на старте с разрывом соединений и полный прогон всех узлов, дублирующий
только что сделанный массовый пинг. Отказ и деградация узла ядро ловит само
(тест удерживаемого каждый интервал, «path is dead», SPEC 126), историю
соседей для деградации даёт массовый пинг по узлам, который остаётся.

Решение: условие в `_runAllUrltestGroups` **инвертировать** — групповой
force-URLTest из хвоста автопинга/массового пинга вызывается только для групп
без `mode` или с `mode: least_test`; `round_robin` и `failover` пропускаются с
той же строкой в журнале (`Group URLTest skipped: <tag> (<mode>, …)`).
«Спасение» при падении выбранного узла, кнопка «Run URLTest» и automation —
без изменений. Тест `mass_ping_group_tail_round_robin_test.dart`: ожидание для
группы `hold` меняется на «не вызывается». Доки `balancing`, `node-ping`,
`urltest-group` (EN+RU), USER_GUIDE, спека 308 и CHANGELOG — формулировка
«кроме round_robin» → «только для Fastest (least_test)».

## Открытые вопросы

- `failover`: решено 23.10 — см. «Дополнение», входит в задачу.
