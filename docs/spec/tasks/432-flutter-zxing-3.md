# 432 — flutter_zxing 3.0: zxing-cpp 2.3.0 → 3.1.1

| Поле | Значение |
|------|----------|
| Статус | In progress |
| Дата старта | 2026-09-13 |
| Триггер | Отложено из [§431](431-file-picker-12-plus-plugins-major-bump.md): смена нативного движка не смешивается с бампом file_picker, чтобы регрессию не спутать |
| Связанные | [§382](382-foss-qr-scanner.md) (сканер на flutter_zxing, дефолты ReaderWidget), [§375](375-qr-scanner-import.md) (контракт исходов), [§380](380-naive-and-reproducible-builds.md) (F-Droid, NDK) |

## Что меняется

`flutter_zxing` 2.4.0 → 3.0.1. Dart-API (`ReaderWidget`, `Format`, `Code`,
`DecodeParams`) не менялся — [qr_scan_screen.dart](../../../app/lib/screens/qr_scan_screen.dart)
не трогается. Меняется нативный zxing-cpp: v2.3.0 → v3.1.1 (633 коммита).

| Изменение апстрима | Для нас |
|---|---|
| `Format.qrCode` теперь матчит и варианты: Micro QR (`Format.microQRCode`), rMQR (`Format.rmqrCode`) | Принимаем: содержимое всё равно уходит в `addFromInput`, который сам разбирает формат; фильтр по `Code.format` не вводим |
| UPC-A/UPC-E → 13 цифр | Не касается: сканируем только QR |
| Снят пин NDK 27.0.12077973 (zxing-cpp 3 собирается NDK 27/28/29) | Закрывает хвост §382 «zxing тянет NDK 27 против r28c в §380»: плагин теперь берёт `flutter.ndkVersion` |
| Выпилен `isolate_manager` (и discontinued `isolate_contactor`) из зависимостей | Две строки из `pub outdated` уходят сами |
| Детект: лучше QR v1 и несколько мелких кодов в кадре, +10–40% скорости на ARM | Профит без правок |
| `DecodeParams.maxNumberOfSymbols` клампится 1–255 | Не используем |

Дефолты §382 (`cropPercent 0.9`, `tryHarder`, `tryDownscale`, `scanDelay 300`)
остаются — они про площадь кадра и частоту попыток, не про версию движка.

## Что НЕ делается

| Не делается | Почему |
|---|---|
| Фильтр `code.format == Format.qrCode` | Micro QR/rMQR с ссылкой — такой же валидный ввод; отсекать нечего |
| Новые форматы (`dxFilmEdge`, `dataBarLimited`, `telepen`, `microPdf417`) | Нецель §375/§382: только QR |
| Распознавание из картинки | Нецель §375, остаётся |

## Проверка

- `flutter analyze`, `flutter test`, APK через `scripts/build-local-apk.sh`
  (pubspec закоммичен ДО сборки — грабля §431).
- Device: сканирование QR с vless-ссылкой (кириллическое имя узла) — узел
  появляется в Servers. На AVD камера — виртуальная сцена; QR подсовывается
  постером (`emulator/resources/poster.png`, бэкап рядом). Реальная камера —
  CPH2411, когда будет под рукой.
- F-Droid: сборка на buildserver с NDK из `flutter.ndkVersion` — проверится
  ботом на следующем теге; в рецепте fdroiddata пина NDK для zxing нет.

## Docs to update

- `CHANGELOG.md` → Unreleased.
