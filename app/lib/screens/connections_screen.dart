import 'dart:async';

import 'package:flutter/material.dart';

import '../services/format_utils.dart';
import '../vpn/cc_channel.dart';
import 'connections_screen/connection_detail_sheet.dart';

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
///
/// §122 — источник = `CcChannel.instance.connections` (libbox CommandClient
/// push-стрим), а не Clash HTTP-pull. Native-аккумулятор сам ведёт
/// closed-историю (`CcConnection.closedAt`); локальный pull-таймер/режим
/// «accumulate» больше не нужны.
class ConnectionsView extends StatefulWidget {
  const ConnectionsView({super.key});

  @override
  State<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends State<ConnectionsView> {
  final _cc = CcChannel.instance;
  StreamSubscription<List<CcConnection>>? _sub;
  List<CcConnection> _connections = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _sub = _cc.connections.listen(_onConnections);
  }

  void _onConnections(List<CcConnection> conns) {
    if (!mounted) return;
    final next = conns.toList()
      // newest first — по createdAt (epoch ms).
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    setState(() {
      _connections = next;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _closeConnection(String id) async {
    if (id.isEmpty) return;
    await _cc.closeConnection(id);
  }

  Future<void> _closeAll() async {
    await _cc.closeConnections();
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
              const SizedBox(width: 4),
              Icon(Icons.link, size: 18, color: cs.onSurfaceVariant),
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

  /// Порт из "host:port" — часть после последнего ':'.
  static String _portOf(String destination) {
    final i = destination.lastIndexOf(':');
    if (i < 0 || i == destination.length - 1) return '';
    return destination.substring(i + 1);
  }

  Widget _buildTile(CcConnection conn) {
    final host = conn.domain;
    final destPort = _portOf(conn.destination);
    final network = conn.network;

    // domain пуст → показываем raw destination ("host:port").
    final destination = host.isNotEmpty ? host : conn.destination;
    final display = (host.isNotEmpty && destPort.isNotEmpty)
        ? '$destination:$destPort'
        : destination;

    final upload = conn.uplink;
    final download = conn.downlink;
    final id = conn.id;
    final closed = conn.isClosed;

    final startTime = conn.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(conn.createdAt)
        : null;
    final endTime = closed && conn.closedAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(conn.closedAt)
        : DateTime.now();
    final duration = startTime != null ? endTime.difference(startTime) : null;

    final oneWay = isOneWayStuck(
      network: network,
      upload: upload,
      download: download,
      startTime: startTime,
      closed: closed,
    );

    final cs = Theme.of(context).colorScheme;
    final rule = conn.rule;

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
          // Row 1: net-arrow + host:port + traffic + close button.
          // §122 — app-иконка убрана: CommandClient не отдаёт processPath.
          Row(
            children: [
              Icon(
                network == 'udp' ? Icons.swap_horiz : Icons.arrow_forward,
                size: 16,
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
          // Row 2: protocol + rule + duration.
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 2),
            child: Text(
              '${network.toUpperCase()}'
              '${rule.isNotEmpty ? '  ·  $rule' : ''}'
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

  static String _formatDuration(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h${d.inMinutes % 60}m';
  }
}
