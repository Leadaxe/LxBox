# §382 — QR-сканер на FOSS-декодере: замена `mobile_scanner`

## Контекст

[§375](375-qr-scanner-import.md) подключил QR-сканер на `mobile_scanner`,
который распознаёт коды через **ML Kit barcode scanning** — проприетарный
компонент Google. На момент §375 это было осознанным выбором: замерена
дельта APK (+3.76 МБ), bundled-вариант предпочтён unbundled ради работы на
деGoogled-прошивках.

[§380](380-naive-and-reproducible-builds.md) меняет требования. Публикация
в F-Droid ставит два условия, которых у §375 не было:

| Требование | ML Kit |
|---|---|
| Только свободные компоненты в сборке | ❌ проприетарный блоб `libbarhopper_v3.so` + `.tflite`-модели |
| Побитовая воспроизводимость APK | ❌ артефакты не под нашим контролем |

Второе — жёстче первого. Воспроизводимость означает, что тот же исходник
даёт байт-в-байт тот же APK; предсобранные бинарные модели ML Kit этой
гарантии не дают в принципе.

Параллельно [§380](380-naive-and-reproducible-builds.md) фиксирует падение
сборки на buildserver F-Droid. Прогон 05.08 показал причину:

```
A problem occurred configuring project ':mobile_scanner'.
> Failed to notify project evaluation listener.
   > java.lang.NullPointerException (no error message)
```

Падает конфигурация именно этого подпроекта, и ровно после того, как сканер
fdroidserver вырезал из `mobile_scanner-7.4.0/android/build.gradle` две
зависимости:

```
Removing usual suspect 'com.google.android.gms(...)'
Removing usual suspect 'com.google.mlkit'
```

Механизм виден в исходнике плагина, строка 32 его `build.gradle`:

```groovy
def agpMajor = Version.ANDROID_GRADLE_PLUGIN_VERSION.tokenize('.')[0] as int
```

после вырезания `buildscript`-зависимостей `com.android.Version` не
резолвится ⇒ `null.tokenize()`.

⚠ **Класс NPE не назван** — Gradle без `--stacktrace` печатает голое
исключение без фрейма, а прогон с флагом на момент написания не завершился.
Связь «вырезали ML Kit → упала конфигурация `:mobile_scanner`» установлена
по логу; конкретная строка падения выведена из кода, а не предъявлена.

⚠ **Ложный след, стоивший времени:** после падения Gradle печатает блок
«Flutter Fix» про AGP 9 и `android.newDsl`. Это эвристическая подсказка,
выводимая после ЛЮБОГО падения Gradle, а не диагноз — **версии AGP в логе
нет вообще**. Диагностировать по ней нельзя.

Замена всё равно делается по требованию лицензионной чистоты и
воспроизводимости: ML Kit в F-Droid не пройдёт при любых настройках, даже
если бы сборка не падала.

## Root cause

Не баг. Смена внешних требований к сборке: §375 оптимизировал качество
распознавания, §380 требует свободного и воспроизводимого стека.

## Цели

- QR-сканер работает без единого проприетарного компонента.
- Фича сохранена целиком — контракт исходов, гейт по камере, путь импорта
  не меняются. Юзер не теряет функциональность.
- Один вариант сборки для всех каналов (Play/GitHub/F-Droid): единый код,
  единое поведение, единый APK. Flavors не вводятся.

## Нецели

- Не вводим build-flavors ради сохранения ML Kit в Play-сборке. Решение
  юзера: один вариант везде. Причина — расхождение сборок противоречит
  цели воспроизводимости и удваивает матрицу тестирования навсегда.
- Не меняем контракт `ScanOutcome`, гейт `hasCamera` (§375 C),
  подключение к `addFromInput` (§375 E), `UserSource.qr` (§375 F).
- Не расширяем набор форматов: только QR, как и было.
- Не добавляем распознавание из файла-картинки (нецель §375, остаётся) —
  встроенная в виджет кнопка галереи выключена явно.

## Выбор замены

Кандидаты рассмотрены по критериям §380 (свобода + воспроизводимость):

| Пакет | Лицензия | Декодер | Прецедент в fdroiddata | Вердикт |
|---|---|---|---|---|
| **`flutter_zxing` 2.3.0** | MIT | ZXing-**C++** через FFI | **38 приложений** | ✅ выбран |
| `qr_code_dart_scan` 0.12.1 | MIT | `zxing_lib` — чистый Dart, в изоляте | 0 | рассматривался, проигрывает |
| `zxing2` 0.2.4 + `camera` | BSD-3 | чистый Dart | 0 | камеру и YUV-конвертацию писать руками |
| `qr_code_scanner_plus` | — | нативный ZXing | — | ❌ форк семейства с историей поломок на новых AGP |

**Решающий критерий — проверенный прецедент.** `flutter_zxing` собирается
в F-Droid 38 раз (`business.braid.polycule`, `com.anywherelan.awl`,
`com.reloado.auth`, `eu.heili.wormhole` и др.). У чисто-Dart-кандидатов
прецедент нулевой, и читать этот ноль надо аккуратно: пакет попадает в
метаданные только когда требует вмешательства, поэтому «0» означает либо
«работает без правок», либо «никто не пробовал» — различить нельзя. Первый
прогон на buildserver'е стоит часы, и ставить их на неизвестность хуже, чем
заплатить известную цену.

**Известная цена — недетерминизм CMake-сборки.** Линкер вшивает уникальный
build-id, и рецепты F-Droid лечат это одной строкой в prebuild:

```
sed -i -e '1a add_link_options("LINKER:--build-id=none")' \
  $PUB_CACHE/hosted/pub.dev/flutter_zxing-*/*/CMakeLists.txt
```

Строка живёт **в рецепте fdroiddata, не в этом репозитории**. Glob со
звёздочкой написан ровно ради переживания обновлений пакета и в 38 рецептах
их пережил. Это единственный хвост сопровождения, который берёт на себя
таска.

**Побочные выигрыши против Dart-декодеров:**

- **Качество распознавания.** ZXing-C++ заметно сильнее Dart-порта — ближе
  к ML Kit. «Цена по качеству», которой пугала предыдущая редакция этой
  спеки, почти обнуляется.
- **Скорость.** Нативный декод против изолята — разница ощутима на живом
  потоке кадров, батарея тратится меньше.
- **Активность проекта.** 133 звезды, push 01.08.2026, MIT, не архивирован.

**Про CameraX.** Пакет тянет `camera` → `camera_android_camerax` —
нативная обвязка в сборке остаётся, полностью бездрайверной камеры на
Android не бывает. Для F-Droid это не проблема: критерий Inclusion Policy —
не «есть ли нативный код», а **«собирается ли всё из исходников и нет ли
проприетарных блобов»**. CameraX — AndroidX, Apache-2.0, лежит в Google
Maven, а Google Maven входит в allowlist политики.

Подтверждено фактом, а не рассуждением, с двух сторон:

- в логе сканера F-Droid на сборке с `mobile_scanner` вырезаны **только**
  `com.google.android.gms` и `com.google.mlkit`, тогда как
  `androidx.camera:camera-lifecycle` и `camera-camera2` остались на месте;
- `camera_android_camerax` присутствует в каталоге самостоятельно —
  `tech.lolli.toolbox`, `dev.linwood.butterfly`, `fr.onyx.lyon1`.

То есть заменяемый компонент — ровно ML Kit, и ничего сверх.

## Что меняется

### A. Зависимости

[`pubspec.yaml`](../../../app/pubspec.yaml):

```yaml
-  mobile_scanner: ^7.1.2  # §375 — QR-сканер (ML Kit barcode; +3.8 МБ к APK, arm64)
+  flutter_zxing: ^2.3.0   # §382 — QR-сканер (ZXing-C++ через FFI; §380 FOSS)
+  camera: ^0.12.0         # §382 — типы CameraController/CameraException в исходе сканера
```

`camera` объявляется **явно**, хотя приходит и транзитивно: экран
использует её типы в сигнатуре `_onControllerCreated`, а линтер
`depend_on_referenced_packages` справедливо требует объявить такое
использование. Констрейнт `^0.12.0` — та версия, которую и так резолвит
`flutter_zxing`; более низкий (`^0.11.0`) откатывал бы `camera` и
`camera_android_camerax` на старые ветки без нужды.

Транзитивно приходят `image_picker` (кнопка галереи виджета — выключаем,
см. D), `camera_android_camerax`, `camera_avfoundation` — все свободные.

### B. Манифест — правок не требует

[`AndroidManifest.xml`](../../../app/android/app/src/main/AndroidManifest.xml):
`CAMERA` + два `uses-feature required="false"` уже стоят (§375 B, строки
53–58). `camera` требует тех же разрешений, что `mobile_scanner`.

### C. Гейт `hasCamera` — не трогаем

§375 C (`FEATURE_CAMERA_ANY` через канал `utils`, скрытие пункта меню на
Android TV) работает поверх любого сканера. Изменений нет.

### D. Экран сканера — переписывается внутренность

[`qr_scan_screen.dart`](../../../app/lib/screens/qr_scan_screen.dart).
**Публичный контракт файла сохраняется полностью**: `QrScanScreen`,
`ScanOutcome` c четырьмя наследниками, `scanProblemText`. Вызывающий
([`subscriptions_screen.dart:281`](../../../app/lib/screens/subscriptions_screen.dart))
не меняется ни на строку.

Замена API (имена сверены по исходникам пакета, не по README — документация
`flutter_zxing` на pub.dev неполная):

| Было (`mobile_scanner`) | Стало (`flutter_zxing`) |
|---|---|
| `MobileScannerController(formats:)` | контроллер не нужен — виджет владеет камерой сам |
| `MobileScanner(controller:, onDetect:, errorBuilder:)` | `ReaderWidget(onScan:, onControllerCreated:, codeFormat:)` |
| `onDetect(BarcodeCapture)` → `capture.barcodes[].rawValue` | `onScan(Code)` → `code.text` (**nullable**) |
| `BarcodeFormat.qrCode` (enum) | `Format.qrCode` (int-битмаска) |
| `MobileScannerException.errorCode` (enum) | `onControllerCreated(controller, Exception?)` |
| кнопка фонарика в `AppBar` вручную | `showFlashlight` виджета (дефолт `true`) |
| `_controller.dispose()` в `dispose()` | виджет освобождает камеру сам |

Отличия поведения, которые заложены в реализацию:

- **`_handled`-флаг остаётся** — `onScan` вызывается на каждом
  распознанном кадре, как и `onDetect`. Защита от повторного `pop`
  закрытого экрана нужна ровно так же.
- **`code.text` nullable** — `Code` несёт `text`, `isValid`, `error`;
  пустое/`null` значение игнорируем и ждём следующий кадр, а не закрываем
  экран с пустым результатом.
- **Своего `dispose()` у экрана больше нет.** `ReaderWidget` держит
  `CameraController` внутри и освобождает его сам; ручной вызов только
  сломал бы его жизненный цикл. Грабля §375 «камера остаётся занятой»
  снимается конструкцией, а не кодом — но пунктом приёмки проверяется.
- **Кнопки виджета сужены** — `showGallery: false` (распознавание из
  файла — нецель §375), `showToggleCamera: false` (фронтальная камера для
  кода с чужого экрана бесполезна). Фонарик оставлен встроенный.
- **`tryInverted: false`** — инвертированные коды в дикой природе
  практически не встречаются, а лишний проход по каждому кадру жжёт
  батарею. `tryRotate` остаётся включённым (дефолт).
- **`scanDelay: 300 мс`** — дефолт пакета 1000 мс заметен как «тормозит».
  Нативный декод дешевле Dart-изолята, можно чаще.
- **Ключ `Torch` больше не используется** — фонарик рисует виджет своими
  иконками. Ключ остаётся в словаре (его использует другой экран); если
  бы он осиротел, `ui_check --strict` дал бы orphan — проверяется п. 5
  приёмки.

**Грабля — распознавание отказа в доступе.** `mobile_scanner` отдавал
типизированный `MobileScannerErrorCode.permissionDenied`; `flutter_zxing`
отдаёт исход инициализации в `onControllerCreated(controller, error)`, где
`error` — `Exception?`, при отказе это `CameraException` со **строковым**
кодом:

```dart
/// Коды `CameraException` от плагина `camera` при отказе в доступе.
/// На Android приходит только `CameraAccessDenied`, остальные два —
/// iOS-only. Неизвестный код трактуем как ScanFailed: лучше показать
/// текст ошибки, чем соврать про разрешения.
bool _isPermissionDenied(String code) =>
    code == 'CameraAccessDenied' ||
    code == 'CameraAccessDeniedWithoutPrompt' ||
    code == 'CameraAccessRestricted';
```

`onControllerCreated` вызывается и при успехе (`error == null`) — ранний
выход обязателен, иначе экран закроется сразу после старта камеры.

### E. Строки (§279/§285) — удаляется один ключ

Четыре ключа §375 G остаются как есть: `Scan QR code`,
`Point the camera at a QR code`, `Camera access denied`,
`Camera error: %s`. Новых не добавляется.

**`Torch` удаляется** из [`assets/l10n/ru/ui.json`](../../../app/assets/l10n/ru/ui.json).
Кнопку фонарика теперь рисует сам `ReaderWidget` своими иконками, ссылки на
ключ в коде не осталось, и `ui_check --strict` падает на нём orphan'ом
(проверено: `orphan: 1, warnings: 1 (strict: warnings are fatal)`). Ключ
использовался только экраном сканера — других мест нет.

### F. Тесты

Юнит-тестов у экрана нет (камера не тестируется в headless-среде), но
`flutter analyze` покрывает весь проект (не только `lib/` — грабля из
памяти), а `flutter test` ловит регрессии в остальном дереве.

## Приёмка

Стенд: эмулятор (запуск + smoke). Телефон CPH2411 и сборка на buildserver
F-Droid — **вне скоупа этой сессии по решению юзера**; релиз не выпускается
(параллельная работа с ядром).

| # | Проверка | Статус |
|---|---|---|
| 1 | `mobile_scanner` отсутствует в `pubspec.yaml` и `pubspec.lock` | ✅ |
| 2 | `flutter analyze` — весь проект | ✅ No issues found |
| 3 | `flutter test` — без регрессий к базовой линии | ✅ 2947 passed |
| 4 | 4 l10n-чекера с `--strict` — 0/0 | ✅ 0/0, orphan 0 |
| 5 | Ни одного упоминания ML Kit / `libbarhopper` в APK | ⏳ |
| 6 | Дельта размера APK (arm64, `--split-per-abi`) записана | ⏳ |
| 7 | APK устанавливается и запускается на эмуляторе | ⏳ |
| 8 | Экран сканера открывается, превью камеры живое | ⏳ |
| 9 | Распознавание `vless://`-кода → confirm-диалог → узел в списке | ⏳ DEVICE-PENDING |
| 10 | Отказ в разрешении камеры → снекбар `Camera access denied` | ⏳ DEVICE-PENDING |
| 11 | Уход назад → камера освобождена, повторный вход работает | ⏳ DEVICE-PENDING |
| 12 | Мусорный QR → `showUnknownFormatDialog`, конфиг не тронут | ⏳ DEVICE-PENDING |
| 13 | Android TV: пункта «Scan QR code» в меню нет (регрессия §375 C) | ⏳ DEVICE-PENDING |

Пункты 9–13 требуют физического устройства с камерой — эмулятор даёт
синтетический кадр, на котором QR не предъявить. Статус честный PENDING,
не «вероятно работает» (урок §375, где 7 из 12 пунктов остались PENDING).

## Docs to update

- [`CHANGELOG.md`](../../../CHANGELOG.md) — Unreleased: QR-сканер
  переведён на свободный декодер.
- [`380-naive-and-reproducible-builds.md`](380-naive-and-reproducible-builds.md) —
  ML Kit-блокер снят; в рецепт F-Droid добавить prebuild-строку
  `--build-id=none` для `flutter_zxing`.
- [`docs/FDROID.md`](../../FDROID.md) — там же: почему строка нужна и что
  проверять при обновлении пакета.
- [`375-qr-scanner-import.md`](375-qr-scanner-import.md) — врезка в
  раздел A: выбор `mobile_scanner` заменён, см. §382.
