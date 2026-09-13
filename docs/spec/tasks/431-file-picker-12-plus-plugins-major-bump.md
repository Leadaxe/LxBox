# 431 — file_picker 12 + plus-плагины: мажорный бамп, свой `PickedFile`, выпил мёртвой codegen-цепочки

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-09-13 |
| Триггер | Play Console, выпуск 22301500 (2.23.1): «Повысьте производительность, уменьшив разрешение растровых изображений» — класс `o1.o` вызывает `BitmapFactory.decodeStream` без `Options` |
| Связанные | [§372](372-android-tv-no-file-picker.md) (TV без пикера), [§383](383-file-picker-get-content-fallback.md) (GET_CONTENT-фолбэк), [§374](374-backup-save-to-device.md) (сохранение файла), [§333](333-large-text-virtualization.md) (utf8 вместо fromCharCodes) |

## Проблема

Play нашёл `BitmapFactory.decodeStream(stream)` без `inSampleSize`. Владелец —
`file_picker 11.0.2`, `FileUtils.compressImage` (единственный `BitmapFactory`
во всём дереве зависимостей; наш Kotlin чист, CameraX и flutter_zxing чисты по
байткоду). Путь у нас недостижим: `compressImage` вызывается только при
`compressionQuality > 0 && isImage(uri)`, а мы выбираем конфиги и
`compressionQuality` не передаём. Play смотрит байткод статически.

Сама по себе претензия — шум. Реальная причина бампа — ветка 11.x мёртвая:
11.0.3 патч не получил (`inSampleSize` есть только в 12.0.0-beta.8+, PR #2083),
и delta 11→12 будет только расти. Шов под миграцию уже есть —
`pickFileSafely`/`saveFileSafely`.

## Каскад зависимостей

`file_picker 12` → `windows_file_picker` → `win32 ^6.3`. Тот же `win32`
держат plus-пакеты, по частям не резолвится. Итог — пять мажоров:

| Пакет | Было → стало | Что ломается у нас |
|---|---|---|
| `file_picker` | 11.0.2 → 12.3.x | `PlatformFile.bytes` удалён; `PlatformFile` — `abstract base` без конструктора (ломает §383, где он строился руками); `FilePickerResult` удалён (`pickFiles → List<PlatformFile>`, пусто = отмена); `saveFile → Uri?`; код ошибки `invalid_format_type` → `explorer_not_found` |
| `share_plus` | 10.1.4 → 13.3.x | класс `Share` удалён; только `SharePlus.instance.share(ShareParams(...))` (12 мест, все уже под `// ignore: deprecated_member_use`) |
| `device_info_plus` | 10.1.2 → 13.2.x | нет: используемые `version.release/sdkInt/manufacturer/model/device/supportedAbis` на месте |
| `package_info_plus` | 8.3.1 → 10.2.x | нет |
| `connectivity_plus` | 6.1.5 → 7.3.x | нет: `checkConnectivity → List<ConnectivityResult>` у нас с 6.0 |

Плюс minor/patch всего дерева (`camera` 0.12.1, `flutter_zxing` 2.4.0, ~35
транзитивных).

**Выпилены** `freezed`, `freezed_annotation`, `json_annotation`,
`json_serializable`, `build_runner`: ноль `@freezed`/`@JsonSerializable`, ноль
`.g.dart`/`.freezed.dart` в репо, нет `build.yaml`, не упоминаются в scripts/CI/
BUILD.md. Пять строк в `pub outdated` и ~30 транзитивных dev-зависимостей за
пакеты, которыми проект не пользуется.

## Решение

### `PickedFile` — свой тип вместо `PlatformFile` в UI

`services/file_import.dart`:

```dart
class PickedFile {
  const PickedFile({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;           // не nullable: обёртка читает сама
  String get text => utf8.decode(bytes, allowMalformed: true);
}
```

`pickFileSafely` вызывает `readAsBytes()` внутри своего `try` (сбой чтения →
`PickFailed`), параметр `withData` уходит. Оба пути — плагин и §383
GET_CONTENT — отдают один тип; вызывающие о развилке не знают, как и раньше.

У 9 call-site'ов исчезает пара `bytes != null … else if (path != null)
File(path).readAsString()` — остаётся `file.text`. Три места с
`String.fromCharCodes` (folder_detail, entry_context_menu, subscriptions)
переходят на utf8 — тот же баг, что §333 чинил в config_screen, только
недочиненный здесь.

### Коды ошибок и `saveFile`

`_noPickerCode = 'explorer_not_found'` в `file_import.dart` и
`file_export.dart`. Предпроверка через `UrlLauncher.filePickerAction()` /
`hasRealFilePicker()` остаётся главным детектом (§372: TV-заглушка
перехватывает intent, ошибка не возникает) — код ошибки только fallback.
`saveFileSafely`: `uri == null` → `SaveCancelled`.

### `Share` → `SharePlus`

`Share.share(text, subject:)` → `SharePlus.instance.share(ShareParams(text:,
subject:))`; `Share.shareXFiles(files, text:, subject:)` → `ShareParams(files:,
text:, subject:)`. Снимаются 12 `// ignore: deprecated_member_use`.

## Что НЕ делается

| Не делается | Почему |
|---|---|
| `flutter_zxing` 3.0 | Смена нативного движка zxing-cpp 2.3.0 → 3.1.1 (633 коммита), `Format.qrCode` начинает матчить Micro QR/rMQR. Нужен тест на реальной камере, не на AVD. Отдельная таска §432, чтобы регрессию не спутать с этой |
| Выпил прямой зависимости `camera` | `flutter_zxing` сам требует `camera >=0.11 <0.13`; CameraX приезжает через него в любом случае, экономии нет |
| `freezed` 4 / `build_runner` 2.16 | Не бампаются — удаляются (не используются) |
| R8 `-keep`/правило под Play-претензию | Play смотрит байткод; правило ничего не меняет |

## Проверка

- `flutter analyze` (весь проект, не `lib/`), `flutter test`.
- APK через `scripts/build-local-apk.sh`, device-verify на AVD LxBox_test:
  импорт конфига (Config), бэкапа (Backup + restore с Home), правил (Routing),
  подписки из файла (один файл; несколько → папка); экспорт бэкапа через SAF
  и через share; share конфига/дампа.
- §372/§383 (TV-заглушка, GET_CONTENT) — на TV-AVD, если поднят; иначе
  DEVICE-PENDING отдельной строкой.
- Размер APK до/после (Tika −465 классов, codegen-цепочка не в APK — ноль).

## Docs to update

- `CHANGELOG.md` → Unreleased (эта таска).
- `docs/ARCHITECTURE.md` — если там перечислены зависимости; иначе none.
