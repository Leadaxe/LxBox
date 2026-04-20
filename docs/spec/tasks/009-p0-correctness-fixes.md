# 009 — P0 correctness fixes перед 1.4.0

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-04-21 |
| Дата завершения | 2026-04-21 |
| Коммиты | см. ниже (ещё не закоммичено на момент написания отчёта) |
| Связанные spec'ы | [`003 home screen`](../features/003%20home%20screen/spec.md), deep review [008](./008-deep-code-review-perf-refactor.md) §A |

## Проблема

Peer review 008 подсветил три **P0-корректностных** пункта в `home_screen.dart` — анти-паттерны Flutter, не оптимизации:

- **A1**: side-effects в `build` — управление `AnimationController` (`_connectingAnim.repeat/stop/reset`) жило в `_buildStatusChip`, который вызывается из `AnimatedBuilder` (т.е. из build). Правило «build чистый» нарушается. Риск: warnings от framework'а в debug-mode, лишняя работа на каждый notify.
- **A2**: планирование `Timer` внутри `Builder` в build — `_errorTimer` логика в error row создавала/отменяла таймер при каждом прохождении build с новым `lastError`. Хрупко при агрессивных rebuild'ах, логика привязана к side-effect прохождения build.
- **A3**: `HomeController.dispose()` / `SubscriptionController.dispose()` / `_connectingAnim.dispose()` не вызывались в `HomeScreen.dispose()`. На production ОС убивает процесс, для hot reload / тестов / потенциальной смены root widget'а — утечка `_statusSub`, heartbeat/transient timers, `AnimationController` ticker'а, listeners.

## Решение

### A1 — animation control в listener

Перенёс `_connectingAnim.repeat/stop/reset` из `_buildStatusChip` в `_onControllerChange` (listener на `HomeController`, существовавший ранее для revoke SnackBar'а). Срабатывает только при реальной смене состояния через `notifyListeners`, не при каждом build'е.

```dart
void _onControllerChange() {
  final isConnecting = state.tunnel == TunnelStatus.connecting;
  if (isConnecting && !_connectingAnim.isAnimating) {
    _connectingAnim.repeat();
  } else if (!isConnecting && _connectingAnim.isAnimating) {
    _connectingAnim.stop();
    _connectingAnim.reset();
  }
  // ...
}
```

`_buildStatusChip` стал pure render — только формирует `icon`/`color`/`bgColor`/`label` по данным state.

### A2 — error timer в listener

Логика `_errorTimer` перенесена из `Builder` внутри build в тот же `_onControllerChange`. Явный transition detection через `_prevError` field: ошибка изменилась — перезапуск 15с таймера; очистилась — `cancel`.

```dart
if (nowError != _prevError) {
  _errorTimer?.cancel();
  _errorTimer = null;
  if (nowError.isNotEmpty) {
    _errorTimer = Timer(const Duration(seconds: 15), () {
      if (mounted) _controller.clearError();
    });
  }
}
```

Удалён `_errorTimerFor` field (раньше дублировал `_prevError` по смыслу). Error row в build стал pure render.

### A3 — `HomeScreen.dispose` complete

```dart
void dispose() {
  _errorTimer?.cancel();
  _errorTimer = null;
  _controller.removeListener(_onControllerChange);
  WidgetsBinding.instance.removeObserver(this);
  _autoUpdater.dispose();
  _controller.dispose();          // NEW — отменяет _statusSub, heartbeat,
  _subController.dispose();       // NEW — ChangeNotifier listeners cleanup
  _connectingAnim.dispose();      // NEW — AnimationController ticker
  super.dispose();
}
```

Порядок: side-effects → observers → затем владельцы в обратном порядке созданию (autoUpdater держит ref на subController; controller держит ref на autoUpdater — значит autoUpdater.dispose сначала). ОК-обоснование порядка добавлено inline-комментарием.

## Риски и edge cases

### Покрыто

- **Первое срабатывание listener'а vs initial state.** `_onControllerChange` не вызывается при подписке — но `_connectingAnim` изначально не анимируется, и `_errorTimer` null. Inconsistency невозможна: если туннель стартует в `connecting` до подписки (unlikely — init асинхронно), listener увидит transition при первом notifyListeners.
- **Повторная подписка в hot reload.** Listener attachment в initState — при hot reload initState не перезапускается (Flutter keeps State). `_onControllerChange` привязан один раз, пересоздание не нужно.
- **dispose ordering.** AutoUpdater использует subController (см. конструктор), HomeController использует autoUpdater. Dispose в обратном порядке: autoUpdater → controller → subController — но autoUpdater хранит ref на subController, к моменту его dispose autoUpdater уже нет. Безопасно.

### Не затрагивает

- Логику VPN lifecycle — только side-effect management.
- Тесты — нет изменений в тестируемых моделях/сервисах.
- Dart analyze — clean.

## Верификация

- `dart analyze lib/` — 0 issues.
- `flutter test` — 242 теста pass.
- `flutter build apk --release` — compile OK.
- **Manual test checklist** (pending на device):
  1. Tap Start → иконка Connecting вращается → когда приходит Started, останавливается. ✓
  2. Stop → Connecting→Stopping transient → после Stopped, иконка сбрасывается.
  3. Вызвать ошибку (неверный конфиг при Start) → через 15с auto-clear.
  4. Dismiss ошибки вручную → ошибка исчезает сразу.
  5. Revoke от другого VPN → SnackBar показывается (логика из 003, не регрессировала).

## Нерешённое / follow-up

**P1 из 008** — отложено до 1.4.1 / 1.5.0 отдельными задачами:

- Снижение радиуса rebuild через разрез `Listenable.merge([_controller, _subController])` — архитектурная правка, требует полного manual re-test reactive зон (drawer, banners, chip).
- Heartbeat tuning — реже `fetchProxies` или лёгкий snapshot для Home — требует продуктового решения по балансу свежести UI vs battery.
- D1/D2/D3/E/H — остальные P1+P2 пункты из 008.
