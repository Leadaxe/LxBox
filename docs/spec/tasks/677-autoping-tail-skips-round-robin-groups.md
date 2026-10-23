# 677 — Хвост автопинга не делает force-URLTest групп `round_robin`

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата начала | 2026-10-23 |
| Дата конца | — |
| Коммиты | см. `git log --grep 677` |
| Связанные спеки | [308](308-group-urltest-after-mass-ping.md) — групповой URLTest после массового пинга; [208](208-urltest-balancer-round-robin.md) — балансировщик; [features/006-DETOUR_AND_BALANCE/FUNCTIONS/balancing.md](../features/006-DETOUR_AND_BALANCE/FUNCTIONS/balancing.md); [features/009-NODE_HEALTH](../features/009-NODE_HEALTH/FEATURE.md) (ping on start, urltest-group) |

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

## Проверка

- Unit: `_runAllUrltestGroups` с группами `least_test`, `round_robin`,
  `failover` → вызов `ccUrlTestGroup` только для не-`round_robin` (мок канала,
  как в соседних тестах `ping_orchestration`).
- Ручная (владелец): направление Load balance, pool 3, tolerance 0, ≥10 узлов,
  Auto ping on start включена → после подключения в журнале ядра один URLTest
  по трём узлам, а не по всем; задержки в списке есть (от пинга по узлам).

## Открытые вопросы

- `failover`: по той же логике force-хвост ломает «hold until failure»
  (перевыбор самого быстрого). В эту задачу не входит, решение владельца
  отдельно.
