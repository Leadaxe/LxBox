import 'dart:async';

import 'package:flutter/material.dart';

import '../../../controllers/home_controller.dart';
import '../../../controllers/subscription_controller.dart';
import '../../../models/home_state.dart';
import '../../../models/node_warning.dart';
import '../../../services/direction_mutations.dart';
import '../../../services/settings_storage.dart';
import '../../../services/haptic_service.dart';
import '../../../services/subscription/auto_updater.dart';
import '../../../widgets/node_row.dart';
import '../../../widgets/node_view_item.dart';
import '../../../widgets/reorder_grab_strip.dart';
import '../../direction_edit_screen.dart';
import '../node_actions.dart';
import '../node_filter_view_model.dart';
import '../../../models/auto_select.dart';
import '../../../models/node_spec.dart';
import '../node_list_presenter.dart';
import '../special_node_display.dart';
import 'add_server_cta.dart';
import 'filter_panel.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/safe_bottom.dart';

/// §328 — предикат полноэкранного гайда «Add a server».
///
/// «Нет серверов» ≠ «нет файла конфига»: конфиг становится непустым при нуле
/// реальных серверов (bootstrap подписки, отдавшей 0 нод; Apply в настройках;
/// удаление всех серверов), и по старому предикату (`configRaw.isEmpty`)
/// подсказка после этого не показывалась больше никогда. Считаем по
/// payload-нодам: [configNodeCount] — `ParsedConfig.nodeCount` сохранённого
/// конфига (control-типы не в счёт; покрывает сырой импорт без entries),
/// [anyServerNodes] — ноды entries (покрывает окно «сервер добавлен, конфиг
/// ещё не пересобран»).
///
/// Только при туннеле down: up с пустым списком — состояния §116 (config load
/// error) и «удалили на лету», у них свои плашки. Ветка [configEmpty]
/// сохраняет прежнее поведение (вкл. Debug API `preview-empty-state`).
bool showAddServerGuide({
  required bool tunnelUp,
  required bool configEmpty,
  required int configNodeCount,
  required bool anyServerNodes,
}) =>
    !tunnelUp && (configEmpty || (configNodeCount == 0 && !anyServerNodes));

/// §537 — порог широкого окна для двух колонок списка узлов (issue #134).
/// 600 dp — граница Material «compact → medium»: телефон в портрете остаётся
/// в одну колонку, планшет, альбом и split-screen на половину планшета — в две.
/// Сравнение нестрогое: ровно 600 dp — уже две колонки.
const double kNodeListTwoColumnsMinWidth = 600;

/// §537 — число колонок списка узлов для ширины [width].
///
/// Ручная сортировка всегда в одну колонку: drag-and-drop идёт через
/// одномерный `ReorderableListView`, в сетке «индекс → позиция» неоднозначен.
///
/// §541 — [twoColumnsEnabled] = тумблер App Settings → Appearance → «Two
/// columns on wide screens»; при false всегда одна колонка.
int nodeListColumnCount(
  double width, {
  required bool isManual,
  bool twoColumnsEnabled = true,
}) =>
    (twoColumnsEnabled && !isManual && width >= kNodeListTwoColumnsMinWidth)
        ? 2
        : 1;

/// Node-list секция главного экрана.
///
/// PRESERVED EXACTLY:
/// - §048 двухфазный filter / split (через [presenter]);
/// - §070/§071 frozen-sort cache (живёт в [presenter], переживает rebuild'ы)
///   + manual-reorder pinnedCount logic;
/// - §078 control-outbound short-circuit;
/// - все NodeRow/NodeViewItem props + callbacks байт-в-байт.
class HomeNodeList extends StatelessWidget {
  const HomeNodeList({
    super.key,
    required this.controller,
    required this.subController,
    required this.autoUpdater,
    required this.filter,
    required this.presenter,
    required this.state,
    required this.showEmptyGuide,
    required this.onRestoreFromBackup,
    required this.onTapToConnect,
    required this.rowKeyFor,
    required this.onSelectServer,
    required this.onViewPool,
  });

  final HomeController controller;
  final SubscriptionController subController;
  final AutoUpdater autoUpdater;
  final NodeFilterViewModel filter;
  final NodeListPresenter presenter;
  final HomeState state;

  /// §328 — результат [showAddServerGuide], посчитан в `_HomeScreenState.build`
  /// (там же гейтит контролы — решение одно на весь экран).
  final bool showEmptyGuide;
  final Future<void> Function() onRestoreFromBackup;
  final VoidCallback onTapToConnect;

  /// §203 — per-tag GlobalKey строки (для scroll-to-node) + колбэк «перейти к
  /// выбранному urltest-серверу» (Select server в меню auto-ноды).
  final GlobalKey Function(String tag) rowKeyFor;
  final void Function(String tag) onSelectServer;

  /// §208 — открыть попап пула round_robin-Направления по его auto-тегу (View pool).
  final void Function(String autoTag) onViewPool;

  @override
  Widget build(BuildContext context) {
    // §328 — ноль реальных серверов при туннеле down: гайд с CTA-кнопкой
    // берёт весь экран ДО проверки `nodes.isEmpty` — конфиг из шаблона несёт
    // control-ноды (direct/Направления), и по ним список выглядел бы «непустым».
    if (showEmptyGuide) {
      return Expanded(
        child: AddServerCta(
          controller: controller,
          subController: subController,
          autoUpdater: autoUpdater,
          onRestoreFromBackup: onRestoreFromBackup,
        ),
      );
    }
    if (state.nodes.isEmpty) {
      // Empty state: residual-ветка гайда — туннель up при пустом конфиге
      // (§116 аномалия); остальные пустые состояния — пассивный текст.
      if (state.configRaw.isEmpty) {
        return Expanded(
          child: AddServerCta(
            controller: controller,
            subController: subController,
            autoUpdater: autoUpdater,
            onRestoreFromBackup: onRestoreFromBackup,
          ),
        );
      }
      final cs = Theme.of(context).colorScheme;
      // tunnelUp — нет узлов в текущем selector'е; пассивный hint.
      if (state.tunnelUp) {
        return Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.dns_outlined,
                      size: 48, color: cs.onSurfaceVariant.withAlpha(120)),
                  const SizedBox(height: 12),
                  Text(
                    getLocalText.s("No nodes in this direction.\nTry another one."),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      // Конфиг есть, не подключены — большая кликабельная Start-зона.
      // Тап = тот же путь что и FilledButton Start в _buildControls.
      final canStart = !state.busy &&
          state.tunnel != TunnelStatus.connecting &&
          state.tunnel != TunnelStatus.stopping;
      return Expanded(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: canStart
                  ? () {
                      HapticService.I.onConnectTap();
                      onTapToConnect();
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.play_circle_outline,
                        size: 64, color: cs.primary),
                    const SizedBox(height: 12),
                    Text(
                      getLocalText.s("Tap to connect"),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final data = presenter.computeListData(state);

    return Expanded(
      child: Column(
        children: [
          if (filter.panelExpanded)
            FilterPanel(
              filter: filter,
              emojis: data.emojis,
              availableProtocols: data.availableProtocols,
              availableVariants: data.availableVariants,
              sourceOptions: data.sourceOptions,
              // §195 — 💾 показываем только когда активное Направление валиден
              // (selectedGroup ∈ groups). Иначе некуда сохранять → null скрывает.
              onSaveRegex: (state.selectedGroup != null &&
                      state.groups.contains(state.selectedGroup))
                  ? (pattern, invert) =>
                      _saveRegexToDirection(context, pattern, invert)
                  : null,
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: controller.pullToRefresh,
              // §071: ReorderableListView вместо ListView.separated.
              // - buildDefaultDragHandles: false — мы провайдим свои через
              //   transparent strip на левом 5% края каждого non-pinned ряда.
              // - Separator делается через BorderSide bottom внутри itemBuilder
              //   (ReorderableListView не имеет separatorBuilder).
              // - pinnedCount определяется sequential check'ом первых элементов
              //   displayList — robust против фильтра §048 (если pinned попал
              //   в nonMatching, он не на index 0 → pinnedCount=0, корректно).
              // §537 — при ширине ≥ 600 dp и не-ручной сортировке список
              // рисуется в две колонки (построчно: 1-2 / 3-4 …). Колонки
              // пересчитываются на лету от ширины секции; скролл переносится.
              child: _NodeListColumns(
                isManual: state.sortMode == NodeSortMode.manual,
                builder: (context, columns, scrollController) => columns > 1
                    ? _buildNodeGrid(
                        context,
                        columns: columns,
                        scrollController: scrollController,
                        displayList: data.displayList,
                        cache: data.cache,
                        matchingSet: data.matchingSet,
                        warningsByTag: data.warningsByTag,
                      )
                    : _buildReorderableNodeList(
                        context,
                        scrollController: scrollController,
                        displayList: data.displayList,
                        cache: data.cache,
                        matchingSet: data.matchingSet,
                        warningsByTag: data.warningsByTag,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// §071 — ReorderableListView для нод. Pinned section (direct/auto)
  /// non-draggable; остальное — Stack с transparent 5%-strip overlay'ом
  /// слева, который ловит long-press+drag через `ReorderableDragStartListener`.
  /// Drag → `commitManualReorder` переключает в `NodeSortMode.manual` +
  /// сохраняет новый порядок.
  Widget _buildReorderableNodeList(
    BuildContext context, {
    required ScrollController scrollController,
    required List<String> displayList,
    required ParsedConfig cache,
    required Set<String> matchingSet,
    required Map<String, List<NodeWarning>> warningsByTag,
  }) {
    // §070+§071+§125+§196: pinned-секция = direct/auto/активная (источник —
    // state.pinnedNodeCount). Считаем сколько из них реально в начале
    // displayList: если фильтр §048 затолкал pinned в nonMatching → префикс
    // короче → pinnedCount меньше (drag-handle покажется на не-pinned, корректно).
    // §446 — готовое множество из HomeState вместо пересборки на каждый build.
    final pinnedTags = state.pinnedTagSet;
    int pinnedCount = 0;
    while (pinnedCount < displayList.length &&
        pinnedTags.contains(displayList[pinnedCount])) {
      pinnedCount++;
    }

    final dividerColor =
        Theme.of(context).colorScheme.outlineVariant.withAlpha(128);

    // §098 — видимый grab-strip (как в routing) показываем ТОЛЬКО в ручной
    // сортировке. В остальных режимах drag-аффорданс — прежний transparent
    // overlay (long-press → drag переключает в manual).
    final isManual = state.sortMode == NodeSortMode.manual;

    return ReorderableListView.builder(
      scrollController: scrollController,
      // §134 — bottom-spacer ~в одну строку (высота NodeRow=56): последний
      // узел не липнет к нижнему краю / не уезжает под controls-блок, всегда
      // можно доскроллить с запасом.
      padding: const EdgeInsets.only(bottom: 56).withSafeBottom(context),
      buildDefaultDragHandles: false,
      itemCount: displayList.length,
      onReorderItem: (oldIndex, newIndex) {
        // onReorderItem отдаёт newIndex уже без перетаскиваемого элемента —
        // сдвиг «-1 при move-down» делать не надо.
        if (oldIndex < pinnedCount) return; // pinned ряды не двигаются
        if (newIndex < pinnedCount) newIndex = pinnedCount; // не дроп в pinned
        final restOnly = displayList.skip(pinnedCount).toList();
        final restOld = oldIndex - pinnedCount;
        final restNew = newIndex - pinnedCount;
        final moved = restOnly.removeAt(restOld);
        restOnly.insert(restNew, moved);
        controller.commitManualReorder(restOnly);
      },
      itemBuilder: (ctx, i) {
        final tag = displayList[i];
        final keyedRow = _buildNodeCell(
          context,
          tag,
          cache: cache,
          matchingSet: matchingSet,
          warningsByTag: warningsByTag,
          dividerColor: dividerColor,
        );
        // Pinned ряды — без grab strip.
        if (i < pinnedCount) {
          return KeyedSubtree(key: ValueKey('node-$tag'), child: keyedRow);
        }
        // §098 — manual-режим: видимый grab-strip слева (как routing/DNS/subs),
        // immediate-drag (dedicated handle не конфликтует со scroll-ареной).
        if (isManual) {
          return KeyedSubtree(
            key: ValueKey('node-$tag'),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ReorderGrabStrip(index: i),
                  Expanded(child: keyedRow),
                ],
              ),
            ),
          );
        }
        // Non-pinned, не-manual — overlay strip 5% от ширины слева (transparent).
        // LayoutBuilder даёт actual row width → strip всегда proportional.
        return KeyedSubtree(
          key: ValueKey('node-$tag'),
          child: LayoutBuilder(
            builder: (ctx, c) => Stack(
              children: [
                keyedRow,
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: c.maxWidth * 0.08,
                  // ReorderableDelayedDragStartListener (long-press → drag)
                  // вместо ReorderableDragStartListener (immediate). С
                  // immediate scroll-жест Scrollable выигрывает gesture
                  // arena у нашего vertical drag и reorder не начинается.
                  // Delayed обходит арбитраж: scroll работает immediately,
                  // drag активируется после long-press hold.
                  child: ReorderableDelayedDragStartListener(
                    index: i,
                    // Container(color:...) — иначе пустой SizedBox не
                    // hit-testable (RenderConstrainedBox.hitTestSelf=false,
                    // нет child'а → жест проваливается на NodeRow ниже,
                    // InkWell его съедает).
                    child: Container(color: Colors.transparent),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// §537 — сетка узлов для широкого окна. Строка `ListView` = `columns`
  /// ячеек равной ширины, порядок построчный, так что визуальный порядок
  /// совпадает с `displayList`. Пустой хвост последней строки добивается
  /// пустой ячейкой, чтобы одиночный узел не растягивался на всю ширину.
  ///
  /// Заголовков папок/групп в этом списке нет: presenter отдаёт плоский список
  /// тегов, папки (§234-239) доходят сюда только как чипы фильтра. Тап,
  /// long-press-меню и подсветка — внутри [NodeRow], как в одной колонке;
  /// перетаскивания в сетке нет (см. [nodeListColumnCount]).
  Widget _buildNodeGrid(
    BuildContext context, {
    required int columns,
    required ScrollController scrollController,
    required List<String> displayList,
    required ParsedConfig cache,
    required Set<String> matchingSet,
    required Map<String, List<NodeWarning>> warningsByTag,
  }) {
    final dividerColor =
        Theme.of(context).colorScheme.outlineVariant.withAlpha(128);
    final rows = (displayList.length + columns - 1) ~/ columns;
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: 56).withSafeBottom(context),
      itemCount: rows,
      itemBuilder: (ctx, r) {
        final cells = <Widget>[];
        for (var c = 0; c < columns; c++) {
          final i = r * columns + c;
          final Widget cell = i < displayList.length
              ? _buildNodeCell(
                  context,
                  displayList[i],
                  cache: cache,
                  matchingSet: matchingSet,
                  warningsByTag: warningsByTag,
                  dividerColor: dividerColor,
                )
              : const SizedBox.shrink();
          cells.add(Expanded(
            child: c < columns - 1
                // Вертикальный разделитель между колонками.
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                          right: BorderSide(color: dividerColor, width: 1)),
                    ),
                    child: cell,
                  )
                : cell,
          ));
        }
        return IntrinsicHeight(
          key: ValueKey('node-row-${displayList[r * columns]}'),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        );
      },
    );
  }

  /// §537 — одна ячейка узла: [NodeRow] с нижним разделителем и §203-GlobalKey.
  /// Общая для одноколоночного списка и сетки ≥600 dp: тап, long-press-меню и
  /// подсветка живут внутри [NodeRow], поэтому в обеих раскладках одинаковы.
  Widget _buildNodeCell(
    BuildContext context,
    String tag, {
    required ParsedConfig cache,
    required Set<String> matchingSet,
    required Map<String, List<NodeWarning>> warningsByTag,
    required Color dividerColor,
  }) {
    final urltestNow = state.urltestNowOf(tag);
    final group = state.groupOf(tag);
    final isUrltestGroup =
        group != null && group.type.toLowerCase().contains('urltest');
    // §322 — auto-двойник НАПРАВЛЕНИЯ (не узел автовыбора): только ему положены
    // подмена имени «✨ Auto» и пин в верхнюю секцию.
    final isDirectionAuto = controller.isDirectionAutoTag(tag);
    // §102 — протокол и variant (transport/awg) берём с ОДНОГО узла:
    // сам tag, либо текущий выбор urltest-группы (§048 fallback).
    final protoSrc = cache.protocolOf(tag) != null
        ? tag
        : (urltestNow != null && cache.protocolOf(urltestNow) != null
            ? urltestNow
            : null);
    final protoSrcNode = protoSrc != null ? cache[protoSrc] : null;
    final protoType = protoSrc != null ? cache.protocolOf(protoSrc) : null;
    final transport = protoSrcNode?.transportLabel;
    final security = protoSrcNode?.securityLabel;
    final outboundType = cache[tag]?.type;
    final notificationWarnings = _notificationWarningsForRow(
      outboundType: outboundType,
      isDirectionAuto: isDirectionAuto,
      warnings: warningsByTag[tag],
    );
    final row = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: dividerColor, width: 1),
        ),
      ),
      child: NodeRow(
        item: NodeViewItem(
          tag: tag,
          active: tag == state.activeInGroup,
          highlighted: tag == state.highlightedNode,
          delay: state.delayOf(tag),
          // §325 — замер не этого Направления: рисуем приглушённо со значком.
          delayIsForeign: state.delayIsForeign(tag),
          pingBusy: state.pingBusy[tag] == '…',
          // §535 — состояние WG/AWG-endpoint'а: не собран / спит вместо
          // пустого бейджа. Тега нет в карте = узел не endpoint.
          endpointState: state.endpointStates[tag] ?? '',
          tunnelUp: state.tunnelUp,
          busy: state.busy,
          // §322 — у round_robin одного «выбранного» нет: трафик
          // раскладывается по пулу. Стрелку не рисуем — вместо неё
          // значки живого пула в метке.
          urltestNow:
              cache.rawOf(tag)?['balancer'] != null ? null : urltestNow,
          hasDetour: cache[tag]?.detour != null,
          outboundType: outboundType, // §125 — точный тип из конфига
          notificationWarnings: notificationWarnings,
          // §322 — двойник Направления vs узел автовыбора: ядру оба `urltest`.
          isDirectionAuto: isDirectionAuto,
          // §322 — метка режима узла автовыбора (`🎯 [3]` / `🔀 [15/7]`)
          // в подзаголовке. Двойник Направления сюда не попадает — у него уже
          // есть подменённое имя «✨ Auto».
          autoGroupLabel: isDirectionAuto
              ? null
              : _autoLabelWithBadges(
                  controller, subController, cache, tag),
          protocolLabel: protoType == null
              ? null
              : [
                  protoLabel(protoType),
                  ?transport,
                  ?security,
                ].join('·'),
          matches: matchingSet.contains(tag),
          // §355 — мёртвая нода с зависимыми (DNS/ноды через detour):
          // ⚠-метка, тап по ней — sheet со списком пострадавших.
          isSickRoot: state.sickRoots.containsKey(tag),
        ),
        onHighlight: () => controller.setHighlightedNode(tag),
        onActivate: () => unawaited(controller.switchNode(tag)),
        onPing: () => unawaited(controller.runNodeUrltest(tag)),
        // §466 — copyNodeUri стал async (диалог подтверждения у узла с
        // приватным ключом в ссылке); пункт меню — VoidCallback.
        onCopyUri: () =>
            unawaited(copyNodeUri(context, tag, subController)),
        onViewJson: () => viewOutboundJson(context, tag, state,
            subController: subController, homeController: controller),
        onRunUrltest: isUrltestGroup
            ? () => unawaited(controller.runGroupUrltest(tag))
            : null,
        // §203 — для auto/urltest-ноды с текущим выбором: «перейти к
        // выбранному серверу» (подсветка + scroll). Иначе null → пункт скрыт.
        onSelectServer:
            urltestNow != null ? () => onSelectServer(urltestNow) : null,
        // §208 — «View pool» только для auto-ноды round_robin-Направления
        // (у least_test пула нет). tag здесь = auto-тег группы.
        onViewPool: (isUrltestGroup && controller.isRoundRobinAuto(tag))
            ? () => onViewPool(tag)
            : null,
        // §355 — ⚠-тап: View details сразу на вкладке Dependents
        // («кто сломан этой мёртвой нодой»).
        onSickTap: state.sickRoots.containsKey(tag)
            ? () => viewOutboundJson(context, tag, state,
                subController: subController,
                homeController: controller,
                openDependents: true)
            : null,
      ),
    );
    // §203 — GlobalKey на сам row (для Scrollable.ensureVisible); reorder-key
    // остаётся ValueKey('node-$tag') (его требует ReorderableListView).
    return KeyedSubtree(key: rowKeyFor(tag), child: row);
  }

  /// §195 — перенести regex из фильтра на главной в активное Направление. Не пишем
  /// тихо: спрашиваем КУДА (node_filter / default_filter), затем открываем
  /// редактор Направления с предзаполненным полем — юзер видит куда легло значение,
  /// может доредактировать и сохранить явно. Результат применяем здесь (на
  /// главной нет routing-стейта, который пишет direction-edit).
  Future<void> _saveRegexToDirection(
      BuildContext context, String pattern, bool invert) async {
    final tag = state.selectedGroup;
    if (tag == null) return;
    final directions = await SettingsStorage.getDirections();
    final idx = directions.indexWhere((c) => c.tag == tag);
    if (idx < 0 || !context.mounted) return;
    final direction = directions[idx];
    final label = direction.label.isNotEmpty ? direction.label : direction.tag;

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Apply to %s", label)),
        content: Text(getLocalText.s("Use \"%s\" as…", pattern)),
        // Горизонтально (Row), порядок: Direction filter → Default → Cancel.
        // Короткие лейблы держат всё в один ряд на телефоне.
        actionsAlignment: MainAxisAlignment.end,
        actionsOverflowDirection: VerticalDirection.down,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'node'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.primary,
              textStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            child: Text(getLocalText.s("Filter")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'default'),
            child: Text(getLocalText.s("Default")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Cancel")),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;

    // Предзаполняем нужное поле и открываем редактор Направления (Routing → Directions
    // → это Направление) — юзер видит подставленное значение и сохраняет явно.
    // §197 — для node_filter переносим и инверсию с главного фильтра; default
    // инверсии не имеет (игнор).
    final seeded = choice == 'node'
        ? direction.copyWith(nodeFilter: pattern, nodeFilterInvert: invert)
        : direction.copyWith(defaultFilter: pattern);
    final allNodeTags = _allNodeTagsFromState();
    final result = await openDirectionEditor(
      context,
      initial: seeded,
      canDelete: !direction.isRequired,
      allNodeTags: allNodeTags,
    );
    if (result == null || result.saved == null || !context.mounted) return;

    // Применяем сохранённое Направление + rebuild конфига (паттерн node_filter_screen).
    // §275 — DirectionMutations зеркалит detour-heal в _entries: generateConfig
    // ниже идёт от in-memory контроллера, без ресинка он воскресил бы
    // вылеченный storage.
    final healed = await DirectionMutations.update(result.saved!, subController);
    await controller.refreshDirectionLabels();
    if (!context.mounted) return;
    final config = await subController.generateConfig();
    if (config != null && context.mounted) {
      await controller.saveParsedConfig(config);
    }
    if (!context.mounted) return;
    // §248 Q3 — heal молчаливым не бывает: flag-unset из этого пути лечит
    // detour-ссылки (rules-часть достижима только с disable/delete, которых
    // здесь нет; §274 убрал flag-set-heal) — досказываем счётчики в том же
    // SnackBar.
    // §292 — части сообщения из единого форматтера (общий с routing_screen).
    final healedParts = DirectionMutations.healMessageParts(healed);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(healedParts.isEmpty
              ? getLocalText.s("Saved direction \"%s\"", label)
              : getLocalText.s("Saved direction \"%1\$s\" — %2\$s", label,
                  healedParts.join('; ')))),
    );
    // §338 — при включённой галке пересборка на возврате на home применит
    // правку сама: просить рестарт нельзя, это прямая ложь.
    if (state.tunnelUp && !await SettingsStorage.getAutoReloadOnChange()) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(getLocalText.s("Restart VPN to apply changes"))),
      );
    }
  }

  /// §502 — уведомления для строки: служебные (Direct / Auto / Block) без
  /// значка; у группы автовыбора — только собственные, не агрегат членов.
  List<NodeWarning>? _notificationWarningsForRow({
    required String? outboundType,
    required bool isDirectionAuto,
    required List<NodeWarning>? warnings,
  }) {
    final special = specialNodeDisplayForType(outboundType);
    if (special != null) {
      if (outboundType == 'urltest' && !isDirectionAuto) {
        return warnings ?? const [];
      }
      return null;
    }
    return warnings ?? const [];
  }

  /// §195 — снимок всех node-тегов из ccGroups (union, без самих групп) для
  /// live-превью фильтров в редакторе. Пусто = туннель не поднят.
  List<String> _allNodeTagsFromState() {
    final groupTags = state.ccGroups.map((g) => g.tag).toSet();
    final seen = <String>{};
    final out = <String>[];
    for (final g in state.ccGroups) {
      for (final item in g.items) {
        if (groupTags.contains(item.tag)) continue;
        if (seen.add(item.tag)) out.add(item.tag);
      }
    }
    return out;
  }
}

/// §322 — метка режима + значки живого пула: `🔀 [15/7] 🇩🇪, 🇳🇱[2]`.
///
/// Состав берём у ЯДРА (`getPool`, §208), а не из конфига: в конфиге весь
/// набор, а в работе — только `pool` штук. Кэш ленивый: первый ребилд отдаёт
/// метку без значков, следом приходит ответ и строка дорисовывается.
String? _autoLabelWithBadges(
  HomeController controller,
  SubscriptionController subs,
  ParsedConfig cache,
  String tag,
) {
  final base = autoGroupLabel(cache.rawOf(tag));
  if (base == null) return null;
  // Тег в конфиге — с префиксом контейнера и, возможно, суффиксом
  // уникализации; ищем группу, чей базовый тег в нём содержится.
  final badge = poolBadgeOf(subs, tag);
  if (badge.isEmpty) return base;
  final slots = controller.poolSlots(tag);
  if (slots == null || slots.isEmpty) return base;
  final badges = poolBadges([for (final s in slots) s.tag], badge);
  return badges.isEmpty ? base : '$base $badges';
}

/// §446 — плоский срез spec'ов автовыбора из всех подписок: пара
/// `(тег, regexp значков)` в том же порядке обхода, что был у линейного
/// поиска. Пересобирается только когда сменился состав подписок.
///
/// Матчинг суффиксный (`tag.endsWith(spec.tag)`), поэтому Map по тегу здесь
/// не годится — итоговый тег несёт префикс контейнера и суффикс
/// уникализации. Зато сам срез теперь короткий: узлов автовыбора единицы,
/// а прежний обход шёл по ВСЕМ узлам всех подписок (сотни при большой
/// сборной подписке) — и делал это на каждую видимую строку каждый кадр.
List<(String, String)> _autoSpecs = const [];
List<List<NodeSpec>>? _autoSpecsSource;

/// Сброс кэша между тестами: кэш держит ссылки на списки узлов, и соседний
/// тест с другим набором подписок получил бы чужие значки (§290 — глобальное
/// состояние течёт между тестами).
@visibleForTesting
void resetPoolBadgeCache() {
  _autoSpecs = const [];
  _autoSpecsSource = null;
}

List<(String, String)> _autoSpecsOf(SubscriptionController subs) {
  // Ключ — identity самих списков узлов: `_replaceList` ставит новый список,
  // мутация на месте состав spec'ов не меняет.
  final source = [for (final e in subs.entries) e.list.nodes];
  final cached = _autoSpecsSource;
  if (cached != null &&
      cached.length == source.length &&
      Iterable<int>.generate(source.length)
          .every((i) => identical(cached[i], source[i]))) {
    return _autoSpecs;
  }
  _autoSpecsSource = source;
  _autoSpecs = [
    for (final nodes in source)
      for (final n in nodes)
        if (n is AutoSelectSpec) (n.tag, n.poolBadge),
  ];
  return _autoSpecs;
}

/// §322 — regexp значков у группы с итоговым тегом [tag]. Дефолт, если группа
/// не нашлась (узел мог приехать из конфиг-редактора, минуя подписки).
@visibleForTesting
String poolBadgeOf(SubscriptionController subs, String tag) {
  for (final (specTag, badge) in _autoSpecsOf(subs)) {
    if (tag.endsWith(specTag)) return badge;
  }
  return kDefaultPoolBadge;
}

/// §537 — выбирает число колонок по ширине секции и держит общий
/// [ScrollController] для обеих раскладок. При смене числа колонок
/// (поворот, split-screen, переход в ручную сортировку) смещение
/// пересчитывается пропорционально числу строк, чтобы на экране остались
/// те же узлы. Подсветка и выбор живут в [HomeState] и не теряются.
class _NodeListColumns extends StatefulWidget {
  const _NodeListColumns({required this.isManual, required this.builder});

  final bool isManual;
  final Widget Function(
    BuildContext context,
    int columns,
    ScrollController scrollController,
  ) builder;

  @override
  State<_NodeListColumns> createState() => _NodeListColumnsState();
}

class _NodeListColumnsState extends State<_NodeListColumns> {
  ScrollController _scroll = ScrollController();
  int? _columns;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // §541 — тумблер двух колонок слушается напрямую: переключение в
    // настройках перестраивает список без перезапуска.
    return ValueListenableBuilder<bool>(
      valueListenable: SettingsStorage.nodeListTwoColumns,
      builder: (context, twoColumnsEnabled, _) => LayoutBuilder(
        builder: (context, constraints) {
          final columns = nodeListColumnCount(
            constraints.maxWidth,
            isManual: widget.isManual,
            twoColumnsEnabled: twoColumnsEnabled,
          );
          final prev = _columns;
          if (prev != null && prev != columns) {
            final old = _scroll;
            final offset = old.hasClients && old.positions.length == 1
                ? old.offset * prev / columns
                : 0.0;
            _scroll = ScrollController(initialScrollOffset: offset);
            // Старый контроллер ещё прицеплен к уходящему списку — отпускаем
            // после кадра, когда тот размонтирован.
            WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          }
          _columns = columns;
          return widget.builder(context, columns, _scroll);
        },
      ),
    );
  }
}
