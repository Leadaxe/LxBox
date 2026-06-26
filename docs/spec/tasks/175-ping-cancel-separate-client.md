# §175 — Реальная отмена масс-пинга: отдельный pingClient + disconnect

**Тип:** bug-fix (зомби-тесты)
**Статус:** Реализовано (device-verify впереди)
**Связано:** ядро SPEC 015 §3.6 (per-call ctx cancel), §122 (urlTestOutbound),
§164 (энергомодель), CLIENT_FEEDBACK_urltest_cancel_binding (ответ ядра)

## Проблема

Масс-пинг (concurrency=10) при «отмене» гасил только ПРИМЕНЕНИЕ результатов в UI
(epoch-гейт), но `urlTestOutbound` — синхронный блокирующий gomobile-вызов:
in-flight dial в ядре **продолжался до своего TCPTimeout** (до ~10 «зомби»-
тестов). UI реагировал, ядро — нет.

## Решение (ответ ядра, вариант #2 — без правок биндинга)

Ядро (SPEC 015 §3.6) подтвердило по коду: `CommandClient.disconnect()` отменяет
**per-call `ctx`** уже-ушедших в dial тестов (`Disconnect()` → `c.cancel()` →
gRPC отменяет серверный stream-ctx → `urltest.URLTest` падает на `DialContext`/
`client.Do`, не дожидаясь `C.TCPTimeout`). Условие: рвать **отдельный** клиент,
иначе оборвутся и другие стримы (один `c.ctx` на инстанс).

Per-call cancel-handle (#1/#3) в биндинге — НЕ нужен (ядро: избыточно, YAGNI).

### Реализация (end-to-end)

**Kotlin (BoxCommandClient.kt):**
- `pingClient: AtomicReference<CommandClient?>` — отдельный инстанс (свой
  ctx/conn). Голый `PingHandler : BaseHandler(0)` (подписок нет, только unary).
- `ensurePingClient()` — лениво поднимает (CAS, идемпотентно). `urlTestOutbound`
  идёт через него (было: `anyClient()` = общий → disconnect задел бы стримы).
- `cancelPing()` = `disconnect(pingClient)` → рвёт in-flight тесты.
- `shutdownAll` сбрасывает pingClient.

**VpnPlugin.kt:** case `ccCancelPing` → `commandClient.cancelPing()`.

**Dart (cc_channel.dart):** `cancelPing()` → `_invoke('ccCancelPing')`.

**ping_orchestration.dart:**
- `cancelMassPing`: `unawaited(_cc.cancelPing())` + epoch-bump (UI). Реальная
  отмена в ядре + мгновенный UI.
- `_runAllUrltestGroups` (конец пинг-прогона): `cancelPing()` освобождает
  pingClient (lazy lifecycle: short-lived conn на прогон, ядро «дёшево»).

### Lifecycle (решение пользователя: лениво под прогон)

pingClient поднимается при первом `urlTestOutbound`, освобождается при отмене
ИЛИ в конце полного прогона (ноды + urltest-группы). В простое лишнего клиента
нет (согласовано с энергомоделью §164). Одиночный пинг (`runNodeUrltest`)
переиспользует pingClient, освобождение — на cancel/shutdown.

## Инвариант

`cancelPing()` рвёт ТОЛЬКО pingClient → status/screen/profiler-стримы целы
(разные инстансы, свои ctx). Это и есть условие ядра для варианта #2.

## Проверка (device, по запросу ядра)

Масс-пинг (concurrency=10) на медленных/недоступных узлах → «отмена»:
1. серверные dial'ы рвутся ~моментально, НЕ висят до `C.TCPTimeout` (логи ядра);
2. Connections/Groups-стримы основного клиента НЕ мигают/не пересоздаются;
3. следующий масс-пинг поднимает свежий pingClient и работает.
