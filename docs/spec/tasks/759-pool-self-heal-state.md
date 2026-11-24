# 759 — состояние самовосстановления пула `round_robin` на экране

| | |
|---|---|
| **Статус** | In progress — Dart-часть в develop (6a02ad80, 38dbfae4); Kotlin-коммит в ветке `claude/759-pool-self-heal-state`, ждёт релиза ядра с `GetPoolState` и поднятия пина; на устройстве не проверено |
| **Дата** | 2026-11-25 |
| **Повод** | Ядро sing-box-lx получило самовосстановление группы `urltest` в режиме `round_robin` (SPEC 138 §3) и отдаёт его состояние через выдачу пула |
| **Связанные** | 208 (пул round_robin, View pool), 209 (unary RPC через pingClient), 344 (экран группы), 322 (узел автовыбора); ядро: SPEC 138 §3.9, SPEC 019 v2 |

## Docs to update

- `docs/api/debug-api-reference.md` — `/pool`.
- `docs/USER_GUIDE.md` / `.ru.md` — строка Load balance.
- `CHANGELOG.md`.
- `docs/KERNEL.md` — при поднятии пина (не в этой задаче).

## Problem

Группа `round_robin` в ядре при отказе соединения повторяет его через
следующий слот, проверяет узлы, заменяет мёртвый узел, сдвигает ключ
закрепления, выводит в карантин узел, который рвёт соединения, и замирает,
когда легла своя сеть. В приложении этого не видно: View pool показывает
только слот, узел и задержку.

У узла в карантине задержка не нулевая (история пробы не стирается), а
приложение считает неживым только слот с `delay == 0`. Карантинный узел
выглядит рабочим.

Профайлер трафика записывает цепочку соединения один раз, при открытии.
Ядро теперь повторяет событие «новое соединение» с тем же id, когда
`round_robin` выбрал узел или сменил его после повтора. Первое событие
уходит до выбора и несёт только группу — фактический узел в запись не
попадает.

## Diagnosis

- Путь пула: `BoxCommandClient.getPool` (Kotlin, `client.getPool`) →
  метод канала `ccGetPool` → `CcChannel.getPool` → `CcPoolSlot` →
  `HomeController.getPool` / `poolSlots` → попап `pool_view_dialog.dart`,
  раздел пула в `outbound_view_screen.dart`, значки в списке узлов,
  Debug API `/pool`. Нативная часть есть только на Android.
- Ядро (ветка `lx-spec138-rr-self-heal`): `CommandClient.GetPoolState(tag)`
  → `PoolState { ShiftedKeys, MarkedKeys, Frozen, FrozenSeconds, Slots() }`;
  у `PoolSlot` добавлены `Quarantined`, `Connections`, `ConfirmedFailures`.
  Прежний `GetPool` сохранён. Вне `round_robin` всё нулевое.
- Соединения в Dart приходят снимком аккумулятора libbox
  (`Connections.ApplyEvents`): повторное NEW заменяет запись целиком, так
  что Dart видит то же соединение с новой цепочкой. Нативную часть для
  профайлера менять не нужно.
- Профайлер: в ветке «соединение уже известно» обновлялись только байты;
  `chains`, `detours`, `outboundType` в `_ConnSnapshot` были `final`.
- Пин ядра `v1.14.4-lx.36` метода `GetPoolState` не содержит: вызов из
  Kotlin с текущим AAR не компилируется.

## Solution

**Модель и канал (`lib/vpn/cc_channel*`).**

- `CcPoolSlot` — поля `quarantined`, `connections`, `confirmedFailures`,
  по умолчанию нулевые. `alive` по-прежнему `delay > 0`; карантин —
  отдельный признак.
- `CcPoolState` — `slots`, `shiftedKeys`, `markedKeys`, `frozen`,
  `frozenSeconds`, `hasSelfHealState`. `fromWire` принимает две формы ответа
  канала: список слотов (нативная часть на ядре без `GetPoolState`) и карту
  `{slots, shiftedKeys, markedKeys, frozen, frozenSeconds}`.
- `CcChannel.getPoolState(tag)`; `getPool` оставлен и берёт слоты из него.
  Метод канала один — `ccGetPool`. Контракт §209 (`null` — клиент
  недоступен, пустой пул — не ошибка) не меняется.
- `HomeController.getPoolState`; `getPool` и кэш значков списка не тронуты.

**Нативная часть (`BoxCommandClient.getPool`).** Вызывает
`client.getPoolState(tag)` и отдаёт карту. Отдельным коммитом: собирается
только с ядром, где метод есть.

**Экран.**

- Строка слота (`poolSlotRow`, общая для View pool и экрана группы): под
  именем узла вторая строка вторичным текстом — `quarantine` (цветом ошибки)
  и `N conn · M fail`. Строки нет, когда узел не в карантине и
  оба счётчика нулевые. Задержка узла в карантине остаётся, но без цвета.
- Шапка пула (`poolStateHeader`): одна строка над слотами из ненулевых
  частей — `shifted keys: N`, `address problems: N`, `frozen for N s`;
  при `frozen` и `frozenSeconds == 0` — `frozen until the network check
  ends`. Все части нулевые — шапки нет.
- Здоровый пул, `least_test` / `failover` и ядро без новых полей выглядят
  как до задачи. Исключение: у работающего пула на новом ядре счётчик
  соединений ненулевой, вторая строка слота есть.
- Остаток заморозки — на момент запроса; обновляется кнопкой Refresh
  попапа и повторным открытием экрана. Таймера нет.
- Переводы — `assets/l10n/{ru,zh}/ui.json`, шесть строк.

**Debug API `/pool`.** Добавлены `shiftedKeys`, `markedKeys`, `frozen`,
`frozenSeconds` и у слота `quarantined`, `connections`,
`confirmedFailures`.

**Профайлер.** `chains`, `detours`, `outboundType` в `_ConnSnapshot`
обновляемые; ветка «соединение уже известно» записывает их из свежего
снимка. Событие закрытия (`tcpClose` / `udpClose`) несёт фактический узел.
Нового события при смене узла нет: запись открытия остаётся с цепочкой на
момент открытия.

## Risks and edge cases

- Нативная часть на старом ядре отдаёт список — `CcPoolState.fromWire`
  разбирает его в состояние с нулями. Проверено тестом.
- Счётчики слота ядро делит пополам на 256 соединениях: это не итог за всё
  время, подпись этого не обещает.
- Карантинный узел ядро заменяет в слоте, когда есть кандидат; отметка
  `quarantine` видна, пока замены нет.
- Значки пула в списке узлов (§322, §715) карантин не отмечают — в задаче
  только View pool и экран группы.

## Verification

- `test/vpn/cc_pool_slot_test.dart` — разбор новых полей слота, карта и
  список от нативной части, `null`.
- `test/widgets/pool_view_dialog_test.dart` — здоровый пул без шапки и
  вторых строк; карантин, счётчики, шапка; заморозка без остатка.
- `test/services/traffic_profiler_test.dart` — повторное NEW с тем же id:
  второй `tcpOpen` не появляется, `tcpClose` несёт последний узел и тип.
- `tool/l10n/ui_check.dart --strict`, `hardcoded_check.dart --strict`,
  `flutter analyze` по затронутым файлам — чисто (25.11).
- Не проверено: сборка Kotlin (нужен AAR с `GetPoolState`), экран на
  эмуляторе и телефоне с новым ядром.

## Unresolved / follow-up

При поднятии пина ядра на релиз с SPEC 138:

1. `app/android/libbox.version` — новый тег; `scripts/fetch-libbox.sh`
   сверит SHA256 сам.
2. `kCoreBuildTagsPin` в `lib/services/builder/core_chain_capability.dart`
   — тот же тег, даже при тех же тегах сборки (`node_core_gate_test`).
3. `javap` по `PoolState` / `PoolSlot` из AAR: имена геттеров против
   `BoxCommandClient.getPool` (`getPoolState`, `slots()`, `shiftedKeys`,
   `markedKeys`, `frozen`, `frozenSeconds`, `quarantined`, `connections`,
   `confirmedFailures`).
4. `docs/KERNEL.md` — пин и история версий.
5. Эмулятор: View pool у `round_robin`-группы под отказами узла.
