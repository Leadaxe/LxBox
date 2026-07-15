# §275 — POST /channels терял detour-ресинк: мутации каналов через ChannelMutations

| Поле | Значение |
|---|---|
| Статус | Готово, не device-verified (Debug API + внутренний инвариант; UI-пути не меняли поведение) |
| Связанные спеки | §248 (detour-каналы, «Зеркальный ресинк контроллера (ОБЯЗАТЕЛЕН)»), §202 (heal rules-ссылок), §238 (Debug API `/channels`), §125 (каналы) |
| Ядро | не затронуто |

## Проблема

Инвариант §248: storage-heal detour-ссылок обязан зеркалиться в in-memory
`_entries` контроллера (`syncDetourChannelRefsCleared`). Storage лечится сам, но
`_entries` живёт с `init()` — без сброса следующий `_persist()` (rename, toggle
члена, авто-refresh подписки) воскрешает вылеченную ссылку на диске, а
`generateConfig()` собирает конфиг с ней вопреки показанному юзеру уведомлению.

`_create` (POST `/channels`) звал `SettingsStorage.updateChannel`, когда body
несёт PATCH-поля, и получал `healed.detours > 0`, но ресинк не делал — в отличие
от `_update` (тридцатью строками ниже, в том же файле) и `_delete`. Найдено
адверсарным ревью §274.

**Достижимость подтверждена пробником** (не теоретическая ветка). Разбор
`_updateChannel` (`settings_storage/channels.dart:66-78`): detour-heal требует
`disabling` или `flagUnset`. Свежий канал — `enabled:true, isDetour:false`,
поэтому `flagUnset` невозможен, а вот `disabling` (`was.enabled && !next.enabled`)
достижим телом `{"enabled": false}`. Пробник на реальном storage:

```
POST /channels {"enabled": false}  →  healed = {rules: 0, detours: 1}
```

Сценарий из жизни: restore из backup оставил ссылку на `vpn-2`, самого канала
нет; re-create тега встречает stale-ссылку.

Баг тихий: storage корректен, тесты зелёные, расходится только in-memory-зеркало,
а стреляет через один-два несвязанных `_persist()` позже — дисциплина ревью его
структурно не ловит.

## Решение

### 1. Фикс

`_create` зеркалит heal, как `_update`/`_delete`.

### 2. Механизм (чтобы шестой call-site не повторил судьбу пятого)

Пропуск случился при идеальных условиях — рабочий образец строкой выше, тот же
файл, тот же автор; собственный комментарий `_create` даже предвидел сценарий
stale-ссылки после restore и всё равно пропускал ресинк. Значит проблема не в
невнимательности, а в том, что инвариант держался на памяти вызывающего в 6
местах при невидимом нарушении.

**`app/lib/services/channel_mutations.dart`** — единственная дверь к мутациям
каналов для кода приложения: heal и ресинк здесь одна операция, разделить их
вызывающий не может.

| Метод | Storage-половина | Ресинк |
|---|---|---|
| `ChannelMutations.add({label})` | `addChannel` | не нужен (новый тег ни на что не ссылается) |
| `ChannelMutations.update(ch, sub)` | `updateChannel` | `syncDetourChannelRefsCleared` при `detours > 0` |
| `ChannelMutations.delete(tag, sub)` | `deleteChannel` | то же |

**Закрытие старого пути** — голые `SettingsStorage.addChannel/updateChannel/
deleteChannel` помечены `@visibleForTesting` (прецеденты: `box_vpn_client.dart:51`,
`subscription_controller.dart:71`). Новый голый вызов из `lib/` — жёлтый в IDE и
красный в CI (analyze гоняется на весь проект, не только `lib/`). Это элемент со
сцепкой «забыл → сломалось сейчас», а не «сломается тихо потом».

Проверено пробником, а не на глаз: временная замена вызова на голый
`SettingsStorage.updateChannel` в `lib/` даёт
`invalid_use_of_visible_for_testing_member` на строке вызова. Тесты `@visibleForTesting`
не задевает — там голый storage законен (≈30 storage-тестов правок не потребовали).

### 3. Переведённые call-site'ы

| Файл | Было | Стало |
|---|---|---|
| `debug/handlers/channels.dart:_create` | `updateChannel`, **ресинка нет** (баг) | `ChannelMutations.update` |
| `debug/handlers/channels.dart:_update` | `updateChannel` + ручной `if` | `ChannelMutations.update` |
| `debug/handlers/channels.dart:_delete` | `deleteChannel` + ручной `if` | `ChannelMutations.delete` |
| `routing_screen.dart:_toggleChannel` | `updateChannel` + `_resyncHealedRefs` | `ChannelMutations.update` |
| `routing_screen.dart:_editChannel` (save/delete) | `updateChannel`/`deleteChannel` + `_resyncHealedRefs` | `ChannelMutations.update/delete` |
| `routing_screen.dart:_addChannel` | `addChannel` | `ChannelMutations.add` |
| `home/widgets/node_list.dart` | `updateChannel` + ручной `if` (единственный UI-путь мимо `_resyncHealedRefs`) | `ChannelMutations.update` |

`_resyncHealedRefs` в `routing_screen` сузился до своей настоящей задачи —
подтянуть буферы экрана после rules-heal (`route_final`/`_customRules`);
detour-половина уехала в сервис.

## Чего механизм не закрывает

Названо вслух, чтобы не создавать ложное чувство защиты:

- **`SettingsStorage.setChannels`** — сырой bulk-overwrite вообще мимо heal'а
  (не помечен: `routing_srs_cache.dart:90` и `_editChannel` зовут его штатно для
  persist'а списка, heal там не при чём).
- **`sub == null`** — ресинк молча пропускается. Это законно (без контроллера нет
  и `_entries`, которые расходятся), Debug API может отработать до готовности UI;
  покрыто тестом.
- **Третий род ссылки на канал**, буде появится, — против него работает только
  коммент-инвариант `server_list.dart:405-408`.

## Тесты

`app/test/services/debug/channels_handler_test.dart`, группа «§275 — detour-ресинк
контроллера» (5 тестов): настоящий `SubscriptionController` в `DebugRegistry.I.sub`,
проверяются `entries`, а не моки-счётчики.

| Тест | Что пиннит |
|---|---|
| POST heal при `enabled:false` зеркалится в entries | сам баг |
| POST: `_persist` после ресинка не воскрешает ссылку | последствие, ради которого инвариант существует |
| PATCH flag-unset зеркалится | регресс `_update` |
| DELETE зеркалится | регресс `_delete` |
| `sub == null` — heal storage без падения | nullable-контроллер |

**Мутационная проверка** (зелёный тест сам по себе ничего не доказывает): при
удалённом ресинке из `ChannelMutations._resync` краснеют 4 из 5 — с сообщением
«без ресинка следующий `_persist` воскресил бы vpn-2». Тесты ловят баг, а не
подогнаны под зелёный.

Итог: `flutter analyze` — No issues found; `flutter test` — 1872 passed.
