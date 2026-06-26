# §174 — Восстановить `chains` в CcConnection (ядро отдаёт через chain()-итератор)

**Тип:** bug-fix (потеря данных при §122-миграции)
**Статус:** Реализовано (device-verify впереди)
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
