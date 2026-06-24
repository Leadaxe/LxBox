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
/// push-стрим), а не Clash HTTP-pull. Native-аккумулятор отдаёт АКТИВНЫЕ
/// соединения; closed-историю (режим «закрытые не исчезают») ведёт ЭТОТ виджет
/// (`_accumulate`/`_closedIds`/`_closedAt`) — точно как раньше с Clash-pull.
class ConnectionsView extends StatefulWidget {
  const ConnectionsView({super.key});

  @override
  State<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends State<ConnectionsView> {
  final _cc = CcChannel.instance;
  StreamSubscription<List<CcConnection>>? _sub;

  /// Последний снапшот живых соединений (id → conn), плюс — в режиме accumulate
  /// — недавно закрытые (помечены через [_closedIds]).
  final Map<String, CcConnection> _byId = {};
  final Set<String> _closedIds = {};
  final Map<String, DateTime> _closedAt = {};
  bool _accumulate = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _sub = _cc.connections.listen(_onConnections);
  }

  void _onConnections(List<CcConnection> conns) {
    if (!mounted) return;
    final liveIds = conns.map((c) => c.id).where((id) => id.isNotEmpty).toSet();

    if (_accumulate) {
      // Соединения, пропавшие из живого снапшота → закрыты (помечаем + timestamp).
      for (final id in _byId.keys) {
        if (id.isNotEmpty && !liveIds.contains(id) && _closedIds.add(id)) {
          _closedAt[id] = DateTime.now();
        }
      }
      // Свежие данные поверх (живые перетирают, закрытые остаются как были).
      for (final c in conns) {
        if (c.id.isNotEmpty) _byId[c.id] = c;
      }
    } else {
      _byId
        ..clear()
        ..addEntries(conns.where((c) => c.id.isNotEmpty).map((c) => MapEntry(c.id, c)));
      _closedIds.clear();
      _closedAt.clear();
    }

    setState(() => _loading = false);
  }

  /// Отсортированный список: новейшие сверху (по createdAt epoch ms).
  List<CcConnection> get _sorted {
    final list = _byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
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
    final list = _sorted;
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
              // Toggle: Live (закрытые исчезают) ↔ Accumulate (закрытые серым остаются).
              IconButton(
                tooltip: _accumulate
                    ? 'Accumulating closed (tap to clear)'
                    : 'Live (tap to keep closed)',
                icon: Icon(
                  _accumulate ? Icons.history_toggle_off : Icons.history,
                ),
                onPressed: () {
                  setState(() {
                    _accumulate = !_accumulate;
                    if (!_accumulate) {
                      // Выключили accumulate → убираем закрытые из набора.
                      _byId.removeWhere((id, _) => _closedIds.contains(id));
                      _closedIds.clear();
                      _closedAt.clear();
                    }
                  });
                },
              ),
              const Spacer(),
              Text('${list.length}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              if (list.isNotEmpty)
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
              : list.isEmpty
                  ? const Center(child: Text('No active connections'))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _buildTile(list[i]),
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

  /// Host из "host:port" — часть до последнего ':'.
  static String _hostOf(String destination) {
    final i = destination.lastIndexOf(':');
    return i < 0 ? destination : destination.substring(0, i);
  }

  Widget _buildTile(CcConnection conn) {
    final network = conn.network;
    final destPort = _portOf(conn.destination);
    // host: domain, иначе host-часть destination (IP-соединения без домена).
    final host = conn.domain.isNotEmpty ? conn.domain : _hostOf(conn.destination);
    final display = destPort.isNotEmpty ? '$host:$destPort' : host;

    final upload = conn.uplink;
    final download = conn.downlink;
    final id = conn.id;
    final closed = conn.isClosed || _closedIds.contains(id);

    final startTime = conn.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(conn.createdAt)
        : null;
    final endTime = closed
        ? (conn.closedAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(conn.closedAt)
            : (_closedAt[id] ?? DateTime.now()))
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
      // §153 — розовый фон у однобоких (зависших) TCP; закрытые — без подсветки.
      color: oneWay && !closed
          ? Color.alphaBlend(Colors.pink.withValues(alpha: 0.16), cs.surface)
          : null,
      child: Opacity(
        opacity: closed ? 0.5 : 1.0,
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
                // Row 1: net-arrow + host:port + traffic + close.
                // §122 — app-иконка убрана (CommandClient не отдаёт processPath).
                Row(
                  children: [
                    Icon(
                      closed
                          ? Icons.check_circle_outline
                          : (network == 'udp'
                              ? Icons.swap_horiz
                              : Icons.arrow_forward),
                      size: 16,
                      color: closed ? cs.primary : cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        display,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w500),
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
                        onPressed: (closed || id.isEmpty)
                            ? null
                            : () => _closeConnection(id),
                      ),
                    ),
                  ],
                ),
                // Row 2: protocol · rule · duration. (chain/process нет в
                // CommandClient — §122 ядровый gap.)
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 2),
                  child: Text(
                    '${network.toUpperCase()}'
                    '${rule.isNotEmpty ? '  ·  $rule' : ''}'
                    '${closed ? '  ·  closed' : ''}'
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
