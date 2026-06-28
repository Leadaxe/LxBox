import 'dart:async';

import 'package:flutter/material.dart';

import '../../../controllers/home_controller.dart';
import '../../../controllers/subscription_controller.dart';
import '../../../models/home_state.dart';
import '../../../services/settings_storage.dart';
import '../../../services/haptic_service.dart';
import '../../../services/subscription/auto_updater.dart';
import '../../../widgets/node_row.dart';
import '../../../widgets/node_view_item.dart';
import '../../../widgets/reorder_grab_strip.dart';
import '../../channel_edit_screen.dart';
import '../node_actions.dart';
import '../node_filter_view_model.dart';
import '../node_list_presenter.dart';
import 'add_server_cta.dart';
import 'filter_panel.dart';

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
  final Future<void> Function() onRestoreFromBackup;
  final VoidCallback onTapToConnect;

  /// §203 — per-tag GlobalKey строки (для scroll-to-node) + колбэк «перейти к
  /// выбранному urltest-серверу» (Select server в меню auto-ноды).
  final GlobalKey Function(String tag) rowKeyFor;
  final void Function(String tag) onSelectServer;

  /// §208 — открыть попап пула round_robin-канала по его auto-тегу (View pool).
  final void Function(String autoTag) onViewPool;

  @override
  Widget build(BuildContext context) {
    if (state.nodes.isEmpty) {
      // Empty state: первый запуск (нет конфига) — гайд с CTA-кнопкой;
      // остальные пустые состояния — пассивный текст-подсказка.
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
                    'No nodes in this channel.\nTry another one.',
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
                      'Tap to connect',
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
              subOptions: data.subOptions,
              // §195 — 💾 показываем только когда активный канал валиден
              // (selectedGroup ∈ groups). Иначе некуда сохранять → null скрывает.
              onSaveRegex: (state.selectedGroup != null &&
                      state.groups.contains(state.selectedGroup))
                  ? (pattern, invert) =>
                      _saveRegexToChannel(context, pattern, invert)
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
              child: _buildReorderableNodeList(
                context,
                displayList: data.displayList,
                cache: data.cache,
                matchingSet: data.matchingSet,
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
    required List<String> displayList,
    required ParsedConfig cache,
    required Set<String> matchingSet,
  }) {
    // §070+§071+§125+§196: pinned-секция = direct/auto/активная (источник —
    // state.pinnedNodeCount). Считаем сколько из них реально в начале
    // displayList: если фильтр §048 затолкал pinned в nonMatching → префикс
    // короче → pinnedCount меньше (drag-handle покажется на не-pinned, корректно).
    final pinnedTags = state.sortedNodes.take(state.pinnedNodeCount).toSet();
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
      // §134 — bottom-spacer ~в одну строку (высота NodeRow=56): последний
      // узел не липнет к нижнему краю / не уезжает под controls-блок, всегда
      // можно доскроллить с запасом.
      padding: const EdgeInsets.only(bottom: 56),
      buildDefaultDragHandles: false,
      itemCount: displayList.length,
      onReorder: (oldIndex, newIndex) {
        // ReorderableListView convention: при move-down newIndex отступает.
        if (newIndex > oldIndex) newIndex -= 1;
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
        final urltestNow = state.urltestNowOf(tag);
        final group = state.groupOf(tag);
        final isUrltestGroup =
            group != null && group.type.toLowerCase().contains('urltest');
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
              delay: state.lastDelay[tag],
              pingBusy: state.pingBusy[tag] == '…',
              tunnelUp: state.tunnelUp,
              busy: state.busy,
              urltestNow: urltestNow,
              hasDetour: cache[tag]?.detour != null,
              outboundType: cache[tag]?.type, // §125 — точный тип из конфига
              protocolLabel: protoType == null
                  ? null
                  : [
                      protoLabel(protoType),
                      ?transport,
                      ?security,
                    ].join('·'),
              matches: matchingSet.contains(tag),
            ),
            onHighlight: () => controller.setHighlightedNode(tag),
            onActivate: () => unawaited(controller.switchNode(tag)),
            onPing: () => unawaited(controller.runNodeUrltest(tag)),
            onCopyUri: () => copyNodeUri(context, tag, subController),
            onViewJson: () => viewOutboundJson(context, tag, state),
            onRunUrltest: isUrltestGroup
                ? () => unawaited(controller.runGroupUrltest(tag))
                : null,
            // §203 — для auto/urltest-ноды с текущим выбором: «перейти к
            // выбранному серверу» (подсветка + scroll). Иначе null → пункт скрыт.
            onSelectServer:
                urltestNow != null ? () => onSelectServer(urltestNow) : null,
            // §208 — «View pool» только для auto-ноды round_robin-канала
            // (у least_test пула нет). tag здесь = auto-тег группы.
            onViewPool: (isUrltestGroup && controller.isRoundRobinAuto(tag))
                ? () => onViewPool(tag)
                : null,
          ),
        );
        // §203 — GlobalKey на сам row (для Scrollable.ensureVisible); reorder-key
        // остаётся ValueKey('node-$tag') (его требует ReorderableListView).
        final keyedRow = KeyedSubtree(key: rowKeyFor(tag), child: row);
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

  /// §195 — перенести regex из фильтра на главной в активный канал. Не пишем
  /// тихо: спрашиваем КУДА (node_filter / default_filter), затем открываем
  /// редактор канала с предзаполненным полем — юзер видит куда легло значение,
  /// может доредактировать и сохранить явно. Результат применяем здесь (на
  /// главной нет routing-стейта, который пишет channel-edit).
  Future<void> _saveRegexToChannel(
      BuildContext context, String pattern, bool invert) async {
    final tag = state.selectedGroup;
    if (tag == null) return;
    final channels = await SettingsStorage.getChannels();
    final idx = channels.indexWhere((c) => c.tag == tag);
    if (idx < 0 || !context.mounted) return;
    final channel = channels[idx];
    final label = channel.label.isNotEmpty ? channel.label : channel.tag;

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Apply to $label'),
        content: Text('Use "$pattern" as…'),
        // Горизонтально (Row), порядок: Channel filter → Default → Cancel.
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
            child: const Text('Filter'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'default'),
            child: const Text('Default'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;

    // Предзаполняем нужное поле и открываем редактор канала (Routing → Channels
    // → этот канал) — юзер видит подставленное значение и сохраняет явно.
    // §197 — для node_filter переносим и инверсию с главного фильтра; default
    // инверсии не имеет (игнор).
    final seeded = choice == 'node'
        ? channel.copyWith(nodeFilter: pattern, nodeFilterInvert: invert)
        : channel.copyWith(defaultFilter: pattern);
    final allNodeTags = _allNodeTagsFromState();
    final result = await openChannelEditor(
      context,
      initial: seeded,
      canDelete: !channel.isRequired,
      allNodeTags: allNodeTags,
    );
    if (result == null || result.saved == null || !context.mounted) return;

    // Применяем сохранённый канал + rebuild конфига (паттерн node_filter_screen).
    await SettingsStorage.updateChannel(result.saved!);
    await controller.refreshChannelLabels();
    if (!context.mounted) return;
    final config = await subController.generateConfig();
    if (config != null && context.mounted) {
      await controller.saveParsedConfig(config);
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved channel "$label"')),
    );
    if (state.tunnelUp && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Restart VPN to apply changes')),
      );
    }
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
