import 'package:flutter/material.dart';

import '../../../models/custom_rule.dart';
import '../widgets/section_header.dart';
import '../../../services/l10n/locale_controller.dart';

/// §117 задача 3 — DNS section: «DNS follows the rule».
///
/// Чекбокс + дропдаун «DNS server» из существующих серверов (по tag —
/// locked decision №2). Правило только **ссылается** на сервер; detour
/// сервера — зона задач 1/2 (№1).
///
/// Гейт: при непустых ports/protocols чекбокс серый + пометка (headless
/// rule_set их не выразит; порт/протокол неизвестны в момент DNS-запроса).
/// Для srs — серая пометка «работает, только если в rule-set есть домены».
class DnsSection extends StatelessWidget {
  const DnsSection({
    super.key,
    required this.dns,
    required this.serverTags,
    required this.gateBlocked,
    required this.isSrs,
    required this.onEnabledChanged,
    required this.onServerTagChanged,
    required this.onForceIpv4Changed,
  });

  final RuleDns? dns;
  final List<String> serverTags;

  /// true → чекбокс disabled (ports/protocols в форме).
  final bool gateBlocked;

  /// true → серая пометка про IP-only rule-set'ы.
  final bool isSrs;

  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<String> onServerTagChanged;

  /// §256 — переключение галки Force IPv4 (AAAA-глушилка).
  final ValueChanged<bool> onForceIpv4Changed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final enabled = dns?.enabled ?? false;
    final forceIpv4 = dns?.forceIpv4 ?? false;
    final serverTag = dns?.serverTag ?? '';
    // Выбранный tag мог исчезнуть из списка (сервер удалён) — показываем
    // его в дропдауне, build тихо не эмитит mirror (решение №3).
    final tags = serverTags.contains(serverTag) || serverTag.isEmpty
        ? serverTags
        : [serverTag, ...serverTags];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'DNS',
          hint: 'Resolve matched traffic with a chosen DNS server.',
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          title: Text(getLocalText.s("Send DNS to dedicated server"),
              style: const TextStyle(fontSize: 13)),
          value: enabled,
          onChanged: gateBlocked ? null : (v) => onEnabledChanged(v ?? false),
        ),
        if (gateBlocked)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4),
            child: Text(
              getLocalText.s("Unavailable with port/protocol filters — they are unknown at DNS-query time."),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        if (enabled && !gateBlocked) ...[
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: DropdownButtonFormField<String>(
              initialValue: tags.contains(serverTag) ? serverTag : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: getLocalText.s("DNS server"),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: tags
                  .map((tag) => DropdownMenuItem(
                        value: tag,
                        child: Text(tag,
                            style: const TextStyle(
                                fontSize: 13, fontFamily: 'monospace')),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v != null) onServerTagChanged(v);
              },
            ),
          ),
          if (isSrs)
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 6),
              child: Text(
                getLocalText.s("Works only if the rule-set contains domains — IP-only lists never match DNS queries."),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
        ],
        // §256 — Force IPv4: независимая галка (не требует dedicated-сервера;
        // predefined отвечает локально). Тот же port/protocol-гейт.
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          title: Text(getLocalText.s("Force IPv4 (drop AAAA)"),
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            getLocalText.s("Answer AAAA (IPv6) queries locally so matched traffic uses IPv4. No DNS server required."),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          value: forceIpv4,
          onChanged:
              gateBlocked ? null : (v) => onForceIpv4Changed(v ?? false),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
