# §372 — Android TV: leanback-манифест, fallback импорта, D-pad фокус

## Контекст

Жалоба пользователя (4PDA, июль 2026): Android TV на 7.1.1 (API 25).
APK ставится — `minSdk = 24` (§233) ниже API 25, установка не блокируется.
Но приложение на телевизоре нерабочее:

1. «при нажатии на кнопку импорт из файла ничего не происходит»;
2. «запрашивает разрешение на vpn, но потом ничего не соединяет
   и при нажатии на кнопки ничего не происходит»;
3. иконки в лаунчере TV нет (пользователь запускал обходным путём).

Пользователь предположил, что нужно понизить minSdk до 23 и выдать
разрешение на чтение диска. **Оба предположения неверны** и в этой таске
не реализуются:

- `minSdk` понижать некуда и незачем: 24 — пол Flutter 3.41.x
  (`FlutterExtension.minSdkVersion`), а API 25 > 24, установка и так
  проходит. См. [§233](233-lower-minsdk-24.md).
- `READ_EXTERNAL_STORAGE` кнопку импорта не оживит: `file_picker`
  использует `ACTION_OPEN_DOCUMENT` / `ACTION_GET_CONTENT`, которым
  разрешения на storage не нужны в принципе.

Настоящая причина — три независимых пробела, разобранные ниже.

## Root cause

### 1. Импорт: на Android TV нет DocumentsUI — но intent НЕ остаётся без обработчика

> **Уточнено device-verification'ом (эмулятор Android TV, API 31).**
> Первоначальная гипотеза — «`resolveActivity` вернёт null, плагин отдаст
> `invalid_format_type`» — **неверна**. Реальность хуже: framework TV
> подкладывает заглушку.

В прошивках Android TV нет DocumentsUI, но `OPEN_DOCUMENT` /
`GET_CONTENT` / `CREATE_DOCUMENT` перехватывает системная заглушка
`com.android.tv.frameworkpackagestubs/.Stubs$DocumentsStub` (проверено:
`cmd package query-activities` на TV отдаёт её и только её; на телефоне и
на CPH2411 — `com.google.android.documentsui`).

Последствия по шагам, из живого logcat на TV:

```
FilePickerUtils: Custom file types are [json] …
ActivityTaskManager: START … cmp=com.android.tv.frameworkpackagestubs/.Stubs$DocumentsStub
NotificationService: Toast already killed. pkg=com.android.tv.frameworkpackagestubs
flutter : AutoUpdater: trigger=resumed        ← вернулись в app, результата пика НЕТ
```

Заглушка показывает тост и сразу finish'ится с `RESULT_CANCELED`.
Для приложения это **неотличимо от «юзер передумал»**: `resolveActivity`
находит обработчика, `invalid_format_type` не возникает, `pickFiles`
возвращает `null`. Кнопка импорта немая — ровно жалоба 4PDA.

Поэтому детект не может опираться на ошибку плагина: нужно спрашивать
платформу **до** запуска пика, есть ли обработчик, не являющийся
заглушкой (`§372 hasRealFilePicker`, см. ниже).

Вторично — даже когда ошибка всё же возникает (устройство вообще без
обработчика), до пользователя она не доходила внятно:

| Место вызова | Что видит юзер на TV |
|---|---|
| [`config_io.dart:241`](../../../app/lib/controllers/home_controller/config_io.dart) `readFromFile` | общий `catch` → «File error: Can't handle the provided file type» (техно-текст, тупик) |
| [`config_screen.dart:112`](../../../app/lib/screens/config_screen.dart) | «Error: Can't handle the provided file type» — техно-текст, не подсказывает выход |
| [`subscriptions_screen.dart:286`](../../../app/lib/screens/subscriptions_screen.dart) | то же |
| [`backup_screen.dart:124`](../../../app/lib/screens/backup_screen.dart), [`restore_backup.dart:28`](../../../app/lib/screens/home/restore_backup.dart), [`folder_detail_screen.dart:699`](../../../app/lib/screens/folder_detail_screen.dart), [`entry_context_menu.dart:305`](../../../app/lib/screens/subscriptions_screen/entry_context_menu.dart) | то же / тишина |

Всего **8 прямых вызовов** `FilePicker.pickFiles`, обёртки нет.

Важно: обходной путь **уже существует** — вставка из буфера
(`readFromClipboard` рядом с `readFromFile`, «Paste from clipboard» в
config-экране) и импорт по URL. Пикер не нужен, нужно довести юзера до
альтернативы вместо технической ошибки.

### 2. Приложение не заявлено как TV-приложение

В [`AndroidManifest.xml`](../../../app/android/app/src/main/AndroidManifest.xml)
нет ни одного из трёх обязательных для TV элементов:

- `<uses-feature android:name="android.software.leanback" android:required="false"/>`
- `<uses-feature android:name="android.hardware.touchscreen" android:required="false"/>`
- `<category android:name="android.intent.category.LEANBACK_LAUNCHER"/>` в
  intent-filter `MainActivity`

Следствие: TV-лаунчер не показывает иконку (он перечисляет только
`LEANBACK_LAUNCHER`-активити), а Play Store счёл бы приложение
несовместимым с TV (для sideload не важно, но декларация всё равно нужна).

`android.hardware.touchscreen` по умолчанию считается **required=true** —
это отдельная причина, по которой приложение формально несовместимо с
устройствами без тачскрина.

### 3. D-pad: фокусной навигации нет

Приложение рассчитано на палец. Инфраструктуры фокуса нет: во всём
`lib/` только точечные `autofocus: true` в диалогах и `requestFocusOnTap`
в комбобоксах; ни `FocusTraversalGroup`, ни явных `FocusNode` на
основных действиях, ни обработки D-pad-клавиш.

Flutter даёт базовый traversal «из коробки» (стрелки двигают фокус,
Enter/`Select` жмёт кнопку), но:

- у `InkWell`/`GestureDetector`-элементов (а не `ElevatedButton`/`TextButton`)
  фокусного узла нет вовсе — пультом на них не попасть;
- фокус не виден: без визуального индикатора юзер не понимает, где он;
- порядок обхода по умолчанию геометрический — на плотных экранах
  (список нод + фильтры + нижняя панель) уводит не туда.

Это и есть «при нажатии на кнопки ничего не происходит»: нажатия
уходят в элемент, который не сфокусирован, либо фокус стоит на
невидимом элементе.

### 4. «Даже директ не соединяет» — вне скопа, нужны логи

VPN-consent система выдаёт (юзер это видел) ⇒ `BoxVpnService` стартует.
Дальше причина не определяется по коду: это может быть следствие п.3
(кнопка старта не получила реального нажатия) либо отказ ядра на
конкретной прошивке. **Диагностика — по `adb logcat` с телевизора**, а не
догадки. В этой таске не чинится; после фиксов п.1-3 запросить у юзера
логи повторно.

## Цели

- Приложение видно и запускается из лаунчера Android TV.
- Импорт на устройстве без пикера даёт понятную подсказку с рабочей
  альтернативой (буфер / URL), а не техно-ошибку и не тишину.
- Основные действия достижимы с пульта, фокус виден.

## Нецели

- Не строим отдельный TV-UI (leanback-лейауты, `BrowseFragment`) — только
  доводим текущий UI до управляемости пультом.
- Не понижаем `minSdk` (см. Контекст).
- Не добавляем storage-разрешения (не относится к делу).
- Не чиним п.4 «не соединяет» — до получения логов.
- Не заявляем TV как поддерживаемый тир: остаётся **best-effort**.

## Что меняется

### A. Манифест (TV-декларация)

[`app/android/app/src/main/AndroidManifest.xml`](../../../app/android/app/src/main/AndroidManifest.xml):

```xml
<uses-feature android:name="android.software.leanback" android:required="false" />
<uses-feature android:name="android.hardware.touchscreen" android:required="false" />
```

и в intent-filter `MainActivity`, рядом с существующей `LAUNCHER`:

```xml
<category android:name="android.intent.category.LEANBACK_LAUNCHER" />
```

`required="false"` в обоих случаях — телефоны/планшеты не должны потерять
совместимость. Отдельный TV-баннер (`android:banner`) — опционально;
без него лаунчер берёт `android:icon`.

### B. Fallback импорта — обёртка над FilePicker

Новый файл [`app/lib/services/file_import.dart`](../../../app/lib/services/file_import.dart):

```dart
sealed class PickOutcome {}   // PickedFiles | PickCancelled | PickNoPicker | PickFailed
Future<PickOutcome> pickFileSafely({...});
String? pickProblemText(PickOutcome);  // текст снекбара, null для ok/cancel
```

Правила разбора:

- **до пика** — `UrlLauncher.hasRealFilePicker()` (нативный метод канала
  `com.leadaxe.lxbox/utils`, реализация в
  [`MainActivity.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt)):
  `queryIntentActivities(OPEN_DOCUMENT)` и отбрасываем кандидатов, чьё имя
  пакета содержит `frameworkpackagestubs`. Пусто → `PickNoPicker`, пикер
  вообще не запускается (заглушка даже не мигает тостом). Канал недоступен
  → `true` (не запрещаем пик там, где не смогли проверить);
- `PlatformException` с `code == 'invalid_format_type'` → `PickNoPicker`
  (устройство вообще без обработчика — страховка второго уровня);
- `result == null` / пустой список → `PickCancelled` (не ошибка, молчим);
- прочее → `PickFailed(error)`.

Матч по подстроке, а не по полному имени: пакет-заглушка различается между
Android TV и Google TV сборками.

Все **8** мест вызова переведены на обёртку. Текст подсказки — ключ
`ErrKey.noFileManager` в [`ui_msg.dart`](../../../app/lib/models/ui_msg.dart)
(ленивый рендер, §285), перевод — в `assets/l10n/ru/ui.json`:

> No file manager on this device. Paste from the clipboard or add by URL instead.

Контроллеры, хранящие `UiMsg` в состоянии, кладут `ErrMsg(ErrKey.noFileManager)`
напрямую; экраны со снекбаром зовут `pickProblemText`.

Отдельно: в [`config_io.dart`](../../../app/lib/controllers/home_controller/config_io.dart)
`readFromFile` больше не отправляет pick-ошибку в общий `catch` →
«File error: …», а различает исходы явно.

### C. D-pad фокус

Скоуп — путь «запустить VPN + импортировать конфиг».
В [`home_controls.dart`](../../../app/lib/screens/home/widgets/home_controls.dart):

- главная кнопка Start/Stop (`FilledButton.icon`) получает `autofocus: true`
  — при открытии экрана фокус стоит на главном действии, первое нажатие
  пульта попадает в цель;
- кнопка масс-пинга: `GestureDetector` → `InkWell`. У `GestureDetector`
  **нет фокусного узла** — D-pad такую кнопку просто пропускает, до неё
  нельзя добраться с пульта в принципе. `InkWell` фокусируется и
  подсвечивается; `onTap`/`onLongPress` не меняются.

Остальные `GestureDetector`-элементы (`app_banner`, `traffic_bar`,
`nodes_header`, иконка support-ссылки в тайле подписки) — вне пути
подключения, их владельцы (`ListTile` и т.п.) фокусируются сами. Не
трогаем: правка ради правки на не-TV устройствах ничего не даёт.

Штатный Flutter-traversal (стрелки двигают фокус, центральная кнопка =
Enter) работает без дополнительного кода — `FocusTraversalGroup` не
понадобился.

## Приёмка

Стенд device-verification: **эмулятор Android TV, API 31, arm64**
(`system-images;android-31;android-tv;arm64-v8a`, AVD `LxBox_TV31`,
device-профиль `tv_1080p`). API 25 взять не вышло: TV-образ 25 существует
только под x86, а эмулятор на Apple Silicon его не запускает —
`FATAL | Avd's CPU Architecture 'x86' is not supported by the QEMU2
emulator on aarch64 host`. Проверяемые свойства (отсутствие DocumentsUI,
D-pad, leanback-лаунчер) — свойства TV-образа, а не версии API.

| # | Проверка | Статус |
|---|---|---|
| 1 | `uses-feature` (обе, `required="false"`) + `LEANBACK_LAUNCHER` в merged-манифесте | ✅ грепом по итоговому XML |
| 2 | `flutter analyze` — весь проект | ✅ No issues found |
| 3 | `flutter test` | ✅ 2937 passed |
| 4 | 4 l10n-чекера с `--strict` | ✅ 0 failures / 0 warnings |
| 5 | **L×Box в лаунчере Android TV** | ✅ DEVICE-VERIFIED — виден в «Select app» с иконкой |
| 6 | Приложение запускается и рисует UI на TV | ✅ DEVICE-VERIFIED — экран «Add a server» |
| 7 | **Импорт без пикера → подсказка про буфер/URL** | ✅ DEVICE-VERIFIED — снекбар на экране; в logcat `[pick] no real file manager (TV stub only)`, заглушка НЕ запускается |
| 8 | На телефоне пикер не сломан | ✅ обработчик `com.google.android.documentsui` (CPH2411 + эмулятор API 34) → `hasRealFilePicker`=true, путь прежний |
| 9 | С пульта достижимы Start / масс-пинг | ⏳ DEVICE-PENDING |
| 10 | Поведение на реальном Android 7.1.1 | ⏳ PENDING — у пользователя 4PDA |

Пункт 9 не проверен: на TV-эмуляторе тест шёл тапами (`input tap`), а не
D-pad-навигацией. Пункт 10 непроверяем в принципе на доступном стенде —
специфика 7.1.1 (старый trust store, `fixAndroidStack`, поведение
VPN-стека на N_MR1) требует реального устройства.

Замечание вне скоупа, замечено при проверке: на 1920×1080 UI рисуется
узкой колонкой по центру (вёрстка под телефонный портрет). Не блокирует,
но на TV выглядит непривычно — кандидат в отдельную таску.

## Docs to update

- [`CHANGELOG.md`](../../../CHANGELOG.md) — Unreleased: TV-совместимость,
  подсказка при отсутствии файлового менеджера.
- [`docs/ARCHITECTURE.md`](../../ARCHITECTURE.md) → Supported platforms —
  строка про Android TV: best-effort, D-pad, без пикера.
