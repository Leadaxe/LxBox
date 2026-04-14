import 'package:flutter/material.dart';

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
