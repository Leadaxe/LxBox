import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_info_cache.dart';
import '../services/clash_api_client.dart';
import '../services/format_utils.dart';
import 'connections_screen/connection_detail_sheet.dart';

/// §154 — чистый package name из `metadata.processPath`. Ядро форматирует
/// его как `com.app (com.app)` либо `com.app (user)` / `com.app (1000)`
/// (см. sing-box `tracker.go`: `processPath + " (" + userName/userId + ")"`).
/// Для резолва иконки нужен голый package — берём часть до первого пробела.
/// Возвращает '' если пусто или похоже на абсолютный путь (не Android-pkg).
String packageNameFromProcess(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '';
  final pkg = s.split(' ').first.trim();
  // Android package = `a.b.c`, без слешей. Путь вида /usr/bin/foo — не pkg.
  if (pkg.contains('/') || !pkg.contains('.')) return '';
  return pkg;
}

/// §153 — «однобокое» (зависшее) соединение: TCP, прожившее ≥
/// [oneWayMinAge], где трафик идёт строго в одну сторону (up>0/down=0 или
/// up=0/down>0). Сигнатура зависшего потока (напр. WhatsApp ↑517 ↓0 —
/// ClientHello ушёл, ответа нет). Порог по возрасту отсекает свежие conns
/// в процессе handshake. Закрытые соединения не маркируются.
///
/// Чистая функция (без BuildContext) — покрыта юнит-тестом на живой
/// фикстуре. [now] инъектируется для детерминизма в тестах.
const Duration oneWayMinAge = Duration(seconds: 3);

bool isOneWayStuck({
  required String network,
  required int upload,
  required int download,
  required DateTime? startTime,
  required bool closed,
  DateTime? now,
}) {
  if (closed) return false;
  if (network != 'tcp') return false;
  if (startTime == null) return false;
  final age = (now ?? DateTime.now()).difference(startTime);
  if (age < oneWayMinAge) return false;
  return (upload > 0 && download == 0) || (upload == 0 && download > 0);
}

/// Embeddable view: toolbar + список соединений. Без Scaffold, без AppBar —
/// сидит во вкладке StatsScreen.
class ConnectionsView extends StatefulWidget {
  const ConnectionsView({super.key, required this.clash});

  final ClashApiClient clash;

  @override
  State<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends State<ConnectionsView>
    with WidgetsBindingObserver {
  static const _intervals = [500, 1000, 2000, 3000, 5000, 10000, 0]; // ms, 0 = off
  List<Map<String, dynamic>> _connections = [];
  final Set<String> _closedIds = {};
  final Map<String, DateTime> _closedAt = {};
  bool _loading = true;
  bool _accumulate = false;
  Timer? _timer;
  int _intervalMs = 2000;
  bool _backgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    if (_intervalMs <= 0) return;
    if (_backgrounded) return;  // Не запускаем таймер в background.
    _timer = Timer.periodic(Duration(milliseconds: _intervalMs), (_) => _refresh());
  }

  void _setInterval(int ms) {
    setState(() => _intervalMs = ms);
    _startTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Connections view опрашивает Clash API каждые 500мс–10с. В background
    // это бесполезный трафик и батарея — юзер экран не видит. Pause/resume
    // по lifecycle-эвенту.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
      case AppLifecycleState.inactive:
        _backgrounded = true;
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.resumed:
        _backgrounded = false;
        if (_timer == null && _intervalMs > 0) {
          unawaited(_refresh());
          _startTimer();
        }
    }
  }

  String _intervalLabel(int ms) {
    if (ms == 0) return 'Off';
    if (ms < 1000) return '${(ms / 1000).toStringAsFixed(1)}s';
    return '${ms ~/ 1000}s';
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

    final oneWay = isOneWayStuck(
      network: network,
      upload: upload,
      download: download,
      startTime: startTime,
      closed: closed,
    );

    final cs = Theme.of(context).colorScheme;
    final rule = conn['rule']?.toString() ?? '';
    final rulePayload = conn['rulePayload']?.toString() ?? '';
    final ruleText = rulePayload.isNotEmpty ? '$rule ($rulePayload)' : rule;

    return Container(
      // §153 — розовый фон у однобоких (зависших) TCP-соединений.
      color: oneWay
          ? Color.alphaBlend(
              Colors.pink.withValues(alpha: 0.16), cs.surface)
          : null,
      child: Opacity(
      opacity: closed ? 0.45 : 1.0,
      child: InkWell(
        onTap: () => unawaited(showConnectionDetailSheet(
          context,
          conn,
          oneWay: oneWay,
          closed: closed,
          onClose: (cid) => unawaited(_closeConnection(cid)),
        )),
        child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: app icon + host:port + traffic + close button
          // §152 — иконка-стрелка (→/⇄ для tcp/udp) убрана; §154 — на её
          // месте launcher-иконка приложения (по processPath = package).
          Row(
            children: [
              _appIcon(packageNameFromProcess(process)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  display,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                // §141 P2.4a — общий канон `formatBytes` (B/KB/MB/GB) вместо
                // локального `_formatBytes` (B/K/M, без GB-разряда).
                '↑${formatBytes(upload)} ↓${formatBytes(download)}',
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
      ),
      ),
    );
  }

  /// §154 — launcher-иконка приложения по package name (`processPath`).
  /// 16×16, перерисовывается через `AppInfoCache.revision` когда иконка
  /// дотянулась из native асинхронно. Fallback пока нет иконки/нет pkg —
  /// нейтральный placeholder того же размера (layout не прыгает).
  Widget _appIcon(String pkg) {
    const double size = 16;
    final cs = Theme.of(context).colorScheme;
    final placeholder = Icon(Icons.apps, size: size, color: cs.onSurfaceVariant);
    if (pkg.isEmpty) return placeholder;
    AppInfoCache.ensure(pkg);
    return AnimatedBuilder(
      animation: AppInfoCache.revision,
      builder: (context, _) {
        final icon = AppInfoCache.of(pkg)?.icon;
        if (icon == null) return placeholder;
        return ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(icon,
              width: size, height: size, gaplessPlayback: true),
        );
      },
    );
  }

  static String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}
