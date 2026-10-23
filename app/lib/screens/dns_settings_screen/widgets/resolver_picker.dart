import 'package:flutter/material.dart';

import '../../../widgets/banner_palette.dart';
import '../../../services/l10n/locale_controller.dart';

/// §047/§048 — DNS resolver picker с info-icon ℹ tooltip'ом и опциональным
/// жёлтым ⚠ маркером когда выбран `local_dns_resolver` (только для
/// `Default Domain Resolver` поля — там это antipattern).
class ResolverPicker extends StatelessWidget {
  const ResolverPicker({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.serverTags,
    required this.onChanged,
    required this.tooltip,
    required this.warnIfLocal,
    this.tunnelDetour,
  });

  final String title;
  final String subtitle;
  final String value;
  final List<String> serverTags;
  final ValueChanged<String> onChanged;
  final String tooltip;
  final bool warnIfLocal;

  /// §682 — выбранный резолвер ходит через Направление с этим тегом (null —
  /// напрямую): оранжевый ⚠ справа от пикера, тап — диалог с пояснением.
  final String? tunnelDetour;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final showWarn = warnIfLocal && value == 'local_dns_resolver';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Tooltip(
            message: tooltip,
            preferBelow: false,
            triggerMode: TooltipTriggerMode.tap,
            showDuration: const Duration(seconds: 12),
            waitDuration: const Duration(milliseconds: 100),
            child: Icon(
              showWarn ? Icons.warning_amber_rounded : Icons.info_outline,
              size: 18,
              color: showWarn
                  ? bannerIconColor(context, BannerSeverity.warning)
                  : cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Text(title),
        ],
      ),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dropdown(),
          if (tunnelDetour case final detour?)
            IconButton(
              key: const ValueKey('resolver_tunnel_warning'),
              tooltip: getLocalText.s("Resolver goes through a tunnel"),
              icon: Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: bannerIconColor(context, BannerSeverity.warning),
              ),
              onPressed: () => _showTunnelWarning(context, detour),
            ),
        ],
      ),
    );
  }

  void _showTunnelWarning(BuildContext context, String detour) {
    final warn = bannerIconColor(context, BannerSeverity.warning);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Заголовок — строкой контента: тот же размер, что у текста, только
        // оранжевый (правка владельца §682).
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              getLocalText.s("Resolver goes through a tunnel"),
              style: TextStyle(color: warn),
            ),
            const SizedBox(height: 12),
            Text(
              getLocalText.s(
                "This resolver sends queries through %s. It is used to look up server addresses while the connection is being set up, before the tunnel exists, so lookups can fail and the VPN may not connect. A direct resolver is the safest choice; for privacy pick a DoT or DoH server.",
                detour,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("OK")),
          ),
        ],
      ),
    );
  }

  Widget _dropdown() {
    return DropdownButton<String>(
      value: serverTags.contains(value) ? value : null,
      hint: Text(getLocalText.s("select")),
      items: serverTags
          .map(
            (t) => DropdownMenuItem(
              value: t,
              child: Text(t, style: const TextStyle(fontSize: 13)),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
