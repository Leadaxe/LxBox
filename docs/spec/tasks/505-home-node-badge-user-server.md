# §505 — значок уведомлений на главном экране: холодный старт и одиночный сервер

| | |
|---|---|
| **Статус** | **Released в v2.25.0** (20.09.2026, ядро `v1.14.1-lx.8`). Реализовано |
| **Дата** | 2026-09-19 |
| **Источник** | дефект §502: на экране Servers у `awg2-home` есть warning MTU, на главном — нет; значок на главном появлялся только после Start в текущем сеансе и пропадал после перезапуска |
| **Связанные** | §502 (значок в списке Nodes), §501 (Diagnostics + уведомления), §497, §479, §473 |
| **Слияние** | §513: вторая спека под тем же номером (`505-home-badge-cold-start.md`, та же тема, описание реализации устарело) слита сюда и удалена |

## Что было

**Симптом холодного старта.** У одиночного AWG-сервера «🏠 awg2-home» на
экране Servers предупреждение «AmneziaWG: MTU lowered to 1280» видно сразу, а
на главном экране значок появлялся только после Start в текущем сеансе и
пропадал после перезапуска приложения. Presenter строил `warningsByTag`
только из `lastEmittedTagMap` — обратной карты **последней сборки конфига в
памяти**; до первой пересборки после холодного старта она пуста, хотя Servers
и Diagnostics уже показывают предупреждения разбора и хранимый вердикт
(`mergedNodeWarnings`).

**Одиночный сервер.** §502 добавил [NodeInfoBadge] в список Nodes главного экрана. Presenter
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
   строки, не по объекту из карты, для всех тегов списка, а не только для
   ключей `lastEmittedTagMap`. Порядок: сначала узел хранилища через
   [storedNodeOfEmittedTag]; карта последней сборки — только запасной путь,
   когда владельца в хранилище нет (`entry_warnings.dart`,
   `warningsForConfigTag`). Отдельный обход `nodeSpecForConfigTag` из первой
   версии спеки в `lib/` не вызывался и снят в §513.
4. **Servers** — подпись одиночного сервера через тот же API + controller.
5. **Детали узла** — вкладка Diagnostics ([NodeSettingsScreen]) через
   [warningsForConfigTag] с emitted-тегом.

## Критерии приёмки

- `awg2-home` (UserServer): warning MTU на Servers, главном и в Diagnostics.
- После холодного старта значок на главном есть без Start и без пересборки;
  то же предупреждение, что на Servers и в Diagnostics.
- Подписка / папка / вердикт страховки — уровни info / warning / error как
  раньше; устаревшая `lastEmittedTagMap` не глушит хранилище.
- Тесты: `home_node_warnings_test`, `home_node_row_notifications_test`,
  `subscription_entry_warnings_test`, `bottom_inset_contract_test`.
- `flutter analyze` без новых замечаний.
