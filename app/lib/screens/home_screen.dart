import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/home_state.dart';
import '../models/node_spec.dart';
import '../services/clash_api_client.dart';
import '../widgets/node_row.dart';
import 'outbound_view_screen.dart';
import 'about_screen.dart';
import 'config_screen.dart';
import 'debug_screen.dart';
import 'dns_settings_screen.dart';
import 'app_settings_screen.dart';
import 'speed_test_screen.dart';
import 'stats_screen.dart';
import 'routing_screen.dart';
import 'settings_screen.dart';
import 'subscriptions_screen.dart';
import '../services/debug/bootstrap.dart';
import '../services/debug/debug_registry.dart';
import '../services/haptic_service.dart';
import '../services/template_loader.dart';
import '../services/settings_storage.dart';
import '../services/subscription/auto_updater.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver, TickerProviderStateMixin {
  late final HomeController _controller;
  late final SubscriptionController _subController;
  late final AutoUpdater _autoUpdater;
  late final AnimationController _connectingAnim;
  bool _showDetourNodes = true;
  bool _autoRebuild = true;
  /// Derived UI flag. True когда:
  /// (а) `state.configStaleSinceStart` (sticky-флаг в HomeState: saveConfig
  ///     происходил при tunnelUp, сбрасывается на up↔down переходах), или
  /// (б) `_subController.configDirty` при tunnelUp (settings изменены,
  ///     конфиг ещё не пересобран).
  bool get _needsRestart {
    final state = _controller.state;
    if (!state.tunnelUp) return false;
    return state.configStaleSinceStart || _subController.configDirty;
  }
  Timer? _errorTimer;
  String _errorTimerFor = '';

  /// Для side-effect'ов на transition tunnel (SnackBar при → revoked).
  /// Обновляется в `_onControllerChange` после каждого notifyListeners.
  TunnelStatus _prevTunnel = TunnelStatus.disconnected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Порядок: subController first → AutoUpdater видит entries,
    // HomeController holds AutoUpdater для VPN-transitions callback.
    _subController = SubscriptionController();
    _autoUpdater = AutoUpdater(_subController);
    _subController.bindAutoUpdater(_autoUpdater);
    _controller = HomeController(autoUpdater: _autoUpdater);
    _connectingAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    // §031 Debug API: публикуем контроллеры в реестр и, если пользователь
    // включал Debug API раньше, поднимаем сервер на старте.
    DebugRegistry.I.home = _controller;
    DebugRegistry.I.sub = _subController;
    DebugRegistry.I.autoUpdater = _autoUpdater;
    unawaited(applyDebugApiSettings());
    unawaited(_controller.init());
    unawaited(_initSubsAndAutoUpdate());
    unawaited(_loadAutoRebuild());
    unawaited(_loadHapticPref());
    // Track tunnel transitions для side-effect'ов (SnackBar при revoke).
    // AnimatedBuilder уже rebuildит UI на notifyListeners; listener здесь
    // нужен только для эффектов вне build-фазы.
    _prevTunnel = _controller.state.tunnel;
    _controller.addListener(_onControllerChange);
  }

  void _onControllerChange() {
    final now = _controller.state.tunnel;
    if (_prevTunnel != TunnelStatus.revoked &&
        now == TunnelStatus.revoked) {
      _showRevokedSnackBar();
    }
    _prevTunnel = now;
  }

  void _showRevokedSnackBar() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text('VPN taken by another app'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Start',
            onPressed: () => unawaited(_controller.start()),
          ),
        ),
      );
  }

  /// init подписок + затем `start()` AutoUpdater'а (триггер #1 appStart
  /// и заведение periodic-таймера на 1 час). Порядок важен — AutoUpdater
  /// итерирует `entries`, они должны быть загружены с диска.
  Future<void> _initSubsAndAutoUpdate() async {
    await _subController.init();
    _autoUpdater.start();
  }

  Future<void> _loadHapticPref() async {
    await HapticService.I.loadFromPrefs();
  }

  Future<void> _loadAutoRebuild() async {
    final val = await SettingsStorage.getVar('auto_rebuild', 'true');
    _autoRebuild = val == 'true';
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    _controller.removeListener(_onControllerChange);
    _autoUpdater.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.onAppResumed();
    }
  }

  void _pushRoute(Widget screen) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen)).then((_) async {
      // Re-read auto-rebuild in case it changed in App Settings
      final val = await SettingsStorage.getVar('auto_rebuild', 'true');
      _autoRebuild = val == 'true';
      if (_subController.configDirty) {
        if (_autoRebuild) {
          unawaited(_rebuildAndClearDirty());
        } else {
          setState(() {});
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_controller, _subController]),
      builder: (context, _) {
        final state = _controller.state;
        final startActive = !state.tunnelUp;
        final startEnabled = !state.busy && !state.tunnelUp && state.configRaw.isNotEmpty;
        final stopEnabled = !state.busy && state.tunnelUp;
        return Scaffold(
          appBar: AppBar(title: const Text('L×Box')),
          drawer: _buildDrawer(state),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildControls(context, state, startActive, startEnabled, stopEnabled),
              if (state.tunnelUp) _buildTrafficBar(context, state),
              if (_subController.busy && _subController.progressMessage.isNotEmpty)
                _buildProgressBanner(context),
              const SizedBox(height: 12),
              _buildNodesHeader(context),
              const SizedBox(height: 4),
              _buildNodeList(context, state),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDrawer(HomeState state) {
    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Servers'),
              subtitle: const Text('Subscriptions & proxy'),
              onTap: () => _pushRoute(SubscriptionsScreen(
                subController: _subController,
                homeController: _controller,
                autoUpdater: _autoUpdater,
              )),
            ),
            ListTile(
              leading: const Icon(Icons.alt_route_outlined),
              title: const Text('Routing'),
              subtitle: const Text('Proxy groups and routing rules'),
              onTap: () => _pushRoute(RoutingScreen(
                subController: _subController,
                homeController: _controller,
              )),
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('DNS Settings'),
              subtitle: const Text('DNS servers and rules'),
              onTap: () => _pushRoute(DnsSettingsScreen(
                subController: _subController,
                homeController: _controller,
              )),
            ),
            ListTile(
              leading: const Icon(Icons.tune_outlined),
              title: const Text('VPN Settings'),
              subtitle: const Text('Config variables'),
              onTap: () => _pushRoute(SettingsScreen(
                subController: _subController,
                homeController: _controller,
              )),
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('App Settings'),
              subtitle: const Text('Theme, appearance'),
              onTap: () => _pushRoute(const AppSettingsScreen()),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.speed_outlined),
              title: const Text('Speed Test'),
              subtitle: const Text('Test download/upload speed'),
              onTap: () => _pushRoute(SpeedTestScreen(homeController: _controller)),
            ),
            ListTile(
              leading: const Icon(Icons.bar_chart_outlined),
              title: const Text('Statistics'),
              subtitle: const Text('Traffic by outbound'),
              enabled: _controller.state.tunnelUp,
              onTap: () {
                final clash = _controller.clashClient;
                if (clash != null) _pushRoute(StatsScreen(clash: clash, configRaw: _controller.state.configRaw));
              },
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Config Editor'),
              subtitle: const Text('View, edit, import JSON'),
              onTap: () => _pushRoute(ConfigScreen(controller: _controller)),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Debug'),
              subtitle: const Text('Last 100 events'),
              onTap: () => _pushRoute(const DebugScreen()),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              onTap: () => _pushRoute(const AboutScreen()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    HomeState state,
    bool startActive,
    bool startEnabled,
    bool stopEnabled,
  ) {
    final isRevoked = state.tunnel == TunnelStatus.revoked;
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
                          _confirmStop(state);
                        } else {
                          unawaited(_startWithAutoRefresh());
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
              _buildStatusChip(state, isRevoked, isConnecting),
              const SizedBox(width: 8),
              _buildReloadButton(context, state),
            ],
          ),
          if (_subController.configDirty && !_subController.busy) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => unawaited(_rebuildAndClearDirty()),
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
          if (_needsRestart && state.tunnelUp) ...[
            const SizedBox(height: 8),
            GestureDetector(
              // Не гасим `_needsRestart` на тап — если юзер отменит Stop-диалог,
              // banner должен остаться. Гаснет только реальным tunnel up↔down.
              onTap: () => _confirmStop(_controller.state),
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
            Builder(builder: (_) {
              if (_errorTimerFor != state.lastError) {
                _errorTimer?.cancel();
                _errorTimerFor = state.lastError;
                _errorTimer = Timer(const Duration(seconds: 15), () {
                  if (mounted) _controller.clearError();
                });
              }
              return Row(
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
                    onPressed: () {
                      _errorTimer?.cancel();
                      _controller.clearError();
                    },
                  ),
                ],
              );
            }),
          ],
          const SizedBox(height: 16),
          const Text('Group', style: TextStyle(fontWeight: FontWeight.w600)),
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
                      hint: const Text('Select group'),
                      items: state.groups
                          .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                          .toList(),
                      onChanged: (!state.tunnelUp || state.busy || state.groups.isEmpty)
                          ? null
                          : (value) async {
                              _controller.setSelectedGroup(value);
                              await _controller.applyGroup(value);
                            },
                    ),
                  ),
                ),
              ),
              GestureDetector(
                onTap: (!state.tunnelUp || state.busy || state.nodes.isEmpty)
                    ? null
                    : () {
                        if (_controller.massPingRunning) {
                          _controller.cancelMassPing();
                        } else {
                          unawaited(_controller.pingAllNodes());
                        }
                      },
                onLongPress: _showPingSettings,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Icon(
                    _controller.massPingRunning ? Icons.stop_circle_outlined : Icons.speed,
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
  Widget _buildReloadButton(BuildContext context, HomeState state) {
    final cs = Theme.of(context).colorScheme;
    final dirty = _subController.configDirty || _needsRestart;
    final enabled = !state.busy && !_subController.busy;
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
    return dirty ? 'Rebuild config + reconnect' : 'Reconnect';
  }

  void _runDefaultReload(HomeState state) {
    HapticService.I.onConnectTap();
    if (!state.tunnelUp) {
      unawaited(_rebuildAndStart());
      return;
    }
    final dirty = _subController.configDirty || _needsRestart;
    if (dirty) {
      unawaited(_rebuildAndReconnect());
    } else {
      unawaited(_controller.reconnect());
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
      context: context,
      position: rect,
      items: [
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
    if (!mounted || choice == null) return;
    HapticService.I.onConnectTap();
    switch (choice) {
      case 'reconnect':
        unawaited(_controller.reconnect());
      case 'rebuild':
        unawaited(_rebuildAndClearDirty());
      case 'rebuild_reconnect':
        unawaited(_rebuildAndReconnect());
    }
  }

  /// Rebuild config → reconnect (если up) или start (если down). Очищает
  /// dirty-флаг как и `_rebuildAndClearDirty`.
  Future<void> _rebuildAndReconnect() async {
    await _rebuildConfig();
    _subController.configDirty = false;
    if (!mounted) return;
    await _controller.reconnect();
  }

  /// Off-state: rebuild then start. Используется как default когда VPN off.
  Future<void> _rebuildAndStart() async {
    await _rebuildConfig();
    _subController.configDirty = false;
    if (!mounted) return;
    await _controller.start();
    if (mounted && _controller.state.lastError.isNotEmpty && !_controller.state.tunnelUp) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_controller.state.lastError),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _confirmStop(HomeState state) {
    if (state.traffic.activeConnections > 3) {
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Stop VPN?'),
          content: Text(
            '${state.traffic.activeConnections} active connections will be closed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stop'),
            ),
          ],
        ),
      ).then((confirmed) {
        if (confirmed == true) _controller.stop();
      });
    } else {
      _controller.stop();
    }
  }

  Widget _buildStatusChip(HomeState state, bool isRevoked, bool isConnecting) {
    // Manage animation state
    if (isConnecting && !_connectingAnim.isAnimating) {
      _connectingAnim.repeat();
    } else if (!isConnecting && _connectingAnim.isAnimating) {
      _connectingAnim.stop();
      _connectingAnim.reset();
    }

    // UI mapping: revoked отображаем как disconnected. Факт "нас выкинули"
    // юзер получает через SnackBar (см. _showRevokedSnackBar), а chip
    // показывает нейтральный off-state — так видна обычная Start кнопка,
    // без алармирующего красного. Само значение state.tunnel=revoked
    // внутри контроллера не меняется — это нужно для side-effect
    // transition detection в _onControllerChange.
    final icon = state.tunnelUp
        ? Icons.shield
        : isConnecting
            ? Icons.sync
            : Icons.shield_outlined;

    final color = state.tunnelUp
        ? Theme.of(context).colorScheme.primary
        : null;

    final bgColor = state.tunnelUp
        ? Theme.of(context).colorScheme.primaryContainer
        : null;

    final label =
        isRevoked ? TunnelStatus.disconnected.label : state.tunnel.label;

    Widget iconWidget = Icon(icon, size: 18, color: color);
    if (isConnecting) {
      iconWidget = AnimatedBuilder(
        animation: _connectingAnim,
        builder: (_, child) => Transform.rotate(
          angle: _connectingAnim.value * 2 * 3.14159,
          child: child,
        ),
        child: iconWidget,
      );
    }

    return Chip(
      label: Text(label),
      avatar: iconWidget,
      backgroundColor: bgColor,
    );
  }

  Widget _buildTrafficBar(BuildContext context, HomeState state) {
    final cs = Theme.of(context).colorScheme;
    final uptime = state.connectedSince != null
        ? _formatDuration(DateTime.now().difference(state.connectedSince!))
        : '';
    return GestureDetector(
      onTap: () {
        final clash = _controller.clashClient;
        if (clash != null) {
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => StatsScreen(clash: clash, configRaw: _controller.state.configRaw),
          ));
        }
      },
      child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          _trafficChip(context, Icons.arrow_upward, state.traffic.uploadFormatted, cs.primary),
          const SizedBox(width: 8),
          _trafficChip(context, Icons.arrow_downward, state.traffic.downloadFormatted, cs.tertiary),
          if (state.traffic.activeConnections > 0) ...[
            const SizedBox(width: 8),
            _trafficChip(context, Icons.link, '${state.traffic.activeConnections}', cs.secondary),
          ],
          const Spacer(),
          if (uptime.isNotEmpty)
            Text(
              uptime,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
        ],
      ),
    ),
    );
  }

  Widget _trafficChip(BuildContext context, IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 2),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: color,
              ),
        ),
      ],
    );
  }

  static String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h < 24) return '${h}h ${m}m';
    return '${d.inDays}d ${h % 24}h';
  }

  Future<void> _startWithAutoRefresh() async {
    // Обновление подписок теперь через AutoUpdater (см. services/subscription/
    // auto_updater.dart) — 4 триггера, общая логика. При Start никакого
    // синхронного HTTP-fetch'а не делаем: если подписки протухли, trigger 2
    // (VPN connected + 2 мин) подтянет их через туннель.
    await _controller.start();
    // Show diagnostic if start failed
    if (mounted && _controller.state.lastError.isNotEmpty && !_controller.state.tunnelUp) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_controller.state.lastError),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Widget _buildProgressBanner(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _subController.progressMessage,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNodesHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () {
          Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => RoutingScreen(
              subController: _subController,
              homeController: _controller,
            ),
          ));
        },
        child: Row(
          children: [
            Text(
              'Nodes',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            if (_controller.state.nodes.isNotEmpty) ...[
              const SizedBox(width: 4),
              Text(
                '(${_controller.state.nodes.length})',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
            const Spacer(),
            IconButton(
              tooltip: _controller.state.sortMode.label,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: _controller.state.nodes.isEmpty
                  ? null
                  : _controller.cycleSortMode,
              icon: Icon(_controller.state.sortMode.icon, size: 20),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.tune, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onSelected: (v) {
                if (v == 'detour') setState(() => _showDetourNodes = !_showDetourNodes);
              },
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'detour',
                  checked: _showDetourNodes,
                  child: const Text('Show detour servers'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  int _countNodesInConfig(String configJson) {
    try {
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final outbounds = (config['outbounds'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .where((o) {
            final type = o['type']?.toString() ?? '';
            // Skip groups and built-in outbounds
            return type != 'selector' && type != 'urltest' && type != 'direct' && type != 'block' && type != 'dns';
          }).length;
      final endpoints = (config['endpoints'] as List<dynamic>? ?? []).length;
      return outbounds + endpoints;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _rebuildAndClearDirty() async {
    await _rebuildConfig();
    _subController.configDirty = false;
    if (mounted) setState(() {});
  }

  Future<void> _rebuildConfig() async {
    // Только пересборка конфига — без HTTP-fetch'а подписок. За fetch
    // отвечает AutoUpdater (по 4 триггерам) и manual ⟳ на Servers.
    final config = await _subController.generateConfig();
    if (!mounted) return;
    if (config != null) {
      final ok = await _controller.saveParsedConfig(config);
      if (ok && mounted) {
        final nodeCount = _countNodesInConfig(config);
        // configStaleSinceStart выставляется внутри saveParsedConfig,
        // AnimatedBuilder переотрисует через _needsRestart getter.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Config rebuilt: $nodeCount nodes${_controller.state.tunnelUp ? " — restart VPN to apply" : ""}',
            ),
          ),
        );
      }
    }
  }

  Future<void> _showPingSettings() async {
    final template = await TemplateLoader.load();
    final pingOpts = template.pingOptions;
    final presets = (pingOpts['presets'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();

    if (!mounted) return;
    final urlCtrl = TextEditingController(text: _controller.pingUrl.isEmpty
        ? (pingOpts['url']?.toString() ?? '')
        : _controller.pingUrl);
    final timeoutCtrl = TextEditingController(text: '${_controller.pingTimeout > 0
        ? _controller.pingTimeout
        : (pingOpts['timeout_ms'] as num?)?.toInt() ?? 10000}');

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Ping Settings', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (presets.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: presets.map((p) {
                    final name = p['name']?.toString() ?? '';
                    final url = p['url']?.toString() ?? '';
                    final selected = urlCtrl.text == url;
                    return ChoiceChip(
                      label: Text(name, style: const TextStyle(fontSize: 12)),
                      selected: selected,
                      onSelected: (_) => setSheetState(() => urlCtrl.text = url),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'Test URL',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: timeoutCtrl,
                decoration: const InputDecoration(
                  labelText: 'Timeout (ms)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  _controller.pingUrl = urlCtrl.text.trim();
                  _controller.pingTimeout = int.tryParse(timeoutCtrl.text) ?? 5000;
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    ).then((_) { urlCtrl.dispose(); timeoutCtrl.dispose(); });
  }

  void _viewOutboundJson(String tag, HomeState state) {
    if (state.configRaw.isEmpty) return;
    Map<String, Map<String, dynamic>> byTag = {};
    Map<String, String> kindByTag = {};
    try {
      final cfg = jsonDecode(state.configRaw) as Map<String, dynamic>;
      for (final o in (cfg['outbounds'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()) {
        final t = o['tag'];
        if (t is String) {
          byTag[t] = o;
          kindByTag[t] = 'outbound';
        }
      }
      for (final o in (cfg['endpoints'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()) {
        final t = o['tag'];
        if (t is String) {
          byTag[t] = o;
          kindByTag[t] = 'endpoint';
        }
      }
    } catch (_) {}

    final entry = byTag[tag];
    if (entry == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not found: $tag')),
      );
      return;
    }

    final chain = <Map<String, dynamic>>[entry];
    final seen = <String>{tag};
    var cur = entry['detour'];
    while (cur is String && cur.isNotEmpty && seen.add(cur)) {
      final next = byTag[cur];
      if (next == null) break;
      chain.add(next);
      cur = next['detour'];
    }

    final payload = chain.length == 1 ? chain.first : chain;
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => OutboundViewScreen(
        tag: tag,
        kind: kindByTag[tag] ?? 'outbound',
        json: json,
      ),
    ));
  }

  void _copyNodeJson(String tag, HomeState state, String mode) {
    if (state.configRaw.isEmpty) return;

    Map<String, dynamic>? server;
    Map<String, dynamic>? detour;
    try {
      final config = jsonDecode(state.configRaw) as Map<String, dynamic>;
      final outbounds = config['outbounds'] as List<dynamic>? ?? [];
      final endpoints = config['endpoints'] as List<dynamic>? ?? [];
      final all = [...outbounds, ...endpoints].whereType<Map<String, dynamic>>();
      server = all.where((o) => o['tag'] == tag).firstOrNull;
      if (server != null) {
        final detourTag = server['detour'] as String?;
        if (detourTag != null && detourTag.isNotEmpty) {
          detour = all.where((o) => o['tag'] == detourTag).firstOrNull;
        }
      }
    } catch (_) {}

    if (server == null) return;

    Object toCopy;
    String label;
    switch (mode) {
      case 'detour':
        if (detour == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No detour for this node')),
            );
          }
          return;
        }
        toCopy = Map<String, dynamic>.from(detour)..remove('detour');
        label = 'Detour copied';
      case 'both':
        final cleanServer = Map<String, dynamic>.from(server)..remove('detour');
        if (detour != null) {
          final cleanDetour = Map<String, dynamic>.from(detour)..remove('detour');
          toCopy = [cleanDetour, cleanServer];
        } else {
          toCopy = cleanServer;
        }
        label = 'Server${detour != null ? " + detour" : ""} copied';
      default: // 'server'
        toCopy = Map<String, dynamic>.from(server)..remove('detour');
        label = 'Server copied';
    }

    final json = const JsonEncoder.withIndent('  ').convert(toCopy);
    Clipboard.setData(ClipboardData(text: json));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(label)));
    }
  }

  /// Lookup исходного `NodeSpec` по display-тэгу (с префиксом подписки).
  /// Возвращает `null` если не нашли (control-узлы direct/auto, чужой
  /// конфиг, или collision-suffix от `allocateTag`). Используется для
  /// "Copy URI" в long-press меню.
  NodeSpec? _findNodeByDisplayTag(String displayTag) {
    for (final e in _subController.entries) {
      final prefix = e.tagPrefix;
      var base = displayTag;
      if (prefix.isNotEmpty && displayTag.startsWith('$prefix ')) {
        base = displayTag.substring(prefix.length + 1);
      }
      for (final n in e.list.nodes) {
        if (n.tag == base) return n;
        // Detour-нода живёт под главным как `chained` — в config она тоже
        // получает prefix. Поищем и там.
        final ch = n.chained;
        if (ch != null && ch.tag == base) return ch;
      }
    }
    return null;
  }

  void _copyNodeUri(String tag) {
    final node = _findNodeByDisplayTag(tag);
    if (node == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No source URI for this node')),
        );
      }
      return;
    }
    final uri = node.toUri();
    if (uri.isEmpty) return;
    Clipboard.setData(ClipboardData(text: uri));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URI copied')),
      );
    }
  }

  Widget _buildNodeList(BuildContext context, HomeState state) {
    if (state.nodes.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      final String message;
      final IconData icon;
      if (state.configRaw.isEmpty) {
        message = 'No config loaded.\nUse Quick Start or add a subscription.';
        icon = Icons.playlist_add;
      } else if (state.tunnelUp) {
        message = 'No nodes in this group.\nTry another selector.';
        icon = Icons.dns_outlined;
      } else {
        message = 'Tap Start to connect.';
        icon = Icons.play_circle_outline;
      }
      return Expanded(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48, color: cs.onSurfaceVariant.withAlpha(120)),
                const SizedBox(height: 12),
                Text(
                  message,
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
    final displayNodes = _showDetourNodes
        ? state.sortedNodes
        : state.sortedNodes.where((t) => !t.startsWith('⚙ ')).toList();
    // configCache парсится один раз при saveParsedConfig (см. HomeState),
    // здесь просто читаем. Раньше jsonDecode шёл на каждый rebuild
    // ListView — с 50+ нодами и сортировкой это был hot-path выжиматель.
    final cache = state.configCache;
    return Expanded(
      child: RefreshIndicator(
        onRefresh: _controller.reloadProxies,
        child: ListView.separated(
          padding: EdgeInsets.zero,
          itemCount: displayNodes.length,
          separatorBuilder: (_, _) => Divider(
            height: 1,
            thickness: 1,
            color: Theme.of(context).colorScheme.outlineVariant.withAlpha(128),
          ),
          itemBuilder: (context, i) {
            final tag = displayNodes[i];
            final urltestNow =
                ClashApiClient.urltestNow(state.proxiesJson, tag);
            // Определяем URLTest-ли тэг (даже если now пустой — тип есть).
            final proxyEntry =
                ClashApiClient.proxyEntry(state.proxiesJson, tag);
            final isUrltestGroup = proxyEntry != null &&
                (proxyEntry['type']?.toString().toLowerCase() ?? '')
                    .contains('urltest');
            // Для urltest-группы (auto) сам тэг — control-узел без
            // протокола; берём proto той ноды, которую urltest сейчас выбрал.
            final protoType = cache.protoByTag[tag] ??
                (urltestNow != null ? cache.protoByTag[urltestNow] : null);
            return NodeRow(
              tag: tag,
              active: tag == state.activeInGroup,
              highlighted: tag == state.highlightedNode,
              delay: state.lastDelay[tag],
              pingBusy: state.pingBusy[tag] == '…',
              tunnelUp: state.tunnelUp,
              busy: state.busy,
              onHighlight: () => _controller.setHighlightedNode(tag),
              onActivate: () => unawaited(_controller.switchNode(tag)),
              onPing: () => unawaited(_controller.pingNode(tag)),
              onCopy: (mode) => _copyNodeJson(tag, state, mode),
              onCopyUri: () => _copyNodeUri(tag),
              onViewJson: () => _viewOutboundJson(tag, state),
              urltestNow: urltestNow,
              onRunUrltest: isUrltestGroup
                  ? () => unawaited(_controller.runGroupUrltest(tag))
                  : null,
              hasDetour: cache.detourTags.contains(tag),
              protocolLabel: protoType != null ? _protoLabel(protoType) : null,
            );
          },
        ),
      ),
    );
  }
}

/// Короткий label протокола для строки ноды. TLS опускаем — у большинства
/// протоколов (VLESS/Trojan/Hy2/TUIC) он дефолт, метить каждую — шум.
String _protoLabel(String type) => switch (type) {
      'vless' => 'VLESS',
      'vmess' => 'VMess',
      'trojan' => 'Trojan',
      'shadowsocks' => 'SS',
      'hysteria2' => 'Hy2',
      'tuic' => 'TUIC',
      'wireguard' => 'WG',
      'ssh' => 'SSH',
      'socks' => 'SOCKS',
      'http' => 'HTTP',
      _ => type.toUpperCase(),
    };
