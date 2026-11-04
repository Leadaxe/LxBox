# §143 — Принудительный обрыв соединений при переключении ноды

> ⚠️ **Коллизия номера §143** (параллельные сессии). Это «§143-interrupt». Второй файл под тем же
> номером — [`143-warp-masquerade-id-ip-ib.md`](143-warp-masquerade-id-ip-ib.md) («§143-warp»).
> Не перенумеровано намеренно — см. [README §«Известные коллизии»](README.md#известные-коллизии-номеров).

**Статус:** Снята 2026-11-01 — глобальный тумблер удалён, см. [§9](#9-снятие-глобального-тумблера-2026-11-01) (до этого Implemented, §122-gap закрыт 2026-06-27)
**Дата:** 2026-06-17
**Тип:** task (bug-fix + новая настройка)
**Связь:** §087 (resetNetwork на смену интерфейса), §119 (vpn_mode), §123 (activeInGroup), §078 (control-outbounds), §122 (CommandClient-миграция), §174 (chains восстановлены)

---

## 0. §122-gap закрыт после §174 (2026-06-27)

При миграции на CommandClient (§122) функция **временно сломалась**: считалось,
что `CcConnection` не несёт `chains`, поэтому матчинг соединений на selector-группу
обрезали заглушкой `_connectionIdsInGroup(group) => const []` (interrupt-on-switch
opt-in, default OFF — мягкая деградация). **§174 восстановил `chains`** в ядре
(`Connection.chain()`-итератор, device-verified 26.06) → `CcConnection.chains`
реально приходит. Блокер снят, заглушка заменена рабочим фильтром.

**Фактическая реализация (CommandClient, заменяет Clash-вариант ниже из §5.2):**

```dart
// home_controller.dart — async: снапшот соединений из _cc.connections (replay-
// кэш стрима §122 → .first отдаёт текущее мгновенно; HomeState список не хранит,
// только агрегаты connectionsIn/Out). Закрываем только живые (!isClosed).
Future<List<String>> _connectionIdsInGroup(String group) async {
  final conns = await _cc.connections.first
      .timeout(const Duration(seconds: 1), onTimeout: () => const []);
  return conns
      .where((c) => !c.isClosed && c.chains.contains(group))
      .map((c) => c.id)
      .where((id) => id.isNotEmpty)
      .toList();
}
```

`group` = `_state.selectedGroup` (тот же selector-тег, что в `selectOutbound` и в
`chains`; urltest исключён из dropdown §078, на selector-теге префиксов нет —
`chains` вида `["L: 🇳🇱⚡Нидерланды","vpn-1"]`, матчим `vpn-1`). Вызов в `switchNode`:
`final ids = await _connectionIdsInGroup(group)` — остальной gate/loop/дедлайн
(§5.1) без изменений. Старый Clash-путь (`ClashApiClient.connectionIdsInChain`,
§5.2) — **неактуален** (HTTP-моста нет с §122).

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

---

## 9. Снятие глобального тумблера (2026-11-01)

### 9.1 Повод

Вопрос пользователя в Telegram (paratroop3r, 01.11.2026): в VPN Settings → System
и в редакторе Направления → Behavior есть галки с одним именем «Interrupt
connections on switch» — одно ли это, и как они взаимодействуют. Разбор показал,
что глобальный тумблер этой задачи после исправления ядра дублирует галку
Направления.

### 9.2 Диагноз §2 был неверен

§2 объяснял жалобу так: `interrupt_exist_connections` по замыслу sing-box рвёт
только inbound-плечо, а upstream-сокеты к серверу доживают сами. Это прочтение
документации, не поведение кода. Настоящая причина — дефект sing-box, живший с
появления interrupt (c320be75a, 2023-09-15, v1.10.0):

- `Selector.SelectOutbound` закрывает соединения из списка своей `interrupt.Group`;
- список пополнялся только в `Selector.DialContext` / `ListenPacket`;
- роутер отдаёт трафик селектору через `ConnectionHandler` → `Selector.NewConnection`,
  а тот передавал соединение дальше выбранному узлу, мимо собственного `DialContext`;
- итог: при смене узла список пуст, флаг `true` стоит в конфиге, но ничего не рвёт.

### 9.3 Хронология

| Дата | Где | Что |
|---|---|---|
| 2026-06-17 | LxBox [`1d75b78bb`](https://github.com/Leadaxe/LxBox/commit/1d75b78bb) | §143: глобальный тумблер, обрыв соединений группы из приложения после `selectOutbound` |
| 2026-06-27 | LxBox [`0dae5b780`](https://github.com/Leadaxe/LxBox/commit/0dae5b780) | §143 восстановлен после миграции на CommandClient (§122, §174) |
| 2026-08-13 | ядро [`bbbf186df`](https://github.com/Leadaxe/sing-box-lx/commit/bbbf186df) | SPEC 064 v1: найден корень §9.2, жалоба лаунчера и LxBox; проверено в поле на `lx.25-rc.7` |
| 2026-08-13 | ядро [`e3ebbbaf9`](https://github.com/Leadaxe/sing-box-lx/commit/e3ebbbaf9) | SPEC 064 v2: обёртка входящего соединения, покрывает вложенные группы |
| 2026-08-14 | LxBox 2.20.9 | пин ядра `lx.27-rc.1` — исправление у пользователей |
| 2026-09-08 | sing-box [`515a73e4e`](https://github.com/SagerNet/sing-box/commit/515a73e4e) | апстрим исправил то же самое (подход из [PR #4285](https://github.com/SagerNet/sing-box/pull/4285)) |
| 2026-09-14 | ядро [`08aecaf6c`](https://github.com/Leadaxe/sing-box-lx/commit/08aecaf6c) | SPEC 084: ABBA-дедлок вложенных селекторов после 064 v2 ([issue #20](https://github.com/Leadaxe/sing-box-lx/issues/20)); в LxBox 2.23.2 |
| позже | sing-box [`0ed951aa0`](https://github.com/SagerNet/sing-box/commit/0ed951aa0) | апстрим принял тот же фикс дедлока, наш патч снят синком SPEC 109 |

Спеки ядра: [064](https://github.com/Leadaxe/sing-box-lx/blob/lx/SPECS/TASKS/064-SELECTOR_INTERRUPT_DEAD_ON_INBOUND/SPEC.md),
[084](https://github.com/Leadaxe/sing-box-lx/blob/lx/SPECS/TASKS/084-INTERRUPT_GROUP_ABBA_DEADLOCK/SPEC.md).

### 9.4 Что покрывал тумблер после 2026-08-14

Ядро с SPEC 064 при `interrupt_exist_connections: true` закрывает обе стороны
соединения селектора при ЛЮБОЙ смене выбора: тап, Quick connect, автоматизация,
Debug API. Тумблер §143 срабатывал только на `HomeController.switchNode` и
закрывал соединения, чья `chains` содержит `selectedGroup`. Пересечение:

| Галка Направления | Тумблер §143 | Итог при ручной смене |
|---|---|---|
| вкл (дефолт шаблона) | любой | рвёт ядро, тумблер — дубль |
| выкл | вкл | рвёт приложение, галка Направления перекрыта |
| выкл | выкл | соединения доживают на старом узле |

Собственной работы у тумблера осталась только вторая строка — перекрыть снятую
галку Направления. Это путает (вопрос §9.1) и не даёт сделать одно Направление
мягким, пока тумблер включён.

### 9.5 Решение

Решение владельца 01.11.2026: глобальный тумблер удалить, обрыв соединений —
только галкой Направления (ядро).

- **Код.** Снять блок обрыва в `HomeController.switchNode` и `_connectionIdsInGroup`,
  тумблер на VPN Settings → System, `SettingsStorage.get/setInterruptOnSwitch`,
  Debug API `GET|PUT /settings/interrupt_on_switch` и его строки в `/help`.
- **Миграция.** Разовый шаг `SettingsStorage.migrateInterruptOnSwitchIfNeeded`
  в `main()` после посева Направлений и в `BackupService.applyImport` после
  restore. Признак — наличие ключа `interrupt_connections_on_switch`, отдельного
  флага нет. При `true` у всех Направлений, где галка снята,
  `interrupt_exist_connections` ставится в `true` (ручная смена рвёт, как
  раньше), конфиг помечается dirty. Ключ удаляется при любом значении.
- **Бэкап.** Ключ остаётся в allowlist импорта и в категории App settings как
  LEGACY: старый архив восстанавливается без строки «dropped unknown key», его
  значение уходит в Направления тем же шагом. Экспорт ключ больше не несёт —
  в живом хранении его нет.
- **Тесты.** `test/controllers/interrupt_on_switch_test.dart` удалён вместе с
  поведением; новый `test/services/interrupt_on_switch_migration_test.dart` —
  три случая миграции (true / false / ключа нет).
- **Доки.** USER_GUIDE (EN+RU): таблица «три тумблера» → два, ссылки из VPN
  Settings и раздела бэкапа; STORAGE.md (ключ — LEGACY, миграция);
  debug-api-reference; фичи 012 (P22) и 026; CHANGELOG Unreleased.

### 9.6 Риски

- Пользователь с тумблером ВКЛ и снятой галкой Направления получает галку
  включённой — поведение ручной смены сохраняется, но теперь ядро рвёт и при
  смене из автоматизации/API. Это и есть заявленное поведение галки.
- Вторая версия SPEC 064 и фикс 084 отдельно на устройстве не гонялись (064 v1
  проверена в поле 13.08). Тумблер не страховал от их дефекта: ядро обрывает
  до того, как приложение успело бы что-то закрыть.

### 9.7 Проверка

- CI по коммиту.
- Эмулятор, сценарий: галка Направления вкл, долгое соединение (загрузка),
  смена узла на главном экране → соединение закрыто в Connections. Не гонялся
  при снятии (на устройстве не проверено).

