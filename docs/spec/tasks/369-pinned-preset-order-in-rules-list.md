# §369 — pinned-пресет выдавливается из шапки при добавлении из каталога

**Статус:** РЕАЛИЗОВАНО, тесты зелёные; DEVICE-PENDING (эмулятор воспроизводит, фикс не проверен на устройстве)
**Тип:** bug-fix, UI-слой (`routing_screen`). Билдер и `route.rules` НЕ затронуты.
**Зависит от:** §264 (locked/pinned пресет Traffic Processing, `ui.pinned`)

---

## 0. Симптом

На экране Routing → Rules пресет **Google push (FCM)** стоит выше **Traffic Processing**,
хотя последний закреплён `ui.pinned: 0`. У Traffic Processing при этом скрыта drag-ручка —
то есть часть pinned-логики отрабатывает, а позиция не держится.

Воспроизведено на эмуляторе (`emulator-5554`, 04.08.2026), storage-снимок через Debug API
`/state/rules`:

```
 0 preset | fcm-push            | enabled=True
 1 preset | traffic-processing  | enabled=True
 2 preset | block-ads           | enabled=True
```

## 1. Что НЕ сломано (важно для оценки серьёзности)

Собранный `route.rules` в том же снимке (`GET /config`) — корректен:

```
 0 action=sniff
 1 action=hijack-dns protocol=dns
 2 action=resolve
 3 action=reject rule_set=ads-all
 ...
```

`sniff` первый, инвариант §264 соблюдён. Причина: `build_config.dart:302` вызывает
`normalizePinnedPresets` на своём входе, поэтому порядок в конфиге чинится независимо от
того, что лежит в storage. **Баг чисто визуальный/storage-уровня** — трафик роутится верно.

## 2. Корень

`_computeInsertIndex` (`routing_screen.dart`) не знал про pinned-шапку:

```dart
if (outbound == kDirectOutboundTag) {
  var i = 0;                       // ← старт с нуля, поверх pinned
  while (i < _customRules.length &&
      _effectiveOutboundOf(_customRules[i]) == kOutboundReject) { i++; }
  return i;
}
```

`fcm-push` имеет `outbound: direct-out`. Reject-блок в списке пуст → цикл не делает ни одной
итерации → `i = 0` → правило садится **на позицию 0**, выше Traffic Processing.

Дальше срабатывал второй дефект — `_pinnedRuleCount()` считал префикс от начала списка и
останавливался на первом не-pinned правиле:

```dart
for (final rule in _customRules) {
  if (preset?.locked == true) { n++; } else { break; }   // ← break на fcm-push
}
```

После того как FCM встал первым, счётчик возвращает **0**, и защита в `_onReorderCustomRule`
(`if (oldIndex < pinnedCount) return` / clamp `newIndex`) отключается целиком. Один сбой
позиции снимал защиту всей шапки.

Третье, помельче: критерии разъехались — `normalizePinnedPresets` фильтрует по `isPinned`
(`pinned != null`), а экран по `locked`. Для `traffic-processing` оба true, так что сейчас это
не проявлялось, но это две независимые колонки `ui`, и расхождение уже дало один баг.

## 3. Фикс

| Место | Было | Стало |
|---|---|---|
| `_computeInsertIndex` | reject → `0`; direct → скан от `0` | оба стартуют с `_pinnedRuleCount()` |
| `_pinnedRuleCount` | префикс от начала, `break` на первом чужом | считает ВСЕ pinned, без `break` |
| `_pinnedRuleCount` | критерий `locked == true` | критерий `isPinned == true` (как в билдере) |

Порядок в уже испорченном storage чинит существующий вызов `normalizePinnedPresets` в
`_load()` (`routing_srs_cache.dart:74`) — он персистит результат, так что кривой storage
выправляется при следующем открытии экрана. Отдельная экранная нормализация не понадобилась.

## 4. Тесты

Новый `test/services/builder/normalize_pinned_presets_test.dart` (5 кейсов) — функция вообще
не была покрыта:

- pinned поднимается из середины в начало;
- относительный порядок не-pinned сохраняется;
- идемпотентность;
- несколько pinned сортируются по возрастанию `ui.pinned`;
- `varsValues` существующего pinned не затирается seed'ом.

`flutter test` — 2895 passed. `flutter analyze` (весь проект) — clean.

## 5. Хвост

- **DEVICE-PENDING:** на эмуляторе воспроизведён симптом и снят storage-снимок; сам фикс на
  устройстве не проверялся (нужна пересборка APK). Проверка: добавить `fcm-push` из каталога
  → он должен встать ПОД Traffic Processing; `/state/rules` — `traffic-processing` на позиции 0.
- Тестов на `_computeInsertIndex` нет (приватный метод State). Покрыт косвенно через
  нормализацию; при следующем касании экрана стоит вынести в чистую функцию.
