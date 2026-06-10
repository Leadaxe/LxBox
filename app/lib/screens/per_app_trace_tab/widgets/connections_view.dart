import 'package:flutter/material.dart';

import '../../../services/traffic_profiler.dart';
import '../../../services/format_utils.dart';
import 'empty_view.dart';
import 'ip_chip.dart';

/// Connections timeline. Tap row → inline-expand (CNAME + all IPs +
/// issues + кнопка `[View in Domains →]` если у event'а есть domain).
class ConnectionsView extends StatelessWidget {
  const ConnectionsView({super.key, required this.session, required this.onViewInDomains});
  final Session? session;
  final ValueChanged<String> onViewInDomains;

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) {
      return const EmptyView(text: 'Start recording to see connections.');
    }
    final conns = s.events
        .where((e) =>
            e.kind == TrafficEventKind.tcpOpen ||
            e.kind == TrafficEventKind.tcpClose ||
            e.kind == TrafficEventKind.udpOpen)
        .toList()
        .reversed
        .toList();
    if (conns.isEmpty) {
      return const EmptyView(text: 'No connections yet.');
    }
    return ListView.builder(
      itemCount: conns.length,
      itemBuilder: (_, i) => _ConnTile(
        // Stable key: ts + domain/ip — events append-only, ts уникальный
        // на event level (микросекундная DateTime.now).
        key: ValueKey<String>(
            '${conns[i].ts.microsecondsSinceEpoch}:${conns[i].kind.name}'),
        event: conns[i],
        session: s,
        onViewInDomains: onViewInDomains,
      ),
    );
  }
}

class _ConnTile extends StatefulWidget {
  const _ConnTile({
    super.key,
    required this.event,
    required this.session,
    required this.onViewInDomains,
  });
  final TrafficEvent event;
  final Session session;
  final ValueChanged<String> onViewInDomains;

  @override
  State<_ConnTile> createState() => _ConnTileState();
}

class _ConnTileState extends State<_ConnTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final cs = Theme.of(context).colorScheme;
    final ts = '${e.ts.hour.toString().padLeft(2, '0')}:'
        '${e.ts.minute.toString().padLeft(2, '0')}:'
        '${e.ts.second.toString().padLeft(2, '0')}';
    final closed = e.kind == TrafficEventKind.tcpClose;

    // Hostless conn: domain отсутствует → показываем `[<ip>]:port`.
    final displayHostPort = e.domain != null && e.domain!.isNotEmpty
        ? '${e.domain}:${e.port ?? "?"}'
        : '[${e.ip ?? "?"}]:${e.port ?? "?"}';

    final domain = e.domain;
    final domainStats =
        (domain != null && domain.isNotEmpty) ? widget.session.byDomain[domain] : null;

    // Click-target — только верхняя часть (header). Раскрытая secция
    // _expandedDetails вне InkWell'а: тап по [View in Domains] кнопке или
    // по тексту CNAME/IPs не схлопывает row.
    final header = Padding(
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
              Expanded(
                child: Text(
                  displayHostPort,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: closed ? cs.onSurfaceVariant : null,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '↑${formatBytes(e.upBytes ?? 0)} ↓${formatBytes(e.downBytes ?? 0)}',
                style:
                    TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              if (e.issues.isNotEmpty) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message:
                      e.issues.map((a) => a.description).join('\n'),
                  child:
                      Icon(Icons.warning_amber, size: 14, color: cs.error),
                ),
              ],
              Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: cs.onSurfaceVariant),
            ],
          ),
          if (e.outboundChain.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: Text('via ${e.outboundChain.join(" → ")}',
                  style:
                      TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
            ),
          if (e.duration != null)
            Padding(
              padding: const EdgeInsets.only(left: 56),
              child: Text('duration ${e.duration!.inMilliseconds}ms',
                  style:
                      TextStyle(fontSize: 10, color: cs.onSurfaceVariant)),
            ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: header,
        ),
        if (_expanded) _expandedDetails(context, e, domainStats),
      ],
    );
  }

  Widget _expandedDetails(
      BuildContext context, TrafficEvent e, DomainStats? d) {
    final cs = Theme.of(context).colorScheme;
    final cnameTargets = d?.cnameTargets.toList() ?? const <String>[];
    final domainIps = d?.ips.toList() ?? const <String>[];
    final issues = e.issues.isNotEmpty
        ? e.issues
        : (d?.issues ?? const <ConnectionIssue>[]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 6, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cnameTargets.isNotEmpty)
            _miniKv(cs, 'CNAME', cnameTargets.join(' → ')),
          if (domainIps.isNotEmpty)
            _miniKvIps(context, cs, 'All IPs', domainIps)
          else if (e.ip != null)
            _miniKvIps(context, cs, 'IP', [e.ip!]),
          if (e.rule != null && e.rule!.isNotEmpty)
            _miniKv(cs,
                'Rule',
                e.rulePayload != null && e.rulePayload!.isNotEmpty
                    ? '${e.rule} (${e.rulePayload})'
                    : e.rule!),
          if (e.processInferred)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('〽 process inferred from prior DNS',
                  style: TextStyle(
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                      color: cs.onSurfaceVariant)),
            ),
          for (final a in issues)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, size: 12, color: cs.error),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(a.description,
                        style: TextStyle(fontSize: 11, color: cs.error)),
                  ),
                ],
              ),
            ),
          if (e.domain != null && e.domain!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => widget.onViewInDomains(e.domain!),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: const Text('View in Domains',
                    style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniKv(ColorScheme cs, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(k,
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace')),
            ),
          ],
        ),
      );

  /// IP-вариант [_miniKv]: вместо строки рендерит [ipChipList] с
  /// ↗-иконкой перехода на Domains tab.
  Widget _miniKvIps(BuildContext context, ColorScheme cs, String k,
          Iterable<String> ips) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(k,
                  style:
                      TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: ipChipList(context, ips, widget.onViewInDomains),
            ),
          ],
        ),
      );
}
