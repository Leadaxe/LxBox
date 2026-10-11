# §625 — Интент `URLTEST_ALL`: форс-URLTest всех Направлений одной командой

| Поле | Значение |
|------|----------|
| Тип | Доработка фичи [014-AUTOMATION](../features/014-AUTOMATION/FEATURE.ru.md) (функции [command-intake](../features/014-AUTOMATION/FUNCTIONS/command-intake.ru.md), [automation-plugin](../features/014-AUTOMATION/FUNCTIONS/automation-plugin.ru.md)); опирается на [009-NODE_HEALTH/urltest-group](../features/009-NODE_HEALTH/FUNCTIONS/urltest-group.ru.md) |
| Статус | Спека, 2026-10-11 |
| Дата | 2026-10-11 |
| Связанные | §047 (публичный Intent API), §308 (групповой URLTest ядра с переселектом), §290 (общий обработчик Automation/Debug API), §322 (auto-двойники `vpn-N-auto`) |

## Проблема

Пользователь (Telegram, 11.10.2026) держит в MacroDroid макрос «встряхнуть
телефон → отправить интент в LxBox» и хочет этим жестом перепроверить **все**
Направления разом, когда сеть «подтухла».

Сейчас в Intent API есть только `com.leadaxe.lxbox.URLTEST_GROUP` с
обязательным extra `group`. Один интент = одна группа. Чтобы перепроверить все
Направления, нужно по действию на каждую группу и знание их тегов
(`vpn-1-auto`, `vpn-2-auto`, …), которые меняются при добавлении Направлений.

## Решение

Новое действие **`com.leadaxe.lxbox.URLTEST_ALL`** без extras и симметричная
ему команда `urltest-all` во всех трёх каналах автоматизации (§290: один
обработчик, три входа).

### Семантика

- Для каждой urltest-группы текущего состояния ядра (`HomeState.urltestGroups`,
  то есть `ccGroups` типа `urltest`) вызвать существующий групповой URLTest
  ядра `runGroupUrltest(tag)` — тот же путь, что `URLTEST_GROUP`, §308: ядро
  тестирует всех членов группы её конфиг-URL и переселектит на живой узел.
- Группы обходятся **последовательно**, один `ccUrlTestGroup` за другим,
  ожидая возврата RPC (сам RPC возвращается сразу после постановки задачи в
  ядре, замер идёт внутри ядра параллельно). Отдельного ограничителя
  параллелизма на стороне Dart не вводить: ядро уже само ограничивает.
- Это **не** mass-ping узлов (`runMassUrltest`, Debug API `?all=true`): узлы
  не перемеряются поодиночке, селекторы Направлений (`vpn-N`) не трогаются.
- Fire-and-forget: обработчик возвращает управление сразу после запуска
  обхода, как `actionUrltestGroup`.

### Предусловия и ошибки (единые для трёх каналов)

| Условие | Поведение |
|---------|-----------|
| Контроллер не готов (`requireHome`) | `Conflict`, как у `urltest-group` |
| Туннель опущен | `Conflict('tunnel not connected')` |
| urltest-групп нет (конфиг без Направлений с auto) | не ошибка: лог `[automation] urltest-all: no urltest groups`, Debug API отвечает `ok` с `groups: 0` |
| Любые extras в интенте | игнорируются |

Ошибка отдельной группы (RPC вернул `false`) обрабатывается внутри
`runGroupUrltest` как сейчас (debug-строка + `lastError`) и **не** прерывает
обход остальных.

### Входы

1. **Intent API** (`LxBoxIntentReceiver`): `ACTION_URLTEST_ALL`, ветка
   `forward(context, "urltest-all", emptyMap())`; регистрация действия в
   `AndroidManifest.xml` рядом с `URLTEST_GROUP`.
2. **Tasker/Locale-плагин** (`LocaleSettingEditActivity.commands`): пункт
   `Cmd("urltest-all", R.string.automation_cmd_urltest_all, null, Source.NONE)`
   после `urltest-group`. Строки: EN «URL-test all directions», RU «URL-тест всех
   Направлений», ZH по образцу `automation_cmd_urltest_group` («延迟测试所有分组»).
   Ресивер `LocaleSettingReceiver` уже форвардит любой `cmd` в
   `handleAutomationAction`, править не нужно, но проверить, что парсер
   bundle не требует extra для команд с `Source.NONE`.
3. **Dart-диспетчер** (`automation_dispatcher.dart`): `case 'urltest-all'` →
   `handlers.actionUrltestAll(ctx)`.
4. **Debug API**: `POST /action/urltest-all` (отдельный маршрут, а не новый
   scope `/action/urltest`: у того scope взаимоисключающие и `all` уже занят
   под mass-ping). Ответ `{ok, action: 'urltest-all', groups: N}`, где N —
   число групп, которым отправлена команда. Зарегистрировать в таблице
   маршрутов `docs/api/debug-api-reference.md` и в
   `027-DEBUG_API/FUNCTIONS/route-map.{md,ru.md}`.

### Обработчик

`app/lib/services/automation/handlers.dart`:

```dart
/// `urltest-all` — §625: групповой URLTest (§308) каждой urltest-группы
/// текущего состояния, последовательно; fire-and-forget. Возвращает число
/// групп, которым отправлена команда (0 — не ошибка).
Future<int> actionUrltestAll(DebugContext ctx) async {
  final home = ctx.requireHome();
  if (!home.state.tunnelUp) throw const Conflict('tunnel not connected');
  final tags = home.state.urltestGroups.map((g) => g.tag).toList();
  if (tags.isEmpty) { /* лог */ return 0; }
  unawaited(() async { for (final t in tags) { await home.runGroupUrltest(t); } }());
  return tags.length;
}
```

Если `urltestGroups` окажется недоступен через фасад контроллера, добавить
в `HomeController` тонкий метод `runAllGroupsUrltest()` рядом с
`runGroupUrltest`, а не дублировать фильтр по типу в обработчике.

## Документация (обязательно в том же коммите)

- `docs/AUTOMATION.md` и `docs/AUTOMATION.ru.md`: строка в таблице действий
  Intent API после `URLTEST_GROUP`; в примерах — рецепт «встряхивание в
  MacroDroid → `URLTEST_ALL`» (одна строка по образцу `RESET_NETWORK`).
- `014-AUTOMATION/FUNCTIONS/command-intake.{md,ru.md}`: строка таблицы.
- `014-AUTOMATION/FUNCTIONS/automation-plugin.{md,ru.md}`: `urltest-all` в
  перечне команд плагина.
- `027-DEBUG_API/FUNCTIONS/route-map.{md,ru.md}` и
  `docs/api/debug-api-reference.md`: маршрут.
- `CHANGELOG.md` → `[Unreleased] / Added`, одним абзацем по образцу соседних,
  со ссылкой на эту спеку. Без «§625» в тексте пользовательских строк.
- Тексты для пользователя — английский в UI, без ИИ-штампов.

## Риски и границы

- Несколько Направлений с одним URL-тестом создают всплеск соединений через
  все узлы одновременно. Это уже так при ручном нажатии по каждой группе;
  ограничение живёт в ядре. Не наш слой.
- Повторное встряхивание во время идущего замера: ядро принимает новый
  форс-тест, предыдущие in-flight замеры не отменяются. Как у `URLTEST_GROUP`.
- Семантика `URLTEST_GROUP` без extra **не меняется**: пустой `group` остаётся
  ошибкой (отказ от варианта «пустой extra = все группы»: тихая опечатка в
  макросе не должна превращаться в массовый замер).

## Проверка

- Юнит-тесты в `app/test/services/automation/handlers_test.dart` по образцу
  соседних: без `home` → `Conflict`; туннель опущен → `Conflict`.
- Если есть тест диспетчера на известные имена команд, добавить `urltest-all`.
- Запускать **только** затронутый тестовый файл, не каталог.
- Ручная проверка не требуется до слияния: интент проверит владелец на
  эмуляторе командой
  `adb shell am broadcast -a com.leadaxe.lxbox.URLTEST_ALL -p com.leadaxe.lxbox`
  (точную форму с компонентом взять из `docs/AUTOMATION.md`).

## Нерешённое

Нет.
