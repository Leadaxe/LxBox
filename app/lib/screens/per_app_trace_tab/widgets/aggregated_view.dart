import 'package:flutter/material.dart';

import '../../../services/traffic_profiler.dart';
import '../../../services/format_utils.dart';
import 'aggregate_axis.dart';
import 'empty_view.dart';
import '../../../services/l10n/locale_controller.dart';

/// §160 — Aggregated-режим: слияние бывших Domains + IPs tab'ов в один
/// список с осью [AggAxis]. Строка — сводка по домену/IP; тап →
/// [onOpenAggregate] (родитель открывает `AggregateDetailSheet`).
///
/// Развязан от `Session`: принимает посчитанные [byDomain]/[byIp] +
/// [events] (для active/total) — TraceExplorer передаёт их и для per-app
/// trace, и для Stats→Live.
///
/// «Тупой» рендер: фильтрация по [search] здесь же (domain/ip/cname для
/// оси Domain, ip/port для оси IP). Раскрытие переехало в sheet.
class AggregatedView extends StatelessWidget {
  const AggregatedView({
    super.key,
    required this.events,
    required this.byDomain,
    required this.byIp,
    required this.axis,
    required this.search,
    required this.onOpenAggregate,
  });

  final List<TrafficEvent> events;
  final Map<String, DomainStats> byDomain;
  final Map<String, IpStats> byIp;
  final AggAxis axis;
  final String search;
  final void Function(String key) onOpenAggregate;

  @override
  Widget build(BuildContext context) {
    return axis == AggAxis.domain
        ? _buildDomains(context)
        : _buildIps(context);
  }

  Widget _buildDomains(BuildContext context) {
    final all = byDomain.values.toList()
      ..sort((a, b) =>
          (b.upBytes + b.downBytes).compareTo(a.upBytes + a.downBytes));
    final filtered =
        search.isEmpty ? all : all.where(_matchesDomain).toList();
    if (all.isEmpty) return const EmptyView(text: 'No domains yet.');
    if (filtered.isEmpty) return const EmptyView(text: 'No matches.');
    // §160 — активные соединения = open − close по ключу (считаем один раз
    // на билд, не в каждой строке).
    final active = activeByKey(events, AggAxis.domain);
    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final d = filtered[i];
        return _domainRow(context, d, active[d.domain] ?? 0);
      },
    );
  }

  Widget _buildIps(BuildContext context) {
    final all = byIp.values.toList()
      ..sort((a, b) =>
          (b.upBytes + b.downBytes).compareTo(a.upBytes + a.downBytes));
    final filtered = search.isEmpty ? all : all.where(_matchesIp).toList();
    if (all.isEmpty) return const EmptyView(text: 'No IPs yet.');
    if (filtered.isEmpty) return const EmptyView(text: 'No matches.');
    final active = activeByKey(events, AggAxis.ip);
    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final ip = filtered[i];
        return _ipRow(context, ip, active[ip.ip] ?? 0);
      },
    );
  }

  /// §160 — число **активных** соединений по ключу (домен/IP): открытых
  /// (`tcpOpen`/`udpOpen`), но ещё не закрытых (`tcpClose`). Считается как
  /// `max(0, open − close)` per ключ. Чистая функция — покрыта тестом.
  static Map<String, int> activeByKey(
      List<TrafficEvent> events, AggAxis axis) {
    final open = <String, int>{};
    final close = <String, int>{};
    for (final e in events) {
      final key = axis == AggAxis.domain ? e.domain : e.ip;
      if (key == null || key.isEmpty) continue;
      switch (e.kind) {
        case TrafficEventKind.tcpOpen:
        case TrafficEventKind.udpOpen:
          open[key] = (open[key] ?? 0) + 1;
        case TrafficEventKind.tcpClose:
          close[key] = (close[key] ?? 0) + 1;
        case TrafficEventKind.dnsResolve:
        case TrafficEventKind.dnsFail:
          break;
      }
    }
    final result = <String, int>{};
    for (final key in open.keys) {
      final a = open[key]! - (close[key] ?? 0);
      result[key] = a < 0 ? 0 : a;
    }
    return result;
  }

  bool _matchesDomain(DomainStats d) {
    final lq = search.toLowerCase();
    if (d.domain.toLowerCase().contains(lq)) return true;
    if (d.ips.any((ip) => ip.contains(search))) return true;
    if (d.cnameTargets.any((c) => c.toLowerCase().contains(lq))) return true;
    return false;
  }

  bool _matchesIp(IpStats ip) {
    if (ip.ip.contains(search)) return true;
    if (ip.ports.any((p) => p.toString().contains(search))) return true;
    return false;
  }

  Widget _domainRow(BuildContext context, DomainStats d, int active) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      onTap: () => onOpenAggregate(d.domain),
      title: Text(d.domain,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          // §160 — активные / всего соединений.
          Text(getLocalText.s("%1\$d/%2\$d conns", active, d.connections),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          const SizedBox(width: 8),
          Text('↑${formatBytes(d.upBytes)} ↓${formatBytes(d.downBytes)}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          if (d.issues.isNotEmpty) ...[
            const SizedBox(width: 6),
            Icon(Icons.warning_amber, size: 12, color: cs.error),
          ],
        ],
      ),
      trailing: Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
    );
  }

  Widget _ipRow(BuildContext context, IpStats ip, int active) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      onTap: () => onOpenAggregate(ip.ip),
      title: Text(ip.ip,
          style: const TextStyle(
              fontSize: 13, fontFamily: 'monospace', fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis),
      subtitle: Text(
        // §160 — активные / всего соединений.
        getLocalText.s("ports %1\$s · %2\$d/%3\$d conns · ↑%4\$s ↓%5\$s%6\$s", (ip.ports.toList()..sort()).join(', '), active, ip.connections, formatBytes(ip.upBytes), formatBytes(ip.downBytes), ip.outbounds.isEmpty ? '' : ' · ${ip.outbounds.join(" / ")}'),
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
    );
  }
}
