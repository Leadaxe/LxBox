# §505 — значок уведомлений на главном экране для одиночного сервера

| | |
|---|---|
| **Статус** | **Released в v2.25.0** (20.09.2026, ядро `v1.14.1-lx.8`). Реализовано |
| **Дата** | 2026-09-19 |
| **Источник** | дефект §502: на экране Servers у `awg2-home` есть warning MTU, на главном — нет |
| **Связанные** | §502 (значок в списке Nodes), §501 (Diagnostics + уведомления), §497, §479 |

## Что было

§502 добавил [NodeInfoBadge] в список Nodes главного экрана. Presenter
собирал `warningsByTag` из `lastEmittedTagMap` через сопоставление
[NodeSpec] по идентичности объекта (`ownerOfNode` / `warningsForEmittedNode`).
У одиночного сервера (`UserServer`) с префиксом тега (🏠) после переразбора
или холодного старта объект в карте сборки и узел в хранилище расходились —
предупреждения разбора (в т.ч. `awg_mtu_clamped`) и вердикт страховки на
главном не находились, хотя экран Servers и подпись узла читали актуальный
узел из записи. Предупреждения сборки (гард реестра, MTU на sing-box-теле)
вообще не попадали в единый источник UI.

## Что сделано

1. **Единый источник** — [warningsForConfigTag] / [allWarningsForEmittedTag]:
   разбор + вердict из хранилища через [storedNodeOfEmittedTag] (тот же обход
   bare-тега, что [ownerOfTag]) + `lastBuildWarningsByTag` с сборки.
2. **Сборка** — [RegistryGateReport.warningsByEmittedTag] →
   [BuildResult.nodeBuildWarningsByEmittedTag] →
   [SubscriptionController.lastBuildWarningsByTag].
3. **Главный экран** — [NodeListPresenter.computeListData] по config-тегу
   строки, не по объекту из карты.
4. **Servers** — подпись одиночного сервера через тот же API + controller.
5. **Детали узла** — вкладка Diagnostics ([NodeSettingsScreen]) через
   [warningsForConfigTag] с emitted-тегом.

## Критерии приёмки

- `awg2-home` (UserServer): warning MTU на Servers, главном и в Diagnostics.
- Подписка / папка / вердикт страховки — уровни info / warning / error как
  раньше; устаревшая `lastEmittedTagMap` не глушит хранилище.
- Тесты: `home_node_warnings_test`, `home_node_row_notifications_test`,
  `subscription_entry_warnings_test`, `bottom_inset_contract_test`.
- `flutter analyze` без новых замечаний.
