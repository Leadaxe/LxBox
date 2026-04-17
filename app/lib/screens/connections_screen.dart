import 'dart:async';

import 'package:flutter/material.dart';

import '../services/clash_api_client.dart';

class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key, required this.clash});

  final ClashApiClient clash;

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  List<Map<String, dynamic>> _connections = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final data = await widget.clash.fetchConnections();
      if (!mounted) return;
      final conns = (data['connections'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList()
        ..sort((a, b) {
          final aStart = a['start']?.toString() ?? '';
          final bStart = b['start']?.toString() ?? '';
          return bStart.compareTo(aStart); // newest first
        });
      setState(() {
        _connections = conns;
        _loading = false;
      });
    } catch (_) {
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  Future<void> _closeConnection(String id) async {
    try {
      await widget.clash.closeConnection(id);
      unawaited(_refresh());
    } catch (_) {}
  }

  Future<void> _closeAll() async {
    try {
      await widget.clash.closeAllConnections();
      unawaited(_refresh());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Connections (${_connections.length})'),
        actions: [
          if (_connections.isNotEmpty)
            IconButton(
              tooltip: 'Close all',
              icon: const Icon(Icons.close_rounded),
              onPressed: _closeAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _connections.isEmpty
              ? const Center(child: Text('No active connections'))
              : ListView.separated(
                  itemCount: _connections.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _buildTile(_connections[i]),
                ),
    );
  }

  Widget _buildTile(Map<String, dynamic> conn) {
    final meta = conn['metadata'] as Map<String, dynamic>? ?? {};
    final host = meta['host']?.toString() ?? '';
    final destIp = meta['destinationIP']?.toString() ?? '';
    final destPort = meta['destinationPort']?.toString() ?? '';
    final network = meta['network']?.toString() ?? '';
    final connType = meta['type']?.toString() ?? '';
    final process = meta['process']?.toString() ?? meta['processPath']?.toString() ?? '';

    final destination = host.isNotEmpty ? host : destIp;
    final display = destPort.isNotEmpty ? '$destination:$destPort' : destination;

    final chains = (conn['chains'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    final chain = chains.isNotEmpty ? chains.join(' → ') : '?';

    final upload = conn['upload'] as int? ?? 0;
    final download = conn['download'] as int? ?? 0;
    final id = conn['id']?.toString() ?? '';

    final start = conn['start']?.toString() ?? '';
    final startTime = DateTime.tryParse(start);
    final duration = startTime != null
        ? DateTime.now().difference(startTime)
        : null;

    final cs = Theme.of(context).colorScheme;
    final rule = conn['rule']?.toString() ?? '';
    final rulePayload = conn['rulePayload']?.toString() ?? '';
    final ruleText = rulePayload.isNotEmpty ? '$rule ($rulePayload)' : rule;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: host:port + traffic + close button
          Row(
            children: [
              Icon(
                network == 'udp' ? Icons.swap_horiz : Icons.arrow_forward,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  display,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '↑${_formatBytes(upload)} ↓${_formatBytes(download)}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  padding: EdgeInsets.zero,
                  tooltip: 'Close',
                  onPressed: id.isNotEmpty ? () => _closeConnection(id) : null,
                ),
              ),
            ],
          ),
          // Row 2: process (app name)
          if (process.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                process,
                style: TextStyle(fontSize: 11, color: cs.primary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // Row 3: chain
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2),
            child: Text(
              chain,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Row 4: protocol + rule + duration
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2),
            child: Text(
              '$network/$connType'
              '${ruleText.isNotEmpty ? '  ·  $ruleText' : ''}'
              '${duration != null ? '  ·  ${_formatDuration(duration)}' : ''}',
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}M';
  }

  static String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}
