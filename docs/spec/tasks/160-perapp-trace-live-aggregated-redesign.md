# 160 — Per-app trace: 4 саб-таба → тогл Live / Aggregated + общий фильтр + drill-down детали

| Поле | Значение |
|------|----------|
| Статус | **Done** — в develop (`15da916`), analyze 0 / 1196 tests green, on-device проверено; вышло в **v2.4.1** |
| Дата | 2026-06-22 |
| Тип | Task (нетривиальное изменение UI существующей фичи §044) |
| Фича-владелец | [`044 per-app traffic profiler`](../features/044%20per-app%20traffic%20profiler/spec.md) |
| Затронутые файлы | `app/lib/screens/per_app_trace_tab.dart`, `app/lib/screens/per_app_trace_tab/widgets/{live_view,domains_view,ips_view,connections_view}.dart`, новый `app/lib/screens/per_app_trace_tab/widgets/aggregated_view.dart`, новый общий `app/lib/screens/stats_screen/traffic_event_detail_sheet.dart`, новый `app/lib/screens/stats_screen/aggregate_detail_sheet.dart`, новый общий движок `app/lib/screens/stats_screen/trace_explorer.dart` |
| Целевой релиз | **v2.4.1** |
| Связанные | [`152 conn-detail-sheet`](152-conn-detail-sheet.md) — образец bottom-sheet для одного соединения (паттерн `_group`/`_row`/Copy JSON), переиспользуем структуру |

> **Процесс этой задачи** (по прямому указанию юзера): git **только** по явной команде; цикл = спека → код → APK на телефон → юзер проверяет → «коммить». НЕ коммитить по инерции после зелёных тестов.

> **UX-правки по фидбэку с устройства (2026-06-22):**
> - START — иконка-треугольник `Icons.play_arrow` (была точка `fiber_manual_record`); STOP остаётся квадратом.
> - Тогл `Aggregated` сокращается до `Agg` когда режим выбран (справа появляется ось Domain/IP — полная подпись не влезает).
> - **Pause/Resume** в Live (IconButton ⏸/▶ справа от поиска, только в Live): замораживает **отображение** ленты (снимок), запись продолжается. Снимок фиксируется в момент паузы; фильтр/поиск применяются к нему. Уход из Live сбрасывает паузу.
> - Aggregated счётчик соединений = **активные/всего** (`0/5 conns`). Активные = `max(0, open − close)` по ключу (`AggregatedView.activeByKey`, чистая функция, покрыта `test/screens/aggregated_active_conns_test.dart`). `connId` у tcp-событий не заполняется ядром, поэтому матчинг по count, не по id. То же в своде sheet агрегата.

---

## Контекст и боль

Запрос пользователя (4PDA, #299): «в Conns можно тапнуть по соединению и увидеть детали — хочу так же в App». При разборе выяснилось, что App-вкладка (per-app trace, §044) перегружена: **4 саб-таба** Live / Domains / IPs / Connections, при этом:

- **Connections — дубль Live.** Это буквально `s.events`, отфильтрованные на `tcp/udp open/close`, + inline-expand (CNAME / All IPs / Rule / issues). Как только у Live появится тап→детали (где есть всё то же самое и больше) — Connections не несёт нового.
- **Domains и IPs — две проекции одного агрегата.** «Куда по именам» (`s.byDomain`) и «куда по адресам» (`s.byIp`). Это одна сущность с двумя осями, а не два таба. В самом коде уже была попытка их слить (`domains_view.dart` doc-comment: «Search field … folded роль ушедшей IPs tab'ы»), но IPs вернули отдельным табом.
- **Тапа в детали нет нигде в App** (в отличие от Conns, §152).

## Цель

Свернуть 4 саб-таба → **тогл Live / Aggregated** (2 режима) с **общим фильтром** сверху и **drill-down деталями по тапу** в обоих режимах. Сделать так, чтобы App-режим стал частным случаем общего движка «Live + Aggregated + фильтр», который позже (отдельным шагом) переиспользуется и в Stats→Live.

**Порядок реализации (решение юзера):** сначала App. Если зайдёт — тем же паттерном Stats→Live (вне scope этой таски, см. §«Будущее»).

## Решения (согласованы с юзером)

| # | Вопрос | Решение |
|---|--------|---------|
| 1 | Структура App | 4 саб-таба → **тогл `Live / Aggregated`** через `SegmentedButton` |
| 2 | Aggregated | слитые Domains+IPs, вторичный `SegmentedButton` **by Domain / by IP** |
| 3 | Connections | **удаляется** (роль = Live + чип TCP/UDP + детали события) |
| 4 | Фильтр | **общий** сверху (поиск + чипы типа события), один на оба режима |
| 5 | Live: тап по строке | → детальный sheet **события** |
| 6 | Aggregated: тап по строке | → детальный sheet **агрегата** = свод + список всех соединений по этому домену/IP; каждое соединение в списке тапается → sheet события (drill-down) |
| 7 | Внутри sheet: domain / ip / process | кликабельны → кладут значение в **общий поиск**; для агрегата кнопка «View in Aggregated» → переключает на Aggregated(by Domain) + поиск |
| 8 | Старое «тап под-зоны строки → в поиск» (Live `ipChip` → onViewInDomains) | **убрать со строки**; любой тап по строке = детали. «фильтр в поиск» переезжает внутрь sheet |
| 9 | App = Live + фикс. процесс | да, концептуально — но фактическая фиксация процесса уже сделана самим `Session.targetPackage`; общий движок просто работает поверх `session.events`. Унификация с Stats→Live — будущий шаг |

---

## Текущее устройство (как есть)

```
per_app_trace_tab.dart  (StatefulWidget, SingleTickerProviderStateMixin)
├── _header            — picker приложения + ▶ Rec
├── _statsRow          — суммарная статистика session
├── _secondaryPackagesRow
├── TabBar (4)  ─────────────────────────────────────┐
│     Live | Domains | IPs | Connections             │
└── TabBarView                                        │
      ├── LiveView          (widgets/live_view.dart)  │  ← свой _eventTile, ipChip→onViewInDomains
      ├── DomainsView       (widgets/domains_view.dart)│  ← свой _searchCtrl, focusDomain, ExpansionTile
      ├── IpsView           (widgets/ips_view.dart)   │  ← ListTile, ipChip→onViewInDomains
      └── ConnectionsView   (widgets/connections_view.dart) ← _ConnTile inline-expand, View in Domains
```

Данные: всё из `Session` (`traffic_profiler/models.dart`):
- `s.events: List<TrafficEvent>` — таймлайн (источник Live и Connections)
- `s.byDomain: Map<String,DomainStats>` — агрегат (источник Domains)
- `s.byIp: Map<String,IpStats>` — агрегат (источник IPs)

`TrafficEvent` поля (для sheet события): `ts, kind, domain, cnameChain, ip, port, outboundChain, upBytes, downBytes, duration, connId, process, processInferred, network, rule, rulePayload, rawLogLine, confidence, matchedVia, shownBecause, dnsRecordType, backfilled, issues, extra`.

`DomainStats`: `domain, connections, upBytes, downBytes, firstSeen, lastSeen, ips:Set, cnameTargets:Set, outbounds:Set, issues`.
`IpStats`: `ip, ports:Set, connections, upBytes, downBytes, firstSeen, lastSeen, outbounds:Set`.

---

## Целевое устройство

```
per_app_trace_tab.dart
├── _header            — без изменений
├── _statsRow          — без изменений
├── _secondaryPackagesRow — без изменений
├── SegmentedButton<_TraceMode>   [ Live | Aggregated ]   ← заменяет TabBar(4)
├── _filterBar (общий)            🔍 поиск + чипы DNS/DNS×/TCP/TCP·/UDP
│                                 (+ Unattributed-only; в Aggregated чипы типа скрыты)
└── body (по _mode):
      ├── Live:        LiveView(... onOpenDetail)        ← тап строки → TrafficEventDetailSheet
      └── Aggregated:  SegmentedButton [by Domain|by IP]
                       AggregatedView(axis, filter, onOpenAggregate)
                                                          ← тап строки → AggregateDetailSheet
```

### Новые/изменённые модели UI-состояния (в `_PerAppTraceTabState`)

```dart
enum _TraceMode { live, aggregated }
enum _AggAxis { domain, ip }

_TraceMode _mode = _TraceMode.live;
_AggAxis _aggAxis = _AggAxis.domain;

// Общий фильтр (поднят из DomainsView/LiveView в parent):
final TextEditingController _searchCtrl = TextEditingController();
String _search = '';
final Set<TrafficEventKind> _kindFilter = {};   // только для Live
bool _onlyUnattributed = false;
```

Удаляется: `_subTabs` (TabController), `_focusDomain`/`_consumeFocusDomain`/`_navigateToDomain` (старая focus-навигация Connections→Domains; заменяется sheet'ом). Тикер «Recording NN:NN» остаётся.

### 1. Общий sheet события — `traffic_event_detail_sheet.dart`

`showTrafficEventDetailSheet(context, TrafficEvent e, {required void Function(String key) onSearchKey})`.

Структура — по образцу §152 `connection_detail_sheet.dart` (`DraggableScrollableSheet` + grabber + header + grouped `_group`/`_row` + footer Copy JSON). Группы:

| Группа | Строки (только непустые) |
|--------|--------------------------|
| Destination | Host (`domain`)·, Dest IP (`ip`)·, Dest port (`port`) |
| DNS | Record type (`dnsRecordType`), CNAME (`cnameChain.join(" → ")`) |
| Network | Network (`network`), Kind (`kind.name`) |
| Process | Process (`process`)·, Confidence (`confidence.name`), Matched via (`matchedVia`), Shown because (`shownBecause`) |
| Routing | Outbound chain (`outboundChain.join("\n")`), Rule (`rule` + `rulePayload`) |
| Traffic | Upload (`upBytes`), Download (`downBytes`) |
| Timing | Started (`ts`), Duration (`duration`) |
| Issues | по одной строке на `issue.description` (⚠ error-цвет) |
| Raw | `rawLogLine` (monospace, если есть) |

Строки помеченные · (Host / Dest IP / Process) — **кликабельны → `onSearchKey(value)`** (вместо copy). Остальные строки — copy по тапу (как в §152). Footer: Copy JSON. (Кнопки Close connection нет — событие историческое, не активный conn.)

Confidence-строка красится по уровню (verified/secondary/inferred/unattributed → как badge в live_view).

### 2. Sheet агрегата — `aggregate_detail_sheet.dart`

`showAggregateDetailSheet(context, {required Session session, required _AggAxis axis, required String key, required void Function(String) onSearchKey, required void Function(TrafficEvent) onOpenEvent})`.

Header: имя домена/IP + бейдж axis. Тело:

- **Свод** (grouped, из `DomainStats`/`IpStats`): connections, ↑↓ totals, для domain — CNAME / IPs(chips→onSearchKey) / outbounds / first-last; для ip — ports / outbounds / first-last.
- **Connections** — список **всех событий** `session.events`, относящихся к этому ключу:
  - axis=domain → `e.domain == key`
  - axis=ip → `e.ip == key`
  фильтруем на `tcpOpen/tcpClose/udpOpen` (как старый ConnectionsView), newest-first. Каждая строка = компактный conn-tile (ts · host:port · ↑↓ · ⚠) → тап → `onOpenEvent(e)` → открывает `TrafficEventDetailSheet` поверх (drill-down).

Footer: Copy JSON (свод агрегата).

### 3. `AggregatedView` (новый, слияние Domains+IPs)

`AggregatedView({Session?, _AggAxis axis, String search, void Function(String key) onOpenAggregate})`.

- axis=domain → `s.byDomain.values`, сорт по `up+down` desc, фильтр `_matchesSearch` (domain||ip||cname — перенести из DomainsView).
- axis=ip → `s.byIp.values`, сорт по `up+down` desc, фильтр (ip||port).
- Каждая строка — `ListTile`/row со сводкой (как нынешние Domains/IPs subtitle), **без ExpansionTile** (раскрытие переехало в sheet) → тап = `onOpenAggregate(key)`.
- ⚠-маркер при `issues` (domain).

### 4. `LiveView` — добавить `onOpenDetail`

- Добавить параметр `void Function(TrafficEvent) onOpenDetail`; обернуть `_eventTile` в `InkWell(onTap: () => onOpenDetail(e))`.
- Убрать `onViewInDomains`/`ipChip`-навигацию **со строки** (IP больше не отдельная tap-зона в ряду; полный IP виден в деталях). Summary остаётся текстом.
- Фильтр (search/kind/unattributed) теперь применяется **снаружи** (parent передаёт уже отфильтрованный список или фильтр-параметры). Решение: parent фильтрует `session.events` и передаёт `List<TrafficEvent> events` в LiveView (LiveView становится «тупым» рендером). System-wide unattributed-секция остаётся.

### 5. `per_app_trace_tab.dart` — сборка

- TabBar(4)+TabBarView → `SegmentedButton<_TraceMode>` + `_filterBar` + `IndexedStack`/switch по `_mode`.
- `_filterBar` — портировать из `live_events_tab.dart` (поиск + `_kindChips` + Unattributed-only). В Aggregated режиме чипы типа события скрыть (нерелевантны), оставить поиск.
- Удалить импорты/использование `ConnectionsView`, `DomainsView`, `IpsView` (заменены на `AggregatedView`). Файлы `connections_view.dart`, `domains_view.dart`, `ips_view.dart` — **удалить** после переноса логики поиска/строк в `AggregatedView`. `ip_chip.dart`/`empty_view.dart` — оставить (переиспользуются).

---

## Drill-down карта (симметрия)

| Режим | Строка | Тап → |
|-------|--------|-------|
| Live | событие | `TrafficEventDetailSheet(event)` |
| Aggregated · by Domain | домен | `AggregateDetailSheet(domain)` → внутри список conn → `TrafficEventDetailSheet(event)` |
| Aggregated · by IP | IP | `AggregateDetailSheet(ip)` → внутри список conn → `TrafficEventDetailSheet(event)` |
| Любой sheet | поле domain/ip/process | `onSearchKey(value)` → закрыть sheet + положить в общий поиск (+ для агрегата: switch на Aggregated by Domain) |

---

## Тесты

`flutter test` (логика):
- фильтр `_matchesSearch` для domain/ip осей (перенос из DomainsView — сохранить покрытие).
- выборка событий агрегата: `events.where(domain==key && kind∈{tcpOpen,tcpClose,udpOpen})` — корректный набор.
- sheet события: grouped-rows скрывают пустые поля (нет пустых групп).

Widget-smoke (по возможности): тогл Live↔Aggregated переключает body; ось Domain↔IP меняет список; тап открывает sheet.

**On-device (обязательно, до git):**
- App → выбрать приложение (напр. Telegram) → Rec → события идут.
- Live: тап по строке → детали; в деталях тап по domain → закрывается, поиск заполнен.
- Aggregated by Domain: тап по домену → свод + список conn → тап по conn → детали события.
- Aggregated by IP: hostless IP виден; тап → свод + conn.
- Общий фильтр работает в обоих режимах; чипы типа — только в Live.

---

> **Модульность — TraceExplorer (2026-06-22):** по фидбэку «App лучше Live, сделай Live по образцу App без дубля» движок вынесен в общий `stats_screen/trace_explorer.dart` (тогл Live/Aggregated + общий фильтр + детали + пауза). App (`per_app_trace_tab`) и Stats→Live (`live_events_tab`) — тонкие обёртки: каждая отвечает только за свой источник событий и шапку, тело = `TraceExplorer`.
> - Источник Live: `globalRollingBuffer` (агрегаты считаются на лету общим `computeTraceAggregates`, вынесенным из `Session._recompute`). App: `session.events`.
> - `aggregate_detail_sheet` и `AggregatedView` развязаны от `Session` — принимают `events`+`byDomain`+`byIp` напрямую.
> - 3-строчная строка события + иконка приложения в общем `LiveView` (образец Conns-row): `[icon] time·kind·conf·summary·⚠·›` / `process` / `chain·rule·duration` (+CNAME/DNS-record/маркеры).
> - Удалён `live_events_tab/event_tile.dart` (старый LiveEventTile) — заменён общим `LiveView`.
> - Live получил Aggregated+детали+паузу «бесплатно». System-wide app-multi-select остался в `live_events_tab` как внешний пре-фильтр.

## Исправлено — баг «чужие приложения в сессии» (open/close attribution symmetry)

**Диагностика по Debug API на устройстве** (сессия Telegram, 54 события): 14 событий — от чужих приложений (youtube/imo/oplus/gsf/heytap/grandstream), все `kind=tcpClose`, `confidence=verified`, `matched_via=connections_meta`. То есть НЕ inferred-по-CDN (как предполагалось) и не unattributed.

**Корень:** в `_pollConnections` атрибуция считается при **open** (`_resolveForSession` → отбрасывает чужие, `return null`), но `_connSnapshots[id]` создаётся для **всех** соединений (нужен global-буферу) с реальным (чужим) process'ом и `confidence=verified`. При **close** событие писалось в session **безусловно** (`if (s != null) _appendEvent`) — без проверки атрибуции. Отсюда ровно `kind=tcpClose` у всех чужих: open отброшен, close прошёл.

**Фикс:** атрибуция фиксируется на open и наследуется close'ом. Добавлено поле `_ConnSnapshot.inSession` (= `resolved != null` при open); на close — `if (s != null && snap.inSession)`. Чужие close уходят; target + unattributed (Strategy 5 возвращает не-null) остаются. Регрессионный тест — `traffic_profiler_test.dart` «non-target connection close also ignored».

> Прежняя гипотеза (фильтровать inferred/чужой-process в UI) **снята** — баг оказался в ядре атрибуции, чинится там, а не в UI. Сессия/JSON/API/агрегаты/байты теперь чистые.

## Не входит (Будущее)

- Перенос того же движка в **Stats→Live** (`live_events_tab.dart`) — отдельная таска после одобрения App-версии. Цель: один общий виджет, App = он же с фиксированным `targetPackage`-фильтром.
- Top Domains/IPs на Overview-экране (если решим, что агрегат «по объёму» удобнее наверху).

## Обновления в фиче §044

После реализации — обновить doc-comment `per_app_trace_tab.dart` (убрать описание 4 саб-табов) и раздел UI в `features/044 .../spec.md` (4 таба → тогл Live/Aggregated), отметить §160.
