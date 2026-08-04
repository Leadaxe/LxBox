# §374 — Экспорт бэкапа: «Сохранить в файл» вместо только share-sheet

## Контекст

Жалоба пользователя: «бекап на некоторых устройствах без стороннего файл
менеджера не сохранить».

Экспорт бэкапа реализован единственным путём — через системный share-sheet
([`backup_screen.dart:104-111`](../../../app/lib/screens/backup_screen.dart)):

```dart
final tmpDir = await getTemporaryDirectory();
final path = '${tmpDir.path}/$filename';
await File(path).writeAsString(json);
await Share.shareXFiles([XFile(path, ...)], subject: 'LxBox backup');
```

Файл кладётся в кэш приложения и отдаётся системе «поделиться». Сам по себе
он никуда не сохраняется — куда он попадёт, решает то, что юзер выберет в
шите, а кэш рано или поздно вычищается системой.

Отсюда жалоба. Два сценария, оба реальные:

1. **Нет файлового менеджера.** В share-sheet нет пункта «Сохранить в
   файлы» — таргета DocumentsUI не существует. Если при этом не стоит
   мессенджер/почта, шит открывается пустой или почти пустой, и сохранить
   бэкап физически некуда.
2. **Менеджер есть, но пункта не видно.** Шит показывает список приложений
   «поделиться с», и «сохранить как файл» пользователь там не находит —
   потому что мы не вызываем SAF-диалог сохранения напрямую.

Это симметричная дыра к [§372](372-android-tv-support.md): там мы закрыли
**импорт** (`pickFileSafely` + подсказка при отсутствии пикера), а экспорт
остался на share-sheet.

## Цели

- Дать экспорту настоящий системный «Сохранить как» (SAF
  `ACTION_CREATE_DOCUMENT`).
- Дать работающий путь на устройствах, где SAF-диалога нет вообще
  (Android TV и подобные прошивки) — запись в публичную `Downloads`.
- Сохранить share как отдельное действие: он полезен сам по себе (отправить
  бэкап себе в мессенджер), просто не должен быть единственным способом.

## Нецели

- Не трогаем импорт — он закрыт §372.
- Не просим `WRITE_EXTERNAL_STORAGE`. На API 28- fallback в Downloads
  недоступен без этого разрешения, и мы предпочитаем показать подсказку, а
  не запрашивать storage-permission (F-Droid/Play к нему придирчивы, а
  выигрыш — узкая доля устройств: pre-29 **и** без файлового менеджера).
- Не меняем формат бэкапа, набор категорий и логику `BackupService`.

## Root cause

`Share.shareXFiles` — это `ACTION_SEND`. Он адресован приложениям, которые
объявили себя приёмниками файла. «Сохранить в файловую систему» в этом
списке появляется только если в системе есть DocumentsUI (или сторонний
менеджер, объявивший `ACTION_SEND`-таргет). Ни того, ни другого на части
прошивок нет.

Правильный intent для «сохранить файл» — `ACTION_CREATE_DOCUMENT`: он
открывает системный диалог сохранения и не зависит от того, какие
приложения умеют принимать файл.

### Контракт `FilePicker.saveFile` (file_picker 11.0.2)

Проверено по исходникам плагина
(`FileUtils.kt:289-330`, `FilePickerDelegate.kt:54-78`):

| Факт | Следствие для нас |
|---|---|
| Строит `Intent(ACTION_CREATE_DOCUMENT)` с `EXTRA_TITLE = fileName` | это и есть нужный «Сохранить как» |
| При `bytes != null` плагин **сам** пишет байты в выбранный Uri (`writeBytesData`) | временный файл в кэше для этого пути не нужен |
| Возвращает `newUri.path` — path **SAF-Uri** (`/document/primary:Download/…`), не файловый путь | юзеру этот путь показывать нельзя, только имя файла |
| `RESULT_CANCELED` → `finishWithSuccess(null)` | отмена = `null` |
| Нет обработчика → `finishWithError("invalid_format_type", …)` | та же ошибка, что в §372 |

Ключевое: **отмена и «некуда сохранить» неразличимы по возвращаемому
значению** — ровно та же ситуация, что в §372 с `pickFiles`. Плюс та же
грабля с TV-заглушкой `frameworkpackagestubs`: она перехватывает
`CREATE_DOCUMENT`, показывает тост и отвечает `RESULT_CANCELED`, так что
`invalid_format_type` даже не возникает. Значит детект «есть ли куда
сохранять» обязан быть **предварительным**, как `hasRealFilePicker()`.

## Решение

### UI: одна кнопка Export → выбор действия

Кнопка `Export...` остаётся одна (как сейчас), но открывает bottom sheet с
выбором. Так экспорт остаётся одним понятным действием, а способ юзер
выбирает осознанно — вместо непрозрачного share-sheet.

| Пункт | Механизм | Показывается |
|---|---|---|
| **Save to file** | `FilePicker.saveFile` → SAF `CREATE_DOCUMENT` | когда `hasRealFilePicker() == true` |
| **Save to Downloads** | нативная запись через MediaStore | когда `canSaveToDownloads() == true` (API 29+) |
| **Share** | `Share.shareXFiles` (текущий код) | всегда |

Порядок в шите — как в таблице: сохранение выше, share ниже.

Если недоступны оба варианта сохранения (нет пикера **и** API 28-), в шите
над пунктом Share показывается пояснение — переиспользуем существующий ключ
`ErrKey.noFileManager` (§372/§285), чтобы не плодить строки.

### Save to Downloads — нативный метод

Новый метод в канале `com.leadaxe.lxbox/utils`
([`MainActivity.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt),
рядом с `hasRealFilePicker`):

| Метод | Аргументы | Возврат |
|---|---|---|
| `canSaveToDownloads` | — | `Boolean` — `Build.VERSION.SDK_INT >= 29` |
| `saveToDownloads` | `fileName: String`, `content: String` | `String?` — отображаемое имя сохранённого файла, `null` при сбое |

Реализация — `MediaStore.Downloads` + `RELATIVE_PATH = Environment.DIRECTORY_DOWNLOADS`,
`MIME_TYPE = application/json`. Разрешений на API 29+ не требует.

Коллизия имён: MediaStore сам разводит дубликаты, дописывая ` (1)` к имени.
Поэтому метод возвращает фактическое `DISPLAY_NAME`, прочитанное обратно из
вставленной записи, — его и показываем в снекбаре, чтобы юзер знал, какой
файл искать.

### Dart-слой

- [`services/url_launcher.dart`](../../../app/lib/services/url_launcher.dart) —
  обёртки `canSaveToDownloads()` (fallback `false` при недоступном канале —
  не обещаем то, чего не проверили) и `saveToDownloads(...)`.
- Новый [`services/file_export.dart`](../../../app/lib/services/file_export.dart) —
  симметричен `file_import.dart`: sealed-исходы и разбор в текст.

```dart
sealed class SaveOutcome {}
class SavedToFile   extends SaveOutcome { final String name; }   // SAF
class SavedToDownloads extends SaveOutcome { final String name; }
class SaveCancelled extends SaveOutcome {}
class SaveNoTarget  extends SaveOutcome {}   // нет ни SAF, ни MediaStore
class SaveFailed    extends SaveOutcome { final Object error; }
```

Предварительная проверка `hasRealFilePicker()` — до вызова `saveFile`, по
образцу `pickFileSafely` (иначе TV-заглушка вернёт `null`, и мы покажем
«отменено» вместо подсказки).

### Итоговое сообщение

| Исход | Снекбар |
|---|---|
| `SavedToFile` | `Saved as %s` (имя файла; SAF-путь не показываем — он не файловый) |
| `SavedToDownloads` | `Saved to Downloads: %s` |
| `SaveCancelled` | молчим |
| `SaveNoTarget` | текст `ErrKey.noFileManager` |
| `SaveFailed` | `Export failed: %s` |

Счётчик байт (`Backup exported (%d bytes)`) уезжает из успеха share в
успех сохранения — юзеру полезнее знать, что файл непустой.

## Файлы

| Файл | Изменение |
|---|---|
| `app/lib/screens/backup_screen.dart` | `_onExport` → выбор действия + разбор `SaveOutcome` |
| `app/lib/screens/backup_screen/export_card.dart` | иконка кнопки `share` → `save_alt` |
| `app/lib/screens/backup_screen/export_action_sheet.dart` | **новый** — bottom sheet с выбором |
| `app/lib/services/file_export.dart` | **новый** — `saveFileSafely`, исходы, разбор текста |
| `app/lib/services/url_launcher.dart` | `canSaveToDownloads`, `saveToDownloads` |
| `app/android/.../MainActivity.kt` | два метода канала + MediaStore-запись |
| `app/assets/l10n/ui/*.json` | новые строки (§285) |

## Критерии приёмки

1. На телефоне с файловым менеджером: Export → Save to file открывает
   системный диалог сохранения, файл появляется в выбранной папке,
   снекбар показывает имя.
2. Отмена диалога сохранения — молча, без снекбара об ошибке.
3. На устройстве без файлового менеджера (API 29+): пункт Save to file
   скрыт, Save to Downloads сохраняет файл в `Downloads`, снекбар
   показывает фактическое имя.
4. Повторный экспорт в Downloads с тем же именем не перезаписывает первый
   файл, а снекбар показывает имя с суффиксом.
5. Share продолжает работать как раньше.
6. Сохранённый файл успешно импортируется обратно (round-trip).

## Device-verification

**DEVICE-VERIFIED** (04.08.2026) — эмулятор-телефон API 34 и эмулятор
Android TV API 31.

### Телефон (API 34, DocumentsUI есть)

| Проверка | Итог |
|---|---|
| Шит выбора | три пункта, порядок как в спеке |
| Save to file | открылся `DocumentsUI PickActivity`, имя предзаполнено |
| Файл на диске | 41919 B, валидный JSON, шапка корректна |
| Save to Downloads | записан без диалога |
| Коллизия имён | ` (1)`, ` (2)` — ничего не перезаписано |
| Снекбар при коллизии | показал `…-1957 (2).json` — реальное имя |
| Round-trip | импорт распарсил: 20 списков, 14 правил, 26 настроек, 8 тумблеров |

### Android TV (API 31, только заглушка)

Подтверждено `cmd package query-activities`: **`CREATE_DOCUMENT`
перехватывает та же `com.android.tv.frameworkpackagestubs`**, что и
`OPEN_DOCUMENT` — гипотеза спеки верна, предварительная проверка
обязательна.

| Проверка | Итог |
|---|---|
| Пункт Save to file | **скрыт** — `hasRealFilePicker()` вернул false |
| Шит | два пункта: Save to Downloads + Share |
| Save to Downloads | файл записан, 3221 B |
| Снекбар | имя + размер совпали с `ls` на диске |

### Дефект, найденный прогоном

Снекбар показывал 41341 при файле 41919 B на диске: `String.length` в Dart
считает UTF-16 code units, а кириллица в именах узлов даёт расхождение.
Исправлено на `utf8.encode(json).length` (коммит `35b78edb`), проверено
повторно на TV — 3221 в снекбаре против 3221 в `ls`.

### Не покрыто

Ветка `SaveNoTarget` (нет ни пикера, ни MediaStore) — для неё нужен API 28-
без файлового менеджера; на TV31 (API 31) fallback доступен, поэтому
подсказка `noFileManager` в живом UI не показывалась.

## Docs to update

- `CHANGELOG.md` — entry в `Unreleased` (user-visible).
- `docs/ARCHITECTURE.md` — не требуется (новых подсистем нет, канал
  `utils` существующий).
- `docs/spec/tasks/372-android-tv-support.md` — перекрёстная ссылка сюда
  как на симметричный фикс экспорта.
