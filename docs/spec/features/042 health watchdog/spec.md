# 042 — Health watchdog (heartbeat metrics + auto-recovery)

| Поле | Значение |
|------|----------|
| Статус | Draft — **backlog** (код не начат: классов `HealthWatchdog` / `HeartbeatHealth` в `app/lib` нет; проверено 2026-06-22, [§155 аудит](../../tasks/155-audit-2026-06-quick-wins.md)). §047 события `HEARTBEAT_FAILED` / `LATENCY_DEGRADED` зарезервированы под эту фичу и сейчас не эмитятся — см. [AUTOMATION.md](../../../AUTOMATION.md). |
| Дата | 2026-05-05 |
| Связанные | [`030 vpn reload button`](../../tasks/030-vpn-reload-button.md), [`031 reset network api`](../../tasks/031-reset-network-api.md), [`031 debug api`](../031%20debug%20api/spec.md), [`047 public intent api`](../047%20public%20intent%20api/spec.md) (health-события) |
| Триггер | После выхода phone'а из сна direct/auto outbound'ы перестают отвечать (sing-box не знает что NAT-таблица оператора протухла, держит зомби-connections в tracker'е по 16+ минут пока TCP keep-alive не сработает). Текущий heartbeat детектит только liveness localhost Clash API, не реальный transport. |

## Цель

Ввести подсистему наблюдения за здоровьем VPN-туннеля и автоматическим **точечным** recovery. Подсистема состоит из двух **строго разделённых** компонентов:

1. **`HeartbeatHealth`** — пассивный коллектор данных. Singleton. **Только пишет/читает state**, ничего не решает.
2. **`HealthWatchdog`** — реактор. Singleton. **Только читает state у Health**, делает решения и иногда дёргает `resetNetwork()`.

Между ними **read-only boundary**. Watchdog никогда не пишет в Health. Health не знает что такое recovery.

## Когда watchdog действует

ВСЕ четыре условия одновременно:

1. **Юзер вернулся в app** — `AppLifecycleState.resumed` event (только в этот момент проверяем).
2. **URL test signal не подтверждает работающий transport:**
   - последний успешный URL test был **> 15 минут назад** (или вообще никогда), **ИЛИ**
   - последний успех был **> 3 минут назад** **И** после него **≥ 3 fails** подряд.
3. **Трафика нет уже >= 5 минут подряд** — `noTrafficStreakDuration >= 5 min`.
4. **Системные проверки watchdog'а:**
   - туннель поднят
   - окно прогрева 10 минут с момента connect — прошло
   - пауза между сбросами 15 минут с момента предыдущего reset — прошла

Если все четыре пройдены → `BoxVpnClient.resetNetwork()`.

## Архитектура — data flow

```
┌──────────────────────────────────────────────────────────────────┐
│                       HomeController                              │
│                                                                   │
│  _checkHeartbeat() ─────────────┐                                 │
│                                 │ writes (recordTick)             │
│  pingNode(tag)         ─┐       │                                 │
│  pingAllNodes()         ├───────┤ writes (recordUrlTestResult)    │
│  runGroupUrltest(group) ┘       │                                 │
│                                 ▼                                 │
└─────────────────────────┬────────────────────────────────────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │   HeartbeatHealth.I   │  singleton. ЕДИНСТВЕННЫЙ writer.
              │                       │
              │  state:               │
              │   - lastSuccessfulUrl │
              │     TestAt + tag + ms │
              │   - urlTestFailures…  │
              │   - noTrafficStreak…  │
              │                       │
              │  recordTick(...)      │  write API
              │  recordUrlTestResult()│  write API
              │  clear()              │  write API (на disconnect)
              │                       │
              │  read-only геттеры    │
              │  debugSnapshot() →Map │
              └──────────┬────────────┘
                         │
                         │ READ ONLY
                         ▼
              ┌───────────────────────┐
              │   HealthWatchdog.I    │  singleton. ТОЛЬКО читает Health.
              │                       │
              │  Subscribes to:       │
              │  - AppLifecycleState  │  (resumed event)
              │  - home.addListener   │  (tunnelUp transitions)
              │                       │
              │  Internal state:      │
              │   - _tunnelUpAt       │  для окна прогрева
              │   - _lastResetAt      │  для паузы между сбросами
              │                       │
              │  на resumed event:    │
              │   1. tunnelUp?        │
              │   2. окно прогрева    │
              │   3. пауза прошла?    │
              │   4. _isDegraded?     │  ← reads Health здесь
              │   → resetNetwork      │
              └──────────┬────────────┘
                         │
                         ▼
                ┌─────────────────┐
                │ BoxVpnClient    │
                │ .resetNetwork() │  → MethodChannel → libbox CommandServer
                └─────────────────┘
```

**Принципиальные правила:**

- `HeartbeatHealth` **не знает** про `HealthWatchdog`. Health не имеет ссылок на recovery actions, на BoxVpnClient, на UI, на HomeController.
- `HealthWatchdog` **читает** Health через явные геттеры. Нет write-доступа.
- Все пороги — в `HealthConstants`. Магических чисел в логике быть не должно.
- На `_onTunnelDead` Watchdog засыпает автоматически через `tunnelUp == false`. Явная подписка не нужна.

---

## `HeartbeatHealth` — collector

### Файл

`lib/services/health/heartbeat_health.dart`

### Публичный контракт

```dart
/// Пассивный коллектор health-данных. **Singleton** — `HeartbeatHealth.I`.
///
/// Не решает действий. Только хранит и отдаёт текущий снимок.
/// Mutate можно только через [recordTick], [recordUrlTestResult], [clear].
/// Read через явные геттеры.
class HeartbeatHealth {
  HeartbeatHealth._();
  static final HeartbeatHealth I = HeartbeatHealth._();

  // ─── Write API ────────────────────────────────────────────────

  /// Вызывается из `HomeController._checkHeartbeat` на каждый успешный
  /// tick. Обновляет zero-traffic streak counter.
  ///
  /// `trafficDelta` — изменение `(uploadTotal + downloadTotal)` с предыдущего
  /// тика. Если `connectionsCount > 0 && trafficDelta == 0` — streak растёт.
  /// Иначе — обнуляется.
  void recordTick({
    required int trafficDelta,
    required int connectionsCount,
  });

  /// Вызывается всеми pingers (single/mass/group). delayMs ≥ 0 = success,
  /// -1 = fail. На успех сбрасывает failure counter и обновляет timestamp.
  void recordUrlTestResult(String tag, int delayMs, {required UrlTestSource source});

  /// Вызывается на VPN disconnect / tunnel-dead. Сбрасывает всё к null/0.
  void clear();

  // ─── Read API ─────────────────────────────────────────────────

  /// Когда был последний успешный URL test. null если ни одного не было
  /// (или после clear).
  DateTime? get lastSuccessfulUrlTestAt;

  /// Тег outbound'а у последнего успешного URL test'а.
  String? get lastSuccessfulUrlTestTag;

  /// Задержка в ms у последнего успешного URL test'а.
  int get lastSuccessfulUrlTestDelayMs;

  /// Сколько fail'ов после последнего успешного URL test'а. На каждый
  /// success обнуляется.
  int get urlTestFailuresSinceLastSuccess;

  /// Длительность текущего streak'а нулевого трафика. 0 если последний tick
  /// показал traffic > 0 (или connectionsCount == 0). Растёт пока подряд
  /// идут tick'и с `trafficDelta == 0 && connectionsCount > 0`.
  Duration get noTrafficStreakDuration;

  /// Snapshot для Debug API `/state/health` — JSON-сериализуемый Map.
  Map<String, dynamic> debugSnapshot();
}

enum UrlTestSource {
  /// Юзер тапнул "Ping" на одной ноде (HomeController.pingNode).
  singleNode,
  /// Mass URL test всей группы (HomeController.pingAllNodes / автопинг).
  massGroup,
  /// Group-level URL test через sing-box (HomeController.runGroupUrltest).
  groupForce,
}
```

### Семантика `recordUrlTestResult`

```dart
void recordUrlTestResult(String tag, int delayMs, {required UrlTestSource source}) {
  if (delayMs >= 0) {
    _lastSuccessfulUrlTestAt = clock.now();
    _lastSuccessfulUrlTestTag = tag;
    _lastSuccessfulUrlTestDelayMs = delayMs;
    _urlTestFailuresSinceLastSuccess = 0;
  } else {
    _urlTestFailuresSinceLastSuccess++;
  }
}
```

`source` сохраняется только в debug snapshot'е, в логике не используется.

### Семантика `recordTick`

```dart
void recordTick({required int trafficDelta, required int connectionsCount}) {
  final hasActiveConns = connectionsCount > 0;
  final hasTraffic = trafficDelta > 0;
  if (hasActiveConns && !hasTraffic) {
    _zeroTrafficStreakStart ??= clock.now();
    _noTrafficStreakDuration = clock.now().difference(_zeroTrafficStreakStart!);
  } else {
    _zeroTrafficStreakStart = null;
    _noTrafficStreakDuration = Duration.zero;
  }
}
```

**Почему именно `connectionsCount > 0` фильтр:**

Идея — streak должен расти только когда есть **попытка использовать transport, и она не удаётся**. Без фильтра чистый idle (юзер не открывал ни одного app, нет TCP в tracker'е) накапливал бы streak впустую → ложные reset'ы.

Возможный контр-вопрос: "если сети физически нет, соединения вообще не установятся, `connectionsCount` останется 0, streak не вырастет". Это **не так** — sing-box добавляет connection в Clash tracker **в момент когда начинает обрабатывать пакет из TUN**, до успешного dial'а к outbound:

```
1. Юзер тапает Telegram → SYN в TUN
2. Sing-box читает пакет → создаёт connection в tracker (connectionsCount += 1)
3. Sing-box ищет outbound → dial'ит TCP к VPN-серверу
4. NAT мёртвый, dial timeout → connection остаётся в tracker как dead, byte counter = 0
```

То есть как только юзер **что-то делает** через VPN, `connectionsCount > 0` независимо от того успешен dial или нет. Streak растёт ровно в нужный момент — соединения **есть** (юзер пытается работать), но byte counter `== 0` (через них ничего не проходит).

Если юзер вообще ничего не делает (пустой idle, нет background apps) — `connectionsCount == 0`, streak не растёт, watchdog не сработает. Это правильное поведение: нет evidence о сломанном transport'е, не действуем.

---

## `HealthWatchdog` — reactor

### Файл

`lib/services/health/health_watchdog.dart`

### Публичный контракт

```dart
/// Реактор поверх [HeartbeatHealth]. **Singleton** — `HealthWatchdog.I`.
/// На `AppLifecycleState.resumed` проверяет деградацию + системные
/// проверки → может дёрнуть `BoxVpnClient.resetNetwork()`.
///
/// **READ-ONLY** для Health.
class HealthWatchdog with WidgetsBindingObserver {
  HealthWatchdog._();
  static final HealthWatchdog I = HealthWatchdog._();

  /// Подписывается на lifecycle + home listener. Вызывать **один раз** в
  /// `main.dart` после готовности `HomeController` и `BoxVpnClient`.
  void attach({
    required HomeController home,
    required BoxVpnClient vpn,
    Clock clock = const Clock.system(),
  });

  /// Отписаться. Опционально на shutdown.
  void dispose();

  // ─── Observability (read-only) ────────────────────────────────

  /// Когда tunnel up'нулся последний раз. null если down.
  DateTime? get tunnelUpAt;

  /// Когда watchdog в последний раз дёрнул resetNetwork. null если ни разу.
  DateTime? get lastResetAt;

  Map<String, dynamic> debugSnapshot();
}
```

### Внутренний flow

```dart
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state != AppLifecycleState.resumed) return;
  unawaited(_maybeReset());
}

Future<void> _maybeReset() async {
  // Проверка 1: туннель поднят
  if (!home.state.tunnelUp || _tunnelUpAt == null) return;

  // Проверка 2: окно прогрева
  if (clock.now().difference(_tunnelUpAt!) < HealthConstants.warmupGrace) return;

  // Проверка 3: пауза между сбросами
  if (_lastResetAt != null &&
      clock.now().difference(_lastResetAt!) < HealthConstants.resetCooldown) {
    return;
  }

  // Проверка 4: деградация
  if (!_isDegraded()) return;

  _lastResetAt = clock.now();
  await vpn.resetNetwork();
  home.addDebugPublic('Watchdog: degraded → resetNetwork');
}

bool _isDegraded() {
  return _urlTestNotConfirmingWorking() && _noTrafficForLong();
}

bool _urlTestNotConfirmingWorking() {
  final lastOk = HeartbeatHealth.I.lastSuccessfulUrlTestAt;

  // Случай A: успехов не было / давно (> 15 мин)
  if (lastOk == null) return true;
  final age = clock.now().difference(lastOk);
  if (age > HealthConstants.urlTestStaleThreshold) return true;

  // Случай B: lastOk > 3 мин назад И ≥ 3 fails после него
  if (age > HealthConstants.urlTestFailingMinAge &&
      HeartbeatHealth.I.urlTestFailuresSinceLastSuccess >=
          HealthConstants.urlTestFailureThreshold) {
    return true;
  }

  return false;
}

bool _noTrafficForLong() {
  return HeartbeatHealth.I.noTrafficStreakDuration >=
         HealthConstants.noTrafficStaleThreshold;
}

void _onHomeStateChanged() {
  final isUp = home.state.tunnelUp;
  if (isUp && _tunnelUpAt == null) {
    _tunnelUpAt = clock.now();
    _lastResetAt = null;       // fresh connect → cooldown сбрасывается
  } else if (!isUp) {
    _tunnelUpAt = null;
  }
}
```

---

## `HealthConstants` — все пороги

### Файл

`lib/services/health/health_constants.dart`

```dart
class HealthConstants {
  HealthConstants._();

  // ─── URL test signal ──────────────────────────────────────────

  /// Случай A: последний успех старше → "давно не пинговал, статус неизвестен".
  static const Duration urlTestStaleThreshold = Duration(minutes: 15);

  /// Случай B: для определения "длится failure streak" — last success
  /// должен быть не менее этого назад.
  static const Duration urlTestFailingMinAge = Duration(minutes: 3);

  /// Случай B: количество failures после lastSuccess (больше или равно).
  static const int urlTestFailureThreshold = 3;

  // ─── Traffic signal ───────────────────────────────────────────

  /// Если 0 трафика идёт уже эту длительность → "transport не пропускает".
  static const Duration noTrafficStaleThreshold = Duration(minutes: 5);

  // ─── Watchdog проверки ────────────────────────────────────────

  /// После tunnel up — первые [warmupGrace] минут НЕ делать reset.
  static const Duration warmupGrace = Duration(minutes: 10);

  /// Не делать reset чаще чем раз в [resetCooldown].
  static const Duration resetCooldown = Duration(minutes: 15);
}
```

---

## Integration в `HomeController`

### `_checkHeartbeat` — recordTick

```dart
int _lastTickTotalBytes = 0;

Future<void> _checkHeartbeat() async {
  if (!_state.tunnelUp) {
    _stopHeartbeat();
    HeartbeatHealth.I.clear();
    return;
  }
  final clash = _clash;
  if (clash == null) return;

  try {
    final traffic = await clash.fetchTraffic().timeout(_heartbeatTimeout);
    // ... existing _emit ...

    final totalBytes = traffic.upTotal + traffic.downTotal;
    HeartbeatHealth.I.recordTick(
      trafficDelta: totalBytes - _lastTickTotalBytes,
      connectionsCount: traffic.connectionsCount,
    );
    _lastTickTotalBytes = totalBytes;
  } catch (_) {
    // failure path — Health не обновляется
  }
}
```

### Pingers — recordUrlTestResult

```dart
// pingNode (single)
final ms = await clash.delay(tag, ...);
HeartbeatHealth.I.recordUrlTestResult(tag, ms, source: UrlTestSource.singleNode);
// catch:
HeartbeatHealth.I.recordUrlTestResult(tag, -1, source: UrlTestSource.singleNode);

// pingAllNodes worker (mass)
HeartbeatHealth.I.recordUrlTestResult(tag, ms, source: UrlTestSource.massGroup);
// catch:
HeartbeatHealth.I.recordUrlTestResult(tag, -1, source: UrlTestSource.massGroup);

// runGroupUrltest result map (group force)
for (final entry in results.entries) {
  HeartbeatHealth.I.recordUrlTestResult(entry.key, entry.value, source: UrlTestSource.groupForce);
}
// catch:
HeartbeatHealth.I.recordUrlTestResult(groupTag, -1, source: UrlTestSource.groupForce);
```

### Wire'инг Watchdog в `main.dart`

```dart
// после инициализации HomeController:
HealthWatchdog.I.attach(
  home: homeController,
  vpn: BoxVpnClient(),
);
```

---

## Debug API — `GET /state/health`

В `lib/services/debug/handlers/state.dart`:

```dart
'/state/health' => _health(req, ctx),
```

```dart
Future<DebugResponse> _health(DebugRequest req, DebugContext ctx) async {
  return JsonResponse({
    'health': HeartbeatHealth.I.debugSnapshot(),
    'watchdog': HealthWatchdog.I.debugSnapshot(),
  });
}
```

### Snapshot формат

```jsonc
{
  "health": {
    "url_test": {
      "last_successful_at": "2026-05-05T19:35:00Z",
      "last_successful_age_seconds": 364,
      "last_successful_tag": "🇵🇱⚡Польша",
      "last_successful_delay_ms": 234,
      "failures_since_last_success": 4
    },
    "no_traffic_streak_seconds": 312
  },
  "watchdog": {
    "tunnel_up_at": "2026-05-05T19:30:00Z",
    "warmup_remaining_seconds": 0,
    "last_reset_at": null,
    "cooldown_remaining_seconds": 0
  }
}
```

При анализе debug-репорта причина «почему не сделан reset» восстанавливается из полей: `tunnel_up_at == null` → tunnel down; `warmup_remaining_seconds > 0` → окно прогрева; `cooldown_remaining_seconds > 0` → пауза между сбросами; иначе — health не degraded.

---

## Tests

### `test/services/health/heartbeat_health_test.dart`

Unit-тесты на чистую логику Health'а. Чистый Dart, без Flutter.

1. **recordUrlTestResult success** → `lastSuccessfulUrlTestAt`/tag/delayMs обновлены, `failures = 0`
2. **recordUrlTestResult fail** (delayMs=-1) → `failures` инкремент, `lastSuccessful*` неизменны
3. **3 fail подряд** → `failures = 3`
4. **success после 5 fails** → `failures = 0`, `lastSuccessful*` обновлено
5. **clear()** → state к null/0
6. **recordTick** с `trafficDelta > 0` → `noTrafficStreakDuration = 0`
7. **recordTick** с `trafficDelta == 0 && connectionsCount > 0` 3 раза подряд (с inject'ом clock) → streak растёт
8. **recordTick** с `connectionsCount == 0` → streak обнуляется (даже если traffic = 0)
9. **debugSnapshot** содержит все поля, корректные JSON-типы

### `test/services/health/health_watchdog_test.dart`

Unit-тесты Watchdog'а через fake `HomeController`, fake `HeartbeatHealth`, fake `BoxVpnClient`. Inject Clock для контроля времени.

1. **resumed in warmup** → reset не вызван
2. **resumed после warmup, healthy URL test, no traffic streak** → reset не вызван (URL test не подтверждает поломку)
3. **resumed после warmup, URL test stale (15+ min), no traffic streak < 5 min** → reset не вызван (нет confirmation no-traffic)
4. **resumed после warmup, URL test stale, no-traffic streak >= 5 min** → reset вызван ✓
5. **resumed после warmup, fails >= 3 + age > 3 min, no-traffic streak >= 5 min** → reset вызван ✓
6. **resumed дважды подряд, оба раза degraded** → второй раз skip (cooldown)
7. **resumed после cooldown, всё ещё degraded** → reset вызван
8. **tunnel down** → resumed → reset не вызван
9. **tunnel reconnect** → fresh tunnelUpAt, _lastResetAt = null, warmup grace заново
10. **isDegraded требует AND**: только URL signal без traffic — false. Только traffic без URL — false. Только оба — true.

---

## Что НЕ в скопе

- **Synthetic URL probes** через `clash.delay('direct-out', url='http://1.1.1.1/')` — отброшено из-за российских mobile белых списков (false positives).
- **UI индикатор health** в HomeScreen — отдельная фича.
- **Per-outbound breakdown** — пока global aggregate.
- **Auto-trigger reset на ConnectivityChange** — sing-box делает сам через `notifyInterfaceUpdate`.
- **Auto-trigger reset на heartbeat fail (red zone)** — `_onTunnelDead` обрабатывается отдельно, делает full reconnect. Watchdog не вмешивается.
- **Калибровка thresholds под Tele2 restricted / etc.** — стартовые значения эвристика, калибруется через debug snapshots.

---

## Risks

| Риск | Митигация |
|---|---|
| Watchdog ложно решает что degraded | AND из URL test signal + traffic streak требует **двух** независимых подтверждений. False positive маловероятен. |
| URL test signal сломан (gstatic заблокирован карриером, все pings fail) | Сам по себе не вызовет reset — нужен ещё no-traffic streak. Если у юзера активно идёт трафик через VPN — streak не накопится → reset не сработает. |
| Memory leak | Все state — fixed-size (counters + timestamps). |
| Pinger зовёт `recordUrlTestResult` параллельно из разных threads | Dart single-isolate → race-free. |
| Watchdog dispose не вызывается | Singleton живёт весь lifetime app'а — приемлемо. |
| Threshold-числа не подходят какому-то юзеру | Все в `HealthConstants`, видны через `/state/health`, легко править. |

---

## План имплементации

1. `lib/services/health/health_constants.dart` — все константы.
2. `lib/services/health/heartbeat_health.dart` — `HeartbeatHealth` + `UrlTestSource` enum.
3. `test/services/health/heartbeat_health_test.dart` — unit-тесты.
4. `lib/services/health/health_watchdog.dart` — `HealthWatchdog` + `Clock` interface (если нет — добавить простой).
5. `test/services/health/health_watchdog_test.dart` — unit-тесты с fake'ами.
6. **Integration в HomeController:** `_checkHeartbeat` → recordTick; pingNode/pingAllNodes/runGroupUrltest → recordUrlTestResult; `_lastTickTotalBytes` поле.
7. **Wire в `main.dart`:** `HealthWatchdog.I.attach(home: ..., vpn: ...)`.
8. Debug API endpoint `GET /state/health`.
9. `flutter analyze` + `flutter test`.
10. Build APK + install + калибровка через эксплуатацию.

## Verification

1. **Healthy idle:** VPN connect, юзер активно использует, swipe в фон → 5 мин idle (но трафик от FCM капает) → resumed → `noTrafficStreakDuration < 5 min` → reset НЕ вызван ✓
2. **Healthy active:** юзер в app, всё работает → resumed (он переключился на app сегодня уже несколько раз) → URL test недавно успешен → reset НЕ вызван ✓
3. **Degraded after wake:** VPN connect → юзер пингал, всё ок → phone в кармане 7 минут (NAT timeout) → resumed → URL test fails вылез + 5+ min нет трафика → reset вызван ✓
4. **Cooldown:** искусственно повторить degraded ситуацию через 5 минут после первого reset → второй reset skipped (cooldown 15 min ещё идёт) ✓
5. **Warmup grace:** в первые 10 мин после connect — никаких reset ✓
6. **Tunnel dead:** `_onTunnelDead` отрабатывает → tunnelUp=false → Watchdog засыпает → после reconnect fresh warmup grace ✓

## Docs to update

См. постоянную карту в [`docs/spec/README.md → Карта обновления документации`](../../README.md#карта-обновления-документации).

| Файл | Что добавить |
|---|---|
| [`docs/api/debug-api-reference.md`](../../../api/debug-api-reference.md) | `GET /state/health` — JSON snapshot HeartbeatHealth + HealthWatchdog (verdict, last successful URL test, no-traffic streak, tunnelUpAt, lastResetAt). Bash use-case: «как из debug-репорта понять почему watchdog не сделал reset». |
| [`CHANGELOG.md`](../../../../CHANGELOG.md) | Entry в `Unreleased`: «Health watchdog — auto-recovery после wake from sleep через resetNetwork (детект через URL test signal + no-traffic streak, AND обоих)». |
| [`docs/ARCHITECTURE.md`](../../../ARCHITECTURE.md) | Section про health subsystem: data flow HeartbeatHealth (passive collector) ↔ HealthWatchdog (reactor, READ-ONLY от Health). |
| [`RELEASE_NOTES.md`](../../../../RELEASE_NOTES.md) + [`docs/releases/vX.Y.Z.md`](../../../releases/) | На bump'е версии — entry про auto-recovery: «после долгого ухода phone'а в фон, VPN сам восстанавливается на open app, без manual reload». |
| [`pubspec.yaml`](../../../../app/pubspec.yaml) | Minor bump (1.6.0 → 1.7.0) — auto-recovery это user-visible behavioral change. Или patch (1.6.0 → 1.6.1) если катим в составе release-batch'а с §035-§037. |
| [`docs/DEVELOPMENT_REPORT.md`](../../../DEVELOPMENT_REPORT.md) | Опционально — нарратив про калибровку thresholds в эксплуатации. |
