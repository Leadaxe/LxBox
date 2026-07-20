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
  });

  final String title;
  final String subtitle;
  final String value;
  final List<String> serverTags;
  final ValueChanged<String> onChanged;
  final String tooltip;
  final bool warnIfLocal;

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
      trailing: DropdownButton<String>(
        value: serverTags.contains(value) ? value : null,
        hint: Text(getLocalText.s("select")),
        items: serverTags
            .map((t) => DropdownMenuItem(
                value: t,
                child: Text(t, style: const TextStyle(fontSize: 13))))
            .toList(),
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }
}
