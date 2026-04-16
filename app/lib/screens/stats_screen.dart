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
  Map<String, _OutboundGroup> _groups = {};
  int _totalUp = 0;
  int _totalDown = 0;
  int _totalConns = 0;
  bool _loading = true;
  Timer? _timer;
  final _expanded = <String>{};

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
      _totalConns = conns.length;

      final perChain = <String, _OutboundGroup>{};
      for (final c in conns) {
        final meta = c['metadata'] as Map<String, dynamic>? ?? {};
        final host = meta['host']?.toString() ?? meta['destinationIP']?.toString() ?? '?';
        final destPort = meta['destinationPort']?.toString() ?? '';
        final network = meta['network']?.toString() ?? '';
        final chains = (c['chains'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
        final chain = chains.isNotEmpty ? chains.first : 'direct';
        final rule = c['rule']?.toString() ?? '';
        final rulePayload = c['rulePayload']?.toString() ?? '';
        final up = (c['upload'] as num?)?.toInt() ?? 0;
        final down = (c['download'] as num?)?.toInt() ?? 0;
        final start = c['start']?.toString() ?? '';

        final conn = _Connection(
          host: host,
          destPort: destPort,
          network: network,
          chains: chains,
          rule: rule,
          rulePayload: rulePayload,
          upload: up,
          download: down,
          start: start,
        );

        final existing = perChain[chain];
        if (existing != null) {
          existing.upload += up;
          existing.download += down;
          existing.connections.add(conn);
        } else {
          perChain[chain] = _OutboundGroup(
            name: chain,
            upload: up,
            download: down,
            connections: [conn],
          );
        }
      }

      if (mounted) {
        setState(() {
          _groups = perChain;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _groups.values.toList()
      ..sort((a, b) => (b.upload + b.download).compareTo(a.upload + a.download));

    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _totalChip(context, 'Upload', _formatBytes(_totalUp), Icons.arrow_upward, Theme.of(context).colorScheme.primary),
                        _totalChip(context, 'Download', _formatBytes(_totalDown), Icons.arrow_downward, Theme.of(context).colorScheme.tertiary),
                        _totalChip(context, 'Connections', '$_totalConns', Icons.link, Theme.of(context).colorScheme.secondary),
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
                  ...sorted.map(_buildOutboundCard),
              ],
            ),
    );
  }

  Widget _totalChip(BuildContext context, String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _buildOutboundCard(_OutboundGroup group) {
    final isExpanded = _expanded.contains(group.name);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            onTap: () => setState(() {
              if (isExpanded) {
                _expanded.remove(group.name);
              } else {
                _expanded.add(group.name);
              }
            }),
            title: Text(group.name, style: const TextStyle(fontWeight: FontWeight.w500)),
            subtitle: Text(
              '${group.connections.length} connections',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('↑ ${_formatBytes(group.upload)}', style: const TextStyle(fontSize: 12)),
                    Text('↓ ${_formatBytes(group.download)}', style: const TextStyle(fontSize: 12)),
                  ],
                ),
                const SizedBox(width: 4),
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (isExpanded) ...[
            const Divider(height: 1),
            ...group.connections.map((c) => _buildConnectionTile(c, cs)),
          ],
        ],
      ),
    );
  }

  Widget _buildConnectionTile(_Connection c, ColorScheme cs) {
    final hostPort = c.destPort.isNotEmpty ? '${c.host}:${c.destPort}' : c.host;
    final duration = _formatDuration(c.start);
    final ruleText = c.rulePayload.isNotEmpty
        ? '${c.rule} (${c.rulePayload})'
        : c.rule;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                c.network == 'udp' ? Icons.swap_horiz : Icons.arrow_forward,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hostPort,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '↑${_formatBytes(c.upload)} ↓${_formatBytes(c.download)}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2),
            child: Text(
              '${c.network.toUpperCase()} · $ruleText · $duration',
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
          ),
          if (c.chains.length > 1)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                'Chain: ${c.chains.join(" → ")}',
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  String _formatDuration(String startIso) {
    if (startIso.isEmpty) return '';
    try {
      final start = DateTime.parse(startIso);
      final diff = DateTime.now().difference(start);
      if (diff.inHours > 0) return '${diff.inHours}h ${diff.inMinutes % 60}m';
      if (diff.inMinutes > 0) return '${diff.inMinutes}m ${diff.inSeconds % 60}s';
      return '${diff.inSeconds}s';
    } catch (_) {
      return '';
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

class _OutboundGroup {
  _OutboundGroup({required this.name, this.upload = 0, this.download = 0, required this.connections});
  final String name;
  int upload;
  int download;
  final List<_Connection> connections;
}

class _Connection {
  _Connection({
    required this.host,
    this.destPort = '',
    this.network = '',
    this.chains = const [],
    this.rule = '',
    this.rulePayload = '',
    this.upload = 0,
    this.download = 0,
    this.start = '',
  });

  final String host;
  final String destPort;
  final String network;
  final List<String> chains;
  final String rule;
  final String rulePayload;
  final int upload;
  final int download;
  final String start;
}
