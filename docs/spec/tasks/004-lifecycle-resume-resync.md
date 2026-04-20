# 004 — Lifecycle resume re-sync через one-shot getVpnStatus pull

| Поле | Значение |
|------|----------|
| Статус | Done (code + build) / pending manual verification |
| Дата старта | 2026-04-20 |
| Дата завершения | 2026-04-20 |
| Коммиты | `82b5b49` feat(vpn): revoke UX + lifecycle resume re-sync (вторая часть) |
| Связанные spec'ы | [`003 home screen`](../features/003%20home%20screen/spec.md), [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md) |

## Проблема

Event-channel pipe, которым native broadcast'ит status updates в Flutter, надёжно работает пока процесс Flutter жив и подписан. Но есть сценарии где broadcast до нас не доходит:

1. **Android Doze mode** — OS приостанавливает background работу, broadcast'ы могут быть отброшены или отложены.
2. **OOM killer** — system убил наш foreground-service (unlikely но возможно при ресурсном давлении), затем при возврате app процесс Flutter жив, но native service мёртв.
3. **Battery optimizations** — некоторые OEM (Xiaomi, Huawei, OnePlus) агрессивно режут background процессы.
4. **Keep-on-exit OFF + user swipe из recents** — service stop'нулся корректно, но app потом возвращается без уведомления Flutter (уже закрыто в [001 keep-on-exit fix]).

В случаях 1-3 Dart-state может остаться «connected», а native-state уже `Stopped` / `Revoked`. Divergence.

## Решение

### Подход

Event-driven one-shot pull **на resume**:
- `didChangeAppLifecycleState(AppLifecycleState.resumed)` в HomeScreen → `_controller.onAppResumed()`
- В `onAppResumed` — pull `getVpnStatus()` от native, сравнение с Dart state.
- Если divergent — прогнать raw через `_handleStatusEvent` (feed fake event), что запустит штатный обработчик: cleanup, haptic, autoupdater hooks, и т.д.

### Почему не polling loop

Отказались явно по запросу пользователя: полинг жрёт CPU/battery в steady-state ради edge cases. Event-driven на resume:
- В steady-state ничего не крутится.
- Дёргается только когда есть реальное основание что могли рассинхрониться (юзер вернулся в app после background'а).

### Реализация

**`home_controller.dart`:**

```dart
void onAppResumed() {
  unawaited(_resyncOnResume());
}

Future<void> _resyncOnResume() async {
  try {
    final raw = await _vpn.getVpnStatus();
    final native = TunnelStatus.fromNative(raw);
    if (native != _state.tunnel) {
      _addDebug(DebugSource.app,
          '[vpn] onAppResumed: divergence native=${native.name} state=${_state.tunnel.name}');
      _handleStatusEvent({'status': raw});
    }
  } catch (e) {
    _addDebug(DebugSource.app, '[vpn] onAppResumed pull error: $e');
  }
  if (_state.tunnelUp) {
    unawaited(_checkHeartbeat());
  }
}
```

Фокус:
1. **Pull native status** через уже существующий `getVpnStatus` method channel (возвращает `currentStatus.name`).
2. **Сравнение** native vs Dart state. Если одинаково — no-op (в steady-state типичный случай).
3. **Если divergent** — feed raw status через `_handleStatusEvent({'status': raw})`. Это идёт через тот же код что обычные broadcast events, со всеми правильными side effects (cleanup, haptic, autoupdater hooks, clash endpoint rebuild).
4. **Heartbeat** — отдельно после re-sync. Если всё ещё up после pull'а, проверяем что Clash жив (он тоже мог умереть если service killed был).

### Интеграция с P2 revoke UX

Если native возвращает `Revoked`, а наш state был `connected` (пропустили broadcast onRevoke):
- `_handleStatusEvent({'status': 'Revoked'})` → tunnel = revoked
- `_onControllerChange` в HomeScreen увидит transition `connected → revoked`
- → SnackBar «VPN taken by another app»

То есть P3 и P2 работают вместе: если юзер вернулся в app после того как кто-то перехватил tunnel пока мы были в background — получит тот же UX что и live revoke.

## Риски и edge cases

### Разобраны

- **Haptic на resume.** Если divergent путь disconnected (был connected, стал Stopped) → _handleStatusEvent зовёт `HapticService.I.onVpnDisconnected`. Юзер вернулся и получил вибро — странно, но фактически правильно (он бы почувствовал если бы не уходил). Acceptable для v1, можно потом guard'ить через флаг «silent mode on resume».
- **AutoUpdater.onVpnStopped trigger.** При divergent Stopped — триггерит. Это 4й триггер (см. spec 027), ведёт к refresh подписок через некоторое время. Приемлемо.
- **Double call onAppResumed.** Flutter может вызвать resumed-событие несколько раз подряд. `_resyncOnResume` идемпотентен: если state уже match'ит native — no-op. Если запустил pull и параллельно пришёл реальный broadcast — race возможен, но `_handleStatusEvent` работает на последнем state, последний wins.
- **Pull fails (method channel error).** Catch + log, не крашим. Heartbeat после этого всё равно выстрелит если tunnelUp — дополнительная проверка.
- **`getVpnStatus` возвращает Stopping/Connecting transient.** `TunnelStatus.fromNative` маппит в соответствующее состояние. Если divergent — `_handleStatusEvent` зарядит safety-timeout (10s). Транзит ок.

### Намеренно НЕ покрыто

- **Reconcile внутри активной сессии.** Никаких periodic pull'ов, никаких «на всякий случай pull перед intent». Только resume. Если в процессе работы tunnel рассинхронится — юзер заметит (traffic не тикает, ping fail), кликнет Stop/Start, оба сделают правильный pass через native с blocking stop.
- **Full state snapshot pull** (все поля, не только status). Сейчас pull только status. Остальные поля (proxies, groups, traffic) обновляются через Clash API на connected transition автоматически.

## Верификация

- `dart analyze` clean
- `flutter build apk --debug` succeeds

**Manual test (pending):**
1. Открыть L×Box, запустить VPN, свернуть app.
2. Через Developer Options → «Don't keep activities» — force-kill Flutter процесс.
   Альтернативно: `adb shell am kill com.leadaxe.lxbox` — убить процесс.
3. Открыть app обратно. Ожидание:
   - Ранее (до [001 keep-on-exit fix]) tunnel показывался Disconnected хотя native жив.
   - Теперь (init-pull + resume-pull) — Connected, всё синхронизировано.
4. Альтернативно: запустить другое VPN когда L×Box в background. Вернуться. Ожидание: SnackBar revoked, chip Disconnected.

## Нерешённое / follow-up

- Расширение `getVpnStatus` до `getVpnState` с дополнительными полями (`connectedSinceMs`, `error`, `seq` для gap detection) — отдельная задача если появится реальная нужда. Сейчас одного статуса хватает.
- Silent-kill telemetry — если юзеры начнут жаловаться что «приложение забывает соединение», логировать pull-vs-state divergence для статистики.
