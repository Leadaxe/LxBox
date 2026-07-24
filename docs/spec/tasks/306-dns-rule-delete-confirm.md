# §306 — Подтверждение удаления DNS-правила

**Тип:** bugfix (несогласованность UX, риск потери данных) · **Статус:** ✅ реализовано · **Размер:** S · **Область:** DNS Settings (UI)

Кнопка «корзина» у inline-правила на вкладке DNS удаляла запись **сразу**, без confirm-диалога и без undo. Одно случайное касание — правило потеряно.

## Проблема

`_deleteRule` в [`dns_settings_screen.dart`](../../../app/lib/screens/dns_settings_screen.dart) делал `_rules.removeAt(index)` прямо из `onPressed` тайла ([`dns_rule_tile.dart:149`](../../../app/lib/screens/dns_settings_screen/widgets/dns_rule_tile.dart)). Цена ошибки — не косметическая: у `kind: inline` тело правила хранится только в storage, восстановить его из шаблона (в отличие от `template`/`preset`/`srs`, которые проксируются) нечем. Undo нет, snackbar'а с откатом нет.

Остальные удаления в проекте уже прикрыты общим §219-диалогом:

| Место | Файл:строка | Confirm |
|---|---|---|
| Routing: custom rule | [`routing_screen.dart:684`](../../../app/lib/screens/routing_screen.dart) | ✅ `showDeleteCustomRuleDialog` |
| DNS: сервер | [`dns_server_edit_screen.dart:143`](../../../app/lib/screens/dns_server_edit_screen.dart) | ✅ `showDeleteConfirmDialog` |
| Канал | [`channel_edit_screen.dart:219`](../../../app/lib/screens/channel_edit_screen.dart) | ✅ `showDeleteConfirmDialog` |
| Custom rule editor | [`custom_rule_edit_screen.dart:142`](../../../app/lib/screens/custom_rule_edit_screen.dart) | ✅ `showDeleteConfirmDialog` |
| **DNS: inline-правило** | `dns_settings_screen.dart:796` | ❌ удаляло молча |

То есть DNS-правило было единственной выпавшей точкой.

## Решение

`_deleteRule` → `Future<void>`, удаление за общим `showDeleteConfirmDialog` (§219, [`ui_helpers.dart:25`](../../../app/lib/services/ui_helpers.dart)) — тот же диалог и те же строки, что у routing-правила:

- title `"Delete rule?"`, message `"Remove \"%s\" permanently?"` с именем правила — оба ключа уже есть в словаре, новых строк не добавляется.
- Guard по индексу до диалога и повторная проверка `index < _rules.length` после await — список мог укоротиться, пока диалог висел.
- `mounted`-проверка после await.

Своего диалога не заводим — обёртка вроде `showDeleteCustomRuleDialog` здесь не нужна, вызов ровно один.

Тип колбэка в `DnsRuleTile` (`void Function(int)`) не меняется: `Future<void>`-метод присваивается ему штатно, `onPressed` не ждёт результата.

## Файлы

- `lib/screens/dns_settings_screen.dart` — `_deleteRule` + импорт `services/ui_helpers.dart`.

## Приёмка

- Тап по корзине у inline-правила открывает диалог «Delete rule?» с именем правила.
- Cancel — правило на месте, экран не помечен dirty.
- Delete — правило исчезает, `_markDirty()` как раньше.
- Диалог виден только у `kind: inline` — у template/preset/srs кнопок удаления нет (не изменилось).
- `flutter analyze` чист, 2266 тестов зелёные, 4 l10n-чекера без missing/orphan.

## Docs to update

- Release notes — «Удаление DNS-правила теперь спрашивает подтверждение».
