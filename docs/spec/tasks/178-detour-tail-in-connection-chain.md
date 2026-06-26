# §178 — detour-хвост в connection-цепочке (`Connection.Detour()`, ядро SPEC 017)

**Тип:** feature (показать реальный физический путь пакета: `node → WARP`)
**Статус:** Dart-слой готов (модель + склейка + тесты, 39 зелёных, analyze чист).
Kotlin-чтение `detour()` ЗАКОММЕНТИРОВАНО — метода нет в AAR rc.5 (javap:
только `chain()`). Активируется при rc.6 (SPEC 017) — инструкция в коде +
ниже. До активации `detours` всегда пуст → склейка no-op → поведение §174.
**Связано:** §174 (chains-паритет с Clash), §168 (профайлер), §044 (Live),
ядро [SPEC 017](../../../../sing-box-lx/SPECS/017-CONNECTION_DETOUR_CHAIN/SPEC.md)

## Контекст

§174 восстановил `chains` = граф **маршрутизации** (`[node, …selectors]`), паритет
с Clash. Но detour-хвост финального outbound (`[BL]-3 --detour--> WARP`) в `chains`
не входил НИКОГДА (ни Clash, ни CommandClient) — это транспортная ось, не роутинг
(разбор в §174). Команда ядра завела **SPEC 017**: вывести detour отдельным полем
`Connection.Detour()` (proto field 23 `detourList`), развёрнутым в ядре атомарно
(чтобы клиент не пересобирал распределённое состояние групп между RPC).

Полный физический путь по SPEC 017: **`Chain[0] ⊕ Detour`** = `[BL]-3 ⊕ [WARP]`.

## Контракт ядра (SPEC 017, цитата)

| Поле | Семантика | Порядок | Пример |
|---|---|---|---|
| `Chain` (есть, §174) | маршрут: финальный outbound + селекторы | node→корень | `["[BL]-3","vpn-2","vpn-1"]` |
| `Detour` (НОВОЕ, поле 23) | транспортный хвост финального outbound | node→наружу | `["WARP"]` |

- `Detour` пуст для: `block`/`dns`/outbound без detour, прямых соединений.
- `Detour` ≥2 звеньев когда detour ведёт в группу: `[группа, её Now()]`.
- **proto additive** — старый клиент без поля 23 читает пустой `Detour` ⇒ наш код
  до выхода ядра компилируется и работает как §174 (detour просто всегда пуст).

## Модель данных (клиент)

```
ядро Connection.Detour()  →  CcConnection.detours: List<String>   (сырая ось, как chains)
                              │
профайлер _ingest...        →  outboundChain = chains ⊕ detours    (склейка ДЛЯ UI)
                              │
TrafficEvent.outboundChain  →  live_view / detail_sheet рисуют join(' → ')
```

**Решение: detour хранится сырым (`CcConnection.detours`), склейка в `outboundChain`
делается в профайлере — единственной точке сборки пути.** UI не трогаем: три места
(`live_view`, `traffic_event_detail_sheet`, Conns) уже рисуют `outboundChain` —
получат полный путь автоматически.

### Почему склейка в профайлере, а не в Kotlin

Kotlin отдаёт **обе оси раздельно** (`chains` + `detours`) — как требует SPEC 017
(«клиент ничего не склеивает» относится к *распределённому состоянию групп*, его
собрало ядро; презентационная склейка двух готовых списков — наша зона). Раздельные
поля в `CcConnection` оставляют дверь для будущей раздельной отрисовки (detour другим
цветом), не форсируя её сейчас.

### Порядок в `outboundChain`

`chains` едет в UI как есть (`[node, selector].join → "node → selector"`, без reverse
— проверено: все `.reversed` в коде про сортировку событий, не звеньев). `detours`
= node→наружу. Склейка `chains ⊕ detours` = `[node, selector, WARP]` → UI:
`node → selector → WARP`. Узел detour-а (`WARP`) встаёт В КОНЕЦ — физически верно
(пакет выходит из node, потом ныряет в WARP). `chains[0]`=node и `detours` оба
«начинаются от node», дублирования node нет — `detours` НЕ содержит node (SPEC:
`Detour[0]` = непосредственный detour узла, не сам узел).

## Точки правки (клиент)

1. **Kotlin** ([BoxCommandClient.kt](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxCommandClient.kt)):
   рядом с чтением `c.chain()` — best-effort прочитать `c.detour()`-итератор
   (lowercase, как `chain()`), положить `"detours"` в map. **СТАТУС: вызов
   ЗАКОММЕНТИРОВАН** — метода нет в AAR rc.5 (не скомпилируется). `detours` едет
   пустым; раскомментировать при rc.6 (чек-лист выше). `"detours" to detours`
   в map уже стоит (пустой список безвреден).

2. **Dart** ([cc_channel.dart](../../../app/lib/vpn/cc_channel.dart)):
   `CcConnection.detours: List<String>` (+ `fromMap` из `m['detours']`, дефолт `const []`).

3. **Профайлер** ([traffic_profiler.dart](../../../app/lib/services/traffic_profiler.dart)):
   где строится `chains` (§174-блок ~990) — после fallback дописать
   `if (c.detours.isNotEmpty) chains = [...chains, ...c.detours];`. `outboundChain`
   получает полный путь.

4. **UI** — НЕ трогаем (live_view/detail_sheet/Conns читают `outboundChain`).

5. **Debug API** — `outbound_chain` в `/profiler/live` автоматически включит detour
   (сериализуется из того же `outboundChain`). Отдельного поля не вводим.

## Forward-compatibility (КЛЮЧЕВОЕ) — урок: метод отсутствует, не пустой

Код пишется ДО выхода ядра с SPEC 017. **Важный нюанс, выявленный javap-сверкой:**
в AAR rc.5 метода `Connection.detour()` НЕТ ВООБЩЕ (есть только `chain()`).
Это значит `runCatching { c.detour() }` **не спасает** — отсутствие метода ловится
на этапе КОМПИЛЯЦИИ (Kotlin не соберётся), а не рантайма. `runCatching` ловит
только исключения уже скомпилированного кода.

Поэтому Kotlin-чтение `detour()` **закомментировано** (не reflection — выбор юзера:
безопаснее, без рефлексии на conn). `detours` объявлен пустым `ArrayList` и едет в
map как `"detours" to []` — проводка до Dart готова, но всегда пустая на rc.5.

Безопасность до rc.6:
- Kotlin компилируется (вызова `c.detour()` нет — закомментирован).
- `detours` = `[]` → Dart `CcConnection.detours` = `[]`.
- proto field 23 additive — даже если ядро частично, отсутствие поля = пустой список.
- пустой `detours` ⇒ склейка `[...chains]` = `chains` ⇒ **поведение §174 неизменно**.
- Тесты §178 гоняют склейку на синтетических `CcConnection` с непустым `detours` —
  логика склейки проверена без ядра (39 зелёных).

### Активация при rc.6 (чек-лист)

1. `./scripts/fetch-libbox.sh` — обновить AAR до rc.6.
2. `javap …/Connection.class | grep detour` — подтвердить метод `detour()` есть,
   тип `StringIterator` (gomobile lowercase'ит `Detour()` из command_types.go).
3. Раскомментировать `runCatching { c.detour() … }` в BoxCommandClient.kt (§178).
4. Убедиться `"detours" to detours` в map (уже есть).
5. Сборка APK + device-verify (раздел «Проверка» ниже).

## Тесты

`traffic_profiler_test`: conn с `chains=[node,sel]` + `detours=[WARP]` →
`outboundChain == [node, sel, WARP]`. conn с пустым `detours` → `outboundChain`
неизменён (== §174). conn прямой (`chains=[]`, `detours=[]`) → fallback `[outbound]`.

## Проверка (device) — КОГДА ПРИЕДЕТ ЯДРО rc.6

1. `javap` AAR: метод `detour()` на `Connection` присутствует, тип `StringIterator`.
2. `/profiler/live` для conn через `[BL]`-ноду с detour=WARP → `outbound_chain`
   оканчивается на `"🔥⛈️ WARP (AWG 1.5)"`.
3. Прямой/direct conn → detour пуст, путь как был.
4. Регресс §174: `chains` (Clash-API `/connections`) не изменился.
