# §479 — уровни уведомлений узла по логике лаунчера

| | |
|---|---|
| **Статус** | Реализовано |
| **Дата** | 2026-09-19 |
| **Источник** | решение владельца 19.09.2026: «в LxBox нужны уровни показа ✖/⚠/ⓘ как у нас» (сказано в сессии лаунчера) и «делать примерно по логике лаунчера» (в этой сессии); итоговый вид лаунчера — его сообщение 19.09.2026, `TASKS_LXBOX.md` §24.11 (частично устарел) |
| **Связанные** | §471 и его ревизия 1 (место значка info — ПЕРЕСМАТРИВАЕТСЯ этой задачей), фича 460 W2b (шторка Warnings), фича 478 (будущий код `core_rejected`) |

## Что меняется

«Примерно по логике лаунчера» — переносим логику, а не пиксели: экран
телефонный, тултипов нет, высота строки списка дорога.

### 1. Строка узла в списке подписки

- Подстрока предупреждения — только error / warning: значок старшего уровня +
  **заголовок** старшего кода (`title_<lang>` из реестра; у кода без заголовка
  и у рукописного предупреждения — прежний `message()`), «+N» считает только
  error и warning. Это как сейчас, кроме источника текста: короткий заголовок
  вместо полного текста.
- **Info — не у имени и не текстом.** Значок `info_outline` ПРИГЛУШЁННОГО
  цвета (`onSurfaceVariant`, не синий): у узла с одними info — в начале строки
  протокола (`ⓘ vless  de1.example.com:443`), третьей строки нет; у узла с
  error/warning — в КОНЦЕ строки предупреждения. Имя узла чистое. Ревизия 1
  §471 (значок у имени, перед значком уровня) отменяется.

```
Frankfurt-01                                   84 ms
ⓘ vless  de1.example.com:443

Amsterdam-02  ✎                               120 ms
vless  nl2.example.com:443
⚠ Deprecated flow (+1)                             ⓘ
```

- Тап по значку ⓘ и по строке предупреждения открывает уведомления узла
  (п. 3); зона тапа значка ≥ 24×24; тап не проваливается в `onTap` строки.
- Счётчик и подсветка у подписки — по error/warning, как сейчас; если в шапке
  подписки есть сводка состава — строка `For your information: N` для info
  (только если сводка уже существует; новой не заводить).

### 2. Уровни и цвета

Палитра одна (`banner_palette.dart`, §471): error — красный, warning —
янтарный, info — синий значок. Приглушённый цвет — ТОЛЬКО у значка info в
строке списка; внутри уведомлений info синий. Код, которого нет в реестре
сборки, показывается как warning (уже так — закрепить тестом).

### 3. Уведомления узла — один компонент, два места

Новый виджет `NodeNotificationsView`:

- шапка со счётчиками по уровням `✖ 1 · ⚠ 2 · ⓘ 3` (нулевые не
  показываются);
- подразделы Errors → Warnings → Info со значком и цветом уровня; при
  ЕДИНСТВЕННОМ уровне подзаголовок не рисуется;
- уведомление — одна строка-заголовок (`title`, обрезается) и раскрывающийся
  блок: путь поля (`path`, моноширинно), `What happened` (text), `Why it
  happens` (cause), `What you can do` (fix списком), `Details` → ссылка на
  якорь доков (`contractWarningDocUrl`, как в W2b). Всё свёрнуто по
  умолчанию; у единственного уведомления — развёрнуто сразу (на телефоне
  лишний тап ради одной записи не нужен).

Места:

1. **Нижняя шторка** из списка (W2b) — тот же компонент вместо нынешнего
   плоского списка; заголовок шторки `Notifications`. Тап по значку ⓘ/⚠ или
   строке предупреждения под узлом.
2. **Вкладка Notifications** в деталях узла (§497) — `node_inspect_screen.dart`
   (узел подписки: JSON / Source / …) и `node_settings_screen.dart` (одиночный
   сервер / член папки: Settings / Source / JSON / …); перед вкладкой
   Diagnostics. Общий виджет `NodeNotificationsTab`; узел без уведомлений —
   пустое состояние, вкладка остаётся. Раздел на вкладке Settings (§479
   первоначально) перенесён сюда.
3. **Шторка отказа ввода** (§500) — тот же [NodeNotificationsView] в
   [NodeWarningsSheet], с меткой входа вместо тега. Лист «N servers disabled»
   после §498 ведёт на вкладку Notifications, а не во вторую шторку.

Видимые строки (английские ключи, переводы ru/zh): `Notifications`, `Errors`,
`Warnings`, `Info`, `What happened`, `Why it happens`, `What you can do`,
`Details`, `For your information: %d`. Прежние `Why`, `What to do`, `Learn
more` из W2b удаляются из кода и словарей, если больше нигде не нужны.

## Критерии приёмки

Виджет-тесты (обновить `node_warnings_sheet_test.dart`, переименовав по
смыслу): только info → приглушённый значок в строке протокола, имя чистое,
третьей строки нет; warning + info → значок info в конце строки
предупреждения; заголовок кода вместо текста; счётчики без нулевых уровней;
единственный уровень — без подзаголовка; запись свёрнута/разворачивается;
единственная запись развёрнута; неизвестный код = warning; раздел на экране
узла последним и отсутствует без уведомлений. `flutter analyze`, l10n-чекеры
`--strict`. Доки: USER_GUIDE.md/.ru.md, GUARDS.md (если названы места),
CHANGELOG (Changed), спека 471 (пометка: ревизия 1 отменена §479), спека 460
§10 (W2b — компонент заменён).

## Как сделано

### Компонент

`NodeNotificationsView`
(`app/lib/screens/subscription_detail_screen/widgets/node_notifications_view.dart`)
— один виджет: шторка из списка, вкладка Notifications (§497) и шторка
отказа ввода (§500). Собирает `groupWarningsBySeverity` (error →
warning → info, порядок ключей = порядок разделов), рисует шапку счётчиков,
подзаголовки уровней и записи. Уровень без записей не попадает ни в счётчик,
ни в разделы: «0 ошибок» читается как ошибка, которую не смогли назвать.
Подзаголовок не рисуется при ЕДИНСТВЕННОМ присутствующем уровне — над одной
группой он повторял бы шапку.

Запись — `ExpansionTile` (тот же элемент, что «Stored JSON» в блоке Sections
экрана узла — паттерн проекта, не новый стиль). Свёрнута по умолчанию;
`initiallyExpanded` включается, когда уведомление у узла одно. В раскрытом
виде: путь поля моноширинно (только у `RegistryWarning` — рукописный класс
пути не знает), `What happened` (`text_<lang>`), `Why it happens`
(`cause_<lang>`), `What you can do` (`fix_<lang>` списком), `Details` —
`contractWarningDocUrl(code)` через `UrlLauncher.open`. Блоки рисуются только
у кода, который знает реестр: у рукописного класса объяснять нечего, и пустая
подпись врала бы.

Заголовок записи — `message()`. У `RegistryWarning` это уже `title_<lang>`
(`registryTitle`, §460 W1) — отдельного геттера заводить не пришлось, чтения
`title_*` в `registry_warning.dart` хватало, менять там ничего не стали.
Рукописный класс отдаёт свой текст, как и прежде.

### Строка списка

`NodeWarningRow` потерял флаг `compact`: режимов больше нет, строка одна и
всегда компактная — экран узла её не показывает вовсе. Info из текста ушёл
окончательно, значок `ⓘ` переехал в КОНЕЦ строки. `NodeInfoBadge` перекрашен
в `onSurfaceVariant`: в списке info не зовёт к действию, и второй яркий значок
спорил бы со значком уровня. Внутри уведомлений info остаётся синим —
приглушение локально для списка, палитра §471 не тронута.

В `subscription_node_list.dart` значок уехал из `title` в `Row` строки
протокола, перед текстом; `title` остался `Flexible`-именем плюс `✎`. Гейт
прежний: значок в строке протокола — только у узла без actionable, иначе он
задвоился бы со значком в строке предупреждения.

### Экран узла

`NodeWarningRow` наверху вкладки Settings убран (§479). Раздел `Notifications`
на вкладке Settings заменён отдельной вкладкой (§497): `NodeNotificationsTab`
на `node_inspect_screen.dart` и `node_settings_screen.dart`, перед
Diagnostics.

### l10n

Добавлены `Errors`, `Details`, `What happened`, `Why it happens`,
`What you can do`, `What the app changed or could not apply`. Удалены `Why`,
`What to do`, `Learn more` — в коде больше не используются (orphan под
`ui_check --strict`). `Notifications`, `Warnings` и `Info` уже были в словарях.

`Info` — коллизия (§285): корневая форма занята разделом «Protocol and server
details» экрана узла («Информация»), а подзаголовку уровня нужно
«К сведению». Подзаголовок зовёт `getLocalText.s(1, "Info")`, перевод — в
`special["1"]` обоих словарей (ru «К сведению», zh «供参考»).

### Чего не делали

`For your information: N` в шапке подписки НЕ заведён: раскрывающейся сводки
состава там нет — шапка это плоская полоса «N nodes with warnings», а спека
разрешает строку только при уже существующей сводке. Заводить новую не стали.

## Что видит пользователь

```
Frankfurt-01                                   84 ms
ⓘ vless  de1.example.com:443

Amsterdam-02  ✎                               120 ms
vless  nl2.example.com:443
⚠ Transport replaced with ws (+1)                  ⓘ
```

Уведомления (свёрнуто / развёрнуто):

```
Notifications
✖ 1 · ⚠ 2 · ⓘ 1

Errors
  ✖ Required field "sni" is missing.            ⌄
Warnings
  ⚠ Transport replaced with ws                  ⌄
  ⚠ Unknown obfuscation removed                 ⌄
Info
  ⓘ Certificate verification disabled           ⌃
      tls.insecure
      What happened
      The entry sets tls.insecure to true, so …
      Why it happens
      …
      What you can do
      •  …
      [↗ Details]
```

## Файлы

| Файл | Что |
|---|---|
| `app/lib/screens/subscription_detail_screen/widgets/node_notifications_view.dart` | новый — общий компонент уведомлений |
| `app/lib/screens/subscription_detail_screen/widgets/node_warnings_sheet.dart` | шторка на общем компоненте, заголовок `Notifications` |
| `app/lib/screens/subscription_detail_screen/widgets/node_warning_row.dart` | без `compact`; `ⓘ` в конце строки и приглушённый |
| `app/lib/screens/subscription_detail_screen/widgets/subscription_node_list.dart` | значок в строке протокола, имя чистое |
| `app/lib/screens/node_settings_screen.dart` | вкладка Notifications перед Diagnostics (§497) |
| `app/assets/l10n/{ru,zh}/ui.json` | новые ключи, удалены `Why`/`What to do`/`Learn more`, `special["1"]` у `Info` |
| `app/test/screens/node_notifications_test.dart` | заменил `node_warnings_sheet_test.dart` |
| `docs/USER_GUIDE.md`, `docs/USER_GUIDE.ru.md` | раздел про значки под узлом переписан |
