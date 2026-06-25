# §168 — Профайлер: источник connections = CommandClient (вместо мёртвого Clash-fetcher)

**Тип:** bug-fix
**Статус:** In progress
**Связано:** [`features/044 traffic-profiler`], §048 (Live/per-app), §122 (CommandClient-миграция), [`164-cc-clients-energy-model`]

## Симптом (device-факт)

`/profiler/live/start` → `{"recording":true}`, но `/profiler/live/state` →
`{"buffer_count":0,"unattributed_count":0}` — при том что `/state` показывает
`active_conns: 25`. Live-вкладка и Per-app trace пусты: ни одного `tcpOpen`/
`tcpClose`/`udpOpen`-события не попадает в `_globalRollingBuffer`.

DNS-строки из core-логов (`_processLogLine`) приходят корректно — пусты именно
**connection-события** (open/close + per-app атрибуция).

## Корень

§044 профайлер имел ДВА источника (см. шапку `traffic_profiler.dart`):
1. core-логи (DNS resolves, package detection) — **жив**;
2. **Clash API `/connections` polling** (tcp/udp open/close + stats) — **мёртв**.

§122 выпилил Clash API. `home_screen.dart:128` забиндил профайлеру **пустой**
fetcher:

```dart
TrafficProfiler.I.bindRuntime(
  connections: () async => const <String, dynamic>{'connections': []},
);
```

→ `_pollConnections()` каждые 5с получает 0 connections → `_connSnapshots`
всегда пуст → ни open, ни close не эмитятся → `buffer_count=0`.

Комментарий там же утверждал «CcConnection processPath НЕ несёт» — **устарел**:
`CcConnection` (cc_channel.dart:380-382) несёт `packageName` И `processPath`
(из libbox `getProcessInfo()`). Per-app атрибуция через CommandClient
**возможна напрямую**, прокидка в ядро не нужна.

## Решение

Источник connection-событий профайлера = `CcChannel.instance.connections`
(push-стрим), а не Clash-pull. Архитектурно правильнее pull-таймера:

- **push** вместо polling 5с → Live видит события с частотой стрима;
- `connectProfiler()` поднимает независимый **profilerClient**, который
  §164-энергомодель НЕ паузит в фоне (`pauseClients` его не трогает) →
  recording живёт при свёрнутом app, как и задумано §048;
- `CcConnection.packageName/processPath` → реальная per-app атрибуция.

### Маппинг полей Clash → CcConnection

| Профайлер ожидал (Clash) | CcConnection | Примечание |
|---|---|---|
| `id` | `id` | для open/close diff |
| `metadata.host` | `domain` | пусто у IP-only conn |
| `metadata.destinationIP` | `destination` (host-часть) | `host:port`, режем по последнему `:` |
| `metadata.destinationPort` | `destination` (port-часть) | |
| `metadata.network` | `network` | tcp/udp |
| `chains[]` | `[outbound]` | у CC одна строка outbound, не цепочка |
| `upload`/`download` | `uplink`/`downlink` | накопленный итог (total) |
| `rule` | `rule` | |
| `rulePayload` | — | нет в CC → '' |
| `metadata.process`/`processPath` | `packageName`/`processPath` | **per-app атрибуция** |
| (close = пропал из снапшота) | `closedAt > 0` ИЛИ пропал | CC шлёт closed-снапшот; страхуемся обоими |

### Изменения

**`traffic_profiler.dart`:**
- Новый метод `ingestCcConnections(List<CcConnection>)` — та же open/close-
  логика что `_pollConnections`, но на полях CcConnection. Переиспользует
  `_connSnapshots`, `_resolveForSession`, `_appendToGlobalRollingBuffer`,
  `_classifyConnectionClose`, closed-detection.
- `_pollConnections`/`_startConnectionPoll`/`_connTimer`/`_connPollInterval`/
  `_connectionsFetcher`/`bindRuntime`/`ConnectionsFetcher` — **удалить**
  (мёртвый Clash-путь). `pollOnceForTest` → `ingestForTest`.
- `startGlobalRecording`/`start`: вместо `_startConnectionPoll()` —
  `_attachCcConnections()` (подписка на `_cc.connections` + `connectProfiler()`).
- `stopGlobalRecording`/`stop`: `_maybeDetachCcConnections()` (отписка +
  `disconnectProfiler()` если ни session, ни global recording).

**`home_screen.dart`:** удалить `bindRuntime(...)` вызов (источник теперь
внутренний — `CcChannel.instance`).

**Native (`BoxCommandClient.kt`):** `connectProfilerClient()` уже существует
(§164), `ccConnectProfiler`/`ccDisconnectProfiler` уже разведены в VpnPlugin.
Изменений native НЕ требуется.

## Инвариант энергомодели (§164)

profilerClient — единственный CC-клиент, живущий в фоне. `pauseClients()`
паузит status+screen, профайлер не трогает (cc_channel.dart:165 коммент).
Подключаем profilerClient только на время recording (start→connect,
stop→disconnect), а не на всю жизнь процесса — в простое (recording off)
лишнего клиента нет.

## Проверка (device)

1. VPN up (или `/action/start-vpn-headless`).
2. `/profiler/live/start` → `recording:true`.
3. Трафик (открыть пару приложений / `/state` active_conns > 0).
4. `/profiler/live/state` → **`buffer_count > 0`**, `unattributed_count`
   отражает conn'ы без атрибуции.
5. Per-app: `/profiler/start?package=<pkg>` → события с `process=<pkg>`,
   `confidence=verified` для conn'ов с packageName.
6. Свернуть app → recording продолжается (profilerClient жив в фоне).

## Тест

`traffic_profiler` юнит-тест: `ingestForTest([CcConnection...])` →
проверить эмит `tcpOpen` в global buffer, затем повторный вызов без conn'а →
`tcpClose`. (Заменяет `pollOnceForTest`.)
