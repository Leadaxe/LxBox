# §624 — JSON-поля на нативном редакторе sora-editor вместо re_editor

| Поле | Значение |
|------|----------|
| Тип | Доработка фичи [019-CONFIG_EDITOR](../features/019-CONFIG_EDITOR/FEATURE.ru.md) (функции [config-editor](../features/019-CONFIG_EDITOR/FUNCTIONS/config-editor.ru.md), [json-fragment-view](../features/019-CONFIG_EDITOR/FUNCTIONS/json-fragment-view.ru.md)) |
| Статус | Спека (ревью 11.10.2026). Прототип: ветка `worktree-agent-a0e6c763717a1a9b8`, коммиты `b7cba591`, `c620c0c8` (не влиты) |
| Дата | 2026-10-11 |
| Связанные | §333 (почему ушли с `TextField` на re_editor: большие тексты), §517/§521/§607 (меню выделения re_editor), §554 (подсветка), §614/§615 (re_editor разнесён по всем JSON-полям; язык по виду текста), §372 (Android TV, D-pad), §429 (нижний отступ, шторки), §285 (язык интерфейса переключает приложение) |

## Проблема

Жалобы пользователей после v2.25.11 (§614 перевёл на `LxCodeEditor` все JSON-поля):

1. **Клавиатура закрывает низ текста.** Тап в последние строки конфига — строка
   с курсором остаётся под клавиатурой.
2. **Стрелки кастомных клавиатур** (Unexpected Keyboard, Hacker's Keyboard)
   сворачивают клавиатуру и не двигают курсор.
3. **Кнопка Copy самой клавиатуры** при выделении нескольких строк копирует
   только первую (на эмуляторе — вообще ничего).

## Диагностика

Причины — в устройстве пакета re_editor 0.10.0, не в нашем коде:

- **IME видит одну строку.** `_buildTextEditingValue`
  (`re_editor-0.10.0/lib/src/_code_input.dart:472`) отдаёт клавиатуре только
  строку с курсором и невидимый префикс `​`. Всё, что клавиатура делает
  сама над своим зеркалом текста (Copy, выделение, движение курсора), видит
  только эту строку → жалоба 3.
- **Курсор на позиции 0 = Backspace.** Если клавиатура ставит курсор перед
  префиксом (стрелка влево в начале строки, стрелка вверх в однострочном
  зеркале), пакет вызывает `deleteBackward()` (`_code_input.dart:176-178`) —
  риск склейки строк. Сворачивание клавиатуры на стрелках подтверждено на
  эмуляторе (ImeTracker: скрытие по запросу приложения); полная цепочка не
  выяснена, но корень тот же — модель ввода пакета → жалоба 2.
- **Нет докрутки к курсору** при появлении клавиатуры (у `TextField` она
  есть через `EditableText`), окно при этом уменьшается штатно (`adjustResize`)
  → жалоба 1.

Это архитектура пакета, патчем не лечится. Рассмотренные замены:

| Вариант | Итог |
|---|---|
| `code_forge` (pub) | Та же схема: IME видит ±2 строки, ≤4096 символов (`_imeProjectionMaxChars`). Плюс нативная Rust-библиотека (flutter_rust_bridge) — сборка F-Droid усложняется. Отклонён |
| `TextField` | Ввод безупречен, но тормозит на сотнях КБ — ровно то, от чего ушёл §333. Отклонён как единый компонент |
| CodeMirror 6 в WebView | Рабочий запасной вариант; новая зависимость `webview_flutter`, JS-мост. Не понадобился |
| **sora-editor** (Rosemoe, нативный Android View, LGPL 2.1, Maven Central) | Полноценный `InputConnection` как у `EditText`. **Выбран** (владелец, 11.10.2026) |

**Прототип на эмуляторе** (sora-editor 0.23.6, hybrid composition, без
переноса строк — `isWordwrap = false`):

| Проверка | re_editor | sora-editor |
|---|---|---|
| Курсор в последней строке над клавиатурой | ❌ | ✅ |
| Copy клавиатуры, 5+ строк | ❌ | ✅ все строки |
| Стрелки ←/→ (в т.ч. через начало строки) | ❌ клавиатура свернулась | ✅ |
| Стрелки ↑/↓ кастомной клавиатуры | — | не проверено (adb-жест не воспроизводит клавишу) |
| Конфиг 926 КБ | открытие ~3,4 с, подсветка выключается | setText 40 мс, подсветка есть, PSS на 9 МБ меньше |
| Поле + просмотрщик на одной прокручиваемой странице | — | ✅ клиппинг, без мерцания; janky 6,3 %, p90 18 мс |
| Шторка с клавиатурой | — | ✅ |
| Растущее поле, 45 Enter | — | ✅ курсор над клавиатурой |
| Пересоздание view (уход с вкладки, смена темы) | — | ✅ несохранённые правки на месте |
| APK | — | **+2,0 МБ** |

Чего в прототипе **нет** (дописывается по этой спеке): `hint`, `wordWrap`,
`language: null` и смена языка на лету, `showLineNumbers`/`language` у
просмотрщика, `autofocus`, цвета из `ColorScheme`, сброс задержки `changed`
при уходе с экрана, заглушка для `flutter test`, кнопки поля (`actions`).

## Решение (владелец, 11.10.2026)

**Все JSON-поля приложения — на sora-editor, re_editor удаляется целиком.**
Один компонент с одним поведением везде, а не два редактора. Публичные
виджеты остаются с прежними именами и прежними параметрами (кроме
перечисленных ниже), чтобы экраны менялись минимально.

### Места использования (12, по `grep -rn "LxCodeEditor(\|LxTextCodeField(\|LxJsonView(" app/lib`)

| Виджет | Где (файл) | Что передаёт сейчас |
|---|---|---|
| `LxCodeEditor` ×3 | `config_screen.dart` | `readOnly` (порог 1 МБ), `hint`, `showLineNumbers: true`, `language: json`, `actions: [Copy]` |
| | `add_server_wizard_screen.dart` — поля URI и JSON | `fontSize: 13`, `hint`; у JSON — `language: json`, у URI — без подсветки |
| `LxTextCodeField` ×5 | `node_settings_screen.dart` — Source узла | `minLines: 12`, `language` по виду текста (`{` → json, иначе `null`), пересчитывается `ListenableBuilder` на каждую правку |
| | `folder_detail_screen.dart` — Edit server в папке (диалог) | `autofocus: true`, `minLines: 3`, `maxLines: 8`, `hint`, `language` по `{` |
| | `dns_server_edit/tabs/json_tab.dart` — JSON-вкладка DNS-сервера | `errorText`, `onChanged`; высоты нет — заполняет `Expanded` |
| | `custom_rule_edit/sections/json_section.dart` — JSON правила маршрута | `minLines: 6`, `maxLines: 20`, `fontSize: 13`, `hint`, `errorText`, `onChanged` |
| | `dns_settings_screen/user_rule_editor_sheet.dart` — шторка DNS-правила | `height: 180`, `label` |
| `LxJsonView` ×4 | `node_settings_screen.dart` — JSON узла | `height: 420`, кнопка Copy Flutter-виджетом поверх (Stack) |
| | `outbound_view_screen.dart` — outbound | без высоты (заполняет родителя) |
| | `subscription_detail_screen/node_inspect_screen.dart` — инспектор узла подписки | без высоты, кнопка Copy поверх |
| | `subscription_detail_screen/widgets/subscription_source_tab.dart` — Source подписки | `height` = 0,6 экрана, `fontSize: 11`, `showLineNumbers: true`, `language` по виду текста |

### API виджетов после замены

Все три виджета живут в `app/lib/widgets/lx_code_editor.dart`; `enum
LxCodeLanguage { json, ini, uri }` (`null` = без подсветки), плюс
`detectCodeLanguage` — см. «Подсветка по виду текста».

| Параметр | `LxCodeEditor` | `LxTextCodeField` | `LxJsonView` | Судьба |
|---|---|---|---|---|
| `controller` | **`TextEditingController`** (было `CodeLineEditingController`) | `TextEditingController` | — (`text: String`) | тип меняется только у `LxCodeEditor` |
| `readOnly` | да | да | всегда `true` | остаётся |
| `showLineNumbers` | да (умолч. `false`) | да (умолч. `true`) | да (умолч. `false`) | остаётся → creation param `lineNumbers` |
| `language` | да | да (умолч. `json`) | да (умолч. `json`) | остаётся; меняется на лету через `setLanguage` |
| `fontSize` | да (12) | да (12) | да (12) | остаётся → `setTextSize` в sp-эквиваленте: Dart передаёт логические пиксели, натив умножает на `density` **без** `fontScale` (как Flutter-текст с `textScaler` по умолчанию) |
| `wordWrap` | да (умолч. `true`) | — (всегда `true`, как сейчас) | — (`true`) | остаётся → `isWordwrap`; прототип мерил без переноса |
| `hint` | да | да | — | остаётся (см. «Hint») |
| `autofocus` | `bool?` → **`bool`**, умолч. `false` | `bool`, умолч. `false` | — | см. «Фокус» |
| `find` | да (`null` = как `showLineNumbers`) | — | — | остаётся |
| `folding` | да | — | — | **удаляется** (решение 1); вместо него `stickyHeaders` (bool, умолч. `false`) у `LxCodeEditor` и `LxJsonView` |
| `actions` | да | — | — | остаётся: Flutter-виджеты поверх view в правом верхнем углу, на время панели поиска прячутся (как §614) |
| `height`, `minLines`, `maxLines` | — | да | `height` | остаются; `height == null && minLines == null` — заполняет ограниченного родителя |
| `label`, `errorText` | — | да | — | остаются Flutter-текстом над/под полем, как сейчас |
| `onChanged` | — | да | — | остаётся: только на правку в поле, не на запись в контроллер из кода |

Экраны по-прежнему читают и пишут `controller.text`; `LxCodeEditor` слушает
контроллер и при внешней записи (Paste, Load from file, форматирование) шлёт
`setText`. Запись в контроллер из `changed` помечается флагом `_syncing`, чтобы
не уйти обратно в натив (как сейчас в `_LxTextCodeFieldState`).

**Платформы.** Приложение только Android; на прочих платформах виджеты
рисуют заглушку — `TextField` с той же раскладкой (`label`, `hint`,
`errorText`, высота, `readOnly`), без подсветки. Гейт — `!kIsWeb &&
Platform.isAndroid` из `dart:io`. **Не** `defaultTargetPlatform`: под
`flutter test` он возвращает `TargetPlatform.android`, и тесты полезут в
platform view. Заглушка — единственный тестовый путь (см. «Проверка»).

### Нативная сторона

- `SoraEditorPlatformView` (Kotlin, `app/android/app/src/main/kotlin/com/leadaxe/lxbox/editor/`),
  фабрика `SoraEditorFactory` регистрируется в `MainActivity`
  (`platformViewsController.registry.registerViewFactory("lxbox/sora_editor", …)`).
- Dart: `PlatformViewLink` + `PlatformViewsService.initExpensiveAndroidView`
  (**hybrid composition** — без неё клавиатура в platform view не работает).
- Зависимость: `implementation(platform("io.github.Rosemoe.sora-editor:bom:0.23.6"))`
  + `editor` + `language-textmate`; версия пинится точно, без диапазонов.
- Подсветка — TextMate-грамматики в `assets/sora/`: `json.tmLanguage.json`
  и `ini.tmLanguage.json` (обе MIT, из microsoft/vscode; лицензия
  `LICENSE-vscode.txt` и README с источниками), `uri.tmLanguage.json` —
  своя (см. «Подсветка по виду текста»). TextMate-реестры sora — глобальные синглтоны: грузятся один
  раз на процесс (`SoraTextMate.ensure`), общие для всех view на экране.
- Тема: два файла `lx-light.json` / `lx-dark.json` (формат тем VS Code) дают
  **цвета токенов**; фон, цвет текста, номеров строк, выделения и каретки
  берутся из `ColorScheme` приложения и приходят в creation params /
  `setTheme` (ключи `EditorColorScheme.WHOLE_BACKGROUND`, `TEXT_NORMAL`,
  `LINE_NUMBER`, `LINE_NUMBER_BACKGROUND`, `SELECTED_TEXT_BACKGROUND`,
  `SELECTION_INSERT`, `CURRENT_LINE`). Иначе фон поля отличается от фона
  экрана (сейчас re_editor рисуется на фоне экрана — ключ `root` темы вырезан).
  Прототип этого не делает: его `editor.background` зашит в JSON темы.
- Шрифт: `Typeface.MONOSPACE` (сейчас у re_editor `fontFamily: 'monospace'` —
  тот же системный шрифт).
- Режим только чтения: `editor.editable = false`, каретка и подсветка текущей
  строки прозрачные (`SELECTION_INSERT`, `CURRENT_LINE`), клавиатура не
  вызывается; выделение и меню Copy / Select all работают.
- `isDisableSoftKbdIfHardKbdAvailable = false` — иначе при подключённой
  аппаратной клавиатуре (BT, эмулятор) экранная не появляется.
- **R8:** keep-правила `proguard-sora.pro` для `org.jcodings`, `org.joni`,
  `org.eclipse.tm4e`, `io.github.rosemoe.sora` и `-dontwarn
  kotlin.Cloneable$DefaultImpls`. Без них release-сборка падает при открытии
  редактора (TextMate-движок грузит классы по имени, R8 их вырезает).
- **Локаль нативного меню.** Строки меню выделения (Cut / Copy / Paste /
  Select all) — ресурсы sora, язык берётся из `Configuration` контекста.
  На API 33+ приложение пушит язык через `LocaleManager` (`vpn/L10n.kt`), на
  API 24–32 контекст Activity остаётся на системном языке и меню может не
  совпадать с языком приложения. Поэтому view создаётся на
  `context.createConfigurationContext(config)` с локалью из creation param
  `locale` (BCP-47 тег текущего языка приложения; пустая строка = системный).

### Канал Dart ↔ натив

Канал на view: `MethodChannel("com.leadaxe.lxbox/sora_editor_<viewId>")`.
Имена — как в прототипе, новые помечены.

| Направление | Сообщение | Аргументы | Когда |
|---|---|---|---|
| Dart → натив | creation params | `text`, `readOnly`, `dark`, `lineNumbers`, `fontSize`, `wordWrap` (новое), `language` (новое: `"json"` / `"ini"` / `"uri"` / `null`), `locale` (новое), `colors` (новое: map ключ→ARGB из `ColorScheme`), `autofocus` (новое) | создание view |
| Dart → натив | `setText {text}` | | внешняя запись в контроллер (Paste, Load from file, подстановка). Натив ставит флаг `applyingFromDart`, чтобы не отразить текст обратно `changed` |
| Dart → натив | `getText` → `String` | | перед Save / Copy / Share на экране Config (см. «Задержка») |
| Dart → натив | `setReadOnly {value}`, `setDark {dark}` + `colors` | | смена порога / темы без пересоздания view |
| Dart → натив | `setLanguage {language}` (новое) | | `didUpdateWidget`: Source узла переключает подсветку по виду текста |
| Dart → натив | `search {query}`, `searchNext`, `searchPrevious` | | панель поиска; пустой `query` = `stopSearch()` |
| натив → Dart | `changed {text?, lines, rowHeight, textOffsetX}` | `text` отсутствует в промежуточных событиях длинного текста; `rowHeight` и `textOffsetX` (`measureTextRegionOffset()`, новое) — в физических пикселях, Dart делит на `devicePixelRatio` | каждая правка; после `setText` — без `text` |
| натив → Dart | `cursor {y, rowHeight, focused}` | `y` — верх строки каретки относительно view, физические пиксели | смена выделения, фокуса, уменьшение view (клавиатура) |

**Задержка `changed`.** Текст ≤ 256 КБ (`SYNC_LIMIT`) уходит в `changed`
сразу. Длиннее — промежуточные `changed` без текста (только метрики), полный
текст — через 300 мс после последней правки (`SYNC_DEBOUNCE_MS`). Задержанный
текст **обязательно** сбрасывается немедленно: при потере фокуса view, при
`getText`, в `dispose()` натива (перед `setMethodCallHandler(null)`). Прототип
в `dispose()` правку **терял** (`removeCallbacks` без сброса) — исправить.

**Истина текста — Dart.** Пересозданный view (уход с вкладки, смена темы,
возврат на экран) получает в creation params актуальный текст контроллера.
Save / Copy / Share экрана читают `controller.text`; на экране Config перед
ними — `await` метода `flush()` виджета (через `GlobalKey<LxCodeEditorState>`),
который вызывает `getText` и пишет результат в контроллер. Остальные поля
держат тексты узлов и правил — порог 256 КБ там недостижим.

**Dispose без утечек.** Обработчик канала на стороне Dart принадлежит не
`State`, а объекту-держателю, который живёт до прихода финального `changed`
после `dispose` натива (иначе финальный текст некуда положить); натив в
`dispose()`: сброс задержки → `setMethodCallHandler(null)` →
`editor.release()`. `WidgetsBindingObserver` снимается в `dispose` `State`.

### Фокус и autofocus

- Фокус внутри view нативный; Flutter узнаёт о нём через
  `onFocus: () => params.onFocusChanged(true)` — так `FocusManager` не держит
  фокус на Flutter-поле одновременно с клавиатурой нативного.
- `autofocus: true` → натив после `setText` вызывает `editor.requestFocus()` и
  показывает клавиатуру (`showSoftInput`). Сейчас у re_editor `autofocus`
  по умолчанию `true` (`code_editor.dart:503`): экран Config и мастер
  открываются с фокусом в поле. Новое умолчание `false` для всех трёх виджетов
  (открытый вопрос 3); диалог Edit server в папке передаёт `true` явно.
- Внешних `FocusNode` у виджетов нет и не появляется: ни один из 12 экранов
  не вызывает `unfocus()` для этих полей. Клавиатуру при уходе с экрана
  закрывает Android вместе с окном фокуса.
- Android TV (§372): D-pad-стрелки внутри view двигают каретку, Back отдаёт
  фокус Flutter. Фокус не должен застревать: после Back D-pad ходит по
  остальным элементам экрана (ручная проверка).

### Hint

Sora не рисует placeholder. `hint` — Flutter-`Text` поверх view
(`IgnorePointer`, стиль `bodyMedium` цвета `onSurfaceVariant`, моноширинный,
тот же `fontSize`), показывается, пока текст контроллера пуст; левый отступ —
`textOffsetX` из последнего `changed` (учитывает ширину gutter с номерами
строк), верхний — как у первой строки. До первого `changed` — отступ без
gutter.

### Поведение в странице

- **Вертикальный жест.** Если текст помещается в поле — вертикальные свайпы
  уходят странице (страница скроллится и по полю). Если не помещается —
  вертикаль забирает редактор. Тап, долгий тап, горизонтальный свайп — всегда
  редактору.
- **Горизонтальный свайп по полю не листает вкладки** — при `wordWrap: false`
  он прокручивает длинные строки; при `wordWrap: true` sora не скроллит по
  горизонтали, но жест всё равно его. Листать вкладки — вне поля. Это
  принимаемое ограничение.
- **Курсор над клавиатурой.** По `cursor` Dart строит прямоугольник строки
  каретки и вызывает `RenderObject.showOnScreen` — ближайший `Scrollable`
  докручивает её над клавиатурой; повтор при изменении `viewInsets`
  (`didChangeMetrics`). Полноэкранный редактор (Config) докручивается внутри
  себя (`ensureSelectionVisible` при уменьшении view).
- **Растущее поле.** Высота = `clamp(lines, minLines, maxLines) × rowHeight
  + отступы`; `maxLines == null` → `max(minLines, 24)`, как сейчас. Пока
  текст помещается, внутренний скролл сброшен в начало (иначе после роста
  первая строка остаётся скрытой).
- **Несколько view на экране.** Настройки узла держат два (Source + JSON),
  подписка — один на вкладке. Каждый hybrid-composition view — отдельная
  Android-поверхность; на API 24–28 это самая тяжёлая конфигурация (см. риски).

### Меню выделения и кнопки поля

- Меню выделения — нативное меню sora (Cut / Copy / Paste / Select all; в
  режиме только чтения — Copy / Select all, как §607). Свой
  `LxSelectionToolbarController` и `_LxToolbarOverlay` (§517/§521) удаляются
  вместе с re_editor.
- Кнопки поля (`actions` у `LxCodeEditor`: Copy на экране Config, поиск)
  остаются Flutter-виджетами поверх view в правом верхнем углу, как сейчас.
  Прототип убрал Copy в меню — **вернуть**. Кнопки Copy над `LxJsonView`
  (JSON узла, инспектор подписки) остаются в своих экранах как есть.
- Поиск: штатный `EditorSearcher` sora; панель поиска — Flutter-виджет над
  редактором (как `_LxFindPanel`), команды — через канал; пустой запрос
  снимает подсветку совпадений.
- Свёртка блоков (§614) **снимается**: в sora 0.23.6 её нет (есть только
  класс-описание `lang.folding.FoldingRegion`, редактор строки не скрывает),
  своя потребовала бы форка библиотеки.
- **Липкие заголовки** вместо свёртки: `DirectAccessProps.stickyScroll = true`,
  `stickyScrollMaxLines = 3` — при прокрутке сверху закреплены строки
  объемлющих блоков (`"outbounds": [` → `{` → …). Включены (`stickyHeaders:
  true`) на экране Config, в JSON узла и в Source подписки; в мелких полях
  выключены. Липкие строки берутся из блоков, которые строит анализатор
  языка — проверить, что TextMate-JSON их отдаёт; если нет — блоки по парным
  скобкам строит свой лёгкий анализатор.
- Линии блоков (`drawSideBlockLine`, направляющие от `{` до `}`) —
  **выключены** (владелец).

### Подсветка по виду текста

`LxCodeLanguage` = `json` | `ini` | `uri`; `null` — голый текст
(`EmptyLanguage` в sora). Смена на лету — `setLanguage`, без пересоздания
view. Прототип подсвечивал всё как JSON — так не оставлять.

**Язык выбирает экран, не виджет**, но по одной общей функции
`detectCodeLanguage(String text)` (рядом с виджетами), а не тремя разными
проверками, как сейчас (`{` в `node_settings_screen.dart` и
`folder_detail_screen.dart`, `_looksLikeJson` в `subscription_source_tab.dart`).
Правило по первой непустой строке без ведущих пробелов:

| Первая непустая строка | Язык |
|---|---|
| начинается с `{` или `[` и **не** похожа на заголовок секции INI | `json` |
| `[Interface]`, `[Peer]` или другая `[Имя]` во всю строку, либо `#`/`;`-комментарий, за которым идут строки `Ключ = значение` | `ini` |
| `схема://…` (схема `[a-zA-Z][a-zA-Z0-9+.-]*`) | `uri` |
| иное (base64-подписка, YAML и т.п.) | `null` |

`[` неоднозначна: JSON-массив против секции INI. Различаем так: строка
целиком `[Слово]` (буквы, цифры, `_`, `-`, пробел) — INI; иначе JSON.
Функция покрывается unit-тестом на таблицу выше плюс пограничные случаи
(пустой текст, текст из пробелов, `[]`, `[ {`, `[Interface]` с BOM).

Где применяется:

| Место | Сейчас | После |
|---|---|---|
| Source узла (`node_settings_screen.dart`) | `{` → json, иначе без подсветки | `detectCodeLanguage` на каждую правку |
| Edit server в папке (`folder_detail_screen.dart`) | `{` → json | `detectCodeLanguage` |
| Source подписки (`subscription_source_tab.dart`) | `_looksLikeJson` | `detectCodeLanguage`; список ссылок построчно — `uri` |
| Поле URI мастера (`add_server_wizard_screen.dart`) | без подсветки | `detectCodeLanguage` (туда вставляют и ссылку, и `.conf`, и JSON) |
| Остальные поля | `json` | `json`, как было |

**INI** — грамматика VS Code `ini.tmLanguage.json`: заголовок секции, ключ,
`=`, значение, комментарии `#` и `;`. Значения не разбираются (ключи,
адреса, списки через запятую — одним цветом значения).

**URI** — своя маленькая грамматика `uri.tmLanguage.json` (одна ссылка на
строку, строк может быть много — список подписки):

| Часть | Пример | Scope (цвет темы) |
|---|---|---|
| схема с `://` | `vless://` | `keyword` |
| userinfo до `@` | `uuid@`, `user:pass@` | `string` |
| хост | `example.com`, `[2001:db8::1]` | `entity.name` |
| `:порт` | `:443` | `constant.numeric` |
| путь | `/path` | обычный текст |
| `?` `&` `=` | | `punctuation` |
| имя параметра | `security`, `sni` | `variable` / `support` (как ключ в JSON) |
| значение параметра | `reality`, `%2F` | `string` |
| `#имя` | `#Node%20name` | `comment` |

Грамматика не валидирует: кривую ссылку красит тем, что совпало, и не
падает. Строки без `://` внутри URI-текста (пустые, комментарии) — обычный
текст. Цвета берутся из тех же `lx-light/lx-dark.json`, отдельной темы не
нужно; scope'ы выбрать из уже покрытых темой, при нехватке — добавить токен
в обе темы.

### Порог только-чтения

Порог `kConfigEditMaxChars = 1 МБ` (`config_screen.dart:23`, §333) **не
меняется** в этой задаче: sora открыл 926 КБ за 40 мс, но поднимать порог —
отдельное решение после замера на телефоне.

## Затрагиваемые файлы

| Файл | Изменение |
|---|---|
| `app/lib/widgets/lx_code_editor.dart` | три публичных виджета переписаны на platform view + заглушка; re_editor-код, `LxSelectionToolbarController`, `_LxToolbarOverlay`, `_highlightTheme` удаляются |
| `app/lib/widgets/lx_native_code_editor.dart` (прототип) | сливается в `lx_code_editor.dart` или остаётся внутренним файлом; публичных `LxNative*` не остаётся |
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/editor/SoraEditorPlatformView.kt` | нативный view + канал (из прототипа, плюс `setLanguage`, `wordWrap`, `colors`, `locale`, `autofocus`, `textOffsetX`, сброс задержки в `dispose`) |
| `app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt` | регистрация фабрики |
| `app/android/app/build.gradle.kts`, `app/android/app/proguard-sora.pro` | зависимость, R8 |
| `app/android/app/src/main/assets/sora/` | грамматики JSON, INI (VS Code) и URI (своя), темы токенов, `LICENSE-vscode.txt`, README с источниками |
| `app/lib/screens/config_screen.dart`, `add_server_wizard_screen.dart` | `CodeLineEditingController` → `TextEditingController`; в Config — `flush()` перед Save / Copy / Share |
| `node_settings_screen.dart`, `folder_detail_screen.dart`, `subscription_source_tab.dart`, поле URI в `add_server_wizard_screen.dart` | своя проверка языка → `detectCodeLanguage` |
| остальные экраны из таблицы «Места использования» | без правок, если сигнатуры сохранены |
| `app/test/widgets/detect_code_language_test.dart` (новый) | таблица правил и пограничные случаи |
| `app/pubspec.yaml` | − `re_editor`, − `re_highlight` (других пользователей нет) |
| `app/test/widgets/lx_code_editor_find_fold_test.dart` | тесты свёртки и re_editor-поиска удаляются; тест «LxTextCodeField: синхронизация с TextEditingController» переписывается на заглушку |
| `app/test/widgets/lx_code_editor_readonly_menu_test.dart`, `lx_code_editor_toolbar_test.dart` | удаляются целиком (меню — нативное) |
| `app/test/screens/custom_rule_edit/app_bar_save_gate_test.dart`, `app/test/screens/folder_member_menu_test.dart` | читают `TextEditingController` вместо `CodeLineEditingController` через `LxCodeEditor`; в прототипе `app_bar_save_gate_test` уже так |
| `docs/FDROID.md` | Maven-зависимость (LGPL 2.1) — проверить, что сборка F-Droid её тянет |

## Риски и граничные случаи

- **Потеря правок при пересоздании view** — закрыто истиной на стороне Dart и
  обязательным сбросом задержки в `dispose`; отдельно проверить уход с экрана
  сразу после правки текста > 256 КБ.
- **Android 7–9 (minSdk 24, `build.gradle.kts:69`):** hybrid composition на
  версиях до 10 медленнее (известное ограничение Flutter). Проверить
  прокрутку страницы настроек узла (два view) на AVD API 24/28.
- **Android TV (§372):** D-pad по полю — фокус входит и выходит из view,
  не застревает внутри; leanback-образ без сенсорного экрана.
- **Доступность (TalkBack).** Нативный view участвует в дереве доступности
  Android сам по себе, но `label` и `errorText` — Flutter-текст рядом, не
  `contentDescription` поля. Проверить на эмуляторе, что TalkBack читает
  текст поля и подпись; если нет — `contentDescription = label` через
  creation params. Сейчас у re_editor семантики тоже нет, хуже не станет.
- **Тема и фон.** Если цвета из `ColorScheme` не прокинуть, поле выглядит
  инородно (прототип). Смена темы на лету — `setDark` + `colors`, без
  пересоздания; `ColorSchemeUpdateEvent` переприменяет прозрачные цвета
  режима только чтения.
- **Язык нативного меню** на API < 33 — см. «Локаль нативного меню»: без
  `createConfigurationContext` меню идёт на системном языке, а не на языке
  приложения. Проверить RU-локаль приложения при EN-системе на AVD API 28.
- **Шторка самопроизвольно закрылась** один раз в прототипе после Home +
  Shift+↓ через adb — не воспроизвелось; повторить вручную.
- **Стрелки ↑/↓ кастомной клавиатуры** не проверены автоматически — ручная
  проверка (scrcpy на эмуляторе или rc у пожаловавшегося пользователя).
- **`uiautomator dump` зависает** при открытом sora (мигающая каретка) —
  сценарии UI-проверки строить на скриншотах и логах, не на дампе.
- **F-Droid.** `sora-editor`, tm4e, joni, jcodings — чистые JVM-артефакты с
  Maven Central, без прекомпилированных `.so` и без JitPack; `fdroid scanner`
  к Maven-зависимостям претензий не имеет. `dependenciesInfo.includeInApk =
  false` уже стоит. Проверить сборкой по рецепту `docs/FDROID.md`.
- **Размер:** +2,0 МБ к APK (измерено на прототипе); `re_editor`/`re_highlight`
  уходят — чистый прирост чуть меньше. В CHANGELOG не выносить.
- **Лицензия:** sora-editor LGPL 2.1 как динамически линкуемый AAR внутри
  приложения GPL-3.0 (`LICENSE`) — совместимо; добавить в перечень
  зависимостей, если такой есть на экране About (`about_screen.dart`) или в
  README.
- **Утечки.** `editor.release()` в `dispose()` обязателен (sora держит
  потоки анализа и `Handler`); проверить `dumpsys meminfo` после 10 входов и
  выходов из настроек узла — число `View`/`Activity`-утечек не растёт.
- **Не покрыто:** автодополнение, подсветка YAML/base64-подписок, подъём порога 1 МБ,
  поиск с заменой.

## Проверка

**Тесты (`flutter test`, не Android):** виджеты рисуют `TextField`-заглушку
(гейт `Platform.isAndroid`); тестируется Dart-логика — контроллер ↔ виджет,
`onChanged` только на правку, рост поля по метрикам (фейковый канал через
`TestDefaultBinaryMessengerBinding`), докрутка по `cursor`, гейт readOnly,
обработка `changed` без текста и с задержкой, сброс задержки на `flush()`.
Экранные тесты (`app_bar_save_gate_test`, `folder_member_menu_test`)
переводятся на `TextEditingController`. Один файл за прогон (правило CI).

**CI:** release-сборка проходит с R8; APK из CI открывает экран Config без
падения (smoke на эмуляторе). Автотесты на CI нативный view не поднимают —
только заглушку; всё нативное проверяется вручную по сценарию ниже.

**Эмулятор (сценарий для проверяющего):**
1. Config: тап в последнюю строку — строка над клавиатурой.
2. Config: выделить 5+ строк, Copy клавиатуры — в буфере все строки.
3. Стрелки ←/→ Unexpected Keyboard в начале строки — курсор двигается, текст
   не меняется, клавиатура на месте.
4. Ввод, Enter, Backspace, Paste, Save; повторное открытие — правка на месте.
5. Config ~1 МБ: открытие, прокрутка, ввод, правка и сразу Back — после
   возврата правка на месте.
6. Настройки узла: Source + JSON на одной странице, прокрутка по полю,
   клиппинг под AppBar/TabBar; вставить в Source по очереди ссылку `vless://`,
   WireGuard `.conf` и JSON — подсветка переключается URI → INI → JSON на
   лету; Source подписки со списком ссылок — каждая строка подсвечена как URI.
7. Шторка DNS-правила с клавиатурой.
8. Растущее поле (правило маршрута): 40+ Enter; пустое поле показывает hint с
   отступом под номера строк.
9. Уход с вкладки / смена темы с несохранёнными правками — правки на месте;
   фон поля = фон экрана в обеих темах.
10. Поиск на Config; кнопка Copy в углу поля; пустой запрос снимает подсветку.
11. Мастер добавления сервера: поля URI и JSON, hint, без автофокуса.
12. Язык приложения RU на AVD API 28: меню выделения — на языке приложения.
13. TalkBack: фокус на поле — читается текст; на `label` — подпись.

**Вручную (владелец / rc):** стрелки ↑/↓ кастомной клавиатуры; Android TV
D-pad; AVD API 24; `dumpsys meminfo` на утечки.

## Решения владельца (11.10.2026)

1. **Свёртка блоков** снимается вместе с параметром `folding`. Вместо неё —
   липкие заголовки (до 3 строк) на Config, в JSON узла и Source подписки;
   линии блоков не включать.
2. **Меню выделения** — нативное меню sora. Строки — ресурсы sora на языке
   приложения (через `locale`), не наши `getLocalText`.
3. **Автофокус** — умолчание `false` везде, `true` только в диалоге Edit
   server в папке.
4. **Перенос строк на Config** остаётся (`wordWrap: true`), параметр
   сохраняется.
5. **Подсветка INI и URI** — входит в эту задачу (см. «Подсветка по виду
   текста»).

## Docs to update

- `features/019-CONFIG_EDITOR/FUNCTIONS/config-editor(.ru).md` — меню
  выделения, поиск, липкие заголовки вместо свёртки, подсветка JSON/INI/URI,
  курсор над клавиатурой.
- `features/019-CONFIG_EDITOR/FUNCTIONS/json-fragment-view(.ru).md` — просмотрщик.
- `docs/ARCHITECTURE.md` — раздел «Редактируемое: `re_editor` вместо
  `TextField`» переписать: нативный редактор, platform view, канал.
- `docs/BUILD.md` / `docs/FDROID.md` — Maven-зависимость, R8-правила.
- `tasks/333-large-text-virtualization.md` — пометка: re_editor заменён §624.
- `CHANGELOG.md` (EN + RU).
