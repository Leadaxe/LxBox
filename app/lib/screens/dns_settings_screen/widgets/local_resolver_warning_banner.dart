import 'package:flutter/material.dart';

import '../../../widgets/banner_palette.dart';

/// §047 — banner который показывается под `Default Domain Resolver` когда
/// выбран `local_dns_resolver`. Объясняет риск + предлагает quick-fix
/// «Switch to cloudflare_udp» если этот server существует в catalog'е.
class LocalResolverWarningBanner extends StatelessWidget {
  const LocalResolverWarningBanner({
    super.key,
    required this.hasCloudflareUdp,
    required this.onSwitchToCloudflareUdp,
  });

  final bool hasCloudflareUdp;
  final VoidCallback onSwitchToCloudflareUdp;

  @override
  Widget build(BuildContext context) {
    // §206 — цвета из единого источника (widgets/banner_palette.dart), а не
    // хардкод `Colors.amber`. Theme-aware для light/dark из коробки.
    final c = bannerColors(context, BannerSeverity.warning);
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 4, 0, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 18, color: c.foreground),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'System DNS leaks lookups to your ISP',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.foreground),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Hostnames sing-box resolves internally (your VPN server '
            'addresses, custom outbound endpoints) will go through your '
            'ISP\'s DNS, bypassing the VPN tunnel. Pick a regular DNS '
            'server for full privacy.',
            style: TextStyle(fontSize: 12, color: c.foreground),
          ),
          if (hasCloudflareUdp) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.bolt, size: 16),
                label: const Text('Switch to cloudflare_udp'),
                onPressed: onSwitchToCloudflareUdp,
                style: TextButton.styleFrom(
                  foregroundColor: c.action,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 4),
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
}
