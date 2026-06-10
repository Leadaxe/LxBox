import 'package:flutter/material.dart';

import '../../../services/traffic_profiler.dart';
import '../../../services/format_utils.dart';
import 'empty_view.dart';
import 'ip_chip.dart';

/// IPs tab — aggregated unique destination IPs. Симметричен Domains tab'у:
/// «куда app ходит по IP». Полезен для:
/// - hostless conn'ов (без SNI sniffing) — здесь они нормально aggregated
/// - подозрительных IP из внешнего источника (threat-feed, логи провайдера)
/// - топ-IP-by-traffic glance view
///
/// На каждой строке — иконка `open_in_new`, симметричная Connections row:
/// тап → переход на Domains tab с автоподстановкой IP в search (увидеть
/// все domain'ы которые резолвились на этот IP — cross-domain CDN-аудит).
class IpsView extends StatelessWidget {
  const IpsView({super.key, required this.session, required this.onViewInDomains});
  final Session? session;
  final ValueChanged<String> onViewInDomains;

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) return const EmptyView(text: 'Start recording to see IPs.');
    final ips = s.byIp.values.toList()
      ..sort((a, b) =>
          (b.upBytes + b.downBytes).compareTo(a.upBytes + a.downBytes));
    if (ips.isEmpty) return const EmptyView(text: 'No IPs yet.');
    return ListView.builder(
      itemCount: ips.length,
      itemBuilder: (_, i) {
        final ip = ips[i];
        return ListTile(
          dense: true,
          title: Align(
            alignment: Alignment.centerLeft,
            child: ipChip(context, ip.ip, onViewInDomains),
          ),
          subtitle: Text(
            'ports ${ip.ports.join(", ")} · ${ip.connections} conns · '
            '↑${formatBytes(ip.upBytes)} ↓${formatBytes(ip.downBytes)}'
            '${ip.outbounds.isEmpty ? "" : " · ${ip.outbounds.join(" / ")}"}',
            style: const TextStyle(fontSize: 11),
          ),
        );
      },
    );
  }
}
