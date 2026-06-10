import 'package:flutter/material.dart';

import '../../../services/traffic_profiler.dart';
import '../../../services/format_utils.dart';
import 'empty_view.dart';
import 'ip_chip.dart';

class LiveView extends StatelessWidget {
  const LiveView({super.key, required this.session, required this.onViewInDomains});
  final Session? session;
  final ValueChanged<String> onViewInDomains;

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) return const EmptyView(text: 'Start recording to see events.');
    // §048 Принцип 1 — показываем events session'и (включая unattributed
    // nearby events с маркерами) + отдельную секцию «System-wide events»
    // (DNS fail без owner и т.п. из global ring buffer'а).
    final cs = Theme.of(context).colorScheme;
    final reversed = s.events.reversed.toList();
    final unattributed = TrafficProfiler.I.globalUnattributedEvents.reversed
        .where((e) {
      // Показываем только events начавшиеся ПОСЛЕ session'и (inclusive
      // observer focuses on what happened during the session window).
      return !e.ts.isBefore(s.startedAt);
    }).toList();

    return AnimatedBuilder(
      animation: TrafficProfiler.I,
      builder: (_, _) {
        return CustomScrollView(
          slivers: [
            if (reversed.isEmpty && unattributed.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyView(text: 'Waiting for events…'),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _eventTile(context, reversed[i]),
                  childCount: reversed.length,
                ),
              ),
            if (unattributed.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Container(
                  width: double.infinity,
                  color: cs.surfaceContainerHigh,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(
                    children: [
                      Icon(Icons.help_outline,
                          size: 14, color: cs.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(
                        'System-wide events (no owner detected) — ${unattributed.length}',
                        style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) =>
                      _eventTile(context, unattributed[i], dimmed: true),
                  childCount: unattributed.length,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _eventTile(BuildContext context, TrafficEvent e,
      {bool dimmed = false}) {
    final cs = Theme.of(context).colorScheme;
    final ts = '${e.ts.hour.toString().padLeft(2, '0')}:'
        '${e.ts.minute.toString().padLeft(2, '0')}:'
        '${e.ts.second.toString().padLeft(2, '0')}';
    final tile = _eventTileInner(context, cs, ts, e);
    if (!dimmed) return tile;
    return Opacity(opacity: 0.62, child: tile);
  }

  Widget _eventTileInner(
      BuildContext context, ColorScheme cs, String ts, TrafficEvent e) {
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
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
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
              const SizedBox(width: 4),
              Expanded(child: _eventSummaryWidget(context, e)),
              if (e.issues.isNotEmpty)
                Tooltip(
                  message:
                      e.issues.map((a) => a.description).join('\n'),
                  child: Icon(Icons.warning_amber,
                      size: 14, color: cs.error),
                ),
            ],
          ),
          if (e.backfilled)
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text(
                '〽 backfilled from pre-recording',
                style: TextStyle(
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                    color: cs.onSurfaceVariant),
              ),
            ),
          if (e.dnsRecordType != null && e.dnsRecordType != 'A' &&
              e.dnsRecordType != 'AAAA' && e.dnsRecordType != 'CNAME')
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text(
                'DNS record: ${e.dnsRecordType}',
                style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant),
              ),
            ),
          if (e.cnameChain.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text(
                '↳ CNAME ${e.cnameChain.join(" → ")}',
                style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant),
              ),
            ),
          if (e.outboundChain.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text(
                '↳ via ${e.outboundChain.join(" → ")}',
                style: TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant),
              ),
            ),
          if (e.processInferred)
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 1),
              child: Text(
                '〽 inferred from prior DNS',
                style: TextStyle(
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                    color: cs.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  /// Rich event-summary с inline-кликабельным IP chip'ом для Live tab'а.
  /// Layout: domain/host text + (если есть IP в event'е) ↗-icon → переход
  /// на Domains tab с автоподстановкой этого IP в search.
  Widget _eventSummaryWidget(BuildContext context, TrafficEvent e) {
    const style = TextStyle(fontSize: 12);
    final ip = e.ip;
    final port = e.port;
    final domain = e.domain;

    String head;
    bool showIpChip = false;
    bool hostlessIpInline = false;

    switch (e.kind) {
      case TrafficEventKind.dnsResolve:
        head = '${domain ?? "?"} →';
        showIpChip = ip != null;
      case TrafficEventKind.dnsFail:
        return const Text('DNS exchange failed',
            style: style, overflow: TextOverflow.ellipsis);
      case TrafficEventKind.tcpOpen:
      case TrafficEventKind.udpOpen:
        if (domain != null && domain.isNotEmpty) {
          head = '$domain:${port ?? "?"}';
        } else {
          head = '[';
          hostlessIpInline = true;
        }
      case TrafficEventKind.tcpClose:
        final bytes =
            '↑${formatBytes(e.upBytes ?? 0)} ↓${formatBytes(e.downBytes ?? 0)}';
        if (domain != null && domain.isNotEmpty) {
          head = '$domain:${port ?? "?"} closed · $bytes';
        } else {
          head = '[';
          hostlessIpInline = true;
        }
        return Row(
          children: [
            Flexible(child: Text(head, style: style, overflow: TextOverflow.ellipsis)),
            if (hostlessIpInline) ...[
              ipChip(context, ip ?? '?', onViewInDomains),
              Text(']:${port ?? "?"} closed · $bytes',
                  style: style, overflow: TextOverflow.ellipsis),
            ],
          ],
        );
    }

    if (hostlessIpInline) {
      return Row(
        children: [
          Text(head, style: style),
          ipChip(context, ip ?? '?', onViewInDomains),
          Flexible(
            child: Text(']:${port ?? "?"}',
                style: style, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    }
    return Row(
      children: [
        Flexible(child: Text(head, style: style, overflow: TextOverflow.ellipsis)),
        if (showIpChip) ...[
          const SizedBox(width: 4),
          ipChip(context, ip!, onViewInDomains),
        ],
      ],
    );
  }

  /// §048 — confidence badge (verified default — no marker, secondary —
  /// 🔗 sec, inferred — 〽, unattributed — ?). Tooltip показывает matched_via
  /// и shown_because для не-verified.
  Widget _confidenceBadge(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    Color color;
    String label;
    switch (e.confidence) {
      case ConfidenceLevel.verified:
        return const SizedBox.shrink();
      case ConfidenceLevel.secondary:
        color = cs.tertiary;
        label = '🔗 sec';
      case ConfidenceLevel.inferred:
        color = cs.secondary;
        label = '〽';
      case ConfidenceLevel.unattributed:
        color = cs.error;
        label = '?';
    }
    final msg = StringBuffer('confidence: ${e.confidence.name}');
    if (e.matchedVia != null) msg.write('\nmatched via: ${e.matchedVia}');
    if (e.shownBecause != null) {
      msg.write('\nshown because: ${e.shownBecause}');
    }
    return Tooltip(
      message: msg.toString(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10, fontFamily: 'monospace', color: color)),
      ),
    );
  }
}
