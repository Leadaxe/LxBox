# §143 — Принудительный обрыв соединений при переключении ноды

**Статус:** Implemented
**Дата:** 2026-06-17
**Тип:** task (bug-fix + новая настройка)
**Связь:** §087 (resetNetwork на смену интерфейса), §119 (vpn_mode), §123 (activeInGroup), §078 (control-outbounds)

---

## 1. Проблема (жалоба)

> «В подписке перестановка галок (и появление надписи *active*) в нодах не означает,
> что она включилась — какое-то время работает предыдущее подключение (возможно,
> до пере-остановки).»

При переключении ноды UI **сразу** показывает новую ноду как `active`, но
фактический трафик ещё какое-то время идёт через **предыдущую** ноду.

## 2. Корневая причина (НЕ баг в нашем коде)

Это штатное поведение sing-box, а не дефект моста/Kotlin.

Цепочка переключения сейчас:

```
UI tap → HomeController.switchNode(nodeTag)         home_controller.dart:556
       → clash.selectInGroup(group, nodeTag)        clash_api_client.dart:85
              → PUT /proxies/{group}  {"name": nodeTag}
       → reloadProxies()   // только перечитать состояние, ядро НЕ перезапускается
```

`selectInGroup` делает ровно один значимый вызов — `PUT /proxies`. Дальше
поведение полностью на стороне ядра.

В шаблоне у всех селекторов **уже** стоит `interrupt_exist_connections: true`:

- `wizard_template.json:166` — urltest `@auto_proxy_tag`
- `wizard_template.json:176` — `vpn-1`
- `wizard_template.json:188` — `vpn-2`
- `wizard_template.json:199` — `vpn-3`

Но по доке sing-box (`outbound/selector/`):

> *"Interrupt existing connections when the selected outbound has changed.
> Only **inbound** connections are affected by this setting, internal connections
> will always be interrupted."*

То есть флаг рвёт только **inbound**-плечо (TUN→ядро). Уже установленные
**upstream-сессии к старому серверу** (TCP-сокеты наружу, keep-alive HTTP/2,
мультиплекс vmess/vless, активные загрузки) ядро по дизайну **не трогает** — они
доживают сами. Это и есть «работает предыдущее подключение».

**Просто добавить флаг нельзя — он уже есть.** Нужен принудительный обрыв
upstream-соединений после переключения.

## 3. Возможности ядра (проверено по исходнику)

`experimental/clashapi/connections.go` (upstream SagerNet/sing-box):

```go
r.Get("/", getConnections(...))
r.Delete("/", closeAllConnections(network, trafficManager))   // DELETE /connections
r.Delete("/{id}", closeConnection(trafficManager))            // DELETE /connections/{id}
```

Ключевые факты:

1. **`DELETE /connections` (close-all) функционально РАВЕН нашему resetNetwork:**
   ```go
   func closeAllConnections(...) {
       trafficManager.CloseAllConnections()
       network.ResetNetwork()       // тот же ResetNetwork, что зовёт BoxService.kt:259
   }
   ```
   Рвёт ВСЁ + flush DNS/rebind. Гранулярности не даёт.

2. **`GET /connections` отдаёт по каждому соединению поле `"chains"`** (`c.Chain`) —
   массив тегов outbound-цепочки, **включая тег группы-селектора** (`vpn-1`/…) и
   тег конкретной ноды. Это позволяет фильтровать соединения по группе.
   Также есть `"id"` (UUID) для `DELETE /connections/{id}`.

   **Проверено на устройстве (2026-06-17, CPH2411, dev.16):** реальный ответ —
   ```json
   {"id":"c7c420a4-...","chains":["L: 🇳🇱⚡Нидерланды","vpn-1"],
    "metadata":{"type":"tun/tun-in",...},"rule":"final"}
   ```
   `chains` идёт **от ноды к группе**: `[<node-tag>, <group-tag>]`. Тег группы
   (`vpn-1`) присутствует у 100% соединений (3/3 в тесте). Фильтр по
   `_state.selectedGroup` валиден. (NB: ICMP-пинги в `/connections` не попадают —
   только TCP/UDP-сессии через ядро.)

## 4. Решение

**Точечный обрыв** соединений переключаемой группы через `DELETE /connections/{id}`,
под управлением **новой настройки-тугла**.

### 4.1 Поведение

После `selectInGroup`, если тугл включён:
1. `GET /connections`
2. отфильтровать соединения, чей `chains` содержит тег переключаемой группы
   (`_state.selectedGroup`)
3. для каждого → `DELETE /connections/{id}`

Старые upstream-сессии этой группы рвутся немедленно; клиенты переустанавливают их
уже через новую ноду. Трафик других групп и DNS-кэш **не трогаются**.

### 4.2 Тугл

- **Название (UI, английский):** `Interrupt connections on switch`
- **Подпись:** `Drop active connections when you switch nodes, so traffic moves
  to the new node immediately`
- **Default:** `false` (выключен — текущее поведение сохраняется для existing
  юзеров; обрыв активных загрузок — opt-in).

## 5. Изменения по файлам

### 5.1 Storage — новый топ-левел bool

Тугл **НЕ config-significant**: не идёт в sing-box config, не требует Restart VPN,
не вызывает `markConfigDirty()`/`markConfigChangedNeedRestart()`. Это чистое
поведение Dart-клиента при `switchNode`. → обычный топ-левел ключ в
`lxbox_settings.json`, по образцу `route_final` (`settings_storage/io.dart:14`).

**`app/lib/services/settings_storage/io.dart`** (или подходящий part):
```dart
Future<bool> _getInterruptOnSwitch() async {
  final data = await _load();
  return data['interrupt_connections_on_switch'] == true;   // default false
}

Future<void> _setInterruptOnSwitch(bool v) async {
  final data = await _load();
  data['interrupt_connections_on_switch'] = v;
  SettingsStorage._cache = data;
  await _save();
}
```
+ публичные обёртки в `SettingsStorage` по существующему паттерну.

→ задокументировать ключ в `docs/STORAGE.md`.

### 5.2 ClashApiClient — метод вернуть `[{id, chains}]`

Примитивы DELETE **уже есть**:
- `closeConnection(String id)` — `clash_api_client.dart:163`
- `closeAllConnections()` — `clash_api_client.dart:172`
- `fetchConnections()` (raw JSON) — `clash_api_client.dart:155`

Не хватает доступа к `id`+`chains`. Добавить статический парсер либо метод,
возвращающий список `(id, chains)`:
```dart
/// id'ы соединений, чей chains содержит [groupTag].
static List<String> connectionIdsInChain(
    Map<String, dynamic> connectionsJson, String groupTag) {
  final conns = connectionsJson['connections'];
  if (conns is! List) return const [];
  final out = <String>[];
  for (final c in conns) {
    if (c is! Map<String, dynamic>) continue;
    final chains = c['chains'];
    final id = c['id']?.toString();
    if (id == null || id.isEmpty) continue;
    if (chains is List && chains.map((e) => e.toString()).contains(groupTag)) {
      out.add(id);
    }
  }
  return out;
}
```

### 5.3 HomeController.switchNode — вызвать обрыв

**`app/lib/controllers/home_controller.dart:556`**:
```dart
Future<void> switchNode(String nodeTag) async {
  final group = _state.selectedGroup;
  final clash = _clash;
  if (group == null || clash == null) return;
  _emit(_state.copyWith(busy: true, highlightedNode: nodeTag));
  try {
    await clash.selectInGroup(group, nodeTag);
    if (await SettingsStorage.getInterruptOnSwitch()) {
      final conns = await clash.fetchConnections();
      final ids = ClashApiClient.connectionIdsInChain(conns, group);
      for (final id in ids) {
        try { await clash.closeConnection(id); } catch (_) {/* best-effort */}
      }
      _addDebug(DebugSource.app, 'Interrupted ${ids.length} conns in $group');
    }
    await reloadProxies();
    _addDebug(DebugSource.app, 'Node selected: $nodeTag');
  } catch (e) {
    _emit(_state.copyWith(lastError: 'Switch failed: ${formatUserError(e)}'));
    _addDebug(DebugSource.app, 'Node switch error: $e');
  } finally {
    _emit(_state.copyWith(busy: false));
  }
}
```

### 5.4 UI — тугл в VPN Settings → System

**`app/lib/screens/settings_screen.dart`** — добавить `SwitchListTile` в System-таб
рядом с «Allow VPN bypass» / «Keep VPN on exit» (`:190`, `:225`).

⚠️ **НЕ копировать паттерн `markConfigChangedNeedRestart()`** от соседних туглов:
они native/config-significant (§084 M14), а этот — нет. Загрузка в `_load`
(`:91`), отдельное поле состояния `bool _interruptOnSwitch`, сохранение через
`SettingsStorage.setInterruptOnSwitch(v)` без баннера Restart.

## 6. Edge-cases

- **Тугл выключен (default):** поведение не меняется — только `selectInGroup`.
- **`/connections` пуст / соединений группы нет:** `ids` пустой, цикл no-op.
- **`closeConnection` падает (соединение уже закрылось):** ловим per-id, best-effort.
- **`chains` отсутствует/не список:** соединение пропускается (не матчим).
- **urltest-группа (`@auto_proxy_tag`):** `selectedGroup` всегда selector-группа
  (§078 dropdown — `selectorGroupTags`, urltest исключён), её тег и матчим в chains.
- **Несколько групп:** рвём только переключаемую (`selectedGroup`), остальной
  трафик не трогаем — в отличие от close-all/resetNetwork.
- **Зависший loopback clash-inbound:** серия из N×`closeConnection` с 10s-таймаутом
  каждый теоретически держала бы `busy=true` слишком долго (кнопки Activate
  заблокированы). → весь interrupt-блок обёрнут общим дедлайном `5s`
  (`.timeout(..., onTimeout: () {})`); по нормальному loopback DELETE'ы sub-ms.
  (Найдено адверсариальным ревью §143, severity nit — упрочнено превентивно.)

## 7. Тесты

- `test/services/clash_api_client_test.dart` — `connectionIdsInChain`:
  матч по группе, пустой/битый JSON, отсутствие `chains`, отсутствие `id`.
- `test/controllers/` (если есть для home_controller) — `switchNode` с туглом
  on/off: проверить число `closeConnection` вызовов через mock-клиент.

## 8. Решения (согласовано с юзером)

- Вариант обрыва: **точечный DELETE /{id} по chains** (не close-all/resetNetwork),
  чтобы не рвать чужой трафик и DNS-кэш.
- Управляется **туглом** (английское название), **default OFF**.
