import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/app_info_cache.dart';
import '../services/clash_api_client.dart';
import 'connections_screen.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.clash, this.configRaw = ''});

  final ClashApiClient clash;
  final String configRaw;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> with WidgetsBindingObserver {
  Map<String, _OutboundGroup> _groups = {};
  int _totalUp = 0;
  int _totalDown = 0;
  int _totalConns = 0;
  int _memory = 0;
  Map<String, int> _byRule = const {};
  Map<String, AppStat> _byApp = const {};
  bool _loading = true;
  Timer? _timer;
  final _expanded = <String>{};
  final _detourMap = <String, String>{};

  static const _refreshInterval = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _parseDetourMap();
    unawaited(_refresh());
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Battery-friendly: stop'имся когда app уходит в background. 3-секундный
    // polling Clash API не имеет смысла когда юзер даже не видит экран.
    // На resume — immediate refresh + перезапуск таймера.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
        _stopTimer();
      case AppLifecycleState.resumed:
        if (_timer == null) {
          unawaited(_refresh());
          _startTimer();
        }
    }
  }

  void _parseDetourMap() {
    if (widget.configRaw.isEmpty) return;
    try {
      final cfg = jsonDecode(widget.configRaw) as Map<String, dynamic>;
      final all = [
        ...(cfg['outbounds'] as List<dynamic>? ?? []),
        ...(cfg['endpoints'] as List<dynamic>? ?? []),
      ].whereType<Map<String, dynamic>>();
      for (final o in all) {
        final t = o['tag'];
        final d = o['detour'];
        if (t is String && d is String && d.isNotEmpty) _detourMap[t] = d;
      }
    } catch (_) {}
  }

  List<String> _detourChain(String tag) {
    final chain = <String>[];
    final seen = <String>{tag};
    var cur = _detourMap[tag];
    while (cur != null && cur.isNotEmpty && seen.add(cur)) {
      chain.add(cur);
      cur = _detourMap[cur];
    }
    return chain;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

      // Breakdown-агрегации (memory, byRule, byDnsMode, byApp) — парсим
      // тот же response'ом через TrafficSnapshot, чтобы не дублировать логику.
      final snap = TrafficSnapshot.fromConnectionsJson(data);
      _memory = snap.memory;
      _byRule = snap.byRule;
      _byApp = snap.byApp;

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

        final process = meta['process']?.toString() ?? meta['processPath']?.toString() ?? '';

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
          process: process,
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Statistics'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.dashboard_outlined), text: 'Overview'),
              Tab(icon: Icon(Icons.link), text: 'Connections'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildOverview(context),
            ConnectionsView(clash: widget.clash),
          ],
        ),
      ),
    );
  }

  Widget _buildOverview(BuildContext context) {
    final sorted = _groups.values.toList()
      ..sort((a, b) => (b.upload + b.download).compareTo(a.upload + a.download));
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
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
                _totalChip(context, 'sing-box', _formatBytes(_memory), Icons.memory, Theme.of(context).colorScheme.secondary),
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
        const SizedBox(height: 8),
        _buildByRuleCard(context),
        _buildTopAppsCard(context),
      ],
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
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < _detourChain(group.name).length; i++)
                  Padding(
                    padding: EdgeInsets.only(left: 8.0 + i * 12.0, top: 2),
                    child: Text(
                      '↳ via ${_detourChain(group.name)[i]}',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${group.connections.length} connections',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
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
          if (c.process.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                c.process,
                style: TextStyle(fontSize: 10, color: cs.primary),
                overflow: TextOverflow.ellipsis,
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

  Widget _buildByRuleCard(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = _byRule.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (s, e) => s + e.value);
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text('By routing rule', style: theme.textTheme.titleSmall),
        subtitle: Text('$total conns', style: const TextStyle(fontSize: 11)),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: entries.isEmpty
            ? [
                Text('No rule data',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
              ]
            : [
                for (final e in entries)
                  _distributionRow(cs, e.key, e.value, total),
              ],
      ),
    );
  }

  Widget _buildTopAppsCard(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = _byApp.entries.toList()
      ..sort((a, b) => b.value.totalBytes.compareTo(a.value.totalBytes));
    final top = entries.take(10).toList();
    // Kick info fetch для каждого видимого pkg'а — сразу при build'е.
    for (final e in top) {
      AppInfoCache.ensure(e.key);
    }
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text('Top apps', style: theme.textTheme.titleSmall),
        subtitle: Text('${_byApp.length} total',
            style: const TextStyle(fontSize: 11)),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: top.isEmpty
            ? [
                Text('No app data',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
              ]
            : [
                // Пере-билдим каждую строку когда в cache подъехали данные.
                AnimatedBuilder(
                  animation: AppInfoCache.revision,
                  builder: (_, _) => Column(
                    children: [for (final e in top) _appRow(cs, e.key, e.value)],
                  ),
                ),
              ],
      ),
    );
  }

  Widget _distributionRow(ColorScheme cs, String label, int count, int total) {
    final pct = total == 0 ? 0.0 : count / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: Text(
              '$count (${(pct * 100).toStringAsFixed(0)}%)',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _appRow(ColorScheme cs, String pkg, AppStat s) {
    final info = AppInfoCache.of(pkg);
    final displayName = info?.appName ?? pkg;
    final Widget leading;
    if (info?.icon != null) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.memory(info!.icon!, width: 28, height: 28, gaplessPlayback: true),
      );
    } else {
      final letter = displayName.isNotEmpty
          ? displayName.characters.first.toUpperCase()
          : '?';
      leading = SizedBox(
        width: 28,
        height: 28,
        child: CircleAvatar(
          backgroundColor: cs.surfaceContainerHighest,
          child: Text(letter,
              style: TextStyle(fontSize: 12, color: cs.onSurface)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500),
                ),
                Text(
                  pkg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 10,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${s.count} conns',
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
              Text('↑ ${_formatBytes(s.upload)}',
                  style: const TextStyle(fontSize: 10)),
              Text('↓ ${_formatBytes(s.download)}',
                  style: const TextStyle(fontSize: 10)),
            ],
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
    this.process = '',
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
  final String process;
}

