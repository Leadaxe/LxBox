# §632 — Подписи настроек расходились с поведением кода

| Поле | Значение |
|------|----------|
| Тип | Дефект |
| Статус | D (done), выпущено в v2.25.13 |
| Дата | 2026-10-12 |
| Связанные | §630 (тот же класс дефекта в Statistics), §051 (запись Wi-Fi), §090 (update-снек), §215 (сон в фоне), §220 (поворот), §413 (Debug API в Backup) |

## Проблема

Шесть подписей и подсказок в настройках описывали интерфейс или поведение,
которых в коде нет. Пользователь искал вкладку, пункт или кнопку по подсказке
и не находил, либо получал неверное ожидание о том, где хранится токен.

| Строка (было) | Где | Что в коде |
|---|---|---|
| «Visible in Debug → Core.» (Forward sing-box logs) | `diagnostics_tab.dart:281` | у Debug вкладки Log / Crashes / OOM / Profiling (`debug_screen.dart:136-139`); Core — фильтр на вкладке Log (`debug_screen.dart:253`) |
| Aggressive battery saving: «…stop until unlock» | `settings_screen.dart:678` | пауза снимается по `ACTION_SCREEN_ON`, не по разблокировке (`BoxService.kt:229-235`) |
| Home-screen shortcut: «choose "Toggle VPN"» | `general_tab.dart:132` | динамические ярлыки по состоянию: Stopped → Connect, Started → Disconnect, переходные → оба; только Android 11+ (`QuickShortcuts.kt:18-21, 46-55`) |
| Check for updates: «"View" opens the release page» | `general_tab.dart:140` | у сообщения кнопки Later / Ignore, тап по тексту открывает страницу обновления своего канала — релиз GitHub или страница стора (`home_dialogs.dart:185-200`, `install_source.dart:137`) |
| Auto-record Wi-Fi: «long-press chip → Remove» | `diagnostics_tab.dart:334` | у записи кнопка ✕ с подсказкой «Remove from history» (`wifi_saved_picker_sheet.dart:321-323`), долгого нажатия нет |
| Debug API: «It is NOT written to any file» | `diagnostics_tab.dart:242` | токен хранится в настройках (`settings_storage.dart:948`), из Backup по умолчанию исключён (`debugApiVarKeys`, `settings_storage.dart:1055`) |

Плюс два комментария в коде противоречили коду:

- `settings_storage.dart:811-813` — «Toggle в App Settings → General → Behavior»;
  тумблер Allow rotation на вкладке Appearance (`appearance_tab.dart:72`).
- `diagnostics_tab.dart:318` — «Default ON»; запись Wi-Fi по умолчанию выключена
  (`settings_storage.dart:806`, `'false'`).

## Решение

Строки переписаны по коду и по `docs/EDITORIAL_POLICY.ru.md` 8.3/8.4: факт,
затем действие; без «please» и «!». Ключи словарей `app/assets/l10n/ru/ui.json`
и `zh/ui.json` переименованы, переводы обновлены (названия кнопок и вкладок — как
в их собственных переводах: Лог / Ядро, Позже / Не напоминать, Убрать из
истории, Подключить / Отключить — по `values-ru/strings.xml`).

| Было | Стало |
|---|---|
| Visible in Debug → Core. | Visible in Debug → Log, filter Core. |
| …background sync stop until unlock. | …background sync stop until the screen turns on again. |
| Long-press the L×Box icon on your home screen → choose "Toggle VPN". | Long-press the L×Box icon on your home screen → "Connect" when the VPN is off, "Disconnect" when it is on. Android 11 and newer. |
| Pings github.com once a day to check for new releases. "View" opens the release page in browser; install is manual. | Pings github.com once a day for new releases. Tap the message to open the update page — the GitHub release or the app's store page. Later hides it until the next launch, Ignore skips this version. |
| …remove individually in Pick saved (long-press chip → Remove). | …remove them one by one in Pick saved with ✕ (Remove from history). |
| Token is shown only here. It is NOT written to any file — use Copy to save. … | The token is stored in app settings and is not included in Backup by default — use Copy to keep it elsewhere. … |

Комментарии: Allow rotation → «App Settings → Appearance»; запись Wi-Fi —
«по умолчанию выключено» с причиной из `getAutoRecordWifi`.

## Риски и границы

- Хвост подсказки Debug API называет порт 9269 в команде `adb forward`, хотя
  порт настраивается; здесь не трогался.
- «Pings github.com» верно для всех каналов установки (проверка идёт в GitHub),
  открываемая страница — своя у канала; это отражено в новой строке.

## Проверка

- `dart run tool/l10n/hardcoded_check.dart` — failures: 0, warnings: 0.
- `dart run tool/l10n/ui_check.dart --strict` — ru/zh: missing 0, orphan 0; failures: 0, warnings: 0.
- Ручная: Settings → Diagnostics — подписи Forward sing-box logs, Debug API,
  Auto-record Wi-Fi; Settings → General — Home-screen shortcut, Check for
  updates; VPN Settings → Aggressive battery saving. Каждая ведёт к
  существующему элементу.
