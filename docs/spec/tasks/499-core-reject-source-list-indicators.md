# §499 — вердикт страховки виден в списке источников

| | |
|---|---|
| **Статус** | Реализовано |
| **Дата** | 2026-09-19 |
| **Источник** | решение владельца 19.09.2026: «состояние видно на самом узле — значок и причина»; дефект на экране Servers/Subscriptions |
| **Связанные** | фича 478 (`core_rejected`), §479 (значки и [NodeWarningRow]), §497, §498 |

## Что было

После автовыключения страховкой (фича 478) вердикт `core_rejected` хранился
рядом с выключением (`UserServer.warnings`, `nodeWarnings` подписки,
`FolderMember.warnings`) и показывался в списке узлов подписки (после
`stampStoredVerdicts`), на вкладке Notifications в деталях узла (§497) и в
листе плашки (§498). На экране **Servers/Subscriptions** у одиночного
`UserServer` переключатель был выключен, а **ни значка, ни причины** — подпись
«SHADOWSOCKS server» как у здорового узла. У строки подписки/папки не было
сводного счётчика узлов с actionable-предупреждениями, включая вердикты
страховки.

## Что сделано

1. **Одиночный сервер (`UserServer`).** Подпись строки: при вердикте
   страховки вместо «%s server» — [NodeWarningRow] с дословной причиной ядра
   (одна строка, ellipsis); значок уровня error (реестр `core_rejected`). Тап
   по строке/значку — [NodeNotificationsView] в шторке (§479). Источник —
   `list.warnings` + предупреждения разбора узла (`mergedNodeWarnings`).
2. **Подписка / папка.** В `trailing` строки — [EntryWarningBadge]: значок
   старшего уровня и число узлов/членов с error/warning (вердикт страховки
   входит; info-only не считается). Одиночный сервер счётчика в trailing не
   получает: значок уже в [NodeWarningRow].
3. **Другие строки узла** (проверено):
   - список узлов подписки (`subscription_node_list.dart`) — уже через
     `stampStoredVerdicts`; inline-текст `core_rejected` — причина ядра;
   - член папки (`folder_detail_screen.dart` `_MemberTile`) — тот же
     [NodeWarningRow], подпись протокола скрывается при вердикте;
   - вкладка Notifications одиночного/члена (`node_settings_screen.dart`) —
     `mergedNodeWarnings` из хранилища;
   - главный экран (`node_list.dart` / [NodeRow]) — узлы disabled страховкой
     не попадают в selector; отдельный значок не нужен.
4. **Ручное включение.** Включение одиночного сервера переключателем в списке
   снимает вердикт (`dropVerdict`), как у члена папки (`toggleMemberAt`).

Вспомогательные функции: `mergedNodeWarnings`, `entryWarningSummary`,
`inlineWarningMessage` (`entry_warnings.dart`, `core_reject_ops.dart`).

## Критерии приёмки

- Одиночный сервер с `core_rejected`: значок error, причина ядра в подписи
  вместо протокола, тап открывает карточку уведомлений; без вердикта — как
  раньше.
- Строка подписки с выключенным страховкой узлом: счётчик-значок в trailing.
- Включение одиночного сервера снимает вердикт — значок исчезает.
- Виджет-тесты `subscription_entry_warnings_test.dart`; `flutter analyze`;
  l10n-чекеры `--strict`. Спека 478 (где видно), CHANGELOG (Unreleased →
  Fixed).
