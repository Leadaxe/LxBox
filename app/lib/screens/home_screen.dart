import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/home_controller.dart';
import '../models/home_state.dart';

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
          drawer: Drawer(
            child: SafeArea(
              child: ListView(
                children: [
                  const DrawerHeader(child: Text('Menu')),
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
                        onTap: () {
                          Navigator.of(context).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ConfigScreen(controller: _controller),
                            ),
                          );
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.folder_open),
                        title: const Text('Read from file'),
                        enabled: !state.busy,
                        contentPadding: const EdgeInsets.only(left: 24, right: 16),
                        onTap: () async {
                          Navigator.of(context).pop();
                          final ok = await _controller.readFromFile();
                          if (ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Config saved')),
                            );
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.content_paste),
                        title: const Text('Paste from clipboard'),
                        enabled: !state.busy,
                        contentPadding: const EdgeInsets.only(left: 24, right: 16),
                        onTap: () async {
                          Navigator.of(context).pop();
                          final ok = await _controller.readFromClipboard();
                          if (ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Config saved')),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  ListTile(
                    leading: const Icon(Icons.bug_report_outlined),
                    title: const Text('Debug'),
                    subtitle: const Text('Last 100 events'),
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DebugScreen(controller: _controller),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
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
                      label: Text('VPN: ${state.statusText}'),
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
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'No data (tunnel and API required)',
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
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
                const SizedBox(height: 12),
                const Text('Nodes', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Expanded(
                  child: state.nodes.isEmpty
                      ? Center(
                          child: Text(
                            state.tunnelUp
                                ? 'No nodes for selected group'
                                : 'Start VPN to load nodes',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          itemCount: state.nodes.length,
                          itemBuilder: (context, i) {
                            final tag = state.nodes[i];
                            final active = tag == state.activeInGroup;
                            final highlighted = tag == state.highlightedNode;
                            final delay = state.lastDelay[tag];
                            final pingLabel = state.pingBusy[tag] == '…'
                                ? '…'
                                : (delay == null ? 'ping' : (delay < 0 ? 'err' : '${delay}ms'));
                            return ListTile(
                              onTap: () => _controller.setHighlightedNode(tag),
                              selected: highlighted,
                              selectedTileColor:
                                  Theme.of(context).colorScheme.secondaryContainer.withAlpha(90),
                              title: Text(
                                tag,
                                style: active ? const TextStyle(fontWeight: FontWeight.bold) : null,
                              ),
                              subtitle: active ? const Text('active') : null,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Activate node',
                                    onPressed: (!state.tunnelUp || state.busy || active)
                                        ? null
                                        : () => unawaited(_controller.switchNode(tag)),
                                    icon: const Icon(Icons.play_arrow),
                                  ),
                                  TextButton(
                                    onPressed: (!state.tunnelUp ||
                                            state.busy ||
                                            (state.pingBusy[tag] == '…'))
                                        ? null
                                        : () => unawaited(_controller.pingNode(tag)),
                                    child: Text(pingLabel),
                                  ),
                                ],
                              ),
                            );
                          },
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

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key, required this.controller});

  final HomeController controller;

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.controller.state.configRaw);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _textController.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  Future<void> _save() async {
    final ok = await widget.controller.saveConfigRaw(_textController.text);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Config saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final busy = widget.controller.state.busy;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Config'),
            actions: [
              IconButton(
                tooltip: 'Copy',
                onPressed: _copy,
                icon: const Icon(Icons.copy_outlined),
              ),
              TextButton(
                onPressed: busy ? null : _save,
                child: const Text('Save'),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'JSON or JSON5 (// and /* */ comments)',
                      alignLabelWithHint: true,
                    ),
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

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key, required this.controller});

  final HomeController controller;

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  DebugFilter _filter = DebugFilter.all;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final entries = widget.controller.state.debugEvents;
        final filtered = entries.where((entry) {
          switch (_filter) {
            case DebugFilter.all:
              return true;
            case DebugFilter.core:
              return entry.source == DebugSource.core;
            case DebugFilter.app:
              return entry.source == DebugSource.app;
          }
        }).toList();

        return Scaffold(
          appBar: AppBar(title: const Text('Debug')),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<DebugFilter>(
                  segments: const [
                    ButtonSegment<DebugFilter>(value: DebugFilter.all, label: Text('All')),
                    ButtonSegment<DebugFilter>(value: DebugFilter.core, label: Text('Core')),
                    ButtonSegment<DebugFilter>(value: DebugFilter.app, label: Text('App')),
                  ],
                  selected: {_filter},
                  onSelectionChanged: (selection) => setState(() => _filter = selection.first),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('No events yet'))
                      : ListView.separated(
                          itemCount: filtered.length,
                          separatorBuilder: (_, index) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final entry = filtered[i];
                            final source = entry.source == DebugSource.core ? 'core' : 'app';
                            return ListTile(
                              dense: true,
                              title: Text(
                                entry.message,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              subtitle: Text(
                                '${entry.time.toIso8601String()} · $source',
                                style: const TextStyle(fontSize: 11),
                              ),
                            );
                          },
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
