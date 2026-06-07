# 083 — Per-channel match-filter memory (in-session)

| Поле | Значение |
|------|----------|
| Статус | Released в v1.9.1 (adversarial review: 0 blocker/real, 3 minor benign) |
| Дата | 2026-06-08 |
| Тип | feature (UX) |
| Зависимости | §048 (home node filters), §078 (control-tag / displayList). |
| Связанные | `home_screen.dart` (filter state fields, `_onControllerChange`), `home/channel_filters.dart` (NEW snapshot class). |

## Триггер

Юзер: «когда я фильтры настраиваю — между разными каналами у меня же
разные настройки, вот они сохраняются по каналам?». Сейчас match-фильтры
(`_enabledProtocols`, `_enabledSubscriptions`, regex, ping) — **одни
глобальные** поля экрана. Переключение канала (dropdown) их не трогает →
к нодам нового канала применяется тот же фильтр что настроен для старого.

## Цель

Запоминать **match-фильтры отдельно для каждого канала** (selector group),
в памяти (per-session, без записи на диск). Переключил канал → его фильтры
восстанавливаются; вернулся обратно → снова его набор.

Scope (согласовано с юзером):
- **Per-channel**: regex (pattern + enabled + invert), protocols,
  subscriptions, ping (value + enabled).
- **Остаются глобальными**: `_showDetourNodes`, `_showNonMatching` — это
  про *отображение*, не про поиск.
- **Ключ** = имя канала (`state.selectedGroup`). Переименование канала →
  фильтр сбросится (acceptable, in-memory).
- **Без персиста** на диск (юзер явно не хочет).

## Не в скопе

- Запись фильтров на диск / восстановление между запусками app.
- Per-channel sort options (§070) / manual order (§071) — отдельный вопрос.
- Миграция / backup.

---

## Текущее состояние

Match-фильтры — поля `_HomeScreenState`:

| Поле | Тип | Что |
|---|---|---|
| `_regexController.text` | String | regex pattern |
| `_regexCompiled` | RegExp? | скомпилированный (null = off/invalid) |
| `_regexFilterEnabled` | bool | checkbox on/off |
| `_regexInvert` | bool | NOT-toggle |
| `_regexValid` | bool | derived (для UI hint) |
| `_enabledProtocols` | Set\<String\> | protocol chips |
| `_enabledSubscriptions` | Set\<String\> | subscription chips |
| `_pingController.text` | String | ping value |
| `_maxPingMs` | int? | parsed |
| `_pingFilterEnabled` | bool | checkbox |

Глобальные (не per-channel): `_showDetourNodes`, `_showNonMatching`.

Канал (`state.selectedGroup`) меняется из нескольких мест:
- dropdown `onChanged` → `setSelectedGroup` + `applyGroup`
- `home_controller` initial при connect (resolve route_final / первая группа)
- любой `applyGroup`

→ детектить смену надёжнее всего в **одной точке**: listener
`_onControllerChange` (вызывается на каждый `notifyListeners`, уже держит
`_prevTunnel`/`_prevError` transition-detection).

---

## Целевое состояние

### Snapshot class — `home/channel_filters.dart` (NEW, pure, тестируемый)

```dart
/// §083 — immutable снимок match-фильтров одного канала.
/// Pure data — capture/restore в home_screen, тестируется отдельно.
class ChannelFilters {
  const ChannelFilters({
    this.regexPattern = '',
    this.regexEnabled = false,
    this.regexInvert = false,
    this.protocols = const <String>{},
    this.subscriptions = const <String>{},
    this.pingText = '',
    this.pingEnabled = false,
  });

  final String regexPattern;
  final bool regexEnabled;
  final bool regexInvert;
  final Set<String> protocols;
  final Set<String> subscriptions;
  final String pingText;
  final bool pingEnabled;

  static const empty = ChannelFilters();

  bool get isEmpty =>
      regexPattern.isEmpty && !regexEnabled && !regexInvert &&
      protocols.isEmpty && subscriptions.isEmpty &&
      pingText.isEmpty && !pingEnabled;
}
```

### home_screen — Map + capture/restore

```dart
final Map<String, ChannelFilters> _filtersByChannel = {};
String? _activeFilterChannel;   // канал для которого сейчас загружены поля

ChannelFilters _captureFilters() => ChannelFilters(
  regexPattern: _regexController.text,
  regexEnabled: _regexFilterEnabled,
  regexInvert: _regexInvert,
  protocols: Set.of(_enabledProtocols),
  subscriptions: Set.of(_enabledSubscriptions),
  pingText: _pingController.text,
  pingEnabled: _pingFilterEnabled,
);

void _restoreFilters(ChannelFilters f) {
  // отменить pending debounce — иначе старый ввод применится к новому каналу
  _regexDebounceTimer?.cancel();
  _pingDebounceTimer?.cancel();
  // regex
  _regexController.text = f.regexPattern;
  if (f.regexPattern.isEmpty) {
    _regexCompiled = null;
    _regexValid = true;
  } else {
    try {
      _regexCompiled = RegExp(f.regexPattern, caseSensitive: false);
      _regexValid = true;
    } catch (_) {
      _regexCompiled = null;
      _regexValid = false;
    }
  }
  _regexFilterEnabled = f.regexEnabled;
  _regexInvert = f.regexInvert;
  // protocols / subscriptions (копии — Set'ы mutable)
  _enabledProtocols..clear()..addAll(f.protocols);
  _enabledSubscriptions..clear()..addAll(f.subscriptions);
  // ping
  _pingController.text = f.pingText;
  final n = int.tryParse(f.pingText);
  _maxPingMs = (n != null && n > 0) ? n : null;
  _pingFilterEnabled = f.pingEnabled;
}
```

### Детект смены канала — в `_onControllerChange`

```dart
void _onControllerChange() {
  final state = _controller.state;
  // ... existing tunnel/error transition detection ...

  // §083 — per-channel filter memory. Канал сменился → save старый,
  // restore новый. Покрывает ВСЕ пути (dropdown, connect-time, applyGroup).
  final ch = state.selectedGroup;
  if (ch != _activeFilterChannel) {
    if (_activeFilterChannel != null) {
      _filtersByChannel[_activeFilterChannel!] = _captureFilters();
    }
    if (ch != null) {
      _restoreFilters(_filtersByChannel[ch] ?? ChannelFilters.empty);
      _activeFilterChannel = ch;
      setState(() {});   // UI отражает восстановленные фильтры
    } else {
      _activeFilterChannel = null;
    }
  }

  _prevTunnel = now;
  _prevError = nowError;
}
```

`_onControllerChange` дёргается часто (heartbeat / ping), но
`ch != _activeFilterChannel` — дешёвый guard, `setState` только при
реальной смене канала.

---

## Edge cases

| Сценарий | Поведение |
|---|---|
| Первый запуск, `_activeFilterChannel == null` | restore `empty` для первого канала, set active. Фильтры чистые. |
| Канал стал `null` (нет групп / disconnect) | save current, `_activeFilterChannel = null`. При возврате канала — restore из map (если был). |
| Pending debounce при смене канала | `_restoreFilters` отменяет `_regexDebounceTimer`/`_pingDebounceTimer` — старый ввод не протечёт в новый канал. |
| Канал удалён из подписок | его entry в `_filtersByChannel` остаётся (orphan, безвреден, in-memory). |
| Invalid regex сохранён | restore перекомпилирует; invalid → `_regexCompiled=null`, `_regexValid=false` (как при вводе). |
| Subscription chip канала A: sub-X нет в нодах B | chip pool **глобальный** — `subOptions` строится из `_subController.entries` (`e.enabled && nodes.isNotEmpty`), не из current pool. Поэтому chip sub-X виден и в B (и будет selected если restore вернул его в `_enabledSubscriptions`). Не баг — toggle остаётся доступен; фильтр в B просто матчит 0 нод. (Review §083 finding #3.) Chip исчезает только если sub-X глобально disabled / пустой. |

---

## Файлы

- `app/lib/screens/home/channel_filters.dart` NEW — immutable snapshot class.
- `app/lib/screens/home_screen.dart` — `_filtersByChannel` map +
  `_captureFilters`/`_restoreFilters` + детект в `_onControllerChange`.
- `app/test/screens/home/channel_filters_test.dart` NEW — round-trip,
  empty, isEmpty, Set-копии независимы.
- `docs/spec/tasks/083-per-channel-filter-memory.md` (этот файл).
- `CHANGELOG.md` — entry под `### Added` (v1.9.1).

## Acceptance criteria

- [x] Настроил фильтр в канале A → переключил на B → B чистый (или свой набор).
- [x] Вернулся в A → фильтры A восстановлены (regex текст, chips, ping).
- [x] show-detour / show-dimmed **не** меняются при смене канала (глобальные).
- [x] Pending debounce не протекает между каналами (`_restoreFilters` cancel).
- [x] Invalid regex round-trip'ит корректно (restore → invalid hint).
- [x] Unit tests `channel_filters_test.dart`: 12 тестов (round-trip, isEmpty, Set).
- [x] `flutter analyze` clean, full suite зелёный (742/742).
- [ ] Manual on-device: A→B→A round-trip фильтров (после install).
