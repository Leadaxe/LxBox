# 002 — Blocking stopVPN на native + intent-based sticky reset

| Поле | Значение |
|------|----------|
| Статус | Done (code + build) / pending manual verification |
| Дата старта | 2026-04-20 |
| Дата завершения | 2026-04-20 |
| Коммиты | `8c3df2f` feat(vpn): blocking stopVPN + intent-based sticky reset |
| Связанные spec'ы | [`003 home screen §8b`](../features/003%20home%20screen/spec.md), [`012 native vpn service`](../features/012%20native%20vpn%20service/spec.md) |
| Связанные задачи | [001](./001-reconnect-sink-leak.md) |

## Проблема

После [001](./001-reconnect-sink-leak.md) reconnect в штатном потоке работает. Но остаются концептуальные дыры:

1. **`await _vpn.stopVPN()` врёт.** Method channel возвращает `true` за ~3мс — после отправки broadcast'а, но до того как native реально остановил туннель (ещё ~50-80мс async cleanup). Любой caller разумно ждёт «после await'а операция завершена» — получает race.
2. **`reconnect()` содержал Dart-side координацию** через `firstWhere(disconnected|revoked).timeout(10s, onTimeout: empty map)`. Этот predicate имел дыру: empty map + `TunnelStatus.fromNative('') → disconnected` → ложная резолюция на мусор. Плюс вся конструкция доверяет broadcast-каналу, который мы сами признали unreliable.
3. **`configStaleSinceStart` сбрасывался только на transition events** (`Stopped`/`Started` в `_handleStatusEvent`). Если event потерялся по любой причине (Doze, system kill, edge-of-edge native race) — флаг застревал.

## Решение

### Native — blocking `stopVPN` через Completer

**`BoxVpnService.kt`:**

```kotlin
companion object {
    @Volatile
    private var stopCompleter: CompletableDeferred<Unit>? = null

    fun stopAwait(context: Context): Deferred<Unit> {
        if (currentStatus == VpnStatus.Stopped) {
            return CompletableDeferred(Unit)
        }
        val completer = CompletableDeferred<Unit>()
        stopCompleter?.cancel()         // защита от re-entry
        stopCompleter = completer
        context.sendBroadcast(Intent(ACTION_STOP).setPackage(context.packageName))
        return completer
    }
}

private fun setStatus(newStatus: VpnStatus, error: String? = null) {
    status = newStatus
    currentStatus = newStatus
    if (newStatus == VpnStatus.Stopped) {
        stopCompleter?.complete(Unit)
        stopCompleter = null
    }
    sendBroadcast(...)
}
```

Ключевое: **finality-signal идёт через direct Completer**, не через broadcast. Broadcast остаётся для transitions (fast-path для UI), но не является источником правды о «stop завершён». Completer не зависит от доставки broadcast'а.

**`VpnPlugin.kt`:**

```kotlin
private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

private fun stopVpn(result: MethodChannel.Result) {
    pluginScope.launch {
        val ok = try {
            withTimeout(5_000) {
                BoxVpnService.stopAwait(context).await()
            }
            true
        } catch (e: TimeoutCancellationException) {
            Log.w(TAG, "[vpn] stopVPN: 5s timeout")
            false
        } catch (e: Exception) {
            Log.e(TAG, "[vpn] stopVPN: exception $e")
            false
        }
        result.success(ok)
    }
}
```

`pluginScope.cancel()` в `onDetachedFromEngine` чтобы не текло.

### Dart — intent-based reset в `_stopInternal`/`_startInternal`

```dart
Future<bool> _stopInternal() async {
  final ok = await _vpn.stopVPN();
  if (ok) {
    // Intent-based reset: юзер остановил туннель, saved больше не
    // "stale vs running" — running перестал существовать.
    _emit(_state.copyWith(configStaleSinceStart: false));
  }
  return ok;
}

Future<bool> _startInternal() async {
  await _vpn.setNotificationTitle('L×Box');
  final ok = await _vpn.startVPN();
  if (ok) {
    // Intent-based reset: running теперь = saved.
    _emit(_state.copyWith(configStaleSinceStart: false));
  }
  return ok;
}
```

**Public `stop()`/`start()`** — busy-wrap + internal + error surfacing.
**`reconnect()`** — композиция `_stopInternal` → `_startInternal` под одним busy-wrap'ом. Никаких `firstWhere`, timeout'ов, wait — blocking stopVPN на native гарантирует `status=Stopped` до startVPN.

### Почему reset именно в обоих (stop И start), не только в одном

Параллельный агент изначально предложил только в `stop()` как «primary; reconnect через композицию получит». Есть валидный edge case который ломает эту логику: **external stop** через Quick Settings tile / system revoke / force-stop notification — наш `stop()` вообще не вызывается, а потом юзер жмёт Start → `_startInternal` реально применяет конфиг, и вот тут reset нужен явно.

Оба примитива семантически самостоятельны:
- stop: «running → nothing, флаг stale vs running теряет смысл»
- start: «running → saved, running == saved»

Идемпотентно с reset'ом в `_handleStatusEvent` (строки 101/127) — двойной reset не вредит.

## Риски и edge cases

### Разобраны

- **Re-entry `stopAwait`:** два одновременных вызова → предыдущий completer cancel'ится, новый регистрируется. Первый caller получит `CancellationException` → через 5s timeout path в plugin → `false`.
- **`stopAwait` при status=Stopped:** возвращает immediately-completed Deferred, без lockup.
- **Timeout 5с:** в логах прежних сессий cleanup занимал ~50-80мс. 5с = 60× запас. Если реально затянется — `stopVPN returned false`, reconnect aborts, юзер видит error.
- **`reconnect` aborts при stop timeout:** не идёт в startVPN, чтобы не попасть в onStartCommand guard (status ≠ Stopped). Юзер видит «Stop timed out — reconnect aborted».
- **`pluginScope` leak:** `cancel()` в `onDetachedFromEngine`. При hot reload — новый scope.

### Не закрыто (отдельные задачи)

- **External revoke UX** — другое VPN приложение захватило туннель. Native уже ловит через `onRevoke()`. UX требует фикса: сейчас рисуется красной пилюлей, надо показать snackbar + маппить в Disconnected. → **003**.
- **Lifecycle resume pull** — если процесс был в background долго и native ушёл тихо. → **004**.
- **Stop button silent failure after APK update** — параллельный агент упоминал. Требует воспроизведения на девайсе для оценки.

## Верификация

- `dart analyze lib/` — clean
- `flutter build apk --debug` — succeeds
- Manual reconnect test — **pending** (девайс недоступен в текущей сессии, пользователь проверит)

Критерии приёмки (для следующей сессии с девайсом):
1. 10 reconnect'ов подряд → `stale=False` во всех case'ах, logcat показывает `stopVPN returned true` до `onStartCommand`
2. Manual Stop → работает как раньше, без «Stop timed out»
3. Manual Start после Stop → работает как раньше

## Нерешённое / follow-up

- ~~003 revoke UX, 004 resume pull~~ — закрыто, см. [003](./003-revoke-ux.md), [004](./004-lifecycle-resume-resync.md).
- ~~Spec 012 native vpn service обновить с описанием `stopAwait` контракта~~ — закрыто коммитом `ee3b6c1`, раздел «Status pipeline reliability» добавлен.
- ~~`TunnelStatus.fromNative` default `disconnected` на unknown~~ — закрыто в рамках follow-up из peer review [007](./007-peer-review-tasks-001-006.md). `TunnelStatus.unknown` добавлен в enum, default в `fromNative` переключён с `disconnected` на `unknown`, UI маппит unknown → Disconnected label.
