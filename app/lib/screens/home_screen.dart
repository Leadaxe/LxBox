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
import 'app_settings_screen.dart';
import 'connections_screen.dart';
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final HomeController _controller;
  late final SubscriptionController _subController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = HomeController();
    _subController = SubscriptionController();
    unawaited(_controller.init());
    unawaited(_subController.init());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _subController.dispose();
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
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
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
          appBar: AppBar(title: const Text('BoxVPN')),
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
              leading: const Icon(Icons.subscriptions_outlined),
              title: const Text('Subscriptions'),
              subtitle: const Text('Add and manage proxy sources'),
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
            ExpansionTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Config'),
              subtitle: const Text('Import and edit'),
              children: [
                ListTile(
                  leading: const Icon(Icons.edit_note_outlined),
                  title: const Text('Editor'),
                  subtitle: const Text('View and edit JSON'),
                  contentPadding: const EdgeInsets.only(left: 24, right: 16),
                  onTap: () => _pushRoute(ConfigScreen(controller: _controller)),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_open),
                  title: const Text('Read from file'),
                  enabled: !state.busy,
                  contentPadding: const EdgeInsets.only(left: 24, right: 16),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.of(context).pop();
                    final ok = await _controller.readFromFile();
                    if (ok) {
                      messenger.showSnackBar(const SnackBar(content: Text('Config saved')));
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.content_paste),
                  title: const Text('Paste from clipboard'),
                  enabled: !state.busy,
                  contentPadding: const EdgeInsets.only(left: 24, right: 16),
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.of(context).pop();
                    final ok = await _controller.readFromClipboard();
                    if (ok) {
                      messenger.showSnackBar(const SnackBar(content: Text('Config saved')));
                    }
                  },
                ),
              ],
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
                style: FilledButton.styleFrom(
                  backgroundColor: state.tunnelUp
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Chip(
                  label: Text(state.tunnel.label),
                  avatar: Icon(
                    isRevoked
                        ? Icons.warning_amber_rounded
                        : state.tunnelUp
                            ? Icons.shield
                            : Icons.shield_outlined,
                    size: 18,
                    color: isRevoked ? Theme.of(context).colorScheme.error : null,
                  ),
                  backgroundColor: isRevoked
                      ? Theme.of(context).colorScheme.errorContainer
                      : null,
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
              IconButton(
                tooltip: _controller.massPingRunning ? 'Stop ping' : 'Ping all nodes',
                onPressed: (!state.tunnelUp || state.busy || state.nodes.isEmpty)
                    ? null
                    : () {
                        if (_controller.massPingRunning) {
                          _controller.cancelMassPing();
                        } else {
                          unawaited(_controller.pingAllNodes());
                        }
                      },
                icon: Icon(
                  _controller.massPingRunning ? Icons.stop_circle_outlined : Icons.speed,
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
            builder: (_) => ConnectionsScreen(clash: clash),
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
              icon: Icon(
                _controller.state.sortMode == NodeSortMode.defaultOrder
                    ? Icons.sort
                    : Icons.sort_by_alpha,
                size: 20,
              ),
            ),
            IconButton(
              tooltip: 'Reload groups',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: (!_controller.state.tunnelUp || _controller.state.busy)
                  ? null
                  : () => unawaited(_controller.reloadProxies()),
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  void _copyNodeJson(String tag, HomeState state) {
    final entry = ClashApiClient.proxyEntry(state.proxiesJson, tag);
    if (entry == null) return;
    final json = const JsonEncoder.withIndent('  ').convert(entry);
    Clipboard.setData(ClipboardData(text: json));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Outbound JSON copied ($tag)')),
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
    final displayNodes = state.sortedNodes;
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
              onCopyJson: () => _copyNodeJson(tag, state),
              urltestNow: ClashApiClient.urltestNow(state.proxiesJson, tag),
            );
          },
        ),
      ),
    );
  }
}
