# §181 — секция ROUTING: цепочка решения + detour-ось

**Тип:** UI + модель (читаемость detail-sheet соединения)
**Статус:** ✅ Реализовано, device-verified по данным (dev.75). routingLine на
устройстве: `[tcp] com.oplus.statistics.rom ⇒ final ⇒ vpn-1 : 🇫🇮Финляндия →
🔥⛈️ WARP → dc-stat-in.heytapmobile.com`. Оси раздельны (outbound_chain без detour,
detour_chain отдельно). 41 профайлер-тест + 1253 полный сьют зелёные. Решения:
**единая цепочка решения**
`rule ⇒ группа ⇒ …auto… ⇒ сервер` (порядок принятия маршрута, сверху вниз) +
detour ОТДЕЛЬНОЙ строкой (транспорт, не решение); пустой rule → метка **«final»**.
**Связано:** §174 (chains), §178 (detour-хвост), §160 (event detail sheet),
§165 (RuleNameResolver), ядро [SPEC 017](../../../../sing-box-lx/SPECS/017-CONNECTION_DETOUR_CHAIN/SPEC.md) (порядок)

## Проблема (device, скриншот play-fe.googleapis.com)

Секция ROUTING показывает `outboundChain.join('\n')` — **плоский список из 4
слитых элементов**, где намешаны ДВЕ разные сущности, а правило не видно вообще:

```
ROUTING
  Outbound:  L: 🇭🇺⚡Венгрия bypass    ← маршрут (node)
             vpn-1                      ← маршрут (selector)
             L: ⚙ ru-upstream-7         ← DETOUR (транспорт)
             🔥⛈️ WARP (AWG 1.5)        ← DETOUR (транспорт)
```

Непонятно: (1) где маршрут, где detour; (2) **через какое правило** соединение
попало в vpn-1 (rule пуст → строки Rule нет).

## Две оси (порядок сверху вниз по решению маршрута)

Юзер: «правило выбирает группу, группа — сервер, там ещё auto может быть.
`final ⇒ vpn-1 ⇒ 🇭🇺Венгрия`». То есть rule — НЕ отдельная строка, а НАЧАЛО единой
**цепочки решения**. Detour — другая ось (транспорт, не решение).

| Ось | Смысл | Источник |
|---|---|---|
| **Цепочка решения** | как роутер выбрал сервер: `rule ⇒ группа ⇒ …auto… ⇒ node` | `rule` + `chains` |
| **Detour** | транспорт: куда физически ныряет пакет (`ru-upstream-7 → WARP`) | `detours` |

### Порядок `chains` от ядра (SPEC 017, javap-сверено)

`chains = [node, …selectors-снизу-вверх]`, напр. `["[BL]-3", "vpn-2", "vpn-1"]`:
- `chains[0]` = **финальный node** (`[BL]-3`)
- `chains[1..]` = селекторы/группы от листа к корню (`vpn-2`=под-группа, `vpn-1`=верхняя)

`detours = [detour, …наружу]`, напр. `["WARP"]` (node НЕ включён — без дублей).
`rule` = отдельное поле (`rule_set=unknown-apps` или ПУСТО=`final`).

### Формат: разделители кодируют ТИП перехода

Юзер — ПОЛНАЯ схема: путь пакета слева направо от источника до назначения.

```
[tcp] com.android.vending ⇒ final ⇒ vpn-1 ⇒ ✨auto : 🇭🇺Венгрия → 🔥⛈️ WARP → play-fe.googleapis.com
└тип┘ └─ процесс ─┘        └──────── ВНУТРИ (роутинг) ────────┘ └ВЫХОД┘ └СНАРУЖИ┘  └─ назначение ─┘
```

Семантика разделителей: «`⇒` — внутренние переходы; `:` — выход во внешний мир;
`→` — переходы снаружи».

| Часть | Источник | Разделитель после |
|---|---|---|
| `[tcp]` / `[udp]` | `network` (префикс в скобках) | пробел |
| процесс | `process` (или `?` если null) | ` ⇒ ` |
| rule | `rule` или `final` | ` ⇒ ` |
| группы (reverse chains[1:]) | `outboundChain[1:]` ↑ | ` ⇒ ` между, ` : ` перед node |
| node | `outboundChain[0]` | ` : ` перед, ` → ` после (если detour/domain) |
| detour | `detourChain` | ` → ` между и перед domain |
| domain | `domain` (или `ip` если нет) | — (конец) |

Полная формула:
```
[network] process ⇒ rule ⇒ группа ⇒ …auto… : node → detour… → domain
```
Все поля уже в `TrafficEvent` (`network`/`process`/`rule`/`outboundChain`/
`detourChain`/`domain`/`ip`). Хелпер `_routingLine(e)` собирает всю строку.

### Деградации (части могут отсутствовать)
- нет process → `?` или пропуск (TBD при коде — смотреть как уже делает live_view).
- нет chains (DNS/прямой без групп) → `[tcp] proc ⇒ rule : node → domain` (node=outbound).
- нет detour → `… : node → domain` (сразу domain после node).
- нет domain → оканчивается на node/detour (есть только ip — берём ip).

### Формула (один проход)

```
parts = [ruleLabel] + reverse(chains[1:])        // rule + группы сверху-вниз, join " ⇒ "
decision = parts.join(" ⇒ ")
if chains not empty: decision += " : " + chains[0]   // ": сервер" (node = chains[0])
if detourChain not empty: decision += " → " + detourChain.join(" → ")  // "→ detour"
```

- `ruleLabel` = `rule` (+payload) если непуст, иначе **`final`** (дефолт-маршрут).
- `reverse(chains[1:])` = группы от ВЕРХНЕЙ к нижней (vpn-1 → vpn-2 → …); **auto**
  вписывается сам (`✨auto` — обычный selector в chains).
- `chains[0]` = сервер (после ` : `).
- detour (`detourChain`) — после ` → `, node→наружу как от ядра.
- Прямой conn (`chains=[node]`, нет групп): `final : direct-out` (parts=[final], node после `:`).
- DNS / нет chains: только `ruleLabel`.

**Один хелпер `_routingLine(e)` строит ВСЮ строку** — используется и в компактной
Live-строке, и в detail-sheet (там та же строка, плюс можно дать raw-список ниже
для копирования).

### Модель: `TrafficEvent` несёт `detourChain` отдельно

```dart
final List<String> outboundChain;  // §181 — chains КАК ОТ ЯДРА: [node, …selectors]. БЕЗ detour.
final List<String> detourChain;    // §181 — detour-ось: [ru-upstream-7, WARP]. НОВОЕ.
final String? rule;                // §174 — уже есть.
```

**Семантика `outboundChain` меняется:** теперь = чистый `chains` (маршрут, БЕЗ
detour — §178-склейку разворачиваем). Сборка человекочитаемой строки — в UI.

### Профайлер (traffic_profiler.dart ~996-1005): НЕ склеивать

```dart
// §181 — РАЗДЕЛЬНО: outboundChain = chains (маршрут как от ядра), detourChain =
// detours (транспорт). Склейку §178 убрали — UI сам строит цепочку решения.
final routeChain = c.chains.isNotEmpty
    ? c.chains
    : (c.outbound.isNotEmpty ? <String>[c.outbound] : <String>[]);
// → TrafficEvent(outboundChain: routeChain, detourChain: c.detours, …)
```

### Где показываем

**Компактная строка (Live `live_view`, Conns-row):** одна строка
`_routingLine(e)` →
```
final ⇒ vpn-1 : 🇭🇺⚡Венгрия → 🔥⛈️ WARP
```
заменяет нынешний `outboundChain.join(' → ')`.

**detail-sheet (traffic_event_detail_sheet.dart ~134) — секция Routing:**
```
ROUTING
  Route:   final ⇒ vpn-1 : 🇭🇺⚡Венгрия → 🔥⛈️ WARP    ← _routingLine(e), читаемая
  Chain:   🇭🇺⚡Венгрия / vpn-1                          ← raw chains (для копирования)
  Detour:  🔥⛈️ WARP (AWG 1.5)                          ← raw detour (опц., если есть)
```
- **Route** — главная человекочитаемая строка (хелпер).
- **Chain** — сырой `outboundChain.join(' / ')` для копирования точных тегов
  (detail-sheet всё-таки про подробности). Опускаем если пуст.
- **Detour** — сырой `detourChain.join(' → ')`, только если непуст.
- Старая строка `Rule` УБИРАЕТСЯ — rule теперь в начале Route-строки.

### Live-строка (live_view.dart) и Conns — НЕ ломать

`live_view` показывает компактный путь одной строкой. Чтобы не потерять detour
там, склеить В ПОТРЕБИТЕЛЕ: `[...outboundChain, ...detourChain].join(' → ')`
(было `outboundChain.join` со склеенным). Conns-row аналогично если показывает chain.

## Точки правки

1. **`TrafficEvent`** ([models.dart](../../../app/lib/services/traffic_profiler/models.dart)):
   поле `detourChain: List<String>` (default `const []`) + в `toJson`
   (`'detour_chain'`) + в `copyWith`/конструкторах.
2. **Профайлер** ([traffic_profiler.dart](../../../app/lib/services/traffic_profiler.dart)):
   НЕ склеивать (§178-блок ~1003) — `outboundChain=routeChain`, `detourChain=c.detours`.
   Все места, что прокидывают `outboundChain` (819/875/1118 — resolved/snap), тоже
   прокидывают `detourChain`.
3. **detail-sheet** ([traffic_event_detail_sheet.dart](../../../app/lib/screens/stats_screen/traffic_event_detail_sheet.dart)):
   секция Routing → 3 строки (Rule с «final»-фолбэком, Route развёрнут, Detour опц.).
4. **live_view** ([live_view.dart](../../../app/lib/screens/per_app_trace_tab/widgets/live_view.dart)):
   склейка `outboundChain ⊕ detourChain` для компактной строки (сохранить полный путь).
5. **Conns-row** — проверить, не сломан ли (если рисует chain).

## Тесты

`traffic_profiler_test`: conn с `chains=[node,sel]` + `detours=[WARP]` →
`outboundChain==[node,sel]` (БЕЗ detour), `detourChain==[WARP]`. Прямой conn →
`detourChain` пуст. (Обновить §178-тесты: они ждали склеенный outboundChain —
теперь оси раздельны.)

## Границы

- Ядро НЕ трогаем — chains/detours уже раздельны в `CcConnection` (§174/§178).
- `outboundChain` toJson-ключ остаётся `outbound_chain` (Debug API совместимость),
  +новый `detour_chain`.
- §178-склейка была компромисс «один список»; §181 разворачивает её для detail —
  это эволюция, не регрессия (detour не теряется, переезжает в свою ось).
