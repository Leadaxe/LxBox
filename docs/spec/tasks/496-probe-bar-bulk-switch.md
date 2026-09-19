# §496 — probe-бар подписки: bulk-Switch в столбец с тогглами строк

| | |
|---|---|
| **Статус** | **Released в v2.25.0** (20.09.2026, ядро `v1.14.1-lx.8`). Реализовано |
| **Дата** | 2026-09-19 |
| **Связанные** | [§391](391-bulk-toggle-phase-and-placement.md) — bulk-переключатель в probe-баре; [§339](339-subscription-probe-button.md) — полоса теста над списком нод |

## Проблема

На вкладке Nodes экрана подписки probe-бар (`_buildProbeBar`) показывал слева
сжатый bulk-переключатель (`Transform.scale(0.7)` в `SizedBox(40)` с
`MaterialTapTargetSize.shrinkWrap`) и постоянную подпись «Test servers». Переключатель
не совпадал по размеру и вертикали с `Switch` в строках узлов ниже; подпись в
простое занимала место, хотя сводка теста нужна только во время и после прогона.

## Решение

- Убрана подпись «Test servers» в состоянии простоя; `Expanded` остаётся пустой
  распоркой. Тексты прогресса и итога теста без изменений.
- Bulk-переключатель — обычный `Switch` в `SizedBox(width: 40)`, как `leading`
  строки узла (`subscription_node_list.dart`). Левый отступ probe-бара 12 px —
  как у `ListView` нод, столбец тогглов выровнен.
- Ключ `"Test servers"` удалён из словарей ru/zh (в `app/lib` больше не
  используется; `help.dart` — своя строка).
- `_buildControlBar` папки не менялся.

## Критерии приёмки

- [x] В простое на probe-баре нет текста «Test servers» / перевода.
- [x] Bulk-`Switch` того же размера, что `Switch` строки узла (`getSize` в тесте).
- [x] Во время/после теста сводка (`Testing…`, `ok · err · broken`) на месте.
- [x] UserServer (`canToggleAll == false`) — прежний `SizedBox(width: 12)`, без bulk-Switch.
- [x] `flutter analyze` без новых issues; точечные тесты и l10n-чекеры зелёные.
