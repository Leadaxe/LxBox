import 'dart:async';

import 'package:flutter/material.dart';

import '../../../controllers/home_controller.dart';
import '../../../controllers/subscription_controller.dart';
import '../../../models/home_state.dart';
import '../../../services/haptic_service.dart';
import '../home_dialogs.dart';
import '../home_menus.dart';
import '../node_list_presenter.dart';

/// §089 — controls-блок главного экрана, вынесенный из
/// `_HomeScreenState._buildControls` + `_buildReloadButton` + reload-menu.
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
          if (subController.configDirty && !subController.busy) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => unawaited(onRebuildAndClearDirty()),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.build_circle_outlined, size: 16, color: Theme.of(context).colorScheme.onPrimaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Settings changed — tap to rebuild config',
                        style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onPrimaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          // §076: показываем «Restart» banner ТОЛЬКО когда rebuild уже
          // сделан (configDirty=false) но running config устарел. Если
          // configDirty=true — выше показывается «Apply» banner, юзер
          // сначала тапнет его → rebuild → configDirty=false → configChangedNeedRestart=true
          // → этот banner появится автоматически. Никаких stacked'ов.
          if (state.tunnelUp &&
              state.configChangedNeedRestart &&
              !subController.configDirty) ...[
            const SizedBox(height: 8),
            GestureDetector(
              // Не гасим `_needsRestart` на тап — если юзер отменит Stop-диалог,
              // banner должен остаться. Гаснет только реальным tunnel up↔down.
              onTap: () => confirmStop(context, controller, controller.state),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Theme.of(context).colorScheme.onTertiaryContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Config changed — restart VPN to apply',
                        style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onTertiaryContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (state.lastError.isNotEmpty) ...[
            const SizedBox(height: 8),
            // Pure render — auto-dismiss timer завведён в _onControllerChange
            // при изменении state.lastError (вне build-фазы).
            Row(
              children: [
                Expanded(
                  child: Text(
                    state.lastError,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: errorTimerOnDismiss,
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          const Text('Channel', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            children: [
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
                      hint: const Text('Select channel'),
                      items: state.groups
                          .map((g) => DropdownMenuItem(value: g, child: Text(g)))
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
          const PopupMenuItem(
            value: 'reload',
            child: Row(children: [
              Icon(Icons.bolt, size: 18),
              SizedBox(width: 12),
              Text('Reload'),
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
        const PopupMenuItem(
          value: 'rebuild',
          child: Row(children: [
            Icon(Icons.build_circle_outlined, size: 18),
            SizedBox(width: 12),
            Text('Rebuild config only'),
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
