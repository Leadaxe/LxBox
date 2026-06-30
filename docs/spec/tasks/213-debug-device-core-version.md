# §213 — Debug API `/device` отдаёт версию ядра

> **СТАТУС: РЕАЛИЗАЦИЯ.** Dart-only (один handler).

## Проблема

`GET /device` отдаёт `app_version`/`app_build`, но **не версию ядра** (libbox /
sing-box-lx). При диагностике рассинхрона «парсер эмитит rc.16-поле, а в APK
ядро rc.15» (XHTTP §127) пришлось выдирать версию из AAR-бинаря вручную. Версия
ядра должна быть в одном запросе рядом с версией приложения — это первое, что
нужно при разборе «конфиг падает на load: unknown field».

## Решение

В [device.dart](../../../app/lib/services/debug/handlers/device.dart) добавить в
JSON-ответ `core_version` — через уже существующий
`BoxVpnClient.getCoreVersion()` (обёртка над Go-side `Libbox.version()`).
Авторитетный источник: что реально вкомпилировано в установленный APK, а не пин
в `libbox.version`.

```dart
final coreVersion = await vpn.getCoreVersion().catchError((_) => '');
// ... в JsonResponse:
'core_version': coreVersion,
```

Формат `Libbox.version()` — строка вида `1.14.0-lx.1-rc.15` (или пустая на
timeout/ошибку — caller рендерит как `unknown`). app-версия уже есть
(`app_version`/`app_build`).

## Файлы

| Слой | Файл | Изменение |
|---|---|---|
| Dart | `services/debug/handlers/device.dart` | +`core_version` через getCoreVersion() |
| docs | `services/debug/handlers/help.dart` | дописать `core_version` в описание /device |

## Тесты

- Device: `GET /device` → JSON содержит `core_version` непустой (формат
  `1.14.0-lx.1-rc.N`).

## Связанные

- §031 Debug API. §127 XHTTP (где всплыл рассинхрон версий ядра).
