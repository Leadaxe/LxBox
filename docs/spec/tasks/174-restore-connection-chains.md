# §174 — Восстановить `chains` в CcConnection (ядро отдаёт через chain()-итератор)

**Тип:** bug-fix (потеря данных при §122-миграции)
**Статус:** Реализовано, device-verified (dev.62, паритет с Clash подтверждён)
**Связано:** §122 (CommandClient-миграция), §168 (профайлер), §044 (Live)

## Контекст (разбор ядра)

При §122 мы решили, что ядро «не кладёт chains в сериализацию», и заменили
Clash `chains` одиночными `outbound`/`outboundType`. Команда ядра разобрала путь
и показала: **chains ядро ОТДАЁТ** через gRPC (`chain_list` в proto), но на
клиенте достаётся **только методом-итератором `Connection.chain()`** (НЕ как
поле). Мы его не читали → цепочка `selector→urltest→node` терялась.

`rulePayload` — отдельная история: в Clash API он был **захардкожен `""`**
(`clashapi/connections.go:103`), содержательного значения не нёс никогда.
`adapter.Rule` умеет только `Type()/String()/Action()` — отдельного match-токена
ядро не материализует. `Connection.Rule` уже несёт `rule.String()` целиком.

## Корень

`BoxCommandClient.applyConnectionEvents` читал `getRule/getOutbound/...`, но
**не звал `c.chain()`** (AAR: метод `chain()` lowercase → `StringIterator`).
Профайлер вынужденно оборачивал `[c.outbound]` в одноэлементный список
(traffic_profiler.dart:948 «CC даёт один outbound — оборачиваем в список»).

## Решение

**Kotlin (BoxCommandClient.kt):** в connection-сериализации best-effort читаем
`c.chain()`-итератор в `ArrayList<String>`, кладём `"chains"` в map (рядом с
`outbound`). Итератор в `runCatching` (как `getProcessInfo`) — null-safe.

**Dart (cc_channel.dart):** `CcConnection.chains: List<String>` (+ в `fromMap`
из `m['chains']`). Комментарий-шапка «outbound — замена chains» исправлен.

**Профайлер (traffic_profiler.dart):** `chains = c.chains.isNotEmpty ? c.chains
: [c.outbound]` — реальная цепочка, fallback на outbound для прямых соединений.
`rulePayload` оставлен `''` (ядро: в Clash всегда `""`, `rule` уже несёт форму).

## Что НЕ делаем

- `rulePayload` как отдельный match-токен — нет в ядре, требовал бы правки
  upstream `adapter.Rule` + proto + сервер + клиент (ядро: отдельная SPEC, если
  понадобится). Сейчас `rule.String()` достаточно — `rulePayload=''` (паритет
  с Clash).

## Проверка (device)

Соединение **через группу** (selector→urltest→node) → `chains` из нескольких
звеньев в `/profiler/live` `outbound_chain`. Прямой outbound (`direct`) → пусто
или `[outbound]` (fallback). Юнит: профайлер-тест 33 зелёных, analyze чист.

**✅ DEVICE-VERIFIED (dev.62, ядро rc.5, 2026-06-26):** живой `/profiler/live`
отдаёт `outbound_chain: ["BL: ...[BL]-3", "vpn-1"]` = `[node, selector]` для conn
через группу; `["direct-out"]` для прямых; `[]` для DNS. Цепочка из ядра
доезжает до Dart — §174-механизм работает.

## detour НЕ входит в chain — это паритет с Clash, НЕ регрессия

Вопрос «почему не видно `… → Warp (detour)` в цепочке» возникает закономерно.
Ответ: **detour не входил в `chains` НИКОГДА** — ни в новом CommandClient, ни в
старом Clash API.

Сверка с фикстурой Clash до §122-выпила
([commit `2711f5b^`](../../../app/test/fixtures/clash_api/connections_sample.json),
снята с устройства):

```
Clash /connections (старое):  chains=["BL: 🇩🇪 …[BL]-4", "vpn-1"]  rule="final"
CommandClient (§174, сейчас): chains=["BL: 🌐 …[BL]-3",  "vpn-1"]  rule=…
                                       └─ ИДЕНТИЧНО: [node, selector] ─┘
```

**Почему detour отсутствует — это семантика, не баг.** `chains` ядра = граф
**маршрутизации** (как роутер выбрал outbound: `правило → selector → node`).
detour (`[BL]-3 → 🔥⛈️ WARP`) — это свойство **транспорта** самого outbound'а
(куда физически идёт пакет ПОСЛЕ выбора), а не решение роутера. Для `chain_list`
ядра это «внутренности» одного outbound'а, поэтому он туда не попадает.
Подтверждено: в config.json у `[BL]`-нод реально `detour='🔥⛈️ WARP (AWG 1.5)'`,
но `chain()` его не разворачивает.

Полная человекочитаемая цепочка `final → vpn-1 → France` собирается УЖЕ СЕЙЧАС
из `rule` (="final", отдельное поле) + `chains` (=[node, selector], развернуть).
Не хватает только detour-хвоста `→ Warp`.

## Показ detour-хвоста — НОВАЯ фича (НЕ долг §174)

Раз Clash detour тоже не показывал, добавление `→ Warp` — это улучшение СВЕРХ
исторического поведения, а не возврат потерянного. Два пути, оба отложены:

- **Вариант A (ждём ядро):** `Connection.chain()` в sing-box-lx разворачивает
  detour финального outbound рекурсивно. Правильнее архитектурно (единый источник
  истины — ядро видит и динамический detour-selector). Требует SPEC → новая rc.
  **Текущий выбор — ждём релиз ядра под это.**
- **Вариант B (дорисовать у нас):** Dart берёт последнее звено `chains`, тянет
  его `detour` из config.json рекурсивно (`config_node.outboundChain(tag)` уже
  это умеет — `[self, d1, …]`), дописывает хвост. Дёшево, device-проверяемо без
  ядра, НО неточно для динамического detour (detour-группа/selector — из статики
  не восстановить). Для прямого detour-тега (наш кейс) точен. Запасной путь, если
  ядро откажется класть detour в chain.

Риск при B: если ядро ОДНОВРЕМЕННО начнёт класть detour — получим дубль
`node → Warp → Warp`. Тогда нужен гейт. Поэтому A предпочтительнее как единый
источник.
