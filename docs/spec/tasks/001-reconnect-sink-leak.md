# 001 — Reconnect не сбрасывает плашку «Config changed»: sink leak

| Поле | Значение |
|------|----------|
| Статус | Done |
| Дата старта | 2026-04-20 |
| Дата завершения | 2026-04-20 |
| Коммиты | `cd39ca9` diag logging · `95650fa` shared broadcast stream · `75c8538` rename [DIAG]→[vpn] + kDebugMode guard |
| Связанные spec'ы | [`003 home screen §8a`](../features/003%20home%20screen/spec.md), [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md) |

## Проблема

После reconnect (short tap на reload-кнопке справа от status chip) плашка «Config changed — restart VPN to apply» **не исчезала**. Симптом повторялся каждый раз; параллельный агент подтверждал что в логах отсутствуют `Stopping/Stopped/Starting/Started` core events после `reconnect: stopVPN/startVPN requested`.

Ручной Stop → Start работал (плашка уходила). Reconnect — нет.

## Диагностика

### Ложный след 1 — native stop/start race

Первая гипотеза: `stopSelf()` в `doStop` убивает service параллельно с `startForegroundService` из нового startVPN → race, onStartCommand silent-return через guard на строке 97 (`if (status != Stopped) return START_NOT_STICKY`) без `setStatus(Starting)` broadcast. Объясняло бы отсутствие events.

Добавил `Log.d` инструментовку в `BoxVpnService` (onStartCommand, doStop, setStatus, receiver register/unregister) и в `VpnPlugin` (statusReceiver, event channel listen/cancel). **Коммит** `cd39ca9`.

Прогнал 3 сценария reconnect через `adb shell input tap`:
- **Запуск 1 (свежий процесс после `pm install -r`):** **все 4 broadcast'а прошли** — `Stopping/Stopped/Starting/Started`. Но `stale=True` в /state. Противоречие с гипотезой.
- **Запуск 2 (минуту спустя):** broadcast'ы отсутствуют, timeout 10s, потом startVPN без transits.
- **Запуск 3 (ещё позже):** то же самое.

Если бы это был native race — Запуск 1 тоже должен был потерять events. А он их получил. Значит корень не в native lifecycle.

### Настоящий след — Dart-side sink churn

Ключевая зацепка в VpnPlugin диагностике:
```
statusEventChannel.onCancel — sink cleared
statusEventChannel.onListen — sink installed
...
plugin.statusReceiver.onReceive Stopping sink=true
plugin.statusReceiver.onReceive Stopped  sink=true
statusEventChannel.onCancel — sink cleared     ← вот тут
onMethodCall: startVPN
plugin.statusReceiver.onReceive Starting sink=false  ← ПОТЕРЯН
plugin.statusReceiver.onReceive Started  sink=false  ← ПОТЕРЯН
```

`statusSink` в `VpnPlugin.kt` — одно mutable поле. Последний `onListen` перезаписывает, первый `onCancel` обнуляет.

### Root cause в `BoxVpnClient.dart`

```dart
Stream<Map<String, dynamic>> get onStatusChanged {
  return _statusEvents.receiveBroadcastStream().map((event) {...});
}
```

Getter возвращает **новый** `receiveBroadcastStream()` на каждый вызов. Каждый такой вызов — новый `StreamController` в Dart SDK, новый `onListen` на native.

Цепочка в `reconnect()`:
1. `HomeController.init()` → `_vpn.onStatusChanged.listen(_handleStatusEvent)` → native onListen #1, `statusSink = A`.
2. `reconnect()` → `_vpn.onStatusChanged.firstWhere(...)` → native onListen #2, `statusSink = B` (перезаписал A).
3. `firstWhere` резолвится на Stopped → subscription #2 закрывается → native `onCancel` → `statusSink = null`.
4. Последующие broadcast'ы (Starting/Started) летят в null → дропаются.
5. `_statusSub` в HomeController (subscription #1) становится **зомби**: Dart думает что подписан, native давно выбросил sink.

**Каскад последствий:**
- `_handleStatusEvent` не получает Started → `configStaleSinceStart: false` не вызывается (строка 101) → плашка висит.
- Heartbeat traffic-обновления могли бы тоже ломаться, но они идут через Clash HTTP API (не event channel), поэтому маскировали баг.
- Keep-on-exit reattach fix (getVpnStatus pull в init) срабатывал один раз и тоже маскировал.

## Решение

Одна правка в [`app/lib/vpn/box_vpn_client.dart:125-130`](../../../app/lib/vpn/box_vpn_client.dart):

```dart
late final Stream<Map<String, dynamic>> _statusStream =
    _statusEvents.receiveBroadcastStream().map((event) {
  if (event is Map) return Map<String, dynamic>.from(event);
  return <String, dynamic>{};
}).asBroadcastStream();

Stream<Map<String, dynamic>> get onStatusChanged => _statusStream;
```

- `late final` — один instance на весь lifecycle `BoxVpnClient` (который сам живёт на protяжении HomeController).
- `.asBroadcastStream()` — один underlying controller, много Dart-listener'ов. Native `onListen` вызывается ровно один раз (на первом listener'е, в init), потом игнорируется.
- `firstWhere` в `reconnect()` становится Dart-уровневым listener'ом на уже кэшированный stream — native-канал не трогает.
- `_statusSub` стабилен на всё время жизни контроллера.

## Риски и edge cases

**Что не закрывает этот фикс:**

1. Platform-level broadcast потери (Doze, system kill FGS, process died without broadcast): если процесс Flutter killed, наш `_statusSub` не получит событий — но это уже другой lifecycle.
2. `onStartCommand` guard на строке 97 всё ещё может silent-return'ить если status рассинхронится. В штатном потоке (после fix'а) такого не происходит.
3. Stop button «silent failure после APK update» (упомянутый параллельным агентом): требует эмпирического воспроизведения для оценки. После sink fix — возможно тоже закрыто, т.к. symptom того же механизма.

**Что намеренно НЕ сделано:**
- Reconciliation loop (periodic pull) — отказались по причине «паразитная нагрузка в steady-state».
- `TunnelStatus.fromNative` default изменить с `disconnected` на `unknown` — отдельная задача (см. 002).

## Верификация

Эмпирически проверено на OnePlus (192.168.1.71:5555) после `adb install -r`:

1. **Запуск 2 после фикса:** tunnel=connected, stale=False после reconnect — плашка ушла.
2. **Серия 10 reconnect'ов подряд:** все итерации `stale=False`, logcat показывает каждый раз полный цикл `Stopping/Stopped/Starting/Started` с `sink=true`. Никаких `onCancel` в середине, никаких `sink=false`, никаких GUARD silent-return'ов.

До фикса: баг воспроизводился **100%** на последующих reconnect'ах. После фикса: **0%** (10/10).

## Нерешённое / follow-up

- **002** — intent-based sticky reset в stop()/start(): защита от редких platform-level потерь events (Doze, kill), делает семантику stop/start честной.
- **003** — revoke UX: SnackBar когда другое VPN захватило туннель, mapping в Disconnected.
- **004** — lifecycle resume pull: одноразовый `getVpnStatus` при возврате в app.
- Эмпирическая проверка «Stop button silent failure после APK update» — воспроизвести на отдельном устройстве, оценить нужен ли дополнительный фикс.
