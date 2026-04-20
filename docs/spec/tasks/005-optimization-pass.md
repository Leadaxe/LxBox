# 005 — Pre-1.4.0 optimization pass

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-04-20 |
| Дата завершения | 2026-04-20 |
| Коммиты | `7a54c60` cache parsed config + batched _emit · `bdd262f` background-paused timers + lint · `743fffa` single safety-timer |
| Связанные spec'ы | [`003 home screen`](../features/003%20home%20screen/spec.md), [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md) |

## Проблема

После стабилизации VPN lifecycle (задачи [001](./001-reconnect-sink-leak.md)–[004](./004-lifecycle-resume-resync.md)) решил перед 1.4.0 пройтись по hot-path'ам и найти конкретные оптимизации. Никаких спекулятивных «может пригодится», только то что имеет измеримый эффект.

## Диагностика

Прошёл через Explore-agent'а — он проверил `lib/` на шесть категорий: hot-path allocations, ChangeNotifier over-notification, stream/timer leaks, rebuild storms, battery-relevant loops, dead code. Получил отчёт с 20 findings по severity (HIGH × 2, MEDIUM × 12, LOW × 6).

Взял топ — те что дают конкретный profile-measurable выигрыш без инвазивных архитектурных изменений.

## Решение

### 1. Hot-path JSON parsing → ConfigCache (HIGH)

`_buildNodeList` в home_screen делал `jsonDecode(state.configRaw)` + итерация по outbounds+endpoints на **каждый rebuild** ListView. При 50+ нодах + сортировке по ping (heartbeat каждые 20с → pinged values update → sort invalidated → rebuild → re-parse) это был hot-path'овый выжиматель.

**Решение:** новый immutable `ConfigCache` в `home_state.dart`:

```dart
class ConfigCache {
  const ConfigCache.empty() : detourTags = {}, protoByTag = {};
  factory ConfigCache.parse(String configRaw) { ... }
  final Set<String> detourTags;
  final Map<String, String> protoByTag;
}
```

Парсится **один раз** в `HomeState.copyWith` когда `configRaw` передан (т.е. в `saveParsedConfig`). `copyWith'ы` без configRaw шарят тот же immutable объект — никаких лишних jsonDecode.

`_buildNodeList` читает `state.configCache.detourTags` / `state.configCache.protoByTag` за O(1) без парсинга. `_NodeProto` class-wrapper над строкой выкинут (`_protoLabel(String)` — свободная функция, не создаёт объект на проход).

### 2. `sortedNodes` memoize (MEDIUM)

Getter `sortedNodes` делал `.where(...).toList() + .sort(...)` на **каждый вызов**. Builder'ы обращаются несколько раз (detour-filter → itemCount → itemBuilder × N) — в худшем случае O(n log n) на каждом из этапов.

**Решение:** `late final List<String> sortedNodes = _computeSortedNodes();` — memoize в пределах одного `HomeState` instance. Новый `copyWith` создаёт новый state → новый кэш, но в пределах одного build-cycle повторных sort'ов нет.

### 3. Batched `_emit` в `_handleStatusEvent` (MEDIUM)

Раньше на одно status event шло 2–3 последовательных `_emit` → 2–3 `notifyListeners` → 2–3 rebuild'а `AnimatedBuilder(animation: Listenable.merge([_controller, _subController]))` на весь home screen.

**Решение:** объединил в один `copyWith` per branch:

```dart
_emit(_state.copyWith(
  tunnel: tunnel,
  connectedSince: DateTime.now(),
  configStaleSinceStart: false,
));
```

Один rebuild на событие.

### 4. Single safety-timer вместо `Future.delayed` спама (MEDIUM)

Safety-timeout для transient-фазы (Starting/Stopping застрял 10с → force disconnected) раньше плодил `Future.delayed` на каждое transient event. Если стриг happens из stopping→stopping→stopping подряд — в scheduler несколько параллельных таймеров.

**Решение:** один `_transientTimeoutTimer: Timer?` на жизнь контроллера:
- `_armTransientTimeout(expected)` — cancel + новый timer на 10с
- Любой non-transient terminal event — cancel таймера.
- `dispose` — cancel.

Побочный bug-fix: в timeout-emit добавлен `configStaleSinceStart: false` (пропущено ранее — если туннель реально застрял, плашка «restart to apply» не имеет смысла после принудительного disconnected).

### 5. Background-paused timers в Stats/Connections (MEDIUM, battery)

`StatsScreen` опрашивал Clash API каждые 3с, `ConnectionsView` — каждые 500мс–10с. Работало даже когда app ушёл в background — method-channel роунд-трипы + network I/O без видимой причины.

**Решение:** обе StatefulWidget'ы получили `WidgetsBindingObserver`:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  switch (state) {
    case AppLifecycleState.paused:
    case AppLifecycleState.hidden:
    case AppLifecycleState.inactive:
    case AppLifecycleState.detached:
      _stopTimer();
    case AppLifecycleState.resumed:
      if (_timer == null) {
        unawaited(_refresh());
        _startTimer();
      }
  }
}
```

Background = таймер cancelled. Resume = immediate refresh + restart. Steady-state в background — zero activity.

Для `ConnectionsView` ещё `_backgrounded: bool` guard, чтобы `_setInterval` (вызывается когда юзер переключает preset) не ожил во время паузы.

### 6. Lint cleanup (LOW)

- `services/app_info_cache.dart`: unused `import 'dart:typed_data'` — `Uint8List` уже приходит через `package:flutter/foundation.dart`.
- `services/template_loader.dart`: angle brackets в docstring обёрнуты в backticks (dartdoc HTML interpretation).
- `widgets/node_row.dart`: `if (proto != null) proto` → `?proto` через null-aware collection marker.

Полный `dart analyze lib/` — **0 issues**.

## Риски и edge cases

### Разобраны

- **ConfigCache empty config.** `ConfigCache.parse('')` возвращает `ConfigCache.empty()` — no-op, UI видит пустые detourTags/protoByTag.
- **ConfigCache malformed JSON.** Try/catch внутри — возвращает empty cache, UI деградирует к placeholder'ам.
- **HomeState был `const`** — после late final больше не const. Проверил — единственный callsite `const HomeState()` в `HomeController._state = const HomeState()` заменён на non-const. Других нет.
- **Tests.** 242 теста прошли без изменений. HomeState из tests не создавался через const.
- **Race `_armTransientTimeout`.** Если transient event пришёл, таймер armed, потом Started — callback проверит `_state.tunnel != expected` → no-op. Плюс _transientTimeoutTimer cancel'ится в non-transient ветке.
- **Resume timer re-create.** Если юзер идёт background → resume быстро, и до паузы был timer с accum — `_backgrounded` сбрасывается, timer стартует заново.

### Намеренно НЕ сделано

- **AppLog batching `notifyListeners`.** Оценил — когда DebugScreen закрыт, listeners пусто → notify почти бесплатно. Когда открыт и логи идут пачками — batching через microtask добавит latency в UI. Overhead минимален, оставил.
- **Map-копии в ping (`Map.from(_state.lastDelay)..[tag] = ms`).** 50 ops × 2 Map.from × 50 entries = ~5k heap writes. Sub-миллисекунда. Не bottleneck.
- **AnimatedBuilder(Listenable.merge) split.** Инвазивная архитектурная правка — риск сломать drawer reactive behavior (Statistics enabled/disabled). Отложено до явного signaling от измерений production.
- **`Theme.of(context)` cache в больших build methods.** 22 вызова в home_screen — каждый O(1) tree walk, не hot. Косметика с риском опечаток.

## Верификация

- `dart analyze lib/` — **0 issues**
- 242 тестов pass
- `flutter build apk --debug` + `--release` — compile OK
- Manual test — pending на финальном APK

Метрик не снимал (profiler под Flutter+Android требует devtools-настройки которой нет в этой сессии). Оптимизации выбраны по профилю типа «явно лишняя аллокация/парсинг в hot path'е», не спекулятивно.

## Нерешённое / follow-up

- Если после production-деплоя станут приходить жалобы на jank при пинге — вернуться к `Map-копиям в ping` (batched emit через delta-queue).
- AnimatedBuilder split — если DebugScreen / AboutScreen будут как-то rebuild'иться от ping-ов, то точно стоит разделять по зонам.
- Measure memory pressure (`flutter run --profile`) на реальном устройстве с нагрузкой, если проблема станет видимой.
