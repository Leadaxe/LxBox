[English](balancing.md) · [Русский](balancing.ru.md)

# Автовыбор и балансировка — самый быстрый узел или нагрузка по пулу

Направление, папка или подписка могут использовать группу `urltest`, которая
держит самый быстрый узел либо раскидывает соединения round-robin по пулу
живых узлов.

| Поле | Значение |
|------|----------|
| Фича | [006-DETOUR_AND_BALANCE](../FEATURE.ru.md) |
| Обещания | P13 P14 |
| Состояние | ✅ написана по коду, 2026-09-28 |

## Что делает

Распределяет трафик между несколькими узлами вместо одного выбранного.
Три носителя одной формы автовыбора:

| Носитель | Где включается | Что в конфиге |
|---|---|---|
| Двойник Направления | редактор Направления → «Include auto (urltest)» | `urltest` `<tag>-auto` по узлам Направления; первый и умолчанием в селекторе, если Default (regex) ничего не выбрал |
| Узел автовыбора | папка → «Add auto node…»; импорт Xray `balancers` | `urltest` (Fastest/Load balance) или `selector` с `default` (Manual) из членов своего контейнера |
| Свёртка источника | подписка/папка → «Replace with a group» | Manual → `selector`; Auto → `urltest`; Both → `<tag>-auto` + `selector` |

Load Balance (бывший план отдельного outbound'а `loadbalance`) —
режим `round_robin` штатного `urltest` форка ядра.

## Параметры

| Ручка | Значения | Умолчание | Ключ ядра |
|---|---|---|---|
| Mode | Fastest («single best server by latency») · Load balance («spread connections across a pool of servers») · Hold until failure («keep the fastest server until it fails») · Manual (узел автовыбора, свёртка) | Hold until failure у новой группы и автовыбора Направления; запись без `mode` читается Fastest | `mode: round_robin` у Load balance, `mode: failover` у Hold until failure; Fastest `mode` не пишет |
| Pool size | ≥1 | 3 | `balancer.pool` |
| Pool tolerance (ms) | 0 = держать весь живой пул; >0 — отбор лучших; у узла автовыбора ≤15000 | 0 | `balancer.pool_tolerance` |
| Sticky session by | process · domain · source ip · dest ip · dest port; пусто = «no stickiness» | process + domain | `balancer.sticky_hash`, пусто → `["none"]` |
| Test URL / Interval / Tolerance / Idle timeout | — | `https://cp.cloudflare.com/generate_204` / 15m / 50 / 30m | `url`, `interval`, `tolerance`, `idle_timeout` |
| Interrupt connections on switch | вкл/выкл | выкл | `interrupt_exist_connections` |
| Узел автовыбора: Members | All · Rule (Include/Exclude regex по тегу и синонимам) · Pick (галочки) | All | `outbounds` |
| Узел автовыбора: Badge in list (regex) | значок пула | первый флаг-эмодзи | — |

`passive_check` больше не пишется: ядро v1.14.2-lx.12 удалило ключ
([611](../../../tasks/611-drop-passive-check-kernel-lx12.md)); замена — режим
Hold until failure (`failover`, [612](../../../tasks/612-contract-1-1-113-failover.md)):
самый быстрый на момент выбора узел держится до своего отказа, и каждый
interval пробуется только он. Задержки остальных членов стареют; ручной тест
группы перевыбирает самого быстрого. При первом запуске после обновления
группы в Fastest становятся Hold until failure, если пассивная проверка не
была выключена.

## Входы / Выходы

**Входы:** узлы Направления / контейнера; Xray `routing.balancers` и
`burstObservatory`; глобальные настройки пинга.
**Выходы:** группы в конфиге; метка в списке узлов `🎯 [N]` (Fastest) /
`🔀 [N/pool]` (Load balance) / `📌 [N]` (Hold until failure); живой пул
работающего ядра («connect to see the live pool»).

## Правила и инварианты

- `balancer{}` пишется только при Load balance: ядро отвергает `balancer`
  без `round_robin` и плоские `pool` (P13). `failover` пишется без
  `balancer` и без `tolerance`, даже если tolerance задан у Направления
  (контракт 1.1.111); поле Tolerance при нём скрыто.
- Пустой `urltest` не эмитится: двойник Направления без узлов, узел
  автовыбора с пустым пулом (явный состав без единого члена — с
  предупреждением «Auto node "…" was skipped…»), свёртка без узлов —
  код `replace_group_empty` (P14).
- Узел автовыбора: в пул — только узлы своего контейнера, не другие
  группы; в селектор Направления попадает, в `<tag>-auto` — нет (urltest
  внутри urltest мерил бы чужой выбор). Члены выключенные или пропавшие
  отсекаются с кодом `group_member_dropped`.
- Импорт Xray: `random`/`roundRobin`/`leastLoad` c `expected>1` →
  Load balance; `leastPing` или `expected≤1` → Fastest; `expected` →
  pool, `maxRTT` → pool_tolerance; `selector` → include-правило
  `^(…)`; `pingConfig` → url/interval; битые формы не роняют разбор.
- `interval` больше `idle_timeout` → `idle_timeout` поднимается до
  `interval` (ядро иначе не стартует).
- Тег свёртки, совпавший с Направлением, — `replace_tag_conflict`,
  источник не свёрнут.
- Группа — не detour-цель и без собственного detour (P12, см.
  [node-detour.md](node-detour.ru.md)).

## Границы

- Выбор узла внутри группы и показ пула на главном — [007-NODE_LIST](../../007-NODE_LIST/FEATURE.ru.md).
- Замеры и их настройки — [009-NODE_HEALTH](../../009-NODE_HEALTH/FEATURE.ru.md).
- Отдельного `loadbalance`-outbound'а и стратегий вне `sticky_hash` нет.

## Ревизии

| # | Ревизия | Статус | Суть |
|---|---|---|---|
| 1 | [024F](../../../tasks/024F-load-balance/spec.md) | Реализовано другим путём | Load Balance как `round_robin` |
| 2 | [208](../../../tasks/208-urltest-balancer-round-robin.md) | РЕАЛИЗОВАНО | Режим, `balancer{}`, просмотр пула |
| 3 | [210](../../../tasks/210-libbox-rc15-sticky-none.md) | РЕАЛИЗОВАНО | Пустая липкость → `["none"]` |
| 4 | [272](../../../tasks/272-idle-suspend-urltest-energy.md) | РЕАЛИЗОВАНО | Interval 15m, `passive_check` |
| 5 | [322F](../../../tasks/322F-balancer-node/spec.md) | DEVICE-VERIFIED | Узел автовыбора, импорт Xray `balancers` |
| 6 | [344](../../../tasks/344-outbound-view-balancer-modes.md) | DEVICE-VERIFIED | Окно узла различает пул и быстрейший |
| 7 | [442](../../../tasks/442-urltest-interval-idle-pair.md) | Released v2.24.0 | `idle_timeout` поднимается до `interval` |
| 8 | [565F](../../../tasks/565F-selector-group-genus/spec.md) | Фаза A влита | Ручной род (`selector`) узла автовыбора |
| 9 | [568](../../../tasks/568-source-replace-fold.md) | Реализовано | «Replace with a group» у папки и подписки |
| 10 | [611](../../../tasks/611-drop-passive-check-kernel-lx12.md) | Реализовано | `passive_check` снят (ядро lx.12) |
| 11 | [612](../../../tasks/612-contract-1-1-113-failover.md) | Реализовано | Hold until failure (`failover`), миграция от `passive_check` |
