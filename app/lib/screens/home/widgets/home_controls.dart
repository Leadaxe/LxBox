import 'dart:async';

import 'package:flutter/material.dart';

import '../../../controllers/home_controller.dart';
import '../../../controllers/subscription_controller.dart';
import '../../../models/home_state.dart';
import '../../../services/haptic_service.dart';
import '../../../services/l10n/l10n.dart';
import '../home_dialogs.dart';
import '../home_menus.dart';
import '../node_list_presenter.dart';
import 'app_banner.dart';

/// Controls-блок главного экрана.
///
/// Поведение байт-в-байт идентично. Все state-mutating flows (rebuild /
/// reconnect / start) приходят callback'ами из `_HomeScreenState`, чтобы
/// владение side-effect'ами (`setState`, `configDirty=false`, SnackBars)
/// оставалось в State — этот widget только рисует + диспатчит.
class HomeControls extends StatelessWidget {
  const HomeControls({
    super.key,
    required this.controller,
    required this.subController,
    required this.presenter,
    required this.connectingAnimChild,
    required this.state,
    required this.startActive,
    required this.startEnabled,
    required this.stopEnabled,
    required this.needsRestart,
    required this.errorTimerOnDismiss,
    required this.onStartWithAutoRefresh,
    required this.onRebuildAndClearDirty,
    required this.onRebuildAndReconnect,
    required this.onRebuildAndStart,
  });

  final HomeController controller;
  final SubscriptionController subController;
  final NodeListPresenter presenter;

  /// Готовый StatusChip (создаётся в State с доступом к `_connectingAnim`).
  final Widget connectingAnimChild;
  final HomeState state;
  final bool startActive;
  final bool startEnabled;
  final bool stopEnabled;
  final bool needsRestart;

  /// Cancel + clear lastError (раньше inline в `_buildControls`: отменял
  /// `_errorTimer` и звал `clearError`). Side-effect живёт в State.
  final VoidCallback errorTimerOnDismiss;

  final void Function() onStartWithAutoRefresh;
  final Future<void> Function() onRebuildAndClearDirty;
  final Future<void> Function() onRebuildAndReconnect;
  final Future<void> Function() onRebuildAndStart;

  @override
  Widget build(BuildContext context) {
    final isConnecting = state.tunnel == TunnelStatus.connecting;
    final isStopping = state.tunnel == TunnelStatus.stopping;
    final canToggle = !state.busy && !isConnecting && !isStopping;
    final toggleEnabled = canToggle && (state.tunnelUp || state.configRaw.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: toggleEnabled
                    ? () {
                        HapticService.I.onConnectTap();
                        if (state.tunnelUp) {
                          confirmStop(context, controller, state);
                        } else {
                          onStartWithAutoRefresh();
                        }
                      }
                    : null,
                icon: Icon(
                  state.tunnelUp ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  size: 20,
                ),
                label: Text(state.tunnelUp ? 'Stop' : 'Start'),
              ),
              const SizedBox(width: 8),
              connectingAnimChild,
              const SizedBox(width: 8),
              _buildReloadButton(context),
            ],
          ),
          // §116 — единый banner-механизм: проекция состояния → BannerStack.
          // Три исторических плашки (settings_changed / restart / last_error)
          // + config_load_error деривятся в activeBanners.
          BannerStack(
            banners: activeBanners(
              state,
              configDirty: subController.configDirty,
              busy: subController.busy,
              actions: BannerActions(
                onRebuild: () => unawaited(onRebuildAndClearDirty()),
                // Не гасим restart на тап — если юзер отменит Stop-диалог,
                // banner остаётся; гаснет реальным tunnel up↔down.
                onConfirmStop: () =>
                    confirmStop(context, controller, controller.state),
                onClearError: errorTimerOnDismiss,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(context.l.homeChannelLabel,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).colorScheme.outline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      isDense: true,
                      value: state.groups.contains(state.selectedGroup)
                          ? state.selectedGroup
                          : null,
                      hint: Text(context.l.homeSelectChannelHint),
                      items: state.groups
                          .map((g) => DropdownMenuItem(
                              value: g, child: Text(state.groupLabelOf(g))))
                          .toList(),
                      onChanged: (!state.tunnelUp || state.busy || state.groups.isEmpty)
                          ? null
                          : (value) async {
                              controller.setSelectedGroup(value);
                              await controller.applyGroup(value);
                            },
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: (!state.tunnelUp || state.busy || state.nodes.isEmpty)
                    ? null
                    : () {
                        if (controller.massPingRunning) {
                          controller.cancelMassPing();
                        } else {
                          // §078 — пингуем в порядке отображения. Фильтр и
                          // sort учитываются: ping всё что **видно**, в том
                          // порядке как видно. Control-outbounds тоже в
                          // списке (clash.delay для них вернёт error или
                          // реальный latency для direct-out).
                          unawaited(controller.runMassUrltest(
                              order: presenter.computeDisplayList(state)));
                        }
                      },
                onLongPress: () => showPingSettings(context, controller),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    controller.massPingRunning ? Icons.stop_circle_outlined : Icons.speed,
                    color: (!state.tunnelUp || state.busy || state.nodes.isEmpty)
                        ? Theme.of(context).disabledColor
                        : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Кнопка справа от status chip. Short tap = умный default (reconnect /
  /// rebuild+start / rebuild+reconnect в зависимости от состояния), long
  /// press = меню с 3 явными действиями. Иконка refresh читается как
  /// «переподключиться», что и является default-поведением.
  Widget _buildReloadButton(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dirty = subController.configDirty || needsRestart;
    final enabled = !state.busy && !subController.busy;
    final fg = dirty ? cs.onPrimaryContainer : null;
    final bg = dirty ? cs.primaryContainer : Colors.transparent;
    // Без Tooltip: на mobile он сам хватает long-press (его default trigger)
    // и наш `onLongPress` на InkWell никогда не срабатывает. Label доступен
    // через Semantics для accessibility.
    return Semantics(
      button: true,
      label: _defaultReloadLabel(state, dirty),
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        // Builder нужен чтобы `findRenderObject` в _showReloadMenu нашёл саму
        // кнопку, а не родительский Row/Column (иначе меню всплывёт с краю).
        child: Builder(builder: (inkCtx) => InkWell(
          onTap: enabled ? () => _runDefaultReload(state) : null,
          onLongPress: enabled ? () => _showReloadMenu(inkCtx, state) : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(Icons.refresh, size: 20, color: fg),
          ),
        )),
      ),
    );
  }

  String _defaultReloadLabel(HomeState state, bool dirty) {
    if (!state.tunnelUp) return 'Rebuild config + connect';
    // §030: default tap теперь делает in-place reload (легче чем reconnect).
    // Long-press menu всё ещё даёт явный 'Reconnect' для full restart.
    return dirty ? 'Rebuild config + reconnect' : 'Reload';
  }

  void _runDefaultReload(HomeState state) {
    HapticService.I.onConnectTap();
    if (!state.tunnelUp) {
      unawaited(onRebuildAndStart());
      return;
    }
    final dirty = subController.configDirty || needsRestart;
    if (dirty) {
      unawaited(onRebuildAndReconnect());
    } else {
      // §030 — in-place reload через `commandServer.startOrReloadService`.
      // Раньше тут был `reconnect()` (full stop+start с recreate Android Service);
      // новый путь не убивает Service, tunnel дропается на ~3s вместо 5-10s.
      // Long-press menu даёт fallback на full reconnect для случаев когда
      // in-place reload не помог.
      unawaited(controller.reloadVpn());
    }
  }

  Future<void> _showReloadMenu(BuildContext anchorCtx, HomeState state) async {
    final box = anchorCtx.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(anchorCtx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = box.size;
    final rect = RelativeRect.fromLTRB(
      pos.dx,
      pos.dy + size.height,
      overlay.size.width - pos.dx - size.width,
      overlay.size.height - pos.dy,
    );
    final reconnectLabel = state.tunnelUp ? 'Reconnect' : 'Connect';
    final rebuildReconnectLabel =
        state.tunnelUp ? 'Rebuild config + reconnect' : 'Rebuild config + connect';
    final choice = await showMenu<String>(
      context: anchorCtx,
      position: rect,
      items: [
        // Reload первый — самый light recovery (in-place через CommandServer.
        // startOrReloadService). Tap по кнопке выполняет это же действие.
        if (state.tunnelUp)
          PopupMenuItem(
            value: 'reload',
            child: Row(children: [
              const Icon(Icons.bolt, size: 18),
              const SizedBox(width: 12),
              Text(anchorCtx.l.homeMenuReload),
            ]),
          ),
        PopupMenuItem(
          value: 'reconnect',
          child: Row(children: [
            const Icon(Icons.sync, size: 18),
            const SizedBox(width: 12),
            Text(reconnectLabel),
          ]),
        ),
        PopupMenuItem(
          value: 'rebuild',
          child: Row(children: [
            const Icon(Icons.build_circle_outlined, size: 18),
            const SizedBox(width: 12),
            Text(anchorCtx.l.homeMenuRebuildOnly),
          ]),
        ),
        PopupMenuItem(
          value: 'rebuild_reconnect',
          child: Row(children: [
            const Icon(Icons.refresh, size: 18),
            const SizedBox(width: 12),
            Text(rebuildReconnectLabel),
          ]),
        ),
      ],
    );
    if (!anchorCtx.mounted || choice == null) return;
    HapticService.I.onConnectTap();
    switch (choice) {
      case 'reload':
        unawaited(controller.reloadVpn());
      case 'reconnect':
        unawaited(controller.reconnect());
      case 'rebuild':
        unawaited(onRebuildAndClearDirty());
      case 'rebuild_reconnect':
        unawaited(onRebuildAndReconnect());
    }
  }
}
