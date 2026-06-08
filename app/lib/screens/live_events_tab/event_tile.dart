// §048 — single TrafficEvent row для Live system-wide tab.
//
// Extracted из `live_events_tab.dart` (behavior-preserving). Рендерит одну
// строку feed'а: timestamp · kind-badge · confidence-badge · summary (domain
// → ip:port), плюс под-строки с process-chips и DNS record type. Каждая
// tap-зона (domain / ip / process pkg) вызывает [onSearchKey] с конкретным
// значением — родитель кладёт его в search field.

import 'package:flutter/material.dart';

import '../../services/traffic_profiler.dart';
import '../../services/format_utils.dart';

class LiveEventTile extends StatelessWidget {
  const LiveEventTile({super.key, required this.event, required this.onSearchKey});

  final TrafficEvent event;
  final void Function(String key) onSearchKey;

  @override
  Widget build(BuildContext context) {
    final e = event;
    final cs = Theme.of(context).colorScheme;
    final ts = '${e.ts.hour.toString().padLeft(2, '0')}:'
        '${e.ts.minute.toString().padLeft(2, '0')}:'
        '${e.ts.second.toString().padLeft(2, '0')}';
    Color kindColor;
    String kindLabel;
    switch (e.kind) {
      case TrafficEventKind.dnsResolve:
        kindColor = cs.tertiary;
        kindLabel = 'DNS';
      case TrafficEventKind.dnsFail:
        kindColor = cs.error;
        kindLabel = 'DNS×';
      case TrafficEventKind.tcpOpen:
        kindColor = cs.primary;
        kindLabel = 'TCP';
      case TrafficEventKind.tcpClose:
        kindColor = cs.outline;
        kindLabel = 'TCP·';
      case TrafficEventKind.udpOpen:
        kindColor = cs.secondary;
        kindLabel = 'UDP';
    }

    // У одного event'а часто есть domain, IP и process одновременно — каждое
    // поле кликабельное независимо. Tap по конкретному значению → search
    // заполняется именно им (см. _applySearchKey).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(ts,
                  style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: kindColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(kindLabel,
                    style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        color: kindColor)),
              ),
              const SizedBox(width: 6),
              _confidenceBadge(context, e),
              const SizedBox(width: 6),
              Expanded(
                child: _eventSummaryRow(context, e),
              ),
            ],
          ),
          if ((e.process ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: _processChips(context, e),
            ),
          if (e.dnsRecordType != null)
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text('record: ${e.dnsRecordType}',
                  style: TextStyle(
                      fontSize: 10, color: cs.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }

  /// Inline summary с независимыми tap-зонами: domain · arrow · ip:port.
  Widget _eventSummaryRow(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    final domain = (e.domain ?? '').trim();
    final ip = (e.ip ?? '').trim();
    final port = e.port;
    final children = <Widget>[];
    if (domain.isNotEmpty) {
      children.add(_tappableText(
        domain,
        () => onSearchKey(domain),
        style: const TextStyle(fontSize: 12),
      ));
    }
    if (ip.isNotEmpty) {
      if (children.isNotEmpty) {
        children.add(Text(' → ',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)));
      }
      final ipPort = port != null ? '$ip:$port' : ip;
      children.add(_tappableText(
        ipPort,
        () => onSearchKey(ip),
        style: const TextStyle(fontSize: 12),
      ));
    }
    if (children.isEmpty) {
      // dnsFail без resolve / closed event без host — fallback на summary текст.
      return Text(_eventSummary(e),
          style: const TextStyle(fontSize: 12),
          overflow: TextOverflow.ellipsis);
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  /// Process line — может быть comma-list ("pkgA, pkgB (uid)"); каждый pkg
  /// — отдельный tap-зон, заполняет search его именем.
  Widget _processChips(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    final raw = (e.process ?? '').trim();
    if (raw.isEmpty) return const SizedBox.shrink();
    final items = raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => s.replaceAll(RegExp(r'\s*\(\d+\)\s*$'), ''))
        .toList();
    final color = e.confidence == ConfidenceLevel.unattributed
        ? cs.error
        : cs.primary;
    final widgets = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) {
        widgets.add(Text(', ',
            style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant)));
      }
      widgets.add(_tappableText(
        items[i],
        () => onSearchKey(items[i]),
        style: TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
          color: color,
        ),
      ));
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: widgets,
    );
  }

  /// Inline tap-zone — InkWell с маленькой hitbox'ой, без splash-overflow.
  Widget _tappableText(String text, VoidCallback onTap, {TextStyle? style}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(2),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
        child: Text(text, style: style, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _confidenceBadge(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    Color color;
    String label;
    switch (e.confidence) {
      case ConfidenceLevel.verified:
        return const SizedBox.shrink();
      case ConfidenceLevel.secondary:
        color = cs.tertiary;
        label = 'sec';
      case ConfidenceLevel.inferred:
        color = cs.secondary;
        label = '〽';
      case ConfidenceLevel.unattributed:
        color = cs.error;
        label = '?';
    }
    return Tooltip(
      message: 'confidence: ${e.confidence.name}'
          '${e.matchedVia != null ? "\nmatched via: ${e.matchedVia}" : ""}'
          '${e.shownBecause != null ? "\nshown because: ${e.shownBecause}" : ""}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: color)),
      ),
    );
  }

  String _eventSummary(TrafficEvent e) {
    switch (e.kind) {
      case TrafficEventKind.dnsResolve:
        return e.ip != null
            ? '${e.domain ?? "?"} → ${e.ip}'
            : (e.domain ?? '?');
      case TrafficEventKind.dnsFail:
        return 'DNS× ${e.domain ?? "?"}';
      case TrafficEventKind.tcpOpen:
      case TrafficEventKind.udpOpen:
        return '${e.domain ?? e.ip ?? "?"}:${e.port ?? "?"}';
      case TrafficEventKind.tcpClose:
        final bytes =
            '↑${formatBytes(e.upBytes ?? 0)} ↓${formatBytes(e.downBytes ?? 0)}';
        return '${e.domain ?? e.ip ?? "?"}:${e.port ?? "?"} closed · $bytes';
    }
  }
}
