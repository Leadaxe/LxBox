# §204 — унификация Routing: Conns в стиле профайлера

> **СТАТУС: РЕАЛИЗОВАНО (28.06.2026).** Ветка `feat/conns-routing-unify-204`.
> 9 тестов эквивалентности (`cc_connection_routing_test.dart`), 1371 зелёный.

## Контекст

Вкладка **Profiler** (Statistics) недавно переделана/вычищена: единая
routing-строка §181 (`[net] proc ⇒ rule ⇒ группы : node → detour → dest`),
detail-sheet с секцией Routing = Route + Rule + Chain + Detour. Вкладка
**Conns** осталась на старом: routing разбит на куски `NETWORK · rule ·
duration` + отдельное `outbound`, а detail-sheet показывает Rule + Outbound +
Outbound type и **НЕ показывает Chain/Detour, хотя данные есть** в
`CcConnection.chains`/`detours`.

**Ключевой факт (разведка):** `CcConnection.chains` и
`TrafficEvent.outboundChain` приходят из ОДНОГО источника (Kotlin
`Connection.chain()`-итератор; профайлер копирует `c.chains` напрямую). Порядок
ИДЕНТИЧЕН (`[node, …selectors]`). detours/detourChain — тоже один источник
(`Connection.detour()`, `[node→наружу]`). Значит `routingLineOf` копируется в
`CcConnection` 1:1, **без reverse**.

## Скоуп (согласовано с юзером 28.06.2026)

Унифицируем **Routing-представление**, не весь ряд:

1. **Ряд Conns** — структуру НЕ переделываем (своя специфика). Заменяем нижнюю
   строку `NETWORK · rule · [closed] · duration` + отдельный `outbound` на
   **одну routing-строку** `conn.routingLineOf(compact: true)` (как ряд
   профайлера в live_view). Иконка/host/traffic/Close — без изменений.
2. **Detail-sheet делаем общим** для Routing-секции: Conns-detail получает ту же
   секцию, что профайлер — **Route** (§181) + **Rule** + **Chain**
   (`chains.join(' / ')`) + **Detour** (`detours.join(' → ')`). Выкидываем
   старые Rule/Outbound/Outbound type.
3. **Сохранить Conns-специфику рантайма:** кнопка **Close connection**, one-way
   banner (зависший стрим), live-трафик активного соединения. Профайлер их не
   имеет (история) — общий рендер Routing-секции их не трогает.
4. Остальные секции Conns-detail (App/Destination/Network/Traffic/Timing/ID)
   приводим к тому же визуальному рендеру, что профайлер (общий `_group`/row),
   но это вторично — главное Routing.
5. **DNS/Confidence/Issues** — у живого conn их нет → секции скрываются при
   пустых данных (как уже в профайлере). Это ОК (Conns = активное соединение,
   не DNS-событие).

НЕ трогаем: модели `CcConnection`/`TrafficEvent` (границы с ядром), аккумулятор
Conns (30с-история, _byId/_closedIds), кэш правил.

## Реализация

| Слой | Файл | Изменение |
|---|---|---|
| модель | `vpn/cc_channel.dart` `CcConnection` | + метод `routingLineOf({compact})` — копия логики `TrafficEvent.routingLineOf` (§181), поля: `network`/`rule`/`chains`(=outboundChain)/`detours`(=detourChain)/`domain`(или `destination` если domain пуст). Duration опускаем (для conn она в Timing/ряду) или считаем из createdAt — см. Решение D ниже. |
| общий рендер | новый `screens/stats_screen/routing_section.dart` (или в существующем shared) | helper `routingSection(context, {routeLine, rule, chain, detour, onCopy})` → List<Widget> секции Routing (Route/Rule/Chain/Detour). Зовётся обоими detail-sheet. |
| profiler detail | `stats_screen/traffic_event_detail_sheet.dart` | Routing-секцию (стр. 145-159) заменить вызовом общего `routingSection` (рефактор-без-изменения-вида). |
| conns detail | `connections_screen/connection_detail_sheet.dart` | Routing-секцию (стр. 181-188) заменить вызовом общего `routingSection` с данными conn. |
| conns ряд | `connections_screen.dart` `_buildTile` (стр. 374-384) | заменить `NETWORK · rule · duration`-строку на `conn.routingLineOf(compact:true)`. |

### routingLineOf на CcConnection — нотация (1:1 с TrafficEvent)

```
[net] ⇒ rule ⇒ группы : node → detour → dest
⇒ внутри (rule + селекторы сверху-вниз = chains[1:].reversed)
:  выход (node = chains[0])
→  снаружи (detours + dest)
compact=true → опускает [net]; начинает с rule (для ряда).
```

dest: `domain` (если есть), иначе host из `destination`. process НЕ включаем
(Conns не несёт process в routing-строку — у ряда своя app-строка).

## Открытые решения (нужен ок юзера)

- **D. Duration — фиксировано справа, НЕ в строке (РЕШЕНО юзером 28.06).**
  Таймеры важны, оставляем. Но `routingLineOf` для conn НЕ пишет хвост `· dur`
  (ни compact, ни в detail Route — там duration в секции Timing). В **ряду**
  duration рендерится ОТДЕЛЬНЫМ виджетом, прижатым к правому краю (как пинг в
  node_list §203): routing-строка слева (Expanded, ellipsis), duration справа
  фикс. — не дёргается при тиках, не уезжает в середину.
- **E. Детали 1:1 — обе секции идентичны (РЕШЕНО юзером 28.06).** Источник
  один: профайлер строит TrafficEvent ИЗ CcConnection (`c.chains`/`c.outbound`).
  Но `c.outboundType` сейчас ОТБРАСЫВАЕТСЯ при конвертации
  (traffic_profiler.dart ~933-962) — **НЕ отбрасывать**: добавить поле
  `TrafficEvent.outboundType` и заполнять из `c.outboundType`. Тогда Routing-
  секция ОДИНАКОВА в Conns и Profiler:
  **Route + Rule + Chain + Detour + Outbound + Outbound type**.
  - `Outbound` (узел) в обоих = `chains[0]`/`outboundChain[0]` (один источник).
  - `Outbound type` теперь есть в обоих (протащили в TrafficEvent).
  Общий `routingSection(...)` рендерит все 6 строк; пустые скрываются.

## Тесты

- `cc_channel` (или новый `cc_connection_routing_test.dart`): `routingLineOf`
  на CcConnection даёт строку, идентичную TrafficEvent.routingLineOf на тех же
  chains/detours/rule/network/domain (golden-сравнение нотации §181: с
  селекторами, с detour, прямой outbound, пустой rule→final).
- Widget-тест routing-секции — опционально (рендер тривиален).

## Связанные

- §181 (CHANGELOG) — нотация routing-строки `⇒ : →` (источник).
- §174/§178 — chains/detours от ядра (один источник для Conn и Event).
- §044 профайлер-редизайн — эталон detail-sheet.
