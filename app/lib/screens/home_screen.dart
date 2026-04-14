import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../models/home_state.dart';
import '../widgets/node_row.dart';
import 'config_screen.dart';
import 'debug_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HomeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = HomeController();
    unawaited(_controller.init());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _pushRoute(Widget screen) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
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
            ExpansionTile(
              leading: const Icon(Icons.settings_outlined),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              startActive
                  ? FilledButton(
                      onPressed: startEnabled ? _controller.start : null,
                      child: const Text('Start'),
                    )
                  : OutlinedButton(
                      onPressed: startEnabled ? _controller.start : null,
                      child: const Text('Start'),
                    ),
              startActive
                  ? OutlinedButton(
                      onPressed: stopEnabled ? _controller.stop : null,
                      child: const Text('Stop'),
                    )
                  : FilledButton(
                      onPressed: stopEnabled ? _controller.stop : null,
                      child: const Text('Stop'),
                    ),
              Chip(
                label: Text('VPN: ${state.tunnel.label}'),
                avatar: Icon(
                  state.tunnelUp ? Icons.shield : Icons.shield_outlined,
                  size: 18,
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
                tooltip: 'Reload groups',
                onPressed: (!state.tunnelUp || state.busy)
                    ? null
                    : () => unawaited(_controller.reloadProxies()),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNodesHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Nodes',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
    );
  }

  Widget _buildNodeList(BuildContext context, HomeState state) {
    if (state.nodes.isEmpty) {
      return Expanded(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              state.tunnelUp
                  ? 'No nodes for selected group'
                  : 'Start VPN to load nodes',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Expanded(
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: state.nodes.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).colorScheme.outlineVariant.withAlpha(128),
        ),
        itemBuilder: (context, i) {
          final tag = state.nodes[i];
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
          );
        },
      ),
    );
  }
}
