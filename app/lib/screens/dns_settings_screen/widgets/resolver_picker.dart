import 'package:flutter/material.dart';

import '../../../widgets/banner_palette.dart';
import '../../../services/l10n/locale_controller.dart';

/// §047/§048 — DNS resolver picker с info-icon ℹ (тап — попап, §682) и опциональным
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
  /// напрямую): оранжевый ⚠ в строке заголовка у правого края, тап — диалог.
  final String? tunnelDetour;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final showWarn = warnIfLocal && value == 'local_dns_resolver';
    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          // ℹ — попап с жирным заголовком (правка владельца §682).
          InkResponse(
            radius: 18,
            onTap: () => _showInfo(context),
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
      trailing: _dropdown(),
    );
    final detour = tunnelDetour;
    if (detour == null) return tile;
    // ⚠ в строке заголовка у правого края — над пикером, ширину пикера не
    // трогает (правка владельца §682).
    return Stack(
      children: [
        tile,
        Positioned(
          top: 6,
          right: 0,
          child: InkResponse(
            key: const ValueKey('resolver_tunnel_warning'),
            radius: 18,
            onTap: () => _showTunnelWarning(context, detour),
            child: Tooltip(
              message: getLocalText.s("Resolver goes through a tunnel"),
              triggerMode: TooltipTriggerMode.manual,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 20,
                  color: bannerIconColor(context, BannerSeverity.warning),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(tooltip),
            ],
          ),
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
