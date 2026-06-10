import 'dart:async';

import 'package:flutter/material.dart';

import '../../../config/consts.dart';
import '../../../controllers/home_controller.dart';
import '../../../controllers/subscription_controller.dart';
import '../../../models/home_state.dart';
import '../../../services/clash_api_client.dart';
import '../../../services/haptic_service.dart';
import '../../../services/subscription/auto_updater.dart';
import '../../../widgets/node_row.dart';
import '../../../widgets/node_view_item.dart';
import '../../../widgets/reorder_grab_strip.dart';
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
  });

  final HomeController controller;
  final SubscriptionController subController;
  final AutoUpdater autoUpdater;
  final NodeFilterViewModel filter;
  final NodeListPresenter presenter;
  final HomeState state;
  final Future<void> Function() onRestoreFromBackup;
  final VoidCallback onTapToConnect;

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
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: controller.reloadProxies,
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
    // §070+§071: pinnedCount определяем sequential проверкой первых элементов.
    // Если фильтр §048 затолкал pinned в nonMatching → pin не на index 0 →
    // pinnedCount=0 (drag-handle покажется и на pinned, но это корректно
    // т.к. формально он не pinned в текущем render'е).
    int pinnedCount = 0;
    if (state.pinDirect &&
        pinnedCount < displayList.length &&
        displayList[pinnedCount] == 'direct-out') {
      pinnedCount++;
    }
    if (state.pinAuto &&
        pinnedCount < displayList.length &&
        displayList[pinnedCount] == kAutoOutboundTag) {
      pinnedCount++;
    }

    final dividerColor =
        Theme.of(context).colorScheme.outlineVariant.withAlpha(128);

    // §098 — видимый grab-strip (как в routing) показываем ТОЛЬКО в ручной
    // сортировке. В остальных режимах drag-аффорданс — прежний transparent
    // overlay (long-press → drag переключает в manual).
    final isManual = state.sortMode == NodeSortMode.manual;

    return ReorderableListView.builder(
      padding: EdgeInsets.zero,
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
        final urltestNow =
            ClashApiClient.urltestNow(state.proxiesJson, tag);
        final proxyEntry = ClashApiClient.proxyEntry(state.proxiesJson, tag);
        final isUrltestGroup = proxyEntry != null &&
            (proxyEntry['type']?.toString().toLowerCase() ?? '')
                .contains('urltest');
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
          ),
        );
        // Pinned ряды — без grab strip.
        if (i < pinnedCount) {
          return KeyedSubtree(key: ValueKey('node-$tag'), child: row);
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
                  Expanded(child: row),
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
                row,
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
}
