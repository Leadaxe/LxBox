# 027 — Auto-обновление подписок

| Поле | Значение |
|------|----------|
| Статус | **Реализовано и в продакшене** (2026-04-18) |
| Дата | 2026-04-18 |
| Зависимости | [`004`](../004x%20subscription%20parser/spec.md) (заменено 026), [`026`](../026%20parser%20v2/spec.md) |

## Прогресс

| Блок | Статус |
|------|--------|
| Модель: `UpdateStatus`, `lastUpdateAttempt`, `lastUpdateStatus`, `consecutiveFails` | ✅ |
| `SubscriptionController.refreshEntry` + записи статуса + crash-safe init-sweep | ✅ |
| Dedup guard внутри `_fetchEntryByRef` (проверка inProgress) | ✅ |
| `AutoUpdater` (4 триггера, gating, fail-cap) | ✅ |
| UI: interval/ago/fails в строках подписок + блок "Subscription" в detail | ✅ |
| Wiring: `HomeScreen.initState` создаёт AutoUpdater, зовёт `start()` после `_subController.init()` | ✅ |
| Wiring: `HomeController._handleStatusEvent` дёргает `onVpnConnected`/`onVpnStopped` на tunnel transitions | ✅ |
| Manual refresh ("Update all" на Servers) через `AutoUpdater.maybeUpdateAll(manual, force:true)` | ✅ |
| Per-entry refresh: `SubscriptionController.updateAt` делает `autoUpdater.resetFailCount` + прямой fetch (inProgress guard) | ✅ |

---

## Цель и рамки

Sing-box клиент потребляет URL-подписки, список узлов устаревает. Нужен фоновый механизм обновления без ввода пользователя, **не нарушающий главную инвариант подписок: никогда не спамить провайдеру**. Любой fetch должен быть оправданным, любой цикл должен иметь cap, любая гонка должна быть dedup'нута.

**Не в скопе:**
- ETag / If-Modified-Since кэширование на HTTP-уровне (делается на `http_cache.dart` отдельно).
- Background fetch когда app убит (Android `WorkManager`). Пока — foreground/opened-app only.
- Per-subscription override триггеров (например «этот только manual»).
- Exponential backoff (fail-cap уже достаточно для защиты).

---

## Триггеры (§026-compat)

| # | Имя | Когда | Задержка после события | Force? |
|---|-----|-------|------------------------|--------|
| 1 | `appStart` | `SubscriptionController.init()` завершился | сразу | ❌ |
| 2 | `vpnConnected` | Туннель перешёл в `connected` | **+2 мин** (даём сессии устояться) | ❌ |
| 3 | `periodic` | Таймер | **раз в 1 час** | ❌ |
| 4 | `vpnStopped` | Туннель ушёл из `connected` | сразу | ❌ |
| 5 | `manual` | Юзер нажал ⟳ на Servers / Detail | сразу | ✅ |

Все триггеры ведут в единый метод `AutoUpdater.maybeUpdateAll(trigger, {force})` — решает **одна функция** `_shouldUpdate`, логика not duplicated.

---

## Gates (всё, что ограничивает HTTP)

| Gate | Значение | Переживает рестарт? | Что защищает |
|------|----------|---------------------|---------------|
| `updateIntervalHours` | 24ч default, override из `profile-update-interval` header или UI | ✅ JSON | Основной «пора ли»: `now - lastUpdated >= interval`. |
| `minRetryInterval` | 15 мин | ✅ JSON (через `lastUpdateAttempt`) | Не дёргать ту же подписку чаще раз в 15 мин. Спасает при fail-шторме на каждом триггере. |
| `maxFailsPerSession` | 5 | ❌ (in-memory) | После 5 фейлов подряд подписка заморожена **до рестарта app**. Спек-решение: не переживать рестарт, чтобы юзер с «поправленной подпиской» не ждал сброса. |
| `perSubscriptionDelay` | 10 сек ± 2 сек jitter | n/a | Между подписками внутри прохода. Не нагружает провайдеров. |
| `_running` flag | — | n/a | `maybeUpdateAll` не запускается параллельно сам в себе. |
| `_inFlight` Set | URL-level | n/a | Внутри одного прохода дедуп по URL (на случай если один URL в двух entries). |
| `lastUpdateStatus == inProgress` guard | per-entry | ✅ JSON | **`_fetchEntryByRef` возвращается сразу, если попытка уже в процессе.** Закрывает: ручная кнопка ⟳ нажата 2 раза подряд; триггер + manual совпали в миллисекунде. |

**Почему `lastUpdateAttempt` надо персистить:** иначе юзер рестартует app 10 раз за час — каждый раз appStart триггер видит "lastUpdated час назад, interval 24h → пора" и дёргает HTTP. С персистом: `now - lastUpdateAttempt < 15min → skip`.

### Crash-safe init sweep

Если app убит во время fetch'а, на диске `lastUpdateStatus=inProgress` → guard в `_fetchEntryByRef` залочит подписку навсегда. Решение: `SubscriptionController.init()` проходит по всем подпискам и конвертит `inProgress → failed` (с сохранением `lastUpdateAttempt`, чтобы `minRetryInterval` продолжал работать).

---

## Состояние подписки

Поля на `SubscriptionServers` (persist в server_lists JSON):

```dart
final DateTime? lastUpdated;         // успешный fetch (nodes валидны)
final DateTime? lastUpdateAttempt;   // любая попытка (ok|failed|inProgress)
final UpdateStatus lastUpdateStatus; // { never, ok, failed, inProgress }
final int updateIntervalHours;       // 24 default; override из profile header
final int consecutiveFails;          // подряд фейлов; сбрасывается в 0 на ok
```

**Invariants:**
- `lastUpdated` меняется **только** на успех. Фейл не трогает последний валидный timestamp.
- `lastUpdateAttempt >= lastUpdated` всегда (fail после success двигает только attempt).
- `lastUpdateStatus == ok` ⟹ `lastUpdated != null`.
- `consecutiveFails == 0` после любого успеха, даже первого.
- `nodes` не очищается при fail — держим последний валидный список.

`consecutiveFails` **не используется** для фризинга (это задача `AutoUpdater._failCounts`, memory-only, reset на рестарт). Оно только для UI: показать юзеру «(3 fails)» в строке подписки.

---

## Поток `maybeUpdateAll`

```
maybeUpdateAll(trigger, force):
  if _running: debug-log, return
  _running = true
  try:
    candidates = [e for e in entries if _shouldUpdate(e, force)]
    if empty: debug-log, return
    for i, entry in candidates:
      if _inFlight has url: continue
      _inFlight.add(url)
      try:
        refreshEntry(entry, trigger)
        if result.ok: _failCounts[url] = 0
        else:         _failCounts[url] += 1
      except e:
        _failCounts[url] += 1
      finally:
        _inFlight.remove(url)
      if i < last: sleep(10s ± 2s jitter)
  finally:
    _running = false
```

Каждый `refreshEntry` внутри:
1. Guard: `lastUpdateStatus == inProgress` → return (dedup).
2. Mark `inProgress` + persist (crash-safe: даже если процесс убит, следующий fetch будет через 15 мин).
3. `parseFromSource` → HTTP + parse + cache.
4. Success: `copyWith(lastUpdated=now, status=ok, consecutiveFails=0, nodes=...)` + persist.
5. Fail: `copyWith(status=failed, consecutiveFails++)` + persist (nodes/lastUpdated не трогаем).

---

## `_shouldUpdate` решение

```dart
bool _shouldUpdate(entry, force):
  if list not SubscriptionServers: false
  if !list.enabled: false
  if !force && _failCounts[url] >= 5: false   // frozen this session
  if force: true
  if lastUpdateAttempt != null && now - lastUpdateAttempt < 15min: false
  if lastUpdated == null: true                // never succeeded
  return now - lastUpdated >= interval
```

Отметить: `force=true` пропускает fail-cap и min-retry, но **не** пропускает `enabled` и type-check.

---

## Manual refresh

Два разных пути, по назначению:

**Per-entry ⟳** (на строке подписки / на detail-экране) → `SubscriptionController.updateAt(index)`:
1. `autoUpdater.resetFailCount(url)` — "размораживаем" подписку если она была в session-cap'е.
2. `_fetchEntry(index, trigger: UpdateTrigger.manual)` — прямой fetch через `_fetchEntryByRef`.
3. `inProgress` guard защищает от двойных кликов.

Не роутим через `maybeUpdateAll(manual)` потому что per-entry ⟳ по смыслу — "обнови ЭТУ подписку", не всю пачку. 10-секундные задержки между подписками здесь не нужны.

**Global "Update all"** (кнопка на Servers screen) → `_updateAll`:
1. `autoUpdater.resetAllFailCounts()` — снимаем session-cap со всех.
2. `autoUpdater.maybeUpdateAll(UpdateTrigger.manual, force: true)` — батч-fetch с `_running` dedup и 10с между подписками.
3. `subController.generateConfig()` — локальная сборка.
4. `homeController.saveParsedConfig(config)` — запись в tunnel (триггерит `configStaleSinceStart` warning если tunnelUp).

---

## Интеграция

### `HomeScreen.initState`

```dart
_subController = SubscriptionController();
_autoUpdater = AutoUpdater(_subController);
_subController.bindAutoUpdater(_autoUpdater);  // для per-entry resetFailCount
_controller = HomeController(autoUpdater: _autoUpdater);

// порядок критичен: AutoUpdater итерирует entries, сначала грузим с диска
unawaited(_initSubsAndAutoUpdate());  // = await sub.init() → autoUpdater.start()
```

`AutoUpdater.start()` делает сразу два дела: взводит periodic-таймер на 1 час и сразу запускает `maybeUpdateAll(appStart)` — триггер #1.

### `HomeController._handleStatusEvent`

```dart
if (tunnel == TunnelStatus.connected) {
  ...
  _autoUpdater?.onVpnConnected();               // триггер #2, +2 мин
} else if (disconnected || revoked) {
  ...
  if (prevTunnel == TunnelStatus.connected) {
    _autoUpdater?.onVpnStopped();               // триггер #4, сразу
  }
}
```

Проверка `prevTunnel == connected` нужна чтобы двойные события (revoked → disconnected) не приводили к двум `onVpnStopped`. `onVpnStopped` сам работает как no-op если туннель и не был up, но лог не стоит мусорить.

### `HomeScreen` rebuild

**Важно (решение §026-followup):** `_rebuildConfig()` зовёт `SubscriptionController.generateConfig()`, НЕ `updateAllAndGenerate()`. Пересборка config **никогда** не триггерит HTTP. За fetch отвечает только AutoUpdater + manual refresh.

---

## UI surface

### Строка подписки (Servers list)

```
[switch] My Provider                                    [⚙ 3]
         124 nodes · 🔄 24h · 🕐 3h ago · (2 fails)
```

Где:
- `🔄 24h` — `updateIntervalHours`, иконка `Icons.sync`.
- `🕐 3h ago` — `formatAgo(lastUpdated)`, иконка `Icons.schedule`. Если `lastUpdated==null` и status=`never` — показываем `never`.
- `(N fails)` — только если `consecutiveFails > 0`, красным.

### Detail screen — Settings tab

Внизу отдельный блок `Subscription`:
- **URL** — read-only, tap = copy to clipboard.
- **Update interval** — tap = picker `[1, 3, 6, 12, 24, 48, 72, 168]h`, persist через `entry.updateIntervalHours`.
- **Status row** — icon + label (`OK` / `Failed (N in a row)` / `Refreshing…` / `Never updated`), subtitle = `Last success: 3h ago · Last attempt: 5m ago · 124 nodes`.
- **Refresh now** кнопка — сейчас `updateAt(index)`, целевой — `autoUpdater.maybeUpdateAll(manual, force:true)`.

---

## Acceptance criteria

- [x] Подписка с `lastUpdated=6h ago`, `interval=24h` не fetch'ится на триггере periodic.
- [x] Подписка с `lastUpdated=null` fetch'ится на appStart.
- [x] Две подписки во время прохода — между ними ≥ 8 сек (10 ± 2).
- [x] Одновременный клик по ⟳ и срабатывание триггера не запускают 2 параллельных HTTP (guard inProgress).
- [x] 5 фейлов подряд → следующий автоматический триггер skip'ается, manual force=true проходит.
- [x] Рестарт app с подпиской `status=inProgress` на диске → статус сбрасывается в `failed`, fetch возможен через 15 мин.
- [x] Rebuild config (⟳ на home) не триггерит HTTP.
- [x] VPN connected → через 2 мин автотриггер fetch.
- [x] Periodic через 1 час работает (таймер взводится в `AutoUpdater.start`).
- [x] Per-entry manual ⟳ размораживает подписку из session-cap (`resetFailCount`).

---

## Open decisions (закрыты)

1. **Exponential backoff?** — Нет. Fail-cap=5 уже режет runaway; дополнительная сложность не окупается.
2. **Persist fail-count?** — Нет для cap (осознанный сброс на рестарт), да для UI (`consecutiveFails` отдельное поле).
3. **Period** — раз в час. Компромисс между актуальностью и тишиной.
4. **Two-minute delay after VPN connected** — оставляем; без неё fetch через только что поднятый туннель ломается (DNS cold, BPF правила не разлиты).
5. **Manual routing через AutoUpdater** — да (pending wiring), но текущий прямой путь работает и не спамит благодаря inProgress guard.

---

## Риски / не-цели

- **Background fetch при убитом app** — вне скопа; Android WorkManager потянет другой уровень сложности (permissions, battery optimizations). Если нужно — отдельная спека.
- **Дубликаты URL в разных entries** — обслуживаются через `_inFlight` per-URL внутри одного прохода; между проходами persist'ит уникально через entry.id, fail-count per-URL.
- **Race: `_failCounts[url]++` и `_failCounts[url]=0` в параллельных проходах** — невозможно, `_running` flag сериализует.

---

## Файлы

```
lib/services/subscription/auto_updater.dart       # новый, ~170 LOC
lib/controllers/subscription_controller.dart      # +refreshEntry, init sweep, inProgress guard, bindAutoUpdater, updateAt→resetFailCount
lib/models/server_list.dart                       # +UpdateStatus, lastUpdateAttempt, lastUpdateStatus, consecutiveFails
lib/screens/subscriptions_screen.dart             # subtitle с 🔄/🕐/(N fails), _updateAll через maybeUpdateAll(manual,force)
lib/screens/subscription_detail_screen.dart       # блок "Subscription" в Settings tab
lib/screens/home_screen.dart                      # construct AutoUpdater, start() после init, pass to SubscriptionsScreen
lib/controllers/home_controller.dart              # optional autoUpdater param, onVpnConnected/onVpnStopped на transitions
```
