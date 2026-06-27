# §187 — Время соединения сбрасывается на swipe-reopen (uptime в шапке)

**Тип:** bug-fix (lifecycle / regression в v2.5.0, родственно §185)
**Статус:** ✅ Реализовано
**Приоритет:** Medium (косметика, но заметная — таймер врёт после swipe)
**Связано:** §185 (cold-start CC-resync), §122

## Симптом (device, dev)

После swipe-reopen время соединения (`↑↓ … Xs` в шапке главного) отсчитывается
**с момента swipe-reopen**, а не с реального старта VPN. Туннель не
перезапускался (keep-VPN), но таймер обнулился.

## Корень

`connectedSince` — чисто Dart-поле (`home_state.dart`), ставится в
`DateTime.now()` на КАЖДОМ `connected`-событии (`home_controller.dart:202`). На
cold-start новый Dart-движок в `init()` пуллит native-статус → прогоняет
`connected` через `_handleStatusEvent` → `connectedSince = now()` → реальное
время старта потеряно (Dart-инстанс новый, прошлого `connectedSince` нет).

Чисто-Dart фикс невозможен: новый движок не знает когда стартовал туннель.
**Источник истины — native** (туннель стартовал в `BoxService.setStatus(Started)`,
это время переживает swipe вместе с процессом).

## Решение

Native хранит время старта туннеля в companion (переживает swipe), Dart
подтягивает на cold-start и вычисляет `connectedSince`.

1. **`BoxVpnService` companion** — `@Volatile tunnelStartedElapsedMs: Long`
   (`SystemClock.elapsedRealtime()` — монотонные часы, не прыгают при смене
   системного времени). Ставится в `setCurrentStatus(Started)` ТОЛЬКО если ещё
   не Started (не перетирать при дедупе/повторе); сбрасывается в 0 на Stopped.
2. **`VpnPlugin` handler `getTunnelUptimeMs`** → `elapsedRealtime() -
   tunnelStartedElapsedMs` (0 если не Started). Возвращает прошедшие мс.
3. **Dart `BoxVpnClient.getTunnelUptimeMs()`** + в `HomeController`: на cold-start
   (когда `connected` пришёл pull'ом в `init`) выставить `connectedSince =
   now - uptime` вместо `now`. На РЕАЛЬНОМ старте (юзер нажал Connect) uptime≈0 →
   `connectedSince≈now` (как раньше, без регресса).

## Где врезать (минимально)

Чтобы не трогать каждый `connected`-путь: в `_handleStatusEvent` на `connected`
поставить `connectedSince = now()` как сейчас (мгновенный отклик), а параллельно
(async) подтянуть native-uptime и, если он значимый (>2с — значит туннель уже
давно жив, это reopen, не свежий старт), скорректировать `connectedSince` назад.
Свежий старт → uptime≈0 → коррекции нет.

## Границы

- НЕ менять семантику min-session (`home_screen.dart:404`) — она от
  `connectedSince`, скорректированное время её только уточняет (честнее).
- Монотонные часы (`elapsedRealtime`), НЕ `currentTimeMillis` — иначе смена
  времени/таймзоны сломает uptime.
- Хотфикс → **v2.5.1** (вместе с §185).
