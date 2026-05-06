# 041 — User error format helper

| Поле | Значение |
|------|----------|
| Статус | Implementing |
| Дата | 2026-05-07 |
| Связанные spec'ы | [`014 dns settings`](../features/014%20dns%20settings/spec.md), [`040 per-group ping settings`](./040-per-group-ping-test-settings.md) |
| Затронутые файлы | `app/lib/services/error_format.dart` (new), `app/lib/controllers/home_controller.dart`, `app/lib/screens/{node_settings,dns_settings,backup,config,debug}_screen.dart`, тесты |

## Цель

Заменить «голые» exception toString'ы в user-visible сообщениях (red banner / snackbar / debug log) на читаемый текст. Сейчас в UI протекает технический жаргон Dart-вых exception'ов, например:

| Exception | Сейчас в banner | Хотим |
|---|---|---|
| `TimeoutException(Duration(seconds:10))` | `TimeoutException after 0:00:10.000000: Future not completed` | `timeout 10s` |
| `SocketException("Connection refused", ...)` | `SocketException: Connection refused (OS Error: Connection refused, errno = 61), address = 127.0.0.1, port = 7842` | `Connection refused` |
| `FileSystemException("Cannot open", ...)` | `FileSystemException: Cannot open file, path = '/p' (OS Error: No such file or directory, errno = 2)` | `No such file or directory` |
| `PlatformException(start_failed, ...)` | `PlatformException(start_failed, vpn_service.prepare returned false, null, null)` | `vpn_service.prepare returned false` |
| `FormatException("Unexpected character", ...)` | `FormatException: Unexpected character (at character 5)\n{...}\n^` | `Unexpected character` |

## Дизайн

### `lib/services/error_format.dart` (new)

```dart
/// Превращает Dart exception в человекочитаемое сообщение для UI banner /
/// snackbar / debug log. Скрывает технические артефакты toString'ов
/// (`Future not completed`, `errno = N`, длинные address кортежи, и т.п.).
///
/// Не переводит локализацию — это формат, не i18n. Если потребуется i18n —
/// отдельный layer поверх с lookup в .arb по типу exception'а.
String formatUserError(Object e) {
  if (e is TimeoutException) {
    final ms = e.duration?.inMilliseconds ?? 0;
    final s = (ms / 1000).toStringAsFixed(ms % 1000 == 0 ? 0 : 1);
    return 'timeout ${s}s';
  }
  if (e is FileSystemException) return e.osError?.message ?? e.message;
  if (e is SocketException) return e.osError?.message ?? e.message;
  if (e is HttpException) return e.message;
  if (e is FormatException) return e.message;
  if (e is ClashHttpException) return 'HTTP ${e.status}';
  if (e is PlatformException) return e.message ?? 'platform error';
  // Fallback — strip "Exception: " prefix, truncate.
  var s = e.toString();
  if (s.startsWith('Exception: ')) s = s.substring('Exception: '.length);
  return s.length > 120 ? '${s.substring(0, 117)}…' : s;
}
```

### Применение

7 user-visible мест в `home_controller.dart`:

| Строка | Было | Станет |
|---|---|---|
| 441 | `'Failed to read file: $e'` | `'Failed to read file: ${formatUserError(e)}'` |
| 466 | `'File error: $e'` | `'File error: ${formatUserError(e)}'` |
| 537 | `'$e'` (start VPN) | `formatUserError(e)` |
| 552 | `'$e'` (stop VPN) | `formatUserError(e)` |
| 622 | `'$e'` (reconnect) | `formatUserError(e)` |
| 667 | `'Clash API: $e'` | `'Clash API: ${formatUserError(e)}'` |
| 707 | `'Switch failed: $e'` | `'Switch failed: ${formatUserError(e)}'` |

Snackbar'ы в screens (опционально — FormatException обычно сам по себе понятен, низкий риск):

| Файл | Строка | Замена |
|---|---|---|
| `node_settings_screen.dart` | 114 | `'Invalid JSON: ${formatUserError(e)}'` |
| `dns_settings_screen.dart` | 297, 382 | то же |
| `backup_screen.dart` | 104, 181 | `'Export failed: ${formatUserError(e)}'` / `'Import failed: ...'` |
| `config_screen.dart` | 59, 105 | то же |
| `debug_screen.dart` | 91, 114 | `'Share failed: ${formatUserError(e)}'` |

### Refactor `_formatProbeError` (§040)

В `home_controller.dart` уже есть `_formatProbeError(target, url, e)` для URLTest ошибок — переписать через `formatUserError(e)` чтобы не дублировать ветви:

```dart
static String _formatProbeError(String target, String url, Object e) {
  final route = _routeLabel(target, url);
  return '$route — ${formatUserError(e)}';
}
```

Результат identical для существующих случаев:
- `direct-out → ya.ru — timeout 5.8s` (TimeoutException)
- `direct-out → ya.ru — HTTP 503` (ClashHttpException)
- `direct-out → ya.ru — connection refused` (SocketException)

## Acceptance

- [ ] **`formatUserError` для всех типов** — TimeoutException / SocketException / FileSystemException / HttpException / FormatException / ClashHttpException / PlatformException / generic Object. Тесты на каждую ветвь.
- [ ] **Edge cases:** TimeoutException с `duration=null` → `timeout 0s` (не crash); FileSystemException без `osError` → fallback на `.message`; very long Object.toString → truncate до 120 chars + `…`.
- [ ] **Применено в `home_controller.dart`:** 7 user-visible callsite'ов используют `formatUserError`.
- [ ] **Применено в screens** (опционально, но желательно): node_settings, dns_settings, backup, config, debug — snackbar'ы.
- [ ] **`_formatProbeError` рефакторнут** через общий helper, output не изменился (regression-test).
- [ ] **Banner показывает короткие сообщения** — реальный smoke-test: `start VPN` пока tunnel занят → видим понятный message без `PlatformException(...)`.

## Risks

| Риск | Mitigation |
|---|---|
| Helper «съест» полезную информацию (например `errno = 13` для permission denied) | Helper берёт `osError.message` для FileSystemException/SocketException — там обычно текстовое описание (`Permission denied`, `Connection refused`). Для глубокой диагностики юзер всё равно идёт в debug log где сырой `$e` сохраняется. |
| Кто-то добавит новый тип exception, helper упадёт на fallback `toString` | Fallback корректный — strip + truncate. Просто менее красиво. Если станет видно — добавим case. |
| i18n потребуется потом → переделывать формат | Helper изолирован; localization можно ввести через wrapper `formatUserErrorL10n(e, AppLocalizations)` без изменения callsite'ов. |
| Тестирование PlatformException требует mock'а Flutter platform-channel | Helper проверяет `e is PlatformException` через type check — unit-тест может создать `PlatformException(code: '...', message: '...')` напрямую без channel'а. |

## План имплементации

1. Создать `lib/services/error_format.dart` с `formatUserError`.
2. Тесты `test/services/error_format_test.dart` — все ветви + edge cases.
3. Заменить 7 user-visible spots в `home_controller.dart`.
4. Заменить snackbar'ы в screens (5 файлов, ~10 callsite'ов).
5. Refactor `_formatProbeError` через общий helper.
6. `flutter analyze` + `flutter test` + APK + smoke (вручную trigger'нуть start VPN error / file pick fail / Invalid JSON paste).
