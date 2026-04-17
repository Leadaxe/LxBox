import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/home_state.dart';
import '../services/clash_api_client.dart';
import '../widgets/node_row.dart';
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
import '../services/config_builder.dart';
import '../services/settings_storage.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver, TickerProviderStateMixin {
  late final HomeController _controller;
  late final SubscriptionController _subController;
  late final AnimationController _connectingAnim;
  bool _showDetourNodes = false;
  bool _autoRebuild = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = HomeController();
    _subController = SubscriptionController();
    _connectingAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    unawaited(_controller.init());
    unawaited(_subController.init());
    unawaited(_loadAutoRebuild());
  }

  Future<void> _loadAutoRebuild() async {
    final val = await SettingsStorage.getVar('auto_rebuild', 'false');
    _autoRebuild = val == 'true';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.onAppResumed();
    }
  }

  void _pushRoute(Widget screen) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen)).then((_) {
      if (_subController.configDirty) {
        if (_autoRebuild) {
          unawaited(_rebuildAndClearDirty());
        } else {
          setState(() {}); // refresh to show highlighted rebuild button
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
                if (clash != null) _pushRoute(StatsScreen(clash: clash));
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
              onTap: () => _pushRoute(DebugScreen(controller: _controller)),
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
              Container(
                decoration: _subController.configDirty
                    ? BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        shape: BoxShape.circle,
                      )
                    : null,
                child: IconButton(
                  tooltip: _subController.configDirty ? 'Config changed — rebuild' : 'Rebuild config',
                  onPressed: state.busy || _subController.busy
                      ? null
                      : () => unawaited(_rebuildAndClearDirty()),
                  icon: Icon(
                    Icons.refresh,
                    size: 20,
                    color: _subController.configDirty ? Theme.of(context).colorScheme.onErrorContainer : null,
                  ),
                ),
              ),
            ],
          ),
          if (state.lastError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              state.lastError,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
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

    final icon = isRevoked
        ? Icons.warning_amber_rounded
        : state.tunnelUp
            ? Icons.shield
            : isConnecting
                ? Icons.sync
                : Icons.shield_outlined;

    final color = isRevoked
        ? Theme.of(context).colorScheme.error
        : state.tunnelUp
            ? Theme.of(context).colorScheme.primary
            : null;

    final bgColor = isRevoked
        ? Theme.of(context).colorScheme.errorContainer
        : state.tunnelUp
            ? Theme.of(context).colorScheme.primaryContainer
            : null;

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
      label: Text(state.tunnel.label),
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
            builder: (_) => StatsScreen(clash: clash),
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
    if (_subController.entries.isNotEmpty) {
      try {
        final template = await ConfigBuilder.loadTemplate();
        final shouldRefresh = await SettingsStorage.shouldRefreshSubscriptions(
          template.parserConfig.reload,
        );
        if (shouldRefresh) {
          final config = await _subController.updateAllAndGenerate();
          if (config != null && mounted) {
            await _controller.saveParsedConfig(config);
            await SettingsStorage.setLastGlobalUpdate(DateTime.now());
          }
        }
      } catch (_) {
        // Non-blocking: if refresh fails, start with existing config
      }
    }
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
    final config = await _subController.updateAllAndGenerate();
    if (!mounted) return;
    if (config != null) {
      final ok = await _controller.saveParsedConfig(config);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Config rebuilt: ${_countNodesInConfig(config)} nodes',
            ),
          ),
        );
      }
    }
  }

  Future<void> _showPingSettings() async {
    final template = await ConfigBuilder.loadTemplate();
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
              urltestNow: ClashApiClient.urltestNow(state.proxiesJson, tag),
            );
          },
        ),
      ),
    );
  }
}
