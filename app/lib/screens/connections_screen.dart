import 'dart:async';

import 'package:flutter/material.dart';

import '../services/clash_api_client.dart';

/// Embeddable view: toolbar + список соединений. Без Scaffold, без AppBar —
/// сидит во вкладке StatsScreen.
class ConnectionsView extends StatefulWidget {
  const ConnectionsView({super.key, required this.clash});

  final ClashApiClient clash;

  @override
  State<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends State<ConnectionsView> {
  static const _intervals = [500, 1000, 2000, 3000, 5000, 10000, 0]; // ms, 0 = off
  List<Map<String, dynamic>> _connections = [];
  final Set<String> _closedIds = {};
  final Map<String, DateTime> _closedAt = {};
  bool _loading = true;
  bool _accumulate = false;
  Timer? _timer;
  int _intervalMs = 2000;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    if (_intervalMs <= 0) return;
    _timer = Timer.periodic(Duration(milliseconds: _intervalMs), (_) => _refresh());
  }

  void _setInterval(int ms) {
    setState(() => _intervalMs = ms);
    _startTimer();
  }

  String _intervalLabel(int ms) {
    if (ms == 0) return 'Off';
    if (ms < 1000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${ms ~/ 1000}s';
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
          .toList();
      List<Map<String, dynamic>> next;
      if (_accumulate) {
        final liveIds = conns.map((c) => c['id']?.toString() ?? '').toSet();
        final byId = <String, Map<String, dynamic>>{};
        for (final c in _connections) {
          final id = c['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          byId[id] = c;
          if (!liveIds.contains(id)) {
            if (_closedIds.add(id)) _closedAt[id] = DateTime.now();
          }
        }
        for (final c in conns) {
          final id = c['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          byId[id] = c;
        }
        next = byId.values.toList();
      } else {
        _closedIds.clear();
        _closedAt.clear();
        next = conns;
      }
      next.sort((a, b) {
        final aStart = a['start']?.toString() ?? '';
        final bStart = b['start']?.toString() ?? '';
        return bStart.compareTo(aStart); // newest first
      });
      setState(() {
        _connections = next;
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
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerLow,
            border: Border(bottom: BorderSide(color: cs.outlineVariant)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Refresh now',
                icon: const Icon(Icons.refresh),
                onPressed: () => unawaited(_refresh()),
              ),
              IconButton(
                tooltip: _accumulate ? 'Accumulating (tap to clear)' : 'Live (tap to keep closed)',
                icon: Icon(_accumulate ? Icons.history_toggle_off : Icons.history),
                onPressed: () {
                  setState(() {
                    _accumulate = !_accumulate;
                    if (!_accumulate) {
                      _closedIds.clear();
                      _closedAt.clear();
                    }
                  });
                },
              ),
              PopupMenuButton<int>(
                tooltip: 'Auto-refresh',
                initialValue: _intervalMs,
                onSelected: _setInterval,
                itemBuilder: (_) => [
                  for (final ms in _intervals)
                    CheckedPopupMenuItem<int>(
                      value: ms,
                      checked: _intervalMs == ms,
                      child: Text(_intervalLabel(ms)),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.timer_outlined, size: 20),
                      const SizedBox(width: 4),
                      Text(_intervalLabel(_intervalMs),
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              Text('${_connections.length}',
                  style: TextStyle(
                      fontSize: 12, color: cs.onSurfaceVariant)),
              if (_connections.isNotEmpty)
                IconButton(
                  tooltip: 'Close all',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _closeAll,
                ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _connections.isEmpty
                  ? const Center(child: Text('No active connections'))
                  : ListView.separated(
                      itemCount: _connections.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _buildTile(_connections[i]),
                    ),
        ),
      ],
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
    final closed = _closedIds.contains(id);

    final start = conn['start']?.toString() ?? '';
    final startTime = DateTime.tryParse(start);
    final endTime = closed ? (_closedAt[id] ?? DateTime.now()) : DateTime.now();
    final duration = startTime != null ? endTime.difference(startTime) : null;

    final cs = Theme.of(context).colorScheme;
    final rule = conn['rule']?.toString() ?? '';
    final rulePayload = conn['rulePayload']?.toString() ?? '';
    final ruleText = rulePayload.isNotEmpty ? '$rule ($rulePayload)' : rule;

    return Opacity(
      opacity: closed ? 0.45 : 1.0,
      child: Padding(
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
                  onPressed: (closed || id.isEmpty) ? null : () => _closeConnection(id),
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
