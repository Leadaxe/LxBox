# §635 — Config Editor: совет при большом файле невыполним

| Поле | Значение |
|------|----------|
| Тип | Дефект |
| Статус | D (done), выпущено в v2.25.13 |
| Дата | 2026-10-12 |
| Связанные | §333 (порог read-only), §037 (Lock config), §219 (несохранённые правки), §624 (sora-editor) |

## Проблема

Конфиг длиннее `kConfigEditMaxChars` = 1 048 576 символов
(`app/lib/screens/config_screen.dart:23`, проверка `configTooLargeToEdit` :25)
открывается только для чтения: `_readOnly` вычисляется один раз в `initState`
(:54) и не меняется. Экран при этом пишет (:279 до правки)
«File is too large to edit on device. Share it, edit externally, then load it
back.»

Совет невыполним:

- **Save** неактивна: `onPressed: (busy || _readOnly) ? null : _save` (:226 до
  правки).
- **⋮ → Load from file** (`_loadFromFile`, :127) есть и принимает файл любого
  размера, но только кладёт текст в `_textController` (:145). Сохранить его
  нечем: Save по-прежнему неактивна, а Back при `_readOnly` уходит без диалога
  несохранённых правок (`_handleBack`, :189), то есть загруженный текст молча
  теряется.
- **⋮ → Paste from clipboard** (`_pasteFromClipboard`, :108) — тот же тупик.

Строка совета к тому же не по EDITORIAL_POLICY 8.3: объект назван «File», хотя
на экране конфиг, а действие «load it back» не говорит, где и что произойдёт.

## Диагностика

- Save идёт через `HomeController.saveConfigRaw`
  (`app/lib/controllers/home_controller/config_io.dart:193`): пустой текст →
  `lastError`, `canonicalJsonForSingboxAsync` (парс JSON/JSON5 в изоляте) →
  `FormatException` → `lastError`, затем `saveParsedConfig`. Ограничения по
  размеру там нет — порог §333 касается только правки в редакторе.
- Lock config (`config_locked_for_debug`, App Settings → Diagnostics) читается
  только на путях пересборки (`subscription_controller.dart:2790`, automation
  `handlers.dart:76`, Debug API `settings.dart:654`); `saveConfigRaw` /
  `saveParsedConfig` его не смотрят. Ручное сохранение при включённом lock
  проходит, а пересборка его потом не перезаписывает.

## Решение — вариант (а)

Загрузка из файла уже есть, поэтому выбран вариант (а): в режиме только
чтения загрузка сохраняет текст сразу, без редактора. Вариант (б) («разрешить
Save для загруженного текста») хуже: потребовал бы отдельного состояния
«загружено, но не сохранено» и всё равно оставлял бы лишний шаг.

`app/lib/screens/config_screen.dart`:

- `_saveImported(text)` — при `_readOnly` вызывается из `_loadFromFile` и
  `_pasteFromClipboard` вместо подстановки текста в редактор. Сохраняет через
  тот же `widget.controller.saveConfigRaw`, что и Save: та же проверка JSON,
  та же ошибка через `lastError`. При успехе показывает pretty-текст,
  обновляет `_baseline` и тот же снек, что Save (`_showSaved`, вынесен из
  `_save`).
- Paste from clipboard включён в тот же путь: в read-only это был тот же
  тупик, а отдельное поведение двух пунктов одного меню было бы непонятно.
- Экран остаётся только для чтения до переоткрытия (`_readOnly` — `late final`;
  переключать `readOnly` у нативного sora-редактора на лету не стали).
- Без read-only поведение Load from file и Paste не изменилось: текст в
  редактор, сохранение — Save.

Строка совета (8.3: факт → действие и что произойдёт):

> Config is too large to edit on device. Share it, edit it elsewhere, then
> pick the edited file in Load from file: it is saved right away.

Переводы ru/zh перенесены под новый ключ (`app/assets/l10n/{ru,zh}/ui.json`).
Эти правки каталогов попали в коммит §632 (16f3d241): параллельный исполнитель
добавил `ui.json` целиком вместе со своими строками.

Lock config: оба пути (Save и загрузка в read-only) идут через
`saveConfigRaw`, поэтому ведут себя одинаково: lock сохранение не запрещает, а
при включённом lock следующая пересборка сохранённый файл не перезапишет.

Документация: абзац про лимит в разделе Config Editor —
`docs/USER_GUIDE.md`, `docs/USER_GUIDE.ru.md`.

## Риски и граничные случаи

- Загрузка в read-only сохраняет без подтверждения. Это прямо написано в
  строке совета; ошибочный файл не пройдёт проверку JSON, а невалидные поля
  sing-box, как и у Save, найдёт ядро при запуске.
- Загруженный файл меньше порога экран всё равно покажет только для чтения —
  до переоткрытия.

## Проверка

- `test/screens/config_screen_gate_test.dart` (граница порога),
  `test/screens/config_screen_unsaved_changes_test.dart` — зелёные;
  `flutter analyze` по файлу экрана — без замечаний; `ui_check --strict` —
  0/0.
- Вручную (эмулятор): конфиг > 1 МБ → экран read-only с новой подписью →
  ⋮ → Load from file с правленым файлом → снек «Config saved…», на главном
  экране баннер «Config changed — restart VPN to apply» при поднятом VPN;
  файл с битым JSON → ошибка разбора, конфиг не меняется.
