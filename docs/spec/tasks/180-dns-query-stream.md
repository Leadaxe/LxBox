# §180 — DNS на структурный стрим `subscribeDNSQueries` (ядро SPEC 018)

**Тип:** feature (выпил текстового DNS-парсинга → структурный live-поток с атрибуцией из ядра)
**Статус:** Клиент РЕАЛИЗОВАН (Dart 39 тестов зелёных, analyze чист, APK rc.7
собран). **БЛОКЕР ЯДРА (device dev.71, rc.7):** ядро отдаёт `rpc error: code =
Unimplemented desc = DNS query tracking not available`. RPC `SubscribeDNSQueries`
объявлен в proto/биндинге (javap классы видит), НО серверная реализация в AAR
rc.7 НЕ активна. Наша сторона дошла штатно: `connectProfiler → connected gen=2`,
`subscribeDNSQueries` вызван, `DnsHandler.onError` поймал Unimplemented, профайлер
не упал, TCP/UDP идут. Ждём ядро с активированным DNS-tracking. ВАЖНО: до фикса
ядра DNS в Live ПУСТ (вариант A — старого текстового пути нет, новый не отвечает).
Решения: §180.5 = вариант A; §177-баннер не трогаем. Биндинг rc.7 сверен javap:
`subscribeDNSQueries(bool, DnsQueryHandler)→DnsQuerySubscription`,
`DnsQuery{getDomain/getQueryType/getRcode/getTTL/getSource/getFailed/getError/
getProcessInfo, answers()}`, `DnsQueryHandler{onQuery, onError}`.
**Связано:** §168 (профайлер на CC-стрим), §171 (DNS из core-логов — этот канал и заменяем),
§176 (FilterState consumer-side), §177 (баннер unattributed — §180 бьёт его КОРЕНЬ),
§174/§178 (chains/detour — тот же «структура вместо текста» приём),
ядро [SPEC 018](../../../../sing-box-lx/SPECS/018-DNS_QUERY_STREAM/SPEC.md)

## Зачем

DNS сейчас берётся из **текстового core-лога**: `_processLogLine` → `_dnsRe`/`_dnsFailRe`
(regex) → `_handleDnsLine`/`_handleDnsFailLine`. Два структурных изъяна:

1. **Атрибуция к приложению хрупкая.** package берётся из ОТДЕЛЬНОГО router-лога через
   сшивку по `connId` (`_connIdToMeta[connId]`). Потеря/гонка package-строки →
   `meta==null` → `confidence: unattributed`. Это **прямой корень §177-баннера** (49
   успешных unattributed DNS на dev.68 — все просто не сшились).
2. **cnameChain собирается вручную** по CNAME-строкам до прихода A/AAAA — ломается при
   потере/переупорядочивании строк. Regex чинили дважды (§141 defensive, §171 голые ESC).

SPEC 018 даёт структурный `DnsQuery` с `processInfo` **из ядра** (атрибуция готовая, не по
connId) + `answers[]` (вся CNAME-цепочка одним событием) + `failed`/`error`/`rcode`.

## Контракт ядра rc.7 (javap-сверено, НЕ догадки)

**Подписка** — прямой метод на ЖИВОМ CommandClient (НЕ `addCommand`-константа):
```
client.subscribeDNSQueries(boolean includeAnswers, DnsQueryHandler) → DnsQuerySubscription
DnsQueryHandler { onQuery(DnsQuery); onError(String) }
DnsQuerySubscription.close()   // отписка
```

**`DnsQuery`** геттеры: `getDomain():String`, `getQueryType():int`, `getRcode():int`,
`getTTL():int`, `getSource():String`, `getFailed():boolean`, `getError():String`,
`getProcessInfo():ProcessInfo`, `answers():DnsAnswerIterator`.
**`DnsAnswer`**: `getName():String`, `getType():int`, `getRData():String`, `getTTL():int`.

### Три грабли из SPEC 018 (команда ядра выделила явно)

| # | Грабля | Клиент обязан |
|---|---|---|
| **Q1** | `getRcode():int` signed; `-1` = «нет ответа» (timeout), физически ≠ 65535 | мапить `rcode == -1` → нет-ответа **ДО** `.toUInt()` (иначе `-1`→`4294967295`) |
| **Q2** | провалы (timeout/SERVFAIL/rejected/loopback) ТОЖЕ эмитят: `failed=true`, `source="failed"` | не игнорить failed — это `dnsFail`-событие |
| **Q3** | `answers()` = ВЕСЬ `response.Answer` (CNAME-hops + A/AAAA), только при `includeAnswers=true` | запрашивать `includeAnswers=true`; cnameChain = промежуточные `type==CNAME` |

## Модель данных (клиент)

```
ядро subscribeDNSQueries(true, handler)  →  DnsQueryHandler.onQuery(DnsQuery)
   │
Kotlin DnsQueryHandler → map → dnsQueriesEmitter → ccDnsQueriesSink (НОВЫЙ EventChannel)
   │
Dart CcChannel.dnsQueries: Stream<CcDnsQuery>  (новая модель, как CcConnection)
   │
профайлер _ingestDnsQuery(CcDnsQuery)  →  TrafficEvent(dnsResolve|dnsFail)
   │                                        (ПЕРЕИСПОЛЬЗУЕТ существующие kind/cnameChain/dnsRecordType)
   └─ ВЫПИЛ: _processLogLine DNS-ветки + _dnsRe/_dnsFailRe + _handleDnsLine/_handleDnsFailLine
            + _DnsAccumulator + _dnsByConnId (cnameChain теперь из answers[], не аккумулируется)
```

**`CcDnsQuery` (новая модель в cc_channel.dart):**
```dart
class CcDnsQuery {
  final String domain;
  final int queryType;       // qtype (1=A, 28=AAAA, 5=CNAME, 65=HTTPS…)
  final int rcode;           // Q1: -1 = нет ответа (timeout). НЕ toUInt!
  final int ttl;
  final String source;       // exchanged/cached/optimistic/refreshed/rejected/failed
  final bool failed;         // Q2
  final String error;        // причина при failed; "" на успехе
  final String packageName;  // processInfo.packageNames().first — АТРИБУЦИЯ ИЗ ЯДРА
  final String processPath;
  final List<CcDnsAnswer> answers;  // Q3: весь Answer, пусто если includeAnswers=false
}
class CcDnsAnswer { final String name; final int type; final String rdata; final int ttl; }
```

### Маппинг CcDnsQuery → TrafficEvent (в профайлере)

| TrafficEvent | источник из CcDnsQuery |
|---|---|
| `kind` | `failed ? dnsFail : dnsResolve` (Q2) |
| `domain` | `domain` (оригинальный, не CNAME-target — как сейчас) |
| `cnameChain` | `answers.where(type==CNAME).map(rdata)` (Q3 — из одного события, без ручной аккумуляции) |
| `ip` | первый `answers.where(type∈{A,AAAA}).rdata` (для dnsResolve) |
| `dnsRecordType` | `_qtypeToString(queryType)` (1→A, 28→AAAA, 5→CNAME, 65→HTTPS…) |
| `process` | `packageName` (НЕ null чаще — атрибуция из ядра) |
| `confidence` | `packageName.isNotEmpty ? verified : unattributed` (но unattributed станет РЕДКИМ) |
| `matchedVia` | `'dns_stream'` (было `'router_log'`) |

## Точки правки

1. **Kotlin** ([BoxCommandClient.kt](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxCommandClient.kt)):
   - `DnsQueryHandler`-реализация: `onQuery(q)` → map (геттеры выше) → `dnsQueriesEmitter.offer`.
     `answers()`-итератор читать как `chain()` (`while hasNext`). `getRcode()` класть КАК ЕСТЬ
     (signed int, `-1` сохранить — НЕ конвертить).
   - подписка: на `profilerClient` после connect — `sub = client.subscribeDNSQueries(true, handler)`.
     Хранить `DnsQuerySubscription` (как pingClient), `sub.close()` в disconnectProfiler/shutdownAll.
   - **forward-compat:** `subscribeDNSQueries` есть в rc.7 (javap ✓), но обернуть в `runCatching`
     на случай старого ядра (старое → `codes.Unimplemented`/нет метода → DNS-стрим просто пуст,
     fallback см. §180.5).
   - новый `dnsQueriesEmitter` (SnapshotEmitter? НЕТ — DNS событийный, не снапшот: эмитить
     по одному событию, как лог-строки; emitter без coalesce, прямой offer в sink).
2. **EventChannel** ([BoxVpnService.kt](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt)):
   `ccDnsQueriesSink` + канал `lxbox/cc/dns` (зеркало `ccConnectionsSink`/`lxbox/cc/connections`).
3. **Dart** ([cc_channel.dart](../../../app/lib/vpn/cc_channel.dart)):
   `CcDnsQuery`/`CcDnsAnswer` модели + `Stream<List<CcDnsQuery>> dnsQueries` (EventChannel
   `lxbox/cc/dns`), broadcast/replay как `connections`.
4. **Профайлер** ([traffic_profiler.dart](../../../app/lib/services/traffic_profiler.dart)):
   - `_ingestDnsQuery` (маппинг-таблица выше) + подписка в `_attachCcConnections`-стиле.
   - **ВЫПИЛ:** `_dnsRe`/`_dnsFailRe`, `_handleDnsLine`/`_handleDnsFailLine`, DNS-ветки 2/3
     в `_processLogLine` (ветка 1 `_packageRe` ОСТАЁТСЯ — нужна для TCP-атрибуции connId),
     `_DnsAccumulator`/`_dnsByConnId` (cnameChain больше не копим вручную).
   - тест-хук `feedDnsQueryForTest(CcDnsQuery)` (вместо `feedLogLineForTest` для DNS).

## Что НЕ трогаем / границы

- **`_packageRe` (router-лог package detection) ОСТАЁТСЯ** — это атрибуция TCP-conn по
  connId, не DNS. §180 убирает только DNS-парсинг из лога.
- **TrafficEventKind/cnameChain/dnsRecordType** — НЕ меняем, переиспользуем.
- **UI** (Domains tab, Live, DNS-бейджи §177-B) читают `TrafficEvent` — без правок.
- **§177-баннер** — НЕ трогаем код, но эффект: unattributed-DNS станет редким (атрибуция из
  ядра) → баннер почти не загорается естественно. Проверить, не нужно ли пересмотреть порог.

## §180.5 — fallback на старое ядро → ✅ ВАРИАНТ A (согласовано)

`subscribeDNSQueries` нет в ядре < rc.7. **Решение: жёстко rc.7+, текстовый DNS-парсинг
выпиливается начисто, fallback НЕ держим.** Обоснование: ядро пинится нами
(`libbox.version`), откат маловероятен; мёртвый regex-путь ради гипотетического отката —
долг. На старом ядре `subscribeDNSQueries` → `runCatching` проглотит (DNS-стрим пуст),
но текстового резерва нет — DNS в Live просто не будет до возврата rc.7+.

## Энергомодель / канал

DNS событийный (эмит на резолв), реже traffic-тиков. Подписка на `profilerClient`
(per-recording, §164 не паузит в фоне → DNS-журнал живёт свёрнутым). Буфер observable
ядра 256 гасит всплески. Отдельного тикера/клиента не нужно — метод-подписка на живом
profilerClient.

## Тесты

`traffic_profiler_test`:
- `CcDnsQuery(failed=false, answers=[CNAME a→b, A b→IP])` → `dnsResolve`, `cnameChain==[b]`,
  `ip==IP`, `domain==a`.
- `CcDnsQuery(failed=true, rcode=-1, error="timeout")` → `dnsFail`, не падаем на `-1`.
- `CcDnsQuery(packageName="com.x")` → `confidence==verified`, `process=="com.x"`.
- `rcode=-1` НЕ превращается в 4294967295 (Q1-регресс).
- (после выпила) `feedLogLineForTest('dns: exchanged …')` БОЛЬШЕ не создаёт событие
  (текстовый путь мёртв) — обновить/удалить старые DNS-лог-тесты.

## Device-verify (rc.7)

1. `subscribeDNSQueries` подписан, `/profiler/live` показывает DNS-события с `process` ИЗ
   ЯДРА (не unattributed) для трафика known-app.
2. cnameChain виден для домена с CNAME (напр. `*.t-bank-app.ru`).
3. DNS-fail (отключить сеть/битый домен) → `dnsFail` с `error`, `rcode=-1` не ломает UI.
4. §177-баннер: unattributed_count резко падает vs текстовый путь.
5. Регресс: TCP-атрибуция (`_packageRe`) жива; Domains tab наполняется.
