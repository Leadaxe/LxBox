import 'package:flutter/material.dart';

import '../../../services/app_info_cache.dart';
import '../../../services/traffic_profiler.dart';
import '../../../services/format_utils.dart';
import '../../../services/process_name.dart';
import 'empty_view.dart';

/// §160 — Live-режим per-app trace. «Тупой» рендер уже отфильтрованного
/// родителем таймлайна событий. Тап по строке → [onOpenDetail] (родитель
/// открывает `TrafficEventDetailSheet`).
///
/// Фильтрация (search / kind / unattributed) и сбор списков теперь в
/// родителе (`per_app_trace_tab.dart`) — общий фильтр на оба режима.
/// [events] = session-события (newest-first), [unattributed] = system-wide
/// «no owner» события за окно session'и (newest-first), показываются
/// отдельной dimmed-секцией.
///
/// До §160 здесь жила IP-jump навигация (`ipChip → onViewInDomains`); она
/// убрана — полный IP виден в деталях по тапу (решение §160).
class LiveView extends StatelessWidget {
  const LiveView({
    super.key,
    required this.recording,
    required this.events,
    required this.unattributed,
    required this.onOpenDetail,
  });

  final bool recording;
  final List<TrafficEvent> events;
  final List<TrafficEvent> unattributed;
  final void Function(TrafficEvent e) onOpenDetail;

  @override
  Widget build(BuildContext context) {
    if (!recording && events.isEmpty && unattributed.isEmpty) {
      return const EmptyView(text: 'Start recording to see events.');
    }
    final cs = Theme.of(context).colorScheme;
    return CustomScrollView(
      slivers: [
        if (events.isEmpty && unattributed.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyView(text: 'Waiting for events…'),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => _eventTile(context, events[i]),
              childCount: events.length,
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
              (_, i) => _eventTile(context, unattributed[i], dimmed: true),
              childCount: unattributed.length,
            ),
          ),
        ],
      ],
    );
  }

  Widget _eventTile(BuildContext context, TrafficEvent e,
      {bool dimmed = false}) {
    final cs = Theme.of(context).colorScheme;
    final ts = formatTime(e.ts);
    final tile = InkWell(
      onTap: () => onOpenDetail(e),
      child: _eventTileInner(context, cs, ts, e),
    );
    if (!dimmed) return tile;
    return Opacity(opacity: 0.62, child: tile);
  }

  /// §160 — выразительная 3-строчная строка по образцу Conns-row:
  /// [иконка app] [time · kind-badge · conf · summary · ⚠ · ›]
  ///             process (app)
  ///             chain · rule · duration  (+ CNAME / DNS-record / маркеры)
  Widget _eventTileInner(
      BuildContext context, ColorScheme cs, String ts, TrafficEvent e) {
    final (Color kindColor, String kindLabel) = switch (e.kind) {
      TrafficEventKind.dnsResolve => (cs.tertiary, 'DNS'),
      TrafficEventKind.dnsFail => (cs.error, 'DNS×'),
      TrafficEventKind.tcpOpen => (cs.primary, 'TCP'),
      TrafficEventKind.tcpClose => (cs.outline, 'TCP·'),
      TrafficEventKind.udpOpen => (cs.secondary, 'UDP'),
    };

    // Строка 3 — chain · rule · duration (то что в Conns row внизу).
    final meta = <String>[];
    if (e.outboundChain.isNotEmpty) meta.add(e.outboundChain.join(' → '));
    if (e.rule != null && e.rule!.isNotEmpty) {
      meta.add(e.rulePayload != null && e.rulePayload!.isNotEmpty
          ? '${e.rule} (${e.rulePayload})'
          : e.rule!);
    }
    if (e.duration != null) meta.add('${e.duration!.inMilliseconds}ms');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _appIcon(context, packageNameFromProcess(e.process ?? '')),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Строка 1: time · kind · confidence · summary · issues · ›
                Row(
                  children: [
                    Text(ts,
                        style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: cs.onSurfaceVariant)),
                    const SizedBox(width: 6),
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
                    const SizedBox(width: 4),
                    Expanded(child: _eventSummary(context, e)),
                    if (e.issues.isNotEmpty)
                      Tooltip(
                        message: e.issues.map((a) => a.description).join('\n'),
                        child:
                            Icon(Icons.warning_amber, size: 14, color: cs.error),
                      ),
                    Icon(Icons.chevron_right,
                        size: 16, color: cs.onSurfaceVariant),
                  ],
                ),
                // Строка 2: process (app).
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    (e.process ?? '').isNotEmpty ? e.process! : '(no owner)',
                    style: TextStyle(
                        fontSize: 11,
                        color: (e.process ?? '').isNotEmpty
                            ? cs.primary
                            : cs.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Строка 3: chain · rule · duration.
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      meta.join('  ·  '),
                      style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                // Доп. маркеры (CNAME / нестандартный DNS-record / inferred /
                // backfilled) — мелким, под основными 3 строками.
                if (e.cnameChain.isNotEmpty)
                  _subline(cs, '↳ CNAME ${e.cnameChain.join(" → ")}', mono: true),
                if (e.dnsRecordType != null &&
                    e.dnsRecordType != 'A' &&
                    e.dnsRecordType != 'AAAA' &&
                    e.dnsRecordType != 'CNAME')
                  _subline(cs, 'DNS record: ${e.dnsRecordType}', mono: true),
                if (e.processInferred)
                  _subline(cs, '〽 inferred from prior DNS', italic: true),
                if (e.backfilled)
                  _subline(cs, '〽 backfilled from pre-recording',
                      italic: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// §154 — launcher-иконка приложения по package (`processPath`), 18×18.
  /// Fallback — нейтральный placeholder (layout не прыгает пока иконка
  /// дотягивается из native асинхронно).
  Widget _appIcon(BuildContext context, String pkg) {
    const double size = 18;
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

  Widget _subline(ColorScheme cs, String text,
      {bool mono = false, bool italic = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontFamily: mono ? 'monospace' : null,
          fontStyle: italic ? FontStyle.italic : null,
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }

  /// Текстовый summary события (domain → ip:port / closed · bytes).
  /// Без inline tap-зон — детали по тапу на всю строку.
  Widget _eventSummary(BuildContext context, TrafficEvent e) {
    const style = TextStyle(fontSize: 12);
    final ip = e.ip;
    final port = e.port;
    final domain = e.domain;

    final String text = switch (e.kind) {
      TrafficEventKind.dnsResolve =>
        ip != null ? '${domain ?? "?"} → $ip' : (domain ?? '?'),
      TrafficEventKind.dnsFail => 'DNS exchange failed: ${domain ?? "?"}',
      TrafficEventKind.tcpOpen || TrafficEventKind.udpOpen =>
        (domain != null && domain.isNotEmpty)
            ? '$domain:${port ?? "?"}'
            : '[${ip ?? "?"}]:${port ?? "?"}',
      TrafficEventKind.tcpClose => () {
          final bytes =
              '↑${formatBytes(e.upBytes ?? 0)} ↓${formatBytes(e.downBytes ?? 0)}';
          final hp = (domain != null && domain.isNotEmpty)
              ? '$domain:${port ?? "?"}'
              : '[${ip ?? "?"}]:${port ?? "?"}';
          return '$hp closed · $bytes';
        }(),
    };
    return Text(text, style: style, overflow: TextOverflow.ellipsis);
  }

  /// §044 confidence badge (verified → no marker, secondary → 🔗 sec,
  /// inferred → 〽, unattributed → ?). Tooltip — matched_via / shown_because.
  Widget _confidenceBadge(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    if (e.confidence == ConfidenceLevel.verified) {
      return const SizedBox.shrink();
    }
    final (Color color, String label) = switch (e.confidence) {
      ConfidenceLevel.verified => (cs.onSurface, ''),
      ConfidenceLevel.secondary => (cs.tertiary, '🔗 sec'),
      ConfidenceLevel.inferred => (cs.secondary, '〽'),
      ConfidenceLevel.unattributed => (cs.error, '?'),
    };
    final msg = StringBuffer('confidence: ${e.confidence.name}');
    if (e.matchedVia != null) msg.write('\nmatched via: ${e.matchedVia}');
    if (e.shownBecause != null) msg.write('\nshown because: ${e.shownBecause}');
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
