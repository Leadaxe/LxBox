# 044 / new-profiler — редизайн: одна control-строка + фильтр-окно

> **Статус (2026-06-27):** ✅ Реализовано + device-pending. Код: control-строка
> (`trace_explorer.dart`), `ProfilerFilter` + `ProfilerFilterSheet`, `AppMultiPicker`,
> `eventsToJson`, Live→Profiler, настраиваемый retention. Сьют 1274 зелёный.
> Коммиты: 7e27ec0/f959424 (база) + fdcb997 (иконка главной) + b98ce0c (фильтр
> Protocol+App + retention).
>
> **Уточнения по итогам device-фидбэка юзера (2026-06-27):**
> - Фильтр-окно: **2 вкладки** (не 4). Таб 1 = **Protocol** (DNS/TCP/UDP чипы в
>   одном табе). Таб 2 = **App** — галочки **замеченных в трафике** пакетов
>   (`seenApps` из текущих событий) + «**потеряшки**» (unattributed) галочкой +
>   кнопка **«Add app»** (полный `AppMultiPicker` для пакета, которого ещё не было).
> - `onlyUnattributed` (эксклюзивно) → **`includeUnattributed`**: потеряшки —
>   пункт app-оси, работает в **OR** с выбранными app (`process∈apps ∨ unattr`).
> - **Live retention настраиваемо** (было жёстко 60s): `SettingsStorage.
>   profiler_retention_sec`, default **10 мин**, опции 1m/10m/1h в control-строке
>   (кнопка `⏱ history`). Hard cap буфера 3000→20000.
> - Иконка фильтра на главном унифицирована: `Icons.tune` → `Icons.filter_list`.

> **Исходная спека (обсуждено 2026-06-26).** Ниже — первоначальный план (4 таба
> App/DNS/TCP/UDP); фактическая реализация = 2 таба (см. уточнения выше).
> **Родитель:** [`spec.md`](spec.md) — фича 044 Per-app traffic profiler.
> **Предшественник:** [`tasks/160-perapp-trace-live-aggregated-redesign.md`](../../tasks/160-perapp-trace-live-aggregated-redesign.md)
> (свернул 4 саб-таба → тогл Live/Aggregated + общий фильтр-строки). Этот документ —
> **следующий шаг той же линии**: свернуть управление в ОДНУ строку, фильтр вынести
> в окно (как фильтр на главной), Live-вкладку переименовать в **Profiler**.
> **Связано:** §181 (`routingLine` в строке события), §174/§178 (chains/detour),
> [`home/widgets/filter_panel.dart`](../../../../app/lib/screens/home/widgets/filter_panel.dart)
> (эталон фильтр-окна: TabBar + amber-точка + сводка InputChip + контент таба).

## Зачем

Сейчас управление в `TraceExplorer` занимает **три ряда**: mode-toggle
(Live/Aggregated) + строка поиска с Pause + строка чипов (DNS/TCP/UDP + Unattributed).
Плюс per-app/Live ещё тащат свои хедеры. Много вертикали съедено контролами, фильтр
размазан. Цель — **одна строка управления** (как панель инструментов), а фильтр (вкл.
выбор приложений) — в отдельное **окно** по уже существующему паттерну фильтра главного
экрана.

## Что меняется (верхнеуровнево)

1. **Live-вкладка → «Profiler».** Переименование (`StatsScreen` tab label + проза).
   Вкладок остаётся **4**: Stats / Conns / **App** / **Profiler**. App-вкладку НЕ
   удаляем этой итерацией.
2. **Общий `TraceExplorer`** получает новую **control-строку** — применяется к ОБОИМ
   потребителям (App + Profiler), без дубля UI.
3. **Фильтр уезжает в окно** (bottom-sheet) по паттерну `filter_panel`.
4. **Export** переносится в control-строку (доступен и в Profiler, и в App).

```
╔══════════════════════════════════════════════════════════════════════╗
║  PROFILER                              (вкладки: Stats · Conns · App · ►)║
╠══════════════════════════════════════════════════════════════════════╣
║   ┌──────┐  ┌──────┐  ┌───────────┐  ┌────────────────────┐  ┌─────┐   ║
║   │ ▶/⏸ │  │ ⏺/⏺̶ │  │  ▤ / ⊞ ▾  │  │  ⛛ Filter   • (3)  │  │  ⤓  │   ║
║   └──────┘  └──────┘  └───────────┘  └────────────────────┘  └─────┘   ║
║    Live      Record    Aggregate ▾     Filter-окно            Export   ║
║    /pause    persist    (меню)          (tap → sheet)         (фильтр.) ║
║              ↔tab-scope                                                 ║
║  ── активные фильтры (если есть) ──────────────────────────────────    ║
║  [📱Chrome ×] [📱Telegram ×] [DNS ×] [/googleapis/ ×]      ← бейджи     ║
║  ──────────────────────────────────────────────────────────────────   ║
║  21:43  [tcp] com.android.chrome ⇒ final ⇒ vpn-1 :                     ║
║         🇫🇮Финляндия → 🔥WARP → play-fe.googleapis.com · 930ms          ║
║  21:43  [dns] com.android.chrome  A github.com → 140.82.x · 12ms       ║
║  ▼ System-wide (no owner) — 28                                         ║
║  21:42  [dns] ?  A  dc-stat-in.heytapmobile.com → … · 8ms              ║
╚══════════════════════════════════════════════════════════════════════╝
```

## Control-строка — 5 affordance

Живёт в `TraceExplorer` (заменяет нынешние `_modeToggle` + `_filterBar`). Одна `Row`.

| # | Кнопка | Семантика | Состояние |
|---|---|---|---|
| 1 | `▶ / ⏸` | **Live / pause** — тогл ОТОБРАЖЕНИЯ (запись не трогает). ⏸ = список замер на снимке. | существующий `_paused` + `_frozenEvents` |
| 2 | `⏺ / ⏺̶` | **Record** — тогл **persistent ↔ tab-scoped** (см. ниже) | НОВОЕ — `recordingScope` |
| 3 | `▤ / ⊞ ▾` | **Aggregate** — кнопка-**меню**: Поток / by Domain / by IP | заменяет `_mode`+`_aggAxis` на enum из меню |
| 4 | `⛛ • (N)` | **Filter** — открывает фильтр-окно. `(N)` = счётчик активных фильтров, `•` точка если есть | НОВОЕ — открывает `ProfilerFilterSheet` |
| 5 | `⤓` | **Export** — выгрузить **видимый отфильтрованный список** событий (см. Export) | НОВОЕ в explorer (перенос из App overflow) |

### Кнопка 2 — Record: persistent ↔ tab-scoped

Два режима ЗАПИСИ (не отображения):

- **`⏺` persistent** (заполненный) — пишем всегда, в фоне тоже; уход с вкладки запись
  не останавливает. = текущее `startGlobalRecording()`.
- **`⏺̶` tab-scoped** (контур/серый) — пишем **только пока вкладка открыта**: старт
  записи на `initState`/вход, стоп на `dispose`/уход. Энергоэкономия для «глянул и
  ушёл».

Реализация scope: новое поле в потребителе (Profiler/App), напр. `enum RecordingScope
{ persistent, tabScoped }`. tap по кнопке тоглит scope; при `tabScoped` — хук на
lifecycle вкладки стартует/стопит `globalRecording`. **Профайлер-бэкенд не меняем** —
это UI-обёртка над `startGlobalRecording`/`stopGlobalRecording`.

> Открытый нюанс реализации: tab-scoped requires знать visibility вкладки. В
> `StatsScreen` табы — `TabBarView`; видимость ловим через `TabController.index` или
> `VisibilityDetector`. Решить при коде — посмотреть как §124 background-mode уже
> детектит «экран не виден».

### Кнопка 3 — Aggregate (меню вместо SegmentedButton)

Заменяет нынешний `_modeToggle` (Live/Aggregated SegmentedButton + ось Domain/IP).
Tap → `PopupMenu`:

```
● Поток событий (no grouping)   ← дефолт, иконка ▤  → _Mode.live
○ Свернуть по Domain            ← иконка ⊞          → _Mode.aggregated + AggAxis.domain
○ Свернуть по IP                ← иконка ⊞          → _Mode.aggregated + AggAxis.ip
```

Внутреннее состояние то же (`_Mode` + `AggAxis`), меняется только триггер (меню vs
сегменты). Иконка/подпись кнопки отражает выбор.

## Фильтр-окно (`ProfilerFilterSheet`)

Новый файл, напр. `app/lib/screens/stats_screen/profiler_filter_sheet.dart`.
Bottom-sheet (modal). **Паттерн 1:1 с `filter_panel.dart`** главного экрана:

```
┌──────────────────────────────────────────────  [✕]  ┐
│  ┌─────┬─────┬─────┬─────┐    ← TabBar, amber-точка   │
│  │App •║ DNS │ TCP │ UDP │      на табе с фильтром     │
│  └─────┴─────┴─────┴─────┘                            │
│  ── сводка активных (InputChip: tap→таб, ✕→снять) ──  │
│  [📱Chrome ×] [📱Telegram ×] [DNS ×]                  │
│  ┌─ контент активного таба ───────────────────────┐  │
│  │ App:  🔍 поиск…   ☐ показать системные          │  │  ← мульти-пикер
│  │   ☑ Chrome        com.android.chrome            │  │
│  │   ☐ Play Services com.google.android.gms        │  │
│  │ DNS:  [✓ resolve] [✓ fail]                      │  │  ← чипы фаз
│  │ TCP:  [✓ open] [✓ close]                        │  │
│  │ UDP:  [✓ udp]                                   │  │
│  └─────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────┘
```

### Две независимые оси

- **App-таб** = фильтр «по процессу» (мульти-выбор пакетов, `Set<String>`).
- **DNS/TCP/UDP-табы** = фильтр «по типу события» (чипы фаз).

Оси ортогональны — можно «Chrome + только DNS» одновременно. Сводка-чипы сверху
показывают активное с обеих осей (как `_summaryChips` в `filter_panel`: tap → нужный
таб, ✕ → снять).

### App-таб — мультивыбор приложений

`SingleAppPickerScreen` — single-select (`Navigator.pop(packageName)` по `onTap`).
Нужен **мульти-select** вариант: чекбоксы + накопление в `Set<String>` (без `pop`,
живёт в state sheet'а). Источник списка = `AppInfoCache.loadAllApps()` (тот же, что в
single-picker), `☐ показать системные` = тот же `_showSystem`. Можно вынести общий
виджет `AppMultiPicker` или параметризовать существующий picker `multi: bool`.

### App-таб СКРЫТ в App-вкладке

В **App-вкладке** target-пакет уже зафиксирован сессией (весь экран про один app) —
фильтровать по app не по чему. Значит: **в App-вкладке таб «App» в фильтр-окне не
показываем** (передаём флаг `showAppTab: false`). Остаются DNS/TCP/UDP. В Profiler —
все 4 таба.

### Перенос текущих фильтров

Нынешний `TraceExplorer` держит: `_search` (TextField), `_kindFilter`
(`Set<TrafficEventKind>`), `_onlyUnattributed`. В новой модели:
- `_kindFilter` → DNS/TCP/UDP-табы (та же `_kindFamily`-логика §177: чип ловит обе
  фазы семейства).
- app-мультивыбор → App-таб (в Profiler берёт `_appFilter` из `live_events_tab`,
  который уже есть; в App-вкладке отсутствует).
- `_search` — оставить отдельным мелким полем в control-строке ИЛИ внести в окно
  (search domain/IP/app). **Рекомендация:** search оставить в окне (App-таб search =
  по приложениям; общий текст-поиск — отдельной строкой в окне над табами, т.к. он
  кросс-осевой: матчит domain/ip/process). Решить при коде; не плодить две строки в
  control-баре.
- `_onlyUnattributed` — чип в окне (или в сводке). Был на Live-строке; переезжает.

## Export (перенос/обобщение)

В App-вкладке export = `_shareSession`/`_copySession` через **`sessionToJson(Session
s)`** (`session_json.dart`) — принимает `Session` (с `byDomain`/`byIp`/`toMetaJson`).
В Profiler **`Session`-объекта нет**, только список `TrafficEvent` (rolling buffer).

**Решение (юзер):** экспортируем **видимый отфильтрованный список событий**. Нужен
вариант сериализации из списка событий, не из `Session`:

```dart
// session_json.dart — новый хелпер рядом с sessionToJson
Map<String, Object?> eventsToJson(List<TrafficEvent> events) {
  final agg = computeTraceAggregates(events); // уже есть в trace_explorer
  return {
    'exported_at': …,            // ts
    'event_count': events.length,
    'events': events.map((e) => e.toJson()).toList(),
    'by_domain': agg.byDomain.values.map((d) => d.toJson()).toList(),
    'by_ip': agg.byIp.values.map((i) => i.toJson()).toList(),
  };
}
```

Кнопка `⤓` в control-строке → выгружает `eventsToJson(<видимый отфильтрованный
список>)` тем же `Share.share` + «copy to clipboard» (как `_copySession`). App-вкладка
сохраняет и старый `sessionToJson`-export в overflow (сессия как единица), и получает
кнопку `⤓` (видимый список) — не конфликтуют.

## Точки правки

1. **`trace_explorer.dart`** — заменить `_modeToggle`+`_filterBar` на **control-строку**
   (5 affordance). Aggregate → меню. Filter → открывает `ProfilerFilterSheet`. Export
   → `eventsToJson` видимого списка. Record-scope тогл. `_applyFilter` остаётся, но его
   входы (`_kindFilter`/`_appFilter`/`_search`/`_onlyUnattributed`) теперь приходят из
   окна. Параметр `showAppTab` (Profiler=true, App=false) — пробросить в sheet.
2. **`profiler_filter_sheet.dart`** (НОВЫЙ) — bottom-sheet по паттерну `filter_panel`:
   TabBar(App?/DNS/TCP/UDP, amber-точка) + сводка InputChip + контент таба. Возвращает/
   мутирует фильтр-state (через callback или shared model).
3. **App-мультипикер** — мульти-select поверх `single_app_picker_screen.dart`
   (`AppMultiPicker` или `multi: bool`). `Set<String>` selected.
4. **`session_json.dart`** — `eventsToJson(List<TrafficEvent>)` (+ `computeTraceAggregates`).
5. **`live_events_tab.dart`** — переименовать вкладку Live→**Profiler** (label в
   `StatsScreen`), отдать `_appFilter` в новый sheet вместо локального pre-фильтра
   (или оставить как источник). `showAppTab: true`.
6. **`per_app_trace_tab.dart`** — `TraceExplorer(showAppTab: false)`; export-кнопка `⤓`
   в control-строке (overflow-share по `Session` оставить). App уже зафиксирован.
7. **`StatsScreen`** — tab label «Live» → «Profiler».

## Что НЕ трогаем

- Профайлер-бэкенд (`traffic_profiler.dart`) — record-scope это UI-обёртка над
  существующими `startGlobalRecording`/`stop`.
- App-вкладку как концепт (выбор app + saved sessions + verbose/wipe overflow) — живёт.
- `routingLine`/`TrafficEvent`/детальный sheet (§181) — строка события без изменений.
- Ядро — фильтрация целиком клиентская.

## Тесты

- `TraceExplorer`: фильтр по app-мультивыбору (несколько пакетов) + по типу
  одновременно (ортогональность осей).
- `eventsToJson`: список событий → JSON с пересчитанными `by_domain`/`by_ip`.
- `showAppTab=false` → App-таб отсутствует в sheet.
- Record-scope тогл (persistent ↔ tab-scoped) — поведение старт/стоп (если тестируемо
  без device; иначе device-verify).

## Открытые вопросы реализации (решить при коде, не блокеры спеки)

1. tab-scoped visibility-детект (TabController.index vs VisibilityDetector) — свериться
   с §124 background-mode.
2. Куда деть кросс-осевой `_search` — отдельной строкой в окне над табами (рекоменд.).
   Не плодить поле в control-баре.
3. `AppMultiPicker`: новый виджет vs `multi:bool` в существующем — по месту, что чище.
