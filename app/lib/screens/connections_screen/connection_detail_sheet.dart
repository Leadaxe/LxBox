import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_info_cache.dart';
import '../../services/format_utils.dart';
import '../connections_screen.dart' show packageNameFromProcess;

/// §152 — детальный bottom sheet по одному соединению.
///
/// Тайл в [ConnectionsView] обрезает host/chain/process/rule ellipsis'ом —
/// здесь показываем полный снимок `conn` (статичный, на момент тапа):
/// сгруппированные `label : value`, только непустые поля, без ellipsis.
/// Тап по строке копирует значение; footer — Copy JSON + Close.
///
/// [onClose] переиспользует `_ConnectionsViewState._closeConnection`
/// (close через Clash API + рефреш списка).
Future<void> showConnectionDetailSheet(
  BuildContext context,
  Map<String, dynamic> conn, {
  required bool closed,
  bool oneWay = false,
  required void Function(String id) onClose,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _ConnectionDetailSheet(
      conn: conn,
      closed: closed,
      oneWay: oneWay,
      onClose: onClose,
    ),
  );
}

class _ConnectionDetailSheet extends StatelessWidget {
  const _ConnectionDetailSheet({
    required this.conn,
    required this.closed,
    required this.oneWay,
    required this.onClose,
  });

  final Map<String, dynamic> conn;
  final bool closed;
  final bool oneWay;
  final void Function(String id) onClose;

  Map<String, dynamic> get _meta =>
      conn['metadata'] as Map<String, dynamic>? ?? const {};

  String _str(Map<String, dynamic> m, String key) =>
      m[key]?.toString().trim() ?? '';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final meta = _meta;

    final host = _str(meta, 'host');
    final destIp = _str(meta, 'destinationIP');
    final destPort = _str(meta, 'destinationPort');
    final id = conn['id']?.toString() ?? '';

    final destination = host.isNotEmpty ? host : destIp;
    final title =
        destPort.isNotEmpty ? '$destination:$destPort' : destination;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          // Grabber
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                _appIcon(context, packageNameFromProcess(_str(meta, 'processPath'))),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title.isNotEmpty ? title : '(connection)',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                    softWrap: true,
                  ),
                ),
                if (oneWay)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                          Colors.pink.withValues(alpha: 0.22), cs.surface),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('One-way',
                        style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w600)),
                  ),
                if (closed)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('closed',
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                if (oneWay) _oneWayBanner(context),
                ..._sections(context),
              ],
            ),
          ),
          _footer(context, id),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final meta = _meta;
    final out = <Widget>[];

    // Поля строго по контракту ядра sing-box-lx
    // (clashapi/trafficontrol/tracker.go → TrackerMetadata.MarshalJSON):
    // metadata = {network,type,sourceIP,destinationIP,sourcePort,
    //             destinationPort,host,dnsMode,processPath}
    // top = {id,upload,download,start,chains,rule,rulePayload}.
    // sniffHost/GeoIP/ASN/uid/inboundName/process апстрим-Clash наш форк
    // не сериализует — не показываем (иначе пустые секции / код-мусор).

    // Destination
    out.addAll(_group(context, 'Destination', [
      _row(context, 'Host', _str(meta, 'host')),
      _row(context, 'Dest IP', _str(meta, 'destinationIP')),
      _row(context, 'Dest port', _str(meta, 'destinationPort')),
    ]));

    // Source
    out.addAll(_group(context, 'Source', [
      _row(context, 'Source IP', _str(meta, 'sourceIP')),
      _row(context, 'Source port', _str(meta, 'sourcePort')),
    ]));

    // Network
    out.addAll(_group(context, 'Network', [
      _row(context, 'Network', _str(meta, 'network')),
      _row(context, 'Inbound', _str(meta, 'type')),
      _row(context, 'DNS mode', _str(meta, 'dnsMode')),
    ]));

    // Process — ядро шлёт только processPath (для Android = package name +
    // опц. uid/user в скобках); поле `process` всегда пустое, оставляем
    // фолбэк на случай иной версии ядра.
    final processPath = _str(meta, 'processPath');
    final process = _str(meta, 'process');
    out.addAll(_group(context, 'Process', [
      _row(context, 'Path', processPath.isNotEmpty ? processPath : process),
    ]));

    // Routing — rulePayload в нашем форке всегда "" (не показываем).
    final chains = (conn['chains'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const [];
    out.addAll(_group(context, 'Routing', [
      if (chains.isNotEmpty)
        _row(context, 'Chain', chains.join('\n')),
      _row(context, 'Rule', conn['rule']?.toString() ?? ''),
    ]));

    // Traffic
    final upload = conn['upload'] as int? ?? 0;
    final download = conn['download'] as int? ?? 0;
    out.addAll(_group(context, 'Traffic', [
      _row(context, 'Upload', '${formatBytes(upload)} ($upload B)'),
      _row(context, 'Download', '${formatBytes(download)} ($download B)'),
    ]));

    // Timing
    final start = conn['start']?.toString() ?? '';
    final startTime = DateTime.tryParse(start);
    String timingStart = '';
    String timingDuration = '';
    if (startTime != null) {
      final local = startTime.toLocal();
      timingStart =
          '${local.year}-${_pad2(local.month)}-${_pad2(local.day)} '
          '${formatTime(local)}';
      timingDuration =
          formatDuration(DateTime.now().difference(startTime), daysRollup: true);
    }
    out.addAll(_group(context, 'Timing', [
      _row(context, 'Started', timingStart),
      _row(context, 'Duration', timingDuration),
    ]));

    // ID
    out.addAll(_group(context, 'ID', [
      _row(context, 'ID', conn['id']?.toString() ?? ''),
    ]));

    return out;
  }

  /// §154 — launcher-иконка приложения по package (`processPath`), 20×20.
  Widget _appIcon(BuildContext context, String pkg) {
    const double size = 20;
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
          borderRadius: BorderRadius.circular(5),
          child: Image.memory(icon,
              width: size, height: size, gaplessPlayback: true),
        );
      },
    );
  }

  /// Плашка-пояснение для однобокого (зависшего) соединения.
  Widget _oneWayBanner(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final upload = conn['upload'] as int? ?? 0;
    final download = conn['download'] as int? ?? 0;
    final detail = upload > 0 && download == 0
        ? 'Data sent (↑), no reply (↓0) — the stream looks stuck.'
        : 'Data received (↓), nothing sent (↑0) — the stream looks stuck.';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            Colors.pink.withValues(alpha: 0.14), cs.surface),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('One-way traffic',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(detail,
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Возвращает заголовок + непустые строки группы, либо `[]` если все
  /// строки группы пустые (группа целиком скрывается).
  List<Widget> _group(BuildContext context, String title, List<Widget?> rows) {
    final visible = rows.whereType<Widget>().toList();
    if (visible.isEmpty) return const [];
    final cs = Theme.of(context).colorScheme;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: cs.primary,
          ),
        ),
      ),
      ...visible,
    ];
  }

  /// `label : value` строка. `null` если value пустое (не рендерится).
  /// Тап копирует value в буфер.
  Widget? _row(BuildContext context, String label, String value) {
    if (value.isEmpty) return null;
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _copy(context, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    height: 1.3),
                softWrap: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, String id) {
    final cs = Theme.of(context).colorScheme;
    final canClose = !closed && id.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, 8 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy JSON'),
              onPressed: () => _copy(
                context,
                const JsonEncoder.withIndent('  ').convert(conn),
                message: 'JSON copied',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Close'),
              onPressed: canClose
                  ? () {
                      onClose(id);
                      Navigator.of(context).pop();
                    }
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  void _copy(BuildContext context, String value, {String message = 'Copied'}) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
}
