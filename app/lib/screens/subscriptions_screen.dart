import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import 'subscription_detail_screen.dart';

class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({
    super.key,
    required this.subController,
    required this.homeController,
  });

  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  final _inputController = TextEditingController();

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    await widget.subController.addFromInput(text);
    if (widget.subController.lastError.isEmpty) {
      _inputController.clear();
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    _inputController.text = text;
  }

  Future<void> _updateAll() async {
    final config = await widget.subController.updateAllAndGenerate();
    if (!mounted) return;
    if (config != null) {
      final ok = await widget.homeController.saveParsedConfig(config);
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Config generated: '
              '${widget.subController.entries.fold<int>(0, (s, e) => s + e.nodeCount)} nodes',
            ),
          ),
        );
      }
    }
  }

  Future<void> _generateOnly() async {
    final config = await widget.subController.generateConfig();
    if (!mounted) return;
    if (config != null) {
      final ok = await widget.homeController.saveParsedConfig(config);
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Config generated and saved')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.subController,
      builder: (context, _) {
        final ctrl = widget.subController;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Subscriptions'),
            actions: [
              IconButton(
                tooltip: 'Update all & generate',
                onPressed: ctrl.busy ? null : () => unawaited(_updateAll()),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Column(
            children: [
              _buildInputBar(ctrl),
              if (ctrl.lastError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    ctrl.lastError,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              if (ctrl.progressMessage.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(ctrl.progressMessage)),
                    ],
                  ),
                ),
              Expanded(child: _buildList(ctrl)),
              if (ctrl.entries.isNotEmpty) _buildBottomBar(ctrl),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInputBar(SubscriptionController ctrl) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              decoration: const InputDecoration(
                hintText: 'Subscription URL or proxy link',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Paste',
            onPressed: _paste,
            icon: const Icon(Icons.content_paste, size: 20),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: ctrl.busy ? null : () => unawaited(_add()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _applyFreePreset() async {
    final config = await widget.subController.applyGetFreePreset();
    if (!mounted || config == null) return;
    final ok = await widget.homeController.saveParsedConfig(config);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Config ready! ${widget.subController.entries.fold<int>(0, (s, e) => s + e.nodeCount)} nodes loaded.',
          ),
        ),
      );
    }
  }

  Widget _buildList(SubscriptionController ctrl) {
    if (ctrl.entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No subscriptions yet.\nPaste a URL above or try free VPN:',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: ctrl.busy ? null : () => unawaited(_applyFreePreset()),
                icon: const Icon(Icons.flash_on),
                label: const Text('Get Free VPN'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: ctrl.entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final entry = ctrl.entries[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            entry.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          subtitle: entry.subtitle.isNotEmpty
              ? Text(entry.subtitle, style: const TextStyle(fontSize: 12))
              : null,
          trailing: entry.nodeCount > 0
              ? Chip(
                  label: Text('${entry.nodeCount}'),
                  visualDensity: VisualDensity.compact,
                )
              : null,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SubscriptionDetailScreen(
                entry: entry,
                index: i,
                controller: widget.subController,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomBar(SubscriptionController ctrl) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: ctrl.busy ? null : () => unawaited(_generateOnly()),
            icon: const Icon(Icons.build_outlined),
            label: const Text('Generate Config'),
          ),
        ),
      ),
    );
  }
}
