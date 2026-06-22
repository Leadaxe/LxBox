# §156 — UI English-only: вычистка кириллицы из интерфейса и API

**Статус:** Done (2026-06-22)
**Тип:** task (локализация существующего поведения, без новой фичи)

## Проблема

Интерфейс приложения — английский, но в код просочились русские строки,
видимые пользователю. Триггер — недавняя автоматизация (§047): раздел
App Settings → Automation был целиком на русском, хотя остальной UI английский.

## Решение

Аудит всей кодовой базы (Dart `app/lib`, Kotlin `app/android`) на кириллицу
вне комментариев. Правило: **в комментариях кириллица допускается** (внутренняя
тех-документация), в **UI-строках и API — только английский**.

### Результат аудита

- **API чист**: ни одного intent-action, extras-ключа, event-ключа,
  storage-ключа, enum-значения, имени method-channel, строки в `strings.xml`
  или `AndroidManifest.xml` с кириллицей. Обратная совместимость НЕ затронута —
  переименовывать API не пришлось.
- Переведено на английский всё видимое пользователю + dev-facing (Debug API).

## Затронутые файлы

UI (видно пользователю):
- `app/lib/screens/app_settings_screen/widgets/automation_tab.dart` — весь раздел
  Automation (диалоги, кнопки, заголовки секций, тоглы, подсказки, snackbar)
- `app/lib/screens/home/filter_widgets.dart` — tooltip'ы negate-тоглов
- `app/lib/screens/home/widgets/filter_panel.dart` — detour-tooltip'ы, hint'ы
  «No protocols» / «No subscriptions»
- `app/lib/screens/home/home_dialogs.dart` — кнопки «Don't show again» / «Later»
- `app/lib/screens/debug_screen.dart` — tooltip кнопки share-dump
- `app/lib/screens/per_app_trace_tab/trace_dialogs.dart` — help-диалог (был
  смешанный EN+RU)
- `app/lib/screens/node_settings_screen.dart` — info-текст AWG↔WireGuard + лог-строка
- `app/lib/screens/live_events_tab/unattributed_banner.dart` — текст баннера
- `app/lib/models/parser_config.dart` — текст ошибки `SelectableRule` (виден юзеру)

Dev-facing (Debug API, localhost / только разработчик):
- `app/lib/services/debug/handlers/help.dart` — `_capabilityText` + `_capabilityJson`
- `app/lib/services/debug/handlers/config.dart` — `note`-поля JSON-ответов

Native logcat:
- `app/android/.../vpn/BoxService.kt` — 2 Log-сообщения
- `app/android/.../vpn/VpnPlugin.kt` — 1 Log-сообщение

## Намеренно оставлено

- **`app/lib/services/parse_hints.dart:63`** — кириллица внутри regex-класса
  `[A-Za-zА-Яа-яЁё...]`. Это функциональный паттерн `_looksLikePlainMessage`:
  распознаёт случай, когда сервер вернул человекочитаемое сообщение на русском
  (например «Подписка истекла») вместо подписки. Удаление сломало бы детекцию
  русских сообщений провайдеров. НЕ UI и НЕ API.
- **Комментарии** (`//`, `/* */`, `///`, KDoc) — оставлены на русском как
  внутренняя тех-документация.

## Верификация

- `flutter analyze` по всем 11 затронутым Dart-файлам → `No issues found!`
- Повторный скан кириллицы вне комментариев → осталась 1 строка
  (намеренный regex в `parse_hints.dart`).
