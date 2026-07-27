# §315 — Трасса DNS-группы в профайлере (kernel SPEC 035)

**Тип:** таска (наблюдаемость; достройка §312/§314)
**Статус:** реализовано
**Ядро:** sing-box-lx SPEC 035 (DNS_GROUP observability), пин `v1.14.0-lx.16-rc.3`
**Связано:** §312 (тип `group` + UI), §314 (Shield DNS дефолтным резолвером), §180/§018 (DNS-стрим), §261 (DNS в CC-мультиплексе)

---

## 1. Проблема

§314 поставил группу `dns_shield` **дефолтным резолвером** — через неё идёт
весь DNS-трафик. Но профайлер показывает только «резолвил `dns_shield`»:
какой из 9 членов реально ответил, была ли гонка, сколько проб и с какими
RTT — не видно. Ровно те вопросы, что возникают при разборе «почему DNS
тормозит / что отвалилось», остаются без ответа.

Ядро эти данные **уже отдаёт** в том же DNS-стриме (`writeDNSQuery`,
kernel SPEC 035 §3), клиент их молча теряет. javap rc.3 подтверждает
наличие в AAR:

```
DnsQuery.groupPath()   → StringIterator          // путь групп изнутри наружу
DnsQuery.attempts()    → DnsGroupAttemptIterator // хронология проб
DnsQuery.getFanned()   → boolean                 // в запросе был веер
DnsQuery.getSurvival() → boolean                 // режим выживания
DnsGroupAttempt: getServer / getServerType / getOutcome / getRTTMs
```

## 2. Семантика полей (контракт ядра, SPEC 035 §3)

| Сценарий | `dnsServer` | `attempts` | `fanned` | `survival` |
|---|---|---|---|---|
| штатный одиночный | цель | одна запись | false | false |
| сбой цели → веер спас | победитель веера | цель (сбой) + участники веера | **true** | false |
| выборы `fastest` / `parallel` | победитель веера | участники веера | **true** | false |
| выживание (чистых нет) | наименее грязный | одна запись | false | **true** |
| полный сбой | **тег группы** | все сделанные пробы | по факту | по факту |
| кеш-попадание | **тег группы** | пусто | false | false |

`outcome` пробы: `answered` · `timeout` · `network_error` · `servfail`.
Заброшенные пробы (сбой при уже завершённом запросе) в трассу не попадают —
это не исход. Опоздавшие ответы веера тоже (их не было на момент эмита);
полная картина живёт в state-RPC `getDNSGroups` (§312).

**`survival: true` — красный флаг:** чистых членов не осталось, резолв идёт
одной попыткой к наименее грязному. Отображается отдельным бейджем.

## 3. Изменения

### Kotlin ([BoxCommandClient.kt](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxCommandClient.kt))

`ProfilerHandler.writeDNSQuery` дочитывает 4 поля — итераторы по образцу
соседних `answers()`/`outbound()`, каждый в своём `runCatching` (старое ядро
без полей не должно ронять весь эмит).

### Dart ([cc_channel.dart](../../../app/lib/vpn/cc_channel.dart))

`CcDnsQuery` + поля `groupPath`/`attempts`/`fanned`/`survival`;
новая модель `CcDnsGroupAttempt{server, serverType, outcome, rttMs}`.
Дефолты пустые — старое ядро/старый native деградируют молча.

### Профайлер ([traffic_profiler.dart](../../../app/lib/services/traffic_profiler.dart))

Групповые поля кладутся в существующий `TrafficEvent.extra` — **без**
расширения самой модели события (она общая для TCP/UDP/DNS, групповое —
DNS-специфика):

| Ключ `extra` | Значение |
|---|---|
| `dns_group_path` | `"dns_shield"` (или `"inner → outer"` при вложенности) |
| `dns_attempts` | `"google_udp answered 12ms · quad9_doh timeout"` |
| `dns_fanned` | `"true"` (только когда true — иначе ключ не пишется) |
| `dns_survival` | `"true"` (аналогично) |

Пишется и в `dnsResolve`, и в `dnsFail` — на провале трасса важнее всего.

Формат `dns_attempts` — плоская строка, а не структура: `extra` типизирован
как `Map<String, Object?>` и рендерится `_copyRow`'ом (копирование строки).
Структурный список потребовал бы отдельного виджета — избыточно для
диагностического поля.

### UI ([traffic_event_detail_sheet.dart](../../../app/lib/screens/stats_screen/traffic_event_detail_sheet.dart))

В секцию DNS — три строки, каждая рисуется только при непустом значении:
`Group` (путь), `Attempts` (хронология), `Group mode` (бейджи
`fanned`/`survival`).

## 4. Что НЕ делаем

- Не расширяем `TrafficEvent` новыми полями — групповое живёт в `extra`
  (иначе TCP/UDP-события таскали бы мёртвые DNS-поля).
- Не трогаем фильтры профайлера (§230) — фильтровать по «был веер» пока
  незачем, данных мало.
- Не дублируем state-RPC `getDNSGroups` — он уже есть в §312 (экран DNS).

## 5. Тесты

`test/services/dns_group_trace_test.dart`:

1. `CcDnsQuery.fromMap` — маппинг всех 4 полей + вложенных `attempts`.
2. Пустой/битый map (старое ядро) → пустые дефолты, не бросает.
3. Профайлер: `dnsResolve` с веером → `extra` содержит путь/пробы/`dns_fanned`.
4. Профайлер: `survival` → `dns_survival` в extra.
5. Флаги `false` → ключей в `extra` НЕТ (не мусорим).
6. `dnsFail` с трассой → те же ключи (провал важнее всего).

## 6. Device-verify

1. Живой туннель с `dns_shield` → трафик → в Stats открыть DNS-событие:
   видны Group/Attempts.
2. Убить прямой путь (белые списки / выключить сеть провайдера) → в событии
   `fanned=true` и в Attempts видно сбойнувшую цель + победителя.
3. Кеш-попадание → `dnsServer` = тег группы, Attempts пусто (контракт ядра).
