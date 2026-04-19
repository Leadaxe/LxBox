# 029 — Haptic Feedback

| Поле | Значение |
|------|----------|
| Статус | **Реализовано и в продакшене** (2026-04-19, 6/6 тестов) |
| Дата | 2026-04-19 |
| Зависимости | [`003`](../003%20home%20screen/spec.md), [`022`](../022%20app%20settings/spec.md) |
| Связано | [`009`](../009%20ux%20and%20theme/spec.md), [`012`](../012%20native%20vpn%20service/spec.md) |

---

## Цель и рамки

Добавить тактильный отклик на ключевые VPN-события (connect/disconnect, критические ошибки). Приложение без haptic воспринимается как "дешёвое"; vibra даёт юзеру подтверждение действия без необходимости смотреть в экран (частый сценарий: нажал connect, сунул телефон в карман).

Реализация — через встроенный Flutter API `HapticFeedback` (`package:flutter/services.dart`), без дополнительных зависимостей.

**Не в скопе:**
- Вибрация на каждый тап (скролл, кнопки, переключатели) — eats battery, раздражает
- Продвинутые pattern'ы (ритмы, кастомные длительности) — требуют platform-channel; избыточно
- iOS-specific Taptic Engine управление (sharpness/intensity) — Android-only приложение
- Haptic для тестирования / прогресса (pull-to-refresh, swipe) — стандартные Flutter-виджеты делают это сами
- Индивидуальная настройка интенсивности per-event — усложнение без пропорционального UX-прибытка

---

## Контекст

### API Flutter

```dart
import 'package:flutter/services.dart';

HapticFeedback.selectionClick();  // ~5 мс, минимальный "тик"
HapticFeedback.lightImpact();     // ~10 мс, мягкий "щёлк"
HapticFeedback.mediumImpact();    // ~20 мс, заметный толчок
HapticFeedback.heavyImpact();     // ~30 мс, сильный удар
HapticFeedback.vibrate();         // ~50 мс, стандартная вибра
```

Под капотом вызывает [`View.performHapticFeedback()`](https://developer.android.com/reference/android/view/View#performHapticFeedback(int)). Без `VIBRATE` permission — Android разрешает haptic до 50 мс без разрешения.

### Platform behaviour

- Android 10+ — respects "Touch feedback" system setting. Если юзер отключил — наши вызовы no-op.
- Android < 10 — всегда работает (пока `VIBRATE` permission есть как transitive dep от `VpnService`).
- Эмулятор — обычно не вибрирует, no-op.
- Tablets без вибро-мотора — `HapticFeedback` silent-fail.

Ошибки вызовов **не нужно ловить** — Flutter поглощает platform exceptions.

---

## Архитектурное решение

1. **Централизованный сервис `HapticService`** — все вибрации идут через него. Это даёт:
   - Одна точка для отключения (user preference / debug-mode)
   - Единый маппинг event → intensity (удобно менять если UX окажется агрессивным)
   - Throttling (не стрелять одинаковыми импульсами в быстрой последовательности)

2. **Event-based API** — не `lightImpact()/mediumImpact()`, а `onVpnConnected()`, `onVpnDisconnected()`, `onVpnCrashed()`. Вызовы говорят **что случилось**, сервис решает **какая интенсивность**.

3. **User-toggle в Settings** — "Haptic feedback" switch в общих настройках приложения. Default **on**. Сохраняется через [`settings_storage.dart`](../../../app/lib/services/settings_storage.dart).

4. **Respects system setting** — если юзер выключил touch feedback в Android → Flutter API автоматически no-op, ничего не добавляем.

5. **Нет haptic в debug-логгере** — debug-события (parse warning, fetch retry) не вибрируют. Только **пользовательские события**.

---

## Mapping событий

| Событие | Интенсивность | Обоснование |
|---|---|---|
| Tap Connect button | `selectionClick` | UI-подтверждение нажатия |
| Tunnel established (status = up) | `mediumImpact` | «Готово, едем» — main success signal |
| Tunnel stopped by user | `lightImpact` | Мягкое «ок, отключено» |
| Tunnel revoked / crashed (unexpected) | `heavyImpact` | «Внимание, что-то пошло не так» |
| Heartbeat fail detected (`020 §Heartbeat`) | `heavyImpact` | Та же семантика что и crash |
| Subscription fetch error (manual) | `mediumImpact` | Подтверждение фейла |
| Subscription fetch success (manual) | `lightImpact` | Мягкое «готово» |
| Node switch (selection change) | `selectionClick` | Как в выпадающих списках iOS |
| Preset apply (`wizard_template` switch) | `mediumImpact` | Применилось важное |

**Не триггерят** haptic:
- Auto subscription updates (фон)
- Auto ping / speed-test результаты
- Debug log events
- Любые scroll/swipe

---

## API

```dart
// app/lib/services/haptic_service.dart
class HapticService {
  HapticService({required this.enabled, Duration throttle = const Duration(milliseconds: 100)})
      : _throttle = throttle;

  final bool enabled;
  final Duration _throttle;
  DateTime _lastFired = DateTime.fromMillisecondsSinceEpoch(0);

  bool _shouldFire() {
    if (!enabled) return false;
    final now = DateTime.now();
    if (now.difference(_lastFired) < _throttle) return false;
    _lastFired = now;
    return true;
  }

  void onConnectTap() => _fire(HapticFeedback.selectionClick);
  void onVpnConnected() => _fire(HapticFeedback.mediumImpact);
  void onVpnDisconnected() => _fire(HapticFeedback.lightImpact);
  void onVpnCrashed() => _fire(HapticFeedback.heavyImpact);
  void onHeartbeatFail() => _fire(HapticFeedback.heavyImpact);
  void onFetchSuccess() => _fire(HapticFeedback.lightImpact);
  void onFetchError() => _fire(HapticFeedback.mediumImpact);
  void onNodeSelect() => _fire(HapticFeedback.selectionClick);
  void onPresetApply() => _fire(HapticFeedback.mediumImpact);

  void _fire(Future<void> Function() impact) {
    if (!_shouldFire()) return;
    unawaited(impact());
  }
}
```

### Wiring

- Создаётся в `main.dart` после `runApp` с учётом prefs.
- Передаётся в `HomeController`, `SubscriptionController` через конструктор.
- Toggle в settings пишет в prefs + обновляет поле `enabled` (hot-swap через `ChangeNotifier`).

---

## UI — Settings

Секция **Appearance / UX** (или создать новую **Feedback**):

| Поле | Тип | Default | Описание |
|------|-----|---------|----------|
| Haptic feedback | Switch | on | Короткая вибрация при подключении/отключении |

Help-текст под switch'ом:
> Вибрация при подключении, отключении и ошибках. Уважает системную настройку "Touch feedback" — если она выключена, вибрации не будет даже при включённом toggle.

---

## Тесты

1. **Unit** `HapticService`: выключенный enabled → ни один метод не зовёт платформу (мок `HapticFeedback`).
2. **Unit** throttle: два быстрых `onVpnConnected` подряд (< 100мс) → только один platform-call.
3. **Integration**: `HomeController` переход `idle → connected` → вызов `onVpnConnected` (проверяется через подменённый `HapticService`).
4. **Integration**: revoked / crash event → `onVpnCrashed` (не `onVpnDisconnected`).
5. **Regression**: toggle в settings → изменение `enabled` применяется немедленно к следующему событию.

---

## Риски

| Риск | Описание | Митигация |
|---|---|---|
| Агрессивность | Слишком частая вибрация раздражает, eats battery | Throttle 100 мс; mapping только на значимые события; user-toggle |
| Heartbeat noise | `020 §Heartbeat` пингует каждые 20с — если в каждом fail вибро → спам | Триггер только на **первый** detected fail (не на каждый tick); reset flag после recovery |
| Platform-divergence | Эмулятор / планшеты без мотора | Silent no-op на platform-уровне; мы не проверяем |
| System override | Android-пользователь отключил haptic глобально | OS делает no-op автоматически; наш toggle — дополнительный слой, не конфликтует |
| Accessibility | Некоторым юзерам вибро неприятно (fibromyalgia, тактильная чувствительность) | Default-on спорно; можно рассмотреть default-off + onboarding-prompt, но фаза 1 — default-on |
| Batteries in background | Если VPN в background — heavy impact привлекает внимание, это хорошо; но если revoked ночью → может разбудить | Acceptable — revoke = critical event |

---

## Будущие расширения

- **Per-event toggle** — продвинутые юзеры хотят отключить только connect-медиум
- **Custom patterns** — через platform-channel и `Vibrator.vibrate(pattern: ...)` для специфичных ритмов
- **iOS Taptic Engine** — если когда-то расширимся на iOS, `HapticFeedback.lightImpact` уже использует Taptic автоматически; кастомные интенсивности потребуют `CoreHaptics`

---

## Файлы

| Файл | Изменения |
|------|-----------|
| `app/lib/services/haptic_service.dart` | Новый сервис (класс `HapticService`) |
| `app/lib/services/settings_storage.dart` | Ключ `haptic_enabled` (bool, default true) |
| `app/lib/main.dart` | Создание `HapticService`, проброс в controllers |
| `app/lib/controllers/home_controller.dart` | Вызовы на tunnel transitions (`_handleStatusEvent`) |
| `app/lib/controllers/subscription_controller.dart` | Вызовы на fetch success/error |
| `app/lib/screens/settings_screen.dart` | Switch "Haptic feedback" |
| `app/lib/screens/home_screen.dart` | `onTap` кнопки Connect → `onConnectTap()` |
| `app/test/services/haptic_service_test.dart` | Unit-тесты |

---

## Критерии приёмки

- [ ] Toggle "Haptic feedback" виден в Settings, autosave
- [ ] Default on
- [ ] Connect tap → лёгкий click
- [ ] Tunnel up → средний impact
- [ ] User-initiated stop → лёгкий impact
- [ ] Revoked/crash → тяжёлый impact
- [ ] Heartbeat fail (первый) → тяжёлый impact; повторы не стреляют до recovery
- [ ] Toggle off → платформенные вызовы не делаются (unit-test)
- [ ] Throttle 100 мс работает (unit-test)
- [ ] Эмулятор — silent no-op, нет crash'ей
- [ ] Help-текст честно упоминает системную настройку

---

## Ссылки

- [Flutter HapticFeedback API](https://api.flutter.dev/flutter/services/HapticFeedback-class.html)
- [Android performHapticFeedback](https://developer.android.com/reference/android/view/View#performHapticFeedback(int))
- [iOS UIImpactFeedbackGenerator (для будущего iOS-порта)](https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator)
