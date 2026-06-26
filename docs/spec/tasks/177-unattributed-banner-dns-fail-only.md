# §177 — Профайлер: баннер только на сбои + объединение DNS-бейджей/фильтров

**Тип:** bug-fix (диагностическая точность) + UI-консистентность
**Статус:** Реализовано (части A + B); device-verify впереди
**Связано:** §048 (system-wide observer + баннер), §176 (TCP-фазы в профайлере),
§171 (DNS из core-логов), §160 (event-детали)

Две смежные правки диагностической точности профайлера, вскрытые device-проверкой
§176:
- **A. Баннер** (реализовано) — `unattributedBannerActive` ложно горел на
  успешных DNS; теперь в счёт идут только признаки сбоя.
- **B. UI DNS-бейджи/фильтры** (реализовано) — `DNS`/`DNS×` как два разных
  бейджа/фильтра — лишняя дробность; объединяем по образцу TCP.

---

## Часть A — баннер unattributed

## Симптом

Баннер «много unattributed» (`unattributedBannerActive`) ложно горит почти
постоянно на устройстве с активным фоном.

Device-наблюдение (vc2828, 2026-06-26, `/profiler/live/unattributed`): 38 событий,
**ВСЕ `dnsResolve` с `process=None`**, ноль `dnsFail`. Домены узнаваемые
(youtubei.googleapis.com, owner-api.teslamotors.com, mdp-appconf-in.heytapdl.com)
— те же приложения, что в TCP-срезе атрибутируются как `verified`
(com.teslamotors.tesla, com.heytap.htms).

## Корень

`recentUnattributedCount` ([traffic_profiler.dart](app/lib/services/traffic_profiler.dart) ~229)
считает в баннер ЛЮБОЕ событие с `confidence == unattributed`. Но успешный
`dnsResolve` без владельца — это **норма, не сбой**: DNS парсится из core-лога
(`_handleDnsLine`) и атрибутируется только при наличии рядом строки
`router: found package name` с тем же connId, которой для резолва часто нет
(DNS уходит раньше, чем роутер определил владельца). TCP того же домена
атрибутируется отлично (несёт packageName из ядра `getProcessInfo`).

Итог: баннер реагирует на нормальный неатрибутированный DNS-фон → теряет смысл
сигнала «system-wide ПРОБЛЕМА» (замысел §048).

## Решение (вариант A)

В счёт баннера идут только **признаки сбоя**:
- `dnsFail` (DNS× — реальная ошибка резолва из лога ядра)
- `tcpOpen` / `udpOpen` с `process == null` (TCP/UDP без владельца — возможная
  утечка/обход)

Успешный `dnsResolve` с `proc=None` — НЕ тревога, в счёт баннера не идёт.

**Blast-radius минимальный — правим ТОЛЬКО счёт, кольцо не трогаем.**
`_globalUnattributedEvents` питает ещё двух потребителей:
[per_app_trace_tab.dart:182](app/lib/screens/per_app_trace_tab.dart) (секция
«System-wide events») и [profiler.dart:228](app/lib/services/debug/handlers/profiler.dart)
(Debug API). Они должны ВИДЕТЬ все unattributed (включая DNS) — список полезен.
Меняется только что считать ТРЕВОГОЙ.

## Изменения

**`traffic_profiler.dart` — `recentUnattributedCount` (~229):**
```dart
int get recentUnattributedCount {
  final cutoff = DateTime.now().subtract(_unattributedBannerWindow);
  var n = 0;
  for (final e in _globalUnattributedEvents) {
    if (!e.ts.isAfter(cutoff)) continue;
    if (!_isBannerWorthy(e)) continue;   // §177
    n++;
  }
  return n;
}

/// §177 — в баннер идут только признаки сбоя: DNS-fail + TCP/UDP без владельца.
/// Успешный dnsResolve без атрибуции — норма (DNS плохо атрибутируется,
/// см. §171), не тревога.
bool _isBannerWorthy(TrafficEvent e) {
  if (e.kind == TrafficEventKind.dnsFail) return true;
  if ((e.kind == TrafficEventKind.tcpOpen ||
       e.kind == TrafficEventKind.udpOpen) &&
      (e.process == null || e.process!.isEmpty)) return true;
  return false;
}
```

`_appendToGlobalUnattributed` / кольцо / getter / Debug API — НЕ трогаем.

## Тесты

`traffic_profiler_test`:
- много успешных `dnsResolve` (proc=null) → `recentUnattributedCount` НЕ растёт,
  баннер НЕ горит (новый — фиксирует вариант A).
- ≥6 `dnsFail` за окно → баннер горит (как существующий тест ~636, но через
  dnsFail вместо абстрактного unattributed).
- TCP-open без владельца → считается; TCP-open с владельцем → нет.
- Проверить, что существующий тест (~636) не сломан / адаптирован под новый
  критерий (сейчас кормит абстрактные unattributed — перевести на dnsFail).

## Границы (часть A)

- Кольцо `_globalUnattributedEvents` и его потребители (UI-секция, Debug API) —
  без изменений: показывают всё.
- Порог (5) / окно (30с) — без изменений.
- НЕ регрессия §176 — баг существовал и до неё; вскрыт device-проверкой §176.

---

## Часть B — DNS-бейджи и фильтр-чипы (реализовано)

### Проблема

`dnsResolve`/`dnsFail` показывались как ДВА разных бейджа (`DNS` / `DNS×`) и
ДВА фильтр-чипа. Это лишняя дробность: фаза (успех/сбой) — атрибут одного
семейства DNS, как open/close у TCP. Эталон в коде — TCP: `tcpOpen` (синий) /
`tcpClose` (серый) = ОДИН бейдж `TCP`, фаза различается цветом.

### Решение

**Бейдж = один на семейство, фаза = цвет** (как TCP):
- [live_view.dart](app/lib/screens/per_app_trace_tab/widgets/live_view.dart) `_eventTileInner`:
  `dnsFail` → метка `DNS` (была `DNS×`), цвет `cs.error` (красный) остаётся.
- [traffic_event_detail_sheet.dart](app/lib/screens/stats_screen/traffic_event_detail_sheet.dart) `_kindBadge`:
  то же — `dnsFail` → `DNS` красным.

**Фильтр-чипы = по семейству, не по фазе** (убраны `DNS×` и `TCP·`):
- [trace_explorer.dart](app/lib/screens/stats_screen/trace_explorer.dart) `_kindChips`:
  остались `DNS` / `TCP` / `UDP`.
- `_applyFilter` фильтрует через `_kindFamily(e.kind)` — представитель семейства:
  `dnsFail→dnsResolve`, `tcpClose→tcpOpen`, `udpOpen` сам себе. Один чип `DNS`
  ловит resolve+fail, `TCP` — open+close. Сбои/закрытия НЕ выпадают из фильтра.

### Границы (часть B)

- Фаза не теряется: видна в бейдже (цвет) и в деталях события (текст
  `DNS exchange failed: ...` остаётся в `live_view` summary).
- UI без виджет-тестов — проверка визуальная на устройстве.
- Чисто визуально-фильтровая правка, модель `TrafficEventKind` НЕ трогается
  (5 видов как были).
