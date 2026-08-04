# §375 — QR-сканер: импорт узла/подписки с камеры

## Контекст

В меню ⋮ экрана подписок есть пункт «Scan QR code»
([`subscriptions_screen.dart:465`](../../../app/lib/screens/subscriptions_screen.dart)),
но обработчик — заглушка:

```dart
Future<void> _scanQrCode() async {
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(getLocalText.s("QR scanner coming soon"))),
    );
  }
}
```

QR — основной способ раздачи конфигов у провайдеров (ссылка в виде кода на
странице панели, скрин в чате поддержки). Сейчас юзеру приходится
распознавать код сторонним приложением и вставлять из буфера.

Пайплайн импорта под QR **уже написан**, недостаёт только источника строки:

| Слой | Состояние |
|---|---|
| [`QrSource`](../../../app/lib/services/subscription/sources.dart) (`sources.dart:63`) | ✅ есть, обрабатывается в `parseFromSource` (`sources.dart:256`) |
| Тест `QrSource with single URI → one node` ([`sources_test.dart:68`](../../../app/test/subscription/sources_test.dart)) | ✅ зелёный |
| `UserSource.qr` ([`server_list.dart:368`](../../../app/lib/models/server_list.dart)) | ⚠️ объявлен, **никем не присваивается** — все add-пути ставят `paste` |
| Экран камеры | ❌ отсутствует |

`UserSource.qr` в коде помечен как «незавершённый задел» — значение
сохраняется при десериализации (`server_list.dart:425`), но записать его
сейчас неоткуда.

Прецедент по недоступности системной подсистемы — [§372](372-android-tv-support.md):
на Android TV нет DocumentsUI, и вместо технической ошибки показывается
подсказка с рабочей альтернативой. Здесь ровно та же форма проблемы —
на TV нет камеры.

## Root cause

Не баг — незаконченная фича. Заглушка `_scanQrCode` в дереве с первых
версий экрана подписок; UI-пункт добавлен авансом вместе с `QrSource` и
`UserSource.qr`, а плагин камеры так и не подключён (в
[`pubspec.yaml`](../../../app/pubspec.yaml) зависимости на сканер нет).

## Цели

- Пункт «Scan QR code» открывает камеру, распознаёт код, и результат
  уходит в тот же `addFromInput`, что paste/file — с confirm-диалогом.
- Узел, добавленный сканером, помечается `UserSource.qr` (задел
  дорабатывается до рабочего состояния, а не остаётся мёртвым).
- На устройстве без камеры (Android TV) пункт **скрыт**, а не показывает
  неработающий сканер.

## Нецели

- **Распознавание QR из файла-картинки** (скрин из галереи) — решением
  юзера в скоуп не входит. Только живая камера.
- Не генерируем QR (шаринг своего узла кодом) — отдельная тема.
- Не добавляем сканер на другие экраны (config-экран, детали ноды,
  папки): точка входа одна — меню ⋮ подписок, там же где paste/file.
- Не поддерживаем пакетный режим (несколько кодов подряд без выхода):
  один код — один результат — закрытие экрана.
- Не трогаем 8 мест `pickFileSafely` (§372) — QR идёт своим путём.

## Что меняется

### A. Зависимость

[`pubspec.yaml`](../../../app/pubspec.yaml):

```yaml
  mobile_scanner: ^7.1.2   # §375 — QR-сканер (ML Kit barcode на Android)
```

Выбор: `mobile_scanner` — единственный живой Flutter-плагин сканера с
поддержкой актуального Android-таргета (`qr_code_scanner` заброшен,
использует устаревший `AndroidView`-путь и не собирается на новых AGP).

Оговорка по весу: плагин тянет ML Kit barcode-scanning. Замерить дельту
размера APK **до** и **после** (`--split-per-abi`, arm64) и записать в
приёмку; если дельта неприемлема — рассмотреть `unbundled`-вариант ML Kit
(модель докачивается Play Services), но тогда на устройствах без GMS
сканер не заработает и это нужно учесть в гейте (см. C).

### B. Разрешение камеры

[`AndroidManifest.xml`](../../../app/android/app/src/main/AndroidManifest.xml):

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-feature android:name="android.hardware.camera" android:required="false" />
<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
```

`required="false"` обязателен в обоих случаях: иначе приложение станет
формально несовместимым с устройствами без камеры — а §372 явно
декларирует Android TV как поддерживаемый (best-effort) таргет.

Runtime-запрос: `CAMERA` — dangerous permission на всех поддерживаемых API
(minSdk 24), запрашивается всегда. Плагин `mobile_scanner` запрашивает
разрешение сам при старте контроллера; отдельный проброс через
`PermissionUtils` не нужен, но исход «отказано» обрабатывается явно
(см. D — `ScanDenied`).

### C. Гейт доступности — по образцу §372

Новый метод канала `com.leadaxe.lxbox/utils`, реализация в
[`MainActivity.kt`](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt)
рядом с `hasRealFilePicker` (строка 291):

```kotlin
private fun hasCamera(): Boolean =
    packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
```

`FEATURE_CAMERA_ANY` (API 17+) — покрывает и заднюю, и фронтальную, и
внешнюю USB-камеру. На Android TV возвращает false, на приставке с
подключённой веб-камерой — true, и сканер там действительно работает.

Dart-обёртка в [`url_launcher.dart`](../../../app/lib/services/url_launcher.dart)
рядом с `hasRealFilePicker` (строка 43):

```dart
/// §375 — есть ли на устройстве камера. false на Android TV.
/// При недоступности канала возвращает true — не прячем пункт там, где
/// не смогли проверить (телефон без камеры практически не встречается).
static Future<bool> hasCamera() async { ... }
```

Фолбэк `true` при сбое канала — та же логика, что у `hasRealFilePicker`:
не запрещаем действие из-за неудавшейся проверки.

**Отличие от §372 по UX:** там пункт остаётся видимым и показывает
подсказку с альтернативой; здесь пункт **скрывается**. Причина — у
импорта из файла есть равноценная альтернатива в том же меню (буфер,
URL), и подсказка ведёт юзера к ней; у сканирования альтернативы нет
вовсе, и пункт, который всегда отвечает «нельзя», — мусор в меню. Решение
юзера, зафиксировано.

Меню в [`subscriptions_screen.dart:454-465`](../../../app/lib/screens/subscriptions_screen.dart)
строится синхронно в `itemBuilder`, а проверка асинхронная ⇒ результат
кэшируется в `State` (`bool? _hasCamera`), запрашивается в `initState`,
пункт добавляется условно:

```dart
if (_hasCamera ?? true)
  PopupMenuItem(value: 'qr', child: Text(getLocalText.s("Scan QR code"))),
```

До ответа канала — показываем (мгновенный `hasSystemFeature` отвечает
задолго до открытия меню; на TV первый показ меню теоретически может
успеть до ответа, но повторный уже без пункта).

### D. Экран сканера

Новый файл [`app/lib/screens/qr_scan_screen.dart`](../../../app/lib/screens/qr_scan_screen.dart) —
полноэкранный `Scaffold` с превью камеры, возвращающий результат через
`Navigator.pop`.

Контракт — sealed-исходы, по образцу `PickOutcome` из
[`file_import.dart`](../../../app/lib/services/file_import.dart):

```dart
sealed class ScanOutcome {}
class ScannedCode extends ScanOutcome { final String value; }
class ScanCancelled extends ScanOutcome {}   // юзер нажал «назад» — молчим
class ScanDenied extends ScanOutcome {}      // отказано в доступе к камере
class ScanFailed extends ScanOutcome { final Object error; }
```

Разбор исходов (`String? scanProblemText(ScanOutcome)`) — там же, зеркально
`pickProblemText`: null для `ScannedCode`/`ScanCancelled`, тексты для
остальных.

Поведение экрана:

- первый распознанный код закрывает экран (`_handled`-флаг против
  повторных срабатываний детектора — стрим отдаёт кадры пачками);
- контроллер `MobileScannerController(formats: [BarcodeFormat.qrCode])` —
  сужаем до QR: не ловим случайные штрихкоды и EAN с окружения;
- `dispose()` контроллера обязателен — иначе камера остаётся занятой
  после ухода с экрана;
- в AppBar — кнопка фонарика (`toggleTorch`); на устройствах без вспышки
  плагин отвечает ошибкой, кнопку прячем по `torchState`.

### E. Подключение к импорту

[`subscriptions_screen.dart:261`](../../../app/lib/screens/subscriptions_screen.dart) —
`_scanQrCode` перестаёт быть заглушкой:

```
push(QrScanScreen) → ScanOutcome
  ├─ ScannedCode(value) → тот же путь, что _importFromClipboard:
  │     analyzeInput → showUnknownFormatDialog / showConfirmAddDialog
  │     → subController.addFromInput(value, origin: UserSource.qr)
  │     → _regenerateAndSave()
  ├─ ScanCancelled → выход молча
  └─ ScanDenied / ScanFailed → снекбар scanProblemText
```

Ключевой инвариант: **сканер не добавляет узел сам** — он только
поставляет строку в существующий разбор. Confirm-диалог с разбором
формата (`showConfirmAddDialog`) остаётся: юзер видит, что именно приехало
в коде, до записи в конфиг. QR — недоверенный ввод из внешнего мира,
подтверждение обязательно.

### F. `UserSource.qr` — дорабатываем задел

`addFromInput` в [`subscription_controller.dart`](../../../app/lib/controllers/subscription_controller.dart)
сейчас жёстко проставляет `origin: UserSource.paste` в 7 местах
(строки 564, 638, 682, 754, 777, 797, 891). Добавляется необязательный
параметр `UserSource origin = UserSource.paste` — дефолт сохраняет
поведение всех существующих вызовов, QR-путь передаёт `UserSource.qr`.

Комментарий в [`server_list.dart:365-367`](../../../app/lib/models/server_list.dart)
про «незавершённый задел» — обновить: `qr` теперь присваивается.

`QrSource` из [`sources.dart:63`](../../../app/lib/services/subscription/sources.dart)
на этом пути **не используется**: `addFromInput` работает со строкой и
внутри собирает `InlineSource`. Оставляем как есть — переписывать
add-путь ради семантически более точного source-типа не стоит, а тест на
`QrSource` продолжает покрывать сам парсинг.

### G. Строки (§279/§285)

Новые ключи (английский текст = ключ), перевод — в
[`assets/l10n/ru/ui.json`](../../../app/assets/l10n/ru/ui.json):

| Ключ | RU |
|---|---|
| `Scan QR code` | уже есть (пункт меню) |
| `Point the camera at a QR code` | Наведите камеру на QR-код |
| `Camera access denied` | Нет доступа к камере |
| `Camera error: %s` | Ошибка камеры: %s |

Удаляется ключ `QR scanner coming soon` — вместе со строкой в ru-словаре
(иначе l10n-чекер `--strict` даст orphan).

Строка `«Scan QR code»` в
[`subscriptions_empty_state.dart:45`](../../../app/lib/screens/subscriptions_screen/widgets/subscriptions_empty_state.dart)
теперь не врёт — правки не требует.

## Приёмка

Стенд: телефон **CPH2411** (камера есть) + эмулятор **Android TV API 31
arm64** (`LxBox_TV31`, стенд §372 — камеры нет).

| # | Проверка | Статус |
|---|---|---|
| 1 | `flutter analyze` — весь проект (не только `lib/`) | ✅ No issues found |
| 2 | `flutter test` | ✅ 2937 passed |
| 3 | 4 l10n-чекера с `--strict` — 0 failures / 0 warnings | ✅ 0/0, orphan 0 |
| 4 | Дельта размера APK от `mobile_scanner` (arm64, `--split-per-abi`) записана | ✅ **+3.76 МБ** (34.62 → 38.38) |
| 5 | Сканирование `vless://`-кода → confirm-диалог → узел в списке | ✅ DEVICE-VERIFIED |
| 6 | Сканирование кода с URL подписки → добавлена подписка, не узел | ⏳ PENDING |
| 7 | Отказ в разрешении камеры → снекбар, не краш и не тишина | ⏳ PENDING |
| 8 | Уход с экрана назад → камера освобождена (нет утечки: индикатор камеры гаснет, повторный вход работает) | ⏳ PENDING |
| 9 | Мусорный QR (текст «hello») → `showUnknownFormatDialog`, конфиг не тронут | ⏳ PENDING |
| 10 | **Android TV: пункта «Scan QR code» в меню ⋮ нет** | ⏳ PENDING |
| 11 | На TV импорт из файла/буфера по-прежнему работает как в §372 | ⏳ PENDING |
| 12 | `origin` добавленного узла — `qr` (проверка через Debug API `/state`) | ⏳ PENDING |

Замер по п.4 — сборка `--split-per-abi` arm64 до и после добавления плагина
на одном и том же коммите и одном `libbox.aar`. Состав прироста: нативный
`libbarhopper_v3.so` 4.95 МБ + три `.tflite`-модели 0.88 МБ + `classes.dex`
1.90 → 3.79 МБ (CameraX и ML Kit-обвязка); в APK всё это лежит сжатым, отсюда
итог меньше суммы. Для контекста: `libbox.so` — 70 МБ несжатых, ядро
доминирует. Bundled-вариант ML Kit выбран сознательно: unbundled даёт ~0.5 МБ,
но требует Play Services и не работает на деGoogled-прошивках и у части
F-Droid-аудитории.

Пункт 5 проверен на CPH2411 (release-сборка, versionCode 3606): скан
`vless://`-кода с REALITY → диалог подтверждения → узел в списке.

Пункты 6–12 на устройстве не прогонялись — статус честный `PENDING`, не
«вероятно работает». Пункты 10/11 требуют TV-эмулятора (стенд §372).

## Docs to update

- [`CHANGELOG.md`](../../../CHANGELOG.md) — Unreleased: QR-сканер для
  импорта узлов и подписок; на устройствах без камеры пункт скрыт.
- [`docs/USER_GUIDE.md`](../../USER_GUIDE.md) +
  [`docs/USER_GUIDE_RU.md`](../../USER_GUIDE_RU.md) — способы добавления
  сервера: строка про QR.
- [`docs/ARCHITECTURE.md`](../../ARCHITECTURE.md) → Supported platforms —
  дополнить строку про Android TV: сканера нет (нет камеры).
- [`docs/l10n.md`](../../l10n.md) — правки не требуются (ключи по общему
  правилу).
