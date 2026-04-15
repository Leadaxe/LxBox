import 'dart:async';

import 'package:flutter/material.dart';

import '../services/clash_api_client.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.clash});

  final ClashApiClient clash;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  Map<String, _AppTraffic> _appTraffic = {};
  int _totalUp = 0;
  int _totalDown = 0;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final data = await widget.clash.fetchConnections();
      final conns = (data['connections'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();

      _totalUp = (data['uploadTotal'] as num?)?.toInt() ?? 0;
      _totalDown = (data['downloadTotal'] as num?)?.toInt() ?? 0;

      // Aggregate traffic per chain (outbound path)
      final perChain = <String, _AppTraffic>{};
      for (final c in conns) {
        final meta = c['metadata'] as Map<String, dynamic>? ?? {};
        final host = meta['host']?.toString() ?? meta['destinationIP']?.toString() ?? '?';
        final chains = (c['chains'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
        final chain = chains.isNotEmpty ? chains.first : 'direct';
        final up = (c['upload'] as num?)?.toInt() ?? 0;
        final down = (c['download'] as num?)?.toInt() ?? 0;

        final key = chain;
        final existing = perChain[key];
        if (existing != null) {
          existing.upload += up;
          existing.download += down;
          existing.connections++;
          if (!existing.hosts.contains(host)) existing.hosts.add(host);
        } else {
          perChain[key] = _AppTraffic(
            name: chain,
            upload: up,
            download: down,
            connections: 1,
            hosts: [host],
          );
        }
      }

      if (mounted) {
        setState(() {
          _appTraffic = perChain;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _appTraffic.values.toList()
      ..sort((a, b) => (b.upload + b.download).compareTo(a.upload + a.download));

    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // Total traffic
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _totalChip(context, 'Upload', _totalUp, Icons.arrow_upward, Theme.of(context).colorScheme.primary),
                        _totalChip(context, 'Download', _totalDown, Icons.arrow_downward, Theme.of(context).colorScheme.tertiary),
                        _totalChip(context, 'Connections', _appTraffic.values.fold<int>(0, (s, e) => s + e.connections), Icons.link, Theme.of(context).colorScheme.secondary),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Traffic by Outbound', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (sorted.isEmpty)
                  const Center(child: Text('No active connections'))
                else
                  ...sorted.map((t) => _buildTrafficTile(t)),
              ],
            ),
    );
  }

  Widget _totalChip(BuildContext context, String label, int value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 4),
        Text(
          label != 'Connections' ? _formatBytes(value) : '$value',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _buildTrafficTile(_AppTraffic t) {
    return Card(
      child: ListTile(
        title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w500)),
        subtitle: Text(
          '${t.connections} conn · ${t.hosts.take(3).join(", ")}${t.hosts.length > 3 ? "..." : ""}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('↑ ${_formatBytes(t.upload)}', style: const TextStyle(fontSize: 12)),
            Text('↓ ${_formatBytes(t.download)}', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

class _AppTraffic {
  _AppTraffic({required this.name, this.upload = 0, this.download = 0, this.connections = 0, List<String>? hosts})
      : hosts = hosts ?? [];
  final String name;
  int upload;
  int download;
  int connections;
  final List<String> hosts;
}
