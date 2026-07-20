# §290 — Automation (§047): пробелы вокруг SWITCH_NODE / ACTIVE_NODE_CHANGED

| Поле | Значение |
|---|---|
| Статус | ОТКРЫТА |
| Связанные спеки | §047 (Public Intent API — источник), §143 (interrupt-on-switch), §157 (drop require-permission) |
| Ядро | не затронуто |
| Источник | форум-репорт (Stendvik, тема LxBox, 2026-07) |

## Контекст

Репорт с 4PDA (пост Stendvik): три вопроса по автоматизации через Tasker.
Разбор по коду показал, что два из трёх — не баги, а UX/доки-пробелы, а третий —
реальный кандидат в правку поведения. Собираю всё в одну таску.

Изучённые точки:
- эмиссия события — `event_emitter.dart:90-100` (`emitNodeChanged`);
- native-мост экстр — `VpnPlugin.kt:88-104` (`sendAutomationBroadcast`);
- переключение — `home_controller.dart:945-1003` (`switchNode`);
- обработчик команды — `handlers.dart:31-38` (`actionSwitchNode`);
- condition-плагин активной ноды — `LocaleConditionReceiver.kt:57`
  (`active-node`, кеш пишется `home_controller.dart:995`
  `setAutomationActiveState`);
- документация — `docs/AUTOMATION.md:130-162`.

## Проблема 1 — «все переменные пустые» у ACTIVE_NODE_CHANGED (доки)

**Не баг кода.** Событие кладёт ровно 4 экстры: `old_tag`, `new_tag`, `group`,
`reason` (`event_emitter.dart:95-98`). Native прокидывает их корректно и пустые
не подставляет (`VpnPlugin.kt:93` `null -> {}`). Юзер получил пусто по двум
причинам, обе — про доку/UX, не про код:

1. Ждал переменную с другим именем (напр. `%active_node`) — такого ключа нет.
2. Tasker не подхватывает экстры из интента автоматически: их надо объявить
   вручную в `Event → System → Intent Received` (фильтр action
   `com.leadaxe.lxbox.event.ACTIVE_NODE_CHANGED` + имена переменных).

Рецепт в `AUTOMATION.md:155-162` показывает `Wait Event … (new_tag ~ …)`, но
**не объясняет**, что имена экстр надо прописать в Tasker руками, и не даёт
список ключей рядом с рецептом. Дополнительно: `old_tag` пуст на первом
переключении после старта (`prevNode` ещё null) — норма, но читается как «баг».

**Решение:** правка `docs/AUTOMATION.md`:
- в раздел рецептов добавить явный шаг «объявить экстры в Intent Received» с
  точными именами (`old_tag`/`new_tag`/`group`/`reason`) и Tasker-синтаксисом
  `%new_tag`;
- пометить, что `old_tag` может быть пустым на первом switch (`new_tag` — всегда
  заполнен).

## Проблема 2 — нет простого pull активной ноды в переменную

Узнать текущую активную ноду **можно** — через Locale/Tasker condition-плагин
`active-node` (`LocaleConditionReceiver.kt:57`), он читает кеш
`setAutomationActiveState`. Но «чистого» pull (broadcast-запрос → ответ в
`%переменную` без плагина-условия) нет: событийная модель есть, condition есть,
одноразового «спросил-получил» нет.

**Решение (обсуждаемо, не обязательное для этой таски):**
- минимум — задокументировать плагин `active-node` в `AUTOMATION.md` как ответ
  на «как узнать текущую ноду» (сейчас в доке слабо виден);
- опционально — команда pull-типа (напр. `QUERY_STATE` / broadcast-ответное
  событие), возвращающая активную ноду/группу в экстры одним запросом. Оценить
  отдельно; не блокирует П1/П3.

## Проблема 3 — SWITCH_NODE на уже активную ноду рвёт соединения (код)

`actionSwitchNode` не сверяет tag с текущим (`handlers.dart:31-37`) и всегда
зовёт `switchNode`, который безусловно делает `selectOutbound` и — при включённом
interrupt-on-switch (§143) — **рвёт активные соединения группы**
(`home_controller.dart:959-974`). Итог: автоматизация, дёргающая одну и ту же
ноду по таймеру, периодически обрывает коннекты на ровном месте. Событие
`ACTIVE_NODE_CHANGED` при этом всё равно эмитится с `old_tag == new_tag`.

**Решение:** no-op guard — если запрошенный tag уже активен в текущей группе,
не делать re-select и не рвать соединения.

Место: `switchNode` (`home_controller.dart:945`), ранний выход перед
`selectOutbound`:

```dart
Future<void> switchNode(String nodeTag) async {
  final group = _state.selectedGroup;
  if (group == null || !_state.tunnelUp) return;
  final prevNode = _state.activeInGroup;
  if (prevNode == nodeTag) return; // §290 — уже активна, не рвать conns зря
  ...
}
```

Открытые вопросы к guard'у:
- **Событие при no-op.** Сейчас на «ту же ноду» эмитится `ACTIVE_NODE_CHANGED`
  (old==new). После guard'а — не эмитится вовсе. Это правильнее (ничего не
  сменилось), но Tasker-сценарии с `Wait Event … OR VPN_ERROR` (timeout) больше
  не получат подтверждения на no-op → уйдут в timeout-ветку. Рекомендация:
  guard молча выходит (событие «сменилось» врать не должно); задокументировать,
  что на no-op подтверждения нет — ждать его не надо. Альтернатива —
  эмитить облегчённое подтверждение, но это усложняет контракт; **по умолчанию
  берём молчаливый выход.**
- Ставить guard в `switchNode` (общий путь UI + automation) или только в
  `actionSwitchNode` (automation-only). Рекомендация — в `switchNode`: тап по
  уже активной ноде в UI тоже не должен рвать коннекты. Проверить, что UI не
  завязан на побочный re-select (подсветка/`highlightedNode`).

## Docs to update

- `docs/AUTOMATION.md` — П1 (объявление экстр + список ключей + `old_tag`-nuance),
  П2 (плагин `active-node` как способ узнать текущую ноду), П3 (поведение
  SWITCH_NODE на активную ноду: no-op, подтверждения нет).
- `CHANGELOG.md` — секция Unreleased: no-op guard на SWITCH_NODE (П3), если
  реализуется.

## Приёмка

- [ ] П1: `AUTOMATION.md` содержит явный шаг объявления экстр в Tasker + список
      ключей события + пометку про пустой `old_tag` на первом switch.
- [ ] П2: `AUTOMATION.md` описывает плагин-условие `active-node` как ответ на
      «узнать текущую ноду». (pull-команда — опционально, отдельной оценкой.)
- [ ] П3: `switchNode` не делает re-select / не рвёт соединения, если tag уже
      активен; поведение задокументировано; UI-тап по активной ноде не
      регрессирует (подсветка на месте).
