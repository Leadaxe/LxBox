# §290 — Automation (§047): пробелы вокруг SWITCH_NODE / ACTIVE_NODE_CHANGED

| Поле | Значение |
|---|---|
| Статус | П3 + инспекция F1/F3/F5/F4/F2/F6 РЕАЛИЗОВАНЫ (код+тесты+доки); П1/П2 — доки |
| Связанные спеки | §047 (Public Intent API — источник), §143 (interrupt-on-switch), §157 (drop require-permission) |
| Ядро | не затронуто |
| Источник | форум-репорт (Stendvik, тема LxBox, 2026-07) + инспекция Automation⟷Debug API |

## Контекст

Репорт с 4PDA (пост Stendvik): три вопроса по автоматизации через Tasker.
Разбор по коду показал, что два из трёх — не баги, а UX/доки-пробелы, а третий —
реальный кандидат в правку поведения. Собираю всё в одну таску.

Изучённые точки (пути от `app/`):
- эмиссия события — `lib/services/automation/event_emitter.dart:90-100`
  (`emitNodeChanged`), гейт категории **State** `_stateEnabled` там же (`:100`);
- native-мост экстр — `android/.../vpn/VpnPlugin.kt:88-106`
  (`sendAutomationBroadcast`);
- переключение — `lib/controllers/home_controller.dart:945-1003` (`switchNode`);
- входной роутер automation-интентов — `lib/services/automation/`
  `automation_dispatcher.dart:25-65` (`_dispatch` → `case 'switch-node'` →
  `handlers.actionSwitchNode`);
- обработчик команды — `lib/services/automation/handlers.dart:31-38`
  (`actionSwitchNode`) — общий и для Debug API `/action/switch-node`
  (`lib/services/debug/handlers/action.dart:233`);
- condition-плагин активной ноды — `android/.../automation/`
  `LocaleConditionReceiver.kt:57` (`active-node`, читает prefs `lxbox_automation`
  ключ `active_node`; пишется из `home_controller.dart:995`
  `BoxVpnClient.I.setAutomationActiveState`);
- документация — `docs/AUTOMATION.md` (таблица событий `:135-148`, рецепт
  request-response `:157-176`).

## Проблема 1 — «все переменные пустые» у ACTIVE_NODE_CHANGED (доки)

**Не баг кода.** Событие кладёт ровно 4 экстры: `old_tag`, `new_tag`, `group`,
`reason` (`event_emitter.dart:95-98`). Native прокидывает их корректно и пустые
не подставляет (`VpnPlugin.kt:93` `null -> {}`; при `null` экстра просто не
кладётся в интент). Юзер получил пусто по одной из трёх причин, все — про
доку/UX/настройку, не про код:

1. **Категория State выключена.** `emitNodeChanged` гейтится за `_stateEnabled`
   (`event_emitter.dart:100`), а все категории по умолчанию OFF (security-дефолт
   §047). Пока юзер не включит **State** в App Settings → Automation → Emit,
   событие вообще не уходит — Tasker ничего не ловит (не «пустые переменные», а
   «событие не пришло», но со стороны юзера выглядит одинаково). Проверять это
   надо **первым**.
2. Ждал переменную с другим именем (напр. `%active_node`) — такого ключа нет.
3. Tasker не подхватывает экстры из интента автоматически: их надо объявить
   вручную в `Event → System → Intent Received` (фильтр action
   `com.leadaxe.lxbox.event.ACTIVE_NODE_CHANGED` + имена переменных).

Рецепт в `AUTOMATION.md:157-176` показывает `Wait Event … (new_tag ~ …)`, но
**не объясняет**, что имена экстр надо прописать в Tasker руками, и не даёт
список ключей рядом с рецептом. Дополнительно: `old_tag` пуст на первом
переключении после старта (`prevNode` ещё null) — норма, но читается как «баг».

**Решение:** правка `docs/AUTOMATION.md`:
- добавить чеклист «событие не приходит» первым пунктом: **проверь, что категория
  State включена** в App Settings → Automation → Emit (иначе `ACTIVE_NODE_CHANGED`
  не эмитится вовсе);
- в раздел рецептов добавить явный шаг «объявить экстры в Intent Received» с
  точными именами (`old_tag`/`new_tag`/`group`/`reason`) и Tasker-синтаксисом
  `%new_tag`;
- пометить, что `old_tag` может быть пустым на первом switch после старта
  (`prevNode` ещё null → экстра не кладётся); `new_tag`/`group`/`reason` —
  всегда заполнены.

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
зовёт `switchNode`, который безусловно делает `selectOutbound`
(`home_controller.dart:953`) и — **только при включённом** interrupt-on-switch
(§143, гейт `getInterruptOnSwitch()` `home_controller.dart:959`) — **рвёт
активные соединения группы** (`closeConnection` в цикле, `:961-968`). Итог:
автоматизация, дёргающая одну и ту же ноду по таймеру, при включённом
interrupt-on-switch периодически обрывает коннекты на ровном месте. Событие
`ACTIVE_NODE_CHANGED` при этом всё равно эмитится с `old_tag == new_tag`
(`:992-993`), а native-кеш переписывается тем же значением (`:995`).

**Решение:** no-op guard — если запрошенный tag уже активен в текущей группе,
не делать re-select и не рвать соединения, но эмитить **лёгкое подтверждающее
событие** `NODE_ALREADY_ACTIVE` (категория State), чтобы ждущий Tasker получил
детерминированный ответ вместо timeout'а (см. request-response ниже).

Место: `switchNode` (`home_controller.dart:945-948`), ранний выход **до** входа
в `try`/`selectOutbound`, сразу после вычисления `prevNode`:

```dart
Future<void> switchNode(String nodeTag) async {
  final group = _state.selectedGroup;
  if (group == null || !_state.tunnelUp) return;
  final prevNode = _state.activeInGroup;
  if (prevNode == nodeTag) {
    // §290 — уже активна: не рвать conns / не делать re-select зря, но дать
    // ждущему Tasker'у подтверждение (иначе Wait Event уйдёт в timeout).
    AutomationEventEmitter.I.emitNodeAlreadyActive(nodeTag, group);
    return;
  }
  _emit(_state.copyWith(busy: true, highlightedNode: nodeTag));
  try {
    // ... selectOutbound / interrupt-on-switch / getGroups-pull / emit
  }
}
```

Guard стоит **перед** `_emit(busy:true)`, иначе на no-op мелькнёт busy-спиннер
и погаснет в `finally` без полезной работы. `highlightedNode` уже указывает на
активную ноду (пишется `_applyGroups`, `:929`), так что подсветка не съедет.

### Новое событие `NODE_ALREADY_ACTIVE`

Добавить в `AutomationEventEmitter` (`event_emitter.dart`, секция State, рядом с
`emitNodeChanged`):

```dart
void emitNodeAlreadyActive(String tag, String group) =>
    _emit('NODE_ALREADY_ACTIVE', {'tag': tag, 'group': group}, _stateEnabled);
```

- **Категория — State** (гейт `_stateEnabled`): семантически про активную ноду,
  как `ACTIVE_NODE_CHANGED`; отдельный toggle не заводим.
- **Экстры:** `tag`, `group` (без `old_tag`/`new_tag`/`reason` — сменой это не
  является, поэтому не мимикрируем под `ACTIVE_NODE_CHANGED`; отдельное имя даёт
  Tasker'у явно различить «сменилось» и «уже было»).
- **Throttle не нужен:** событие идёт только в ответ на явную команду
  SWITCH_NODE, спама быть не может (в отличие от `SUB_REFRESH_FAILED`).
- **UI-тап по активной ноде** тоже пройдёт через guard и эмитнет
  `NODE_ALREADY_ACTIVE`. Это безвредно (при выключенной категории State — no-op;
  при включённой — честный сигнал «нода не менялась»).

Открытые вопросы к guard'у:
- Ставить guard в `switchNode` (общий путь UI + automation) или только в
  `actionSwitchNode` (automation-only). Рекомендация — в `switchNode`: тап по
  уже активной ноде в UI тоже не должен рвать коннекты. Проверить, что UI не
  завязан на побочный re-select — `highlightedNode` уже равен активной ноде
  (`_applyGroups` `:929`), но убедиться, что pull-to-refresh и повторный тап по
  подсвеченной ноде в списке не рассчитывают на форс-`getGroups` внутри
  `switchNode` (если рассчитывают — им нужен отдельный путь refresh, не
  `switchNode`).

## Docs to update

- `docs/AUTOMATION.md`:
  - П1 — чеклист «событие не приходит» (первым — категория State) + объявление
    экстр в Intent Received + список ключей рядом с рецептом + `old_tag`-nuance;
  - таблица outgoing-событий (`:135-148`) — добавить строку
    `NODE_ALREADY_ACTIVE | tag, group | State | SWITCH_NODE на уже активную ноду
    (нода не менялась)`;
  - раздел «Symmetric request-response» (`:157-176`) — обновить рецепт: ждать
    `ACTIVE_NODE_CHANGED` **OR** `NODE_ALREADY_ACTIVE` OR `VPN_ERROR`, чтобы
    повторный SWITCH_NODE той же ноды не уходил в timeout;
  - П2 — плагин `active-node` как способ узнать текущую ноду.
- UI subtitle категории State (`automation_tab.dart:242`) — сейчас
  `ACTIVE_NODE_CHANGED · ACTIVE_GROUP_CHANGED`; дописать `· NODE_ALREADY_ACTIVE`.
- `CHANGELOG.md` — секция Unreleased: no-op guard на SWITCH_NODE + событие
  `NODE_ALREADY_ACTIVE` (П3).

## Tests

Guard живёт в `HomeController.switchNode`, а не в `actionSwitchNode`, поэтому
существующие `test/services/automation/handlers_test.dart` (проверяют
BadRequest/Conflict на уровне хендлера) его не покрывают. Нужен тест на
`switchNode` там, где мокается `HomeController` / CommandClient:
- `switchNode(activeTag)` при `activeInGroup == activeTag` → **не** зовёт
  `selectOutbound`, **не** зовёт `closeConnection`, **не** эмитит
  `ACTIVE_NODE_CHANGED`, но **эмитит** `NODE_ALREADY_ACTIVE` c `tag`/`group`
  (перехватить через `debugConfigureForTest(onSend:)`);
- `switchNode(otherTag)` → прежнее поведение не изменилось (регресс-гард).

Плюс в `test/services/automation/event_emitter_test.dart`:
- `emitNodeAlreadyActive` при `_stateEnabled == false` → no-op (ничего не
  отправлено); при `true` → отправлен `NODE_ALREADY_ACTIVE` с `tag`/`group`.

## Инспекция Automation ⟷ Debug API

Заодно проведена сквозная проверка, что обе поверхности (§047 Automation +
Debug API `/action/*`) стоят на одной базе `handlers.dart`. **Вердикт: база
честная** — 5 из 6 сквозных команд физически зовут те же функции, что Debug API
(`switch-node`/`set-group`/`rebuild-config`/`refresh-subs`/`reset-network`).
Дельта Automation⊂Debug обоснована (диагностика/скриншоты живут только по HTTP).
`START/STOP/TOGGLE` идут напрямую в `BoxVpnService` на native (быстро, без
Flutter-engine) — осознанное исключение, не обход.

Найденные и **исправленные** в этом проходе дефекты по краям базы:

### F1 — SWITCH_NODE при опущенном туннеле был полностью немой (bug)

`switchNode` делает ранний `return` при `!tunnelUp` (`home_controller.dart:962`),
но `actionSwitchNode` проверял только `selectedGroup == null` — не туннель. Итог:
группа выбрана + VPN опущен → precondition проходит → контроллер тихо выходит →
ни события, ни `VPN_ERROR`; мост логирует `→ ok`, Tasker виснет до timeout.
Соседи (`actionUrltestGroup`/`actionResetNetwork`) `tunnelUp` проверяют —
`switch-node` выбивался из паттерна.

**Фикс:** `actionSwitchNode` (`handlers.dart:31`) — `if (!home.state.tunnelUp)
throw Conflict('tunnel not connected')`, симметрично соседям. Провал стал видим.

### F3 — SET_GROUP на несуществующую группу слал ложное событие (bug)

`setSelectedGroup` эмитил `ACTIVE_GROUP_CHANGED` на любой непустой новый `group`
без проверки существования (`home_controller.dart:1071`), а `applyGroup` следом
молча выходил (`groupOf → null`, `:937`) и ноды не грузил. Наружу улетало
«группа сменилась», хотя не сменилось ничего. Тот же анти-паттерн «немой гейт»,
что §277/§278.

**Фикс:** `actionSetGroup` (`handlers.dart:40`) — `if (!home.state.groups
.contains(group)) throw NotFound(...)` до эмиссии. UI-путь (`home_controls.dart`,
dropdown всегда даёт валидную группу) не тронут.

### F2 — VPN_ERROR гейтится Lifecycle, а успех — State (UX, не код)

Успех switch идёт под категорией **State** (`ACTIVE_NODE_CHANGED`), а провал —
под **Lifecycle** (`emitVpnError`, `event_emitter.dart:77`). Юзер, включивший
только State ради подтверждений, при `SWITCH_NODE` на битый tag получает
`Conflict` → `emitVpnError` → **молча дропается** на выключенном Lifecycle-гейте.

**Решение — НЕ трогать контракт событий** (`VPN_ERROR` семантически цельный: оба
источника — обрыв туннеля `tunnel_error` + провал команды — это «что-то не так»,
оба lifecycle-уровня; расщеплять или выносить в отдельный канал — лишняя
сущность). Чиним UX там, где юзер спотыкается:
- UI-хинт под заголовком «Outbound events» (`automation_tab.dart`): для
  подтверждения команд включить **обе** категории — Lifecycle и State;
- ремарка в `AUTOMATION.md` (раздел request-response).

### F5 — Automation раскрывал `e.toString()` в открытый broadcast (privacy)

Для не-`DebugError` исключений `emitVpnError` получал сырой `e.toString()` и слал
его broadcast'ом всем приложениям (setPackage не выставлен). Произвольное
исключение из `generateConfig`/`saveParsedConfig` могло вынести путь файла, URL
подписки, фрагмент конфига. Debug API те же исключения прячет в generic
`InternalError`.

**Фикс:** маппинг вынесен в `automationErrorSignal(e)` (`automation_dispatcher
.dart`, `@visibleForTesting`): `DebugError` → его `code`/`message`; любое другое
→ `(error, 'internal error')`. Полный текст — только в AppLog.

### F4 — bool-парсер `force` расходился между путями (consistency)

Debug API `qBool` понимал `true`/`1`/`yes`; dispatcher `_bool` — только `'true'`.
Латентно (native шлёт настоящий Boolean), но контракт разъехался.

**Фикс:** `_bool` (`automation_dispatcher.dart`) выровнен под тот же набор.

### F6 — `PERMISSION_NEEDED` было мёртвым в основной таблице доки

`emitPermissionNeeded` определён, но 0 call-site в `lib/` — тот же статус, что
health-события, честно вынесенные в «Future». **Фикс (только дока):** перенесён
в блок «Зарезервированные» рядом с health в `AUTOMATION.md`.

### F7 — ядро request-response было без тестов

`_dispatch` (catchError→`VPN_ERROR`), `emitVpnError`, symmetric-response — 0
тестов. **Фикс:** `automation_dispatcher_test.dart` (маппинг `automationError
Signal`, включая generic-нормализацию F5) + `emitVpnError` gate/extras в
`event_emitter_test` + precondition-тесты F1/F3 в `switch_node_noop_guard_test`.

### Не тронуто (латентное / by-design, задокументировано)

- **F8** — automation-путь собирает `DebugContext` с заглушёнными `config`
  (`port:0/token:''`) и `appStartedAt=now()`. Сейчас безопасно (ни один из 6
  хендлеров их не читает), но добавишь команду, читающую их, — получит фальшь.
  Латентная ловушка, активного бага нет.
- **F9** — fire-and-forget доменные провалы (`selectOutbound` reject, timeout
  провайдера в refresh, сбой urltest) происходят **после** возврата хендлера →
  `catchError` их не видит → `VPN_ERROR` не летит. Для refresh есть отложенный
  `SUB_REFRESH_FAILED`; для остальных — тишина. By design.
### urltest-group дубль — УСТРАНЁН

Было единственное нарушение общей базы: Debug API `_urltest` (`action.dart:191`)
не проходил через shared `actionUrltestGroup`, а дублировал tunnel-check +
`runGroupUrltest` в своей group-ветке (у `_urltest` шире scope: `?tag`/`?group`/
`?all`/`?cancel`).

**Фикс:** group-ветка `_urltest` теперь делегирует в `automation.actionUrltest
Group(group, ctx)` — единственный источник правды для group-urltest, тексты
ошибок/precondition'ы не могут разъехаться. Прочие scope (`tag`/`all`/`cancel`)
остались Debug-only (automation их не экспонирует). Контракт ответа не изменился
(`{scope:'group', group}`). Покрыто новым `test/services/debug/
action_urltest_test.dart` (9 кейсов: scope-роутинг + делегация group → тот же
`Conflict`/`BadRequest`, что shared) — заодно закрыта дыра «Debug `/action` без
тестов».

## Приёмка

- [ ] П1: `AUTOMATION.md` содержит чеклист «событие не приходит» (первым — гейт
      категории State), явный шаг объявления экстр в Tasker + список ключей
      события + пометку про пустой `old_tag` на первом switch.
- [ ] П2: `AUTOMATION.md` описывает плагин-условие `active-node` как ответ на
      «узнать текущую ноду». (pull-команда — опционально, отдельной оценкой.)
- [x] П3: `switchNode` не делает re-select / не рвёт соединения / не эмитит
      `ACTIVE_NODE_CHANGED`, если tag уже активен; вместо этого эмитит
      `NODE_ALREADY_ACTIVE` (`tag`/`group`, категория State); guard стоит до
      `_emit(busy)`; UI-тап по активной ноде не регрессирует (подсветка на месте).
- [x] П3-док: `NODE_ALREADY_ACTIVE` в таблице событий `AUTOMATION.md`, рецепт
      request-response обновлён (Wait включает `NODE_ALREADY_ACTIVE`), subtitle
      State в UI дописан.
- [x] П3-тест: `switchNode(activeTag)` не зовёт `selectOutbound`/`closeConnection`,
      не эмитит `ACTIVE_NODE_CHANGED`, эмитит `NODE_ALREADY_ACTIVE`;
      `switchNode(otherTag)` — прежнее поведение; `emitNodeAlreadyActive`
      гейтится за State.
- [x] `flutter analyze` чистый; `flutter test` зелёный.
- [x] F1: `actionSwitchNode` бросает `Conflict` при `!tunnelUp` (тест:
      `switch_node_noop_guard_test` — Conflict + нет `ccSelectOutbound`).
- [x] F3: `actionSetGroup` бросает `NotFound` на группу вне `state.groups` без
      эмиссии `ACTIVE_GROUP_CHANGED`; валидная группа не бросает (тесты там же).
- [x] F2: UI-хинт «включить Lifecycle+State» под «Outbound events» + ремарка в
      `AUTOMATION.md`; контракт событий не тронут.
- [x] F5: `automationErrorSignal` прячет не-`DebugError` в generic message
      (тест: `automation_dispatcher_test` — путь файла не утекает).
- [x] F4: `_bool` в dispatcher = `qBool` (`true`/`1`/`yes`).
- [x] F6: `PERMISSION_NEEDED` перенесён в «Зарезервированные» в `AUTOMATION.md`;
      `VPN_ERROR.code` уточнён (`tunnel_error` добавлен).
- [x] F7: `emitVpnError` gate/extras + `automationErrorSignal` покрыты тестами.

Осталось: П1/П2 (доки в `AUTOMATION.md` — чеклист «событие не приходит» и
плагин `active-node`) не входили в этот проход, кроме П3-части таблицы/рецепта.
`urltest-group`-дубль (нарушение общей базы) — отдельной таской. F8/F9 —
задокументированы как известные. Device-verify (no-op guard + F1/F3 на реальном
Tasker) — pending.
