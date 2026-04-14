import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../controllers/home_controller.dart';
import '../models/home_state.dart';

class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key, required this.controller});

  final HomeController controller;

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  DebugFilter _filter = DebugFilter.all;

  static String _entriesToText(List<DebugEntry> entries) {
    final buf = StringBuffer();
    for (final e in entries) {
      final src = e.source == DebugSource.core ? 'CORE' : 'APP ';
      buf.writeln('[${e.time.toIso8601String()}] $src  ${e.message}');
    }
    return buf.toString();
  }

  void _copyAll(List<DebugEntry> entries) {
    Clipboard.setData(ClipboardData(text: _entriesToText(entries)));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${entries.length} entries copied')),
    );
  }

  Future<void> _shareLogs(List<DebugEntry> entries) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/boxvpn_debug.log');
      await file.writeAsString(_entriesToText(entries));
      // ignore: deprecated_member_use
      await Share.shareXFiles([XFile(file.path)], text: 'BoxVPN debug log');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final entries = widget.controller.state.debugEvents;
        final filtered = entries.where((entry) {
          return switch (_filter) {
            DebugFilter.all => true,
            DebugFilter.core => entry.source == DebugSource.core,
            DebugFilter.app => entry.source == DebugSource.app,
          };
        }).toList();

        return Scaffold(
          appBar: AppBar(
            title: const Text('Debug'),
            actions: [
              IconButton(
                tooltip: 'Copy all',
                onPressed: filtered.isEmpty ? null : () => _copyAll(filtered),
                icon: const Icon(Icons.copy_outlined),
              ),
              IconButton(
                tooltip: 'Share logs',
                onPressed: filtered.isEmpty ? null : () => _shareLogs(filtered),
                icon: const Icon(Icons.share_outlined),
              ),
            ],
          ),
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
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final entry = filtered[i];
                            final source = entry.source == DebugSource.core ? 'core' : 'app';
                            return ListTile(
                              dense: true,
                              title: Text(
                                entry.message,
                                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
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
