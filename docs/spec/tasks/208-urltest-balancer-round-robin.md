# §208 — Round-robin балансировщик в auto-группе + просмотр пула (ядро SPEC 019 V2)

> **СТАТУС: РЕАЛИЗОВАНО (28.06.2026).** Ветка `feat/urltest-balancer-208`.
> Ядро: `v1.14.0-lx.1-rc.14` (SPEC 019 — фича с rc.13, `pool:0`-фикс rc.14).
> Включает бамп пина (rc.12 → rc.14, [§208a](#208a--бамп-пина-ядра-rc12--rc14)).
> §207 занят другой сессией (goroutine-cpu-dump) — взят 208.
> 1397 тестов зелёные (+26); Dart analyze чист; Kotlin compile OK.
> **DEVICE-VERIFIED 28.06.2026** (Debug API): конфиг `vpn-1-auto` эмитит
> `mode:round_robin` + `balancer{pool:3,pool_tolerance:100,sticky_hash:
> [process,domain]}`; трафик в профайлере раскидан по слотам пула (🇩🇪/🇫🇮/🇨🇭/
> 🇬🇧). Sticky держит TCP-домены на одном узле.
>
> **Нюанс ядра (НЕ баг §208):** UDP/QUIC-флоу часто приходит в ядро с пустым
> `destination.Fqdn` (Chrome уже зарезолвил домен на IP / HTTP3 после Alt-Svc)
> → sticky-ключ `[process,domain]` для UDP = `process+""`, а для TCP того же
> сайта = `process+fqdn` → **разные слоты** для UDP и TCP одного домена.
> Профайлер показывает domain постфактум (`matched_via:connections_meta`),
> хотя ядро в момент `pick()` Fqdn не видело. Улучшение — на стороне ЯДРА
> (для UDP с пустым Fqdn добавлять `dest_ip` в ключ), не нашего билдера.

## Контекст

Ядро (SPEC 019 V2) расширило `urltest`-группу режимом балансировки нагрузки.
Раньше urltest = **least_test**: один «лучший» узел по delay, все соединения
идут через него (через `tolerance`-гистерезис). Новый режим **round_robin**
раскидывает соединения по **пулу** из N узлов: фиксированные слоты, ленивый
health-check, sticky-привязка сессий по ключу (process/domain/…). Для юзера с
1000 нод это нагрузочная балансировка; для обычного — «несколько серверов
параллельно, сессии липнут к своему».

У нас auto-двойник канала (`<tag>-auto`, §125) — это и есть urltest-группа.
Сейчас редактор канала ([channel_edit_screen.dart](../../app/lib/screens/channel_edit_screen.dart))
правит только апстрим-поля (`url`/`interval`/`tolerance`/`idle_timeout`/
`interrupt_exist_connections`). Нужно (1) добавить выбор **режима** и параметры
балансировщика, прокинуть в config через билдер, и (2) дать **просмотр текущего
состава пула** по long-press на auto-ноде (через новый RPC `GetPool`).

## Что даёт ядро (rc.14, по SPEC 019 V2)

Поля urltest-группы (в дополнение к существующим):

| поле | дефолт | смысл |
|---|---|---|
| `mode` | `least_test` | `least_test` (апстрим, как сейчас) \| `round_robin` |
| `balancer` | — | объект; **только** при `round_robin`; при `mode != round_robin` с ним → **ошибка старта ядра** |
| `balancer.pool` | 3 | размер пула; `0`/опущено → 3; `< 0` → ошибка; факт = `min(pool, len(nodes))` |
| `balancer.pool_tolerance` | 0 | мс. `0` — держать `pool` живых (скорость неважна); `> 0` — отбирать лучших по delay |
| `balancer.sticky_hash` | `["process","domain"]` (если поле **опущено**) | компоненты ключа липкости; `[]` (явный пустой) → липкость ВЫКЛ (чистый round_robin) |

`sticky_hash` компоненты: `process`, `domain`, `source_ip`, `dest_ip`,
`dest_port`.

**RPC `GetPool` (rc.14 libbox, подтверждено javap):**
```
CommandClient.getPool(group_tag) → PoolSlotIterator
PoolSlot { int getSlot(); String getTag(); int getDelay(); }   // delay мс, 0 = мёртвая/не измерена
```
- unary snapshot (не стрим). Не-round_robin группа → **пустой список** (не
  ошибка). `delay` живой ноды всегда ≥1 (ядро клампит 0→1), `0`=мёртвая.

Доп. факты ядра (для подсказок UI, не для логики):
- `tolerance` (апстрим, корень urltest) при `round_robin` **игнорируется**
  ядром → ядро шлёт варн. В round_robin за гистерезис отвечает
  `balancer.pool_tolerance`. **Решение юзера: в Load balance поле Tolerance
  гасим** (disabled).
- **`interval` дефолт ядра 3m**; для round_robin SPEC рекомендует **15m** (на
  больших пулах частый дотест избыточен). Нас не ломает (эмитим явно), но
  UI-hint в Load balance подскажет «15m recommended for large pools».
- **`interval ≤ idle_timeout`** — апстрим-требование (`urltest.go:221`), иначе
  ошибка старта ядра (оба режима). Сейчас редактор не проверяет. Добавим
  дешёвую advisory-проверку (см. «Валидация редактора»).
- `Now()` round_robin = `lastSelected` (прыгает с ротацией, by design).
  Следствие: пинг auto-ноды (`URLTestOutbound`) в round_robin тоже «шумит» —
  цифра скачет. Не ломается. Просмотр пула (GetPool) даёт честную картину.

## Скоуп (согласовано с юзером 28.06.2026)

1. **Модель** `ChannelAuto` — поля `mode`, `pool`, `poolTolerance`,
   `stickyHash` (+ enum, JSON, copyWith, дефолты, кламп).
2. **Билдер** `build_config.dart` — при `mode == round_robin` дописывать
   `mode` + `balancer{}` в urltest-объект.
3. **Редактор** `channel_edit_screen.dart` — SegmentedButton «Mode» (Fastest /
   Load balance) + (под Load balance) Pool size / Pool tolerance + чипы
   sticky_hash; гашение Tolerance; hint 15m; advisory interval≤idle.
4. **GetPool RPC** (полный путь, согласовано — правая кнопка → попап):
   - Kotlin `BoxCommandClient.getPool(tag)` + `serializePoolSlot` (1:1 с
     `getGroups`-паттерном).
   - VpnPlugin handler `ccGetPool` (unary, `Dispatchers.IO`, как
     `ccUrlTestOutbound`).
   - Dart `CcChannel.getPool(tag)` + модель `CcPoolSlot`.
   - UI: пункт **«View pool»** в контекстном меню node_row (long-press,
     только для round_robin auto-ноды) → попап-диалог со слотами.
5. **Тесты** — модель (JSON, дефолты, кламп, enum-wire), билдер (эмиссия
   balancer, leastTest=без полей), `CcPoolSlot.fromMap`.

НЕ трогаем: главный экран «Auto → сервер» (Now() прыгает — оставляем как есть,
пул смотрят через попап), Conns/Profiler, реакцию ping-цифры на ротацию.

## UI-дизайн A — редактор канала (блок «Include auto»)

Между Idle timeout и Interrupt-галкой вставляем секцию режима. Логика:
сначала «как тестируем» (url/interval/idle), потом «как выбираем» (mode +
balancer), потом interrupt.

```
┌─ Include auto (urltest) ────────────────────[✓]─┐
│   latency-tested twin of this channel           │
│  Test URL          [ https://cp.cloudflare… ]    │
│  Interval [ 5m ]      Tolerance (ms) [ 50 ]      │  ← Tolerance ГАСИМ в Load balance
│  Idle timeout [ 30m ]                            │
│  Mode   ┌─ Fastest ─┬─ Load balance ─┐           │  ← SegmentedButton (2 сегмента)
│         └───────────┴────────────────┘           │
│  ── если Load balance: ──────────────────────    │
│  ⓘ 15m interval recommended for large pools      │
│  Pool size [ 3 ]    Pool tolerance (ms) [ 0 ]    │
│  Sticky session by:                              │
│   [process ✓][domain ✓][source ip][dest ip]      │  ← FilterChip multi-select
│   [dest port]                                    │
│   ⓘ none selected → no stickiness (pure rotation)│
│  [✓] Interrupt connections on switch             │
└──────────────────────────────────────────────────┘
```

**Решения по UI:**
- **`mode` → SegmentedButton «Mode»**: `Fastest` (least_test, «single best
  server») / `Load balance` (round_robin, «spread across a pool»). Человеческие
  лейблы, не ядровый жаргон (нейминг «Load balance» согласован).
- **Tolerance ГАСИМ** при Load balance (`enabled: false`, hint «used in
  Fastest mode»). За гистерезис в пуле отвечает Pool tolerance.
- **Pool size** — number, дефолт 3. Клиентский кламп при сохранении: `< 1 → 1`.
  Опц. hint «of N nodes» из `allNodeTags.length`. Реальный `min(pool,len)` —
  ядро.
- **Pool tolerance (ms)** — number, дефолт 0. Hint «0 = keep pool full».
- **`sticky_hash` → ряд из 5 FilterChip** (multi-select). Дефолт для нового
  round_robin = `{process, domain}`. 0 чипов → `sticky_hash: []` (липкость
  выкл). Подсказка под чипами.
  - **nil-vs-[] (важно):** наша модель — `List<StickyHashKey>` (не nullable);
    в режиме round_robin билдер ВСЕГДА эмитит `sticky_hash` явно (непустой или
    `[]`). Ядровый «опущен→дефолт» нам не нужен — задаём из UI без
    неоднозначности.

**Видимость:** секция Mode — только при `_autoEnabled`. balancer-поля — только
при `Load balance`. Tolerance существует всегда, но disabled в Load balance.

### Валидация редактора (interval ≤ idle_timeout)

Дешёвая advisory-проверка (не hard-gate): парсим обе duration-строки
(`5m`/`30m`/`1h`/`90s`) в секунды простым парсером; при `interval > idle`
показываем `errorText` под Interval «must be ≤ idle timeout». Сохранение не
блокируем жёстко (парсер неполон / юзер знает лучше). Если в проекте есть
duration-парсер — переиспользуем, иначе минимальный helper (s/m/h).

## UI-дизайн B — просмотр пула (long-press auto-ноды → попап)

В контекстном меню node_row ([node_row.dart:206](../../app/lib/widgets/node_row.dart#L206),
рядом с §203 «Select server») добавляем пункт **«View pool»** (иконка
`Icons.hub_outlined` / `Icons.lan_outlined`), гейт `onViewPool != null` —
прокидывается только для auto-ноды в **round_robin**-канале.

При тапе → `cc.getPool(autoTag)` → попап-диалог (`showDialog`,
`AlertDialog`/простой sheet) со списком слотов:

```
┌─ Pool · VPN ① auto ───────────────┐
│  slot 0   🇩🇪 node-de-1     12 ms  │   ← delay цветной (зелёный/жёлтый/красный)
│  slot 1   🇳🇱 node-nl-3     34 ms  │
│  slot 2   🇫🇮 node-fi-2      — ms  │   ← delay 0 → «—» (мёртвая/не измерена)
│                          [ Close ] │
└────────────────────────────────────┘
```

- Слоты в порядке `slot` (фиксированный). `delay==0` → «—» (мёртвая).
- Пустой список (туннель down / не round_robin / пул не готов) → «Pool not
  available». Не ошибка.
- Снапшот (unary). Можно добавить pull-to-refresh / кнопку Refresh — опц.
  (пул меняется раз в interval, статичный снимок достаточен).
- Кто round_robin: канал из storage по autoTag → `channel.auto.mode ==
  roundRobin`. Прокидывается в node_list как `onViewPool`.

## Модель `ChannelAuto`

```dart
enum UrltestMode { leastTest, roundRobin }   // wire: 'least_test' | 'round_robin'
enum StickyHashKey { process, domain, sourceIp, destIp, destPort }
//   wire: 'process','domain','source_ip','dest_ip','dest_port'
```

Новые поля (с дефолтами — обратная совместимость со старым JSON):

| поле | тип | дефолт | wire |
|---|---|---|---|
| `mode` | `UrltestMode` | `leastTest` | `mode` |
| `pool` | `int` | `3` | `balancer.pool` |
| `poolTolerance` | `int` | `0` | `balancer.pool_tolerance` |
| `stickyHash` | `List<StickyHashKey>` | `[process, domain]` | `balancer.sticky_hash` |

Старый канал без новых ключей → `leastTest` + дефолты. `toJson` пишет новые
поля всегда (storage +4 ключа, чтение не ломается). Кламп: `pool→max(1,v)`,
`poolTolerance→_clampTolerance` (uint16, reuse §161).

## Билдер `build_config.dart` (urltest-двойник, стр. 519-531)

```dart
final m = <String, dynamic>{
  'tag': c.autoTag, 'type': 'urltest', 'outbounds': nodes,
  'url': a.url, 'interval': a.interval, 'tolerance': a.tolerance,
  'idle_timeout': a.idleTimeout,
  'interrupt_exist_connections': a.interruptExistConnections,
};
if (a.mode == UrltestMode.roundRobin) {
  m['mode'] = 'round_robin';
  m['balancer'] = {
    'pool': a.pool,
    'pool_tolerance': a.poolTolerance,
    'sticky_hash': a.stickyHash.map((k) => k.wire).toList(), // всегда явно ([] = выкл)
  };
}
result.add(m);
```

**leastTest** → `mode`/`balancer` НЕ пишем (бит-в-бит как сейчас → нулевой diff
для существующих конфигов, не триггерит balancer+wrong-mode ошибку). `tolerance`
оставляем всегда (ядро игнорит в round_robin, в least_test работает).

## Native (Kotlin) — GetPool (1:1 с getGroups/urlTestOutbound)

**`BoxCommandClient.kt`:**
```kotlin
fun getPool(tag: String): List<Map<String, Any>> {
    val client = anyClient() ?: return emptyList()
    return runCatching {
        val out = ArrayList<Map<String, Any>>()
        val it = client.getPool(tag)
        while (it.hasNext()) {
            val s = it.next()
            out.add(mapOf("slot" to s.slot, "tag" to s.tag, "delay" to s.delay))
        }
        out
    }.getOrElse { Log.d(TAG, "getPool unavailable: ${it.message}"); emptyList() }
}
```
(использует `anyClient()` — снапшот, как getGroups; НЕ pingClient.)

**`VpnPlugin.kt`** handler `ccGetPool` (рядом с `ccGetGroups`), на
`Dispatchers.IO` (как `ccUrlTestOutbound` — RPC может блокировать):
```kotlin
"ccGetPool" -> {
    val tag = call.argument<String>("tag") ?: ""
    scope.launch {
        val r = withContext(Dispatchers.IO) { cc.getPool(tag) }
        result.success(r)
    }
}
```

## Dart — `CcChannel.getPool` + `CcPoolSlot`

```dart
class CcPoolSlot {
  const CcPoolSlot({required this.slot, required this.tag, required this.delay});
  final int slot;
  final String tag;
  final int delay; // мс, 0 = мёртвая/не измерена
  factory CcPoolSlot.fromMap(Map<String, dynamic> m) => CcPoolSlot(
        slot: (m['slot'] as num?)?.toInt() ?? 0,
        tag: m['tag'] as String? ?? '',
        delay: (m['delay'] as num?)?.toInt() ?? 0,
      );
}

Future<List<CcPoolSlot>> getPool(String tag) async {
  final r = await _methods.invokeMethod<List<dynamic>>('ccGetPool', {'tag': tag});
  return (r ?? const []).map((m) => CcPoolSlot.fromMap(_asMap(m))).toList();
}
```

## Тесты

- **`channel_test.dart`**: `ChannelAuto` JSON round-trip с новыми полями; старый
  JSON без полей → дефолты; кламп pool `0→1`, poolTolerance отриц→0; enum
  wire-мэппинг обе стороны (2 mode + 5 sticky).
- **builder-тест**: канал `auto.mode==roundRobin` → `mode:'round_robin'` +
  `balancer{pool,pool_tolerance,sticky_hash}`; `stickyHash==[]`→`sticky_hash:[]`;
  `leastTest` → НЕТ `mode`/`balancer` (бит-в-бит старый объект).
- **`CcPoolSlot.fromMap`** — микротест (slot/tag/delay, дефолты, delay 0).
- Widget-тест попапа — опц.

## §208a — бамп пина ядра rc.12 → rc.14

Предусловие (пин уже `v1.14.0-lx.1-rc.14`, AAR скачан, SHA256 OK):
- **rc.13** SPEC 019 V2 (пул/sticky/GetPool RPC); **rc.14** фикс валидации
  `balancer.pool: 0`, «no behaviour change».
- **javap rc.14:** базовый CommandClient API не менялся
  (`getGroups`/`urlTestOutbound`/`OutboundGroup.getSelected/getTag/getType`);
  **добавлены** `getPool(String)→PoolSlotIterator`, `PoolSlot{getSlot/getTag/
  getDelay}` — используем (UI-дизайн B).

## Не в скоупе (следующие таски)

- Главный экран «Auto → X» в round_robin прыгает (`Now()=lastSelected`).
  Возможная индикация «balanced / N серверов» вместо одного — отдельно.
- Стрим пула (живой) вместо unary snapshot — если понадобится «живой» пул.
- `weighted_round_robin` / веса — ядро отложило.

## Связанные

- ядро SPEC 019 V2 (`sing-box-lx/SPECS/019-URLTEST_MODE_STICKY/SPEC.md`).
- [§125 configurable-channels](../features/125%20configurable-channels/spec.md) — auto-двойник = urltest-группа.
- [§203 select-server](203-select-server-on-auto.md) — контекстное меню auto-ноды (рядом «View pool»).
- [§205 rc.12](205-libbox-rc12-cold-urltest.md) — предыдущий бамп ядра; этот = rc.12→rc.14.
- §161 — uint16-кламп tolerance (reuse для pool_tolerance).
