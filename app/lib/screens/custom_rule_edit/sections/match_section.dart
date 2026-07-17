import 'package:flutter/material.dart';

import '../../../services/l10n/l10n.dart';
import '../punycode.dart';
import '../validators.dart' as v;
import '../widgets/items_field.dart';
import '../widgets/section_header.dart';

/// §030 new_fields — quick-вставки для CIDR-полей (кнопка «Presets ▾»).
/// Три ходовых сценария: само устройство, домашний Wi-Fi, поймать всё.
/// `Localhost`/`All` дают обе IP-семьи (v4+v6) одной вставкой.
const List<FieldPreset> kCidrPresets = [
  FieldPreset(label: 'Localhost', value: '127.0.0.0/8\n::1/128'),
  FieldPreset(label: 'Wi-Fi subnet', value: '192.168.0.0/16'),
  FieldPreset(label: 'All (IPv4 + IPv6)', value: '0.0.0.0/0\n::/0'),
];

/// §053 Stage 2 — MATCH section: domain / suffix / keyword / IP CIDR
/// + ipIsPrivate toggle.
///
/// Controllers owned by parent (для save flow). Виджет — dumb StatelessWidget
/// который рендерит секцию. ItemsField сам подписывается на controller
/// для self-rebuild.
class MatchSection extends StatelessWidget {
  const MatchSection({
    super.key,
    required this.domainCtrl,
    required this.domainSuffixCtrl,
    required this.domainKeywordCtrl,
    required this.ipCidrCtrl,
    required this.ipIsPrivate,
    required this.onIpIsPrivateChanged,
    required this.sourceIpCidrCtrl,
    required this.sourceIpIsPrivate,
    required this.onSourceIpIsPrivateChanged,
  });

  final TextEditingController domainCtrl;
  final TextEditingController domainSuffixCtrl;
  final TextEditingController domainKeywordCtrl;
  final TextEditingController ipCidrCtrl;
  final bool ipIsPrivate;
  final ValueChanged<bool> onIpIsPrivateChanged;

  /// §030/new_fields — source-IP-CIDR (источник пакета). Эмитится в headless
  /// match (sing-box 1.14). chip-поле, та же cidr-валидация что у [ipCidrCtrl].
  final TextEditingController sourceIpCidrCtrl;
  final bool sourceIpIsPrivate;
  final ValueChanged<bool> onSourceIpIsPrivateChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'MATCH',
          hint: 'Fields work in parallel (OR — any match wins).',
        ),
        ItemsField(
          label: 'Domain (exact)',
          controller: domainCtrl,
          validator: v.isValidDomain,
          normalize: (s) => domainToAscii(s.toLowerCase()),
          hint: 'example.com',
        ),
        ItemsField(
          label: 'Domain suffix',
          controller: domainSuffixCtrl,
          validator: v.isValidDomainSuffix,
          normalize: (s) {
            var x = s.toLowerCase();
            if (x.startsWith('.')) x = x.substring(1);
            return domainToAscii(x);
          },
          hint: 'google.com\n.io\nco.uk',
        ),
        ItemsField(
          label: 'Domain keyword',
          controller: domainKeywordCtrl,
          validator: v.isValidKeyword,
          hint: 'tracker\nanalytics',
        ),
        ItemsField(
          label: 'IP CIDR',
          controller: ipCidrCtrl,
          validator: v.isValidCidr,
          normalize: (s) {
            if (!s.contains('/')) {
              return s.contains(':') ? '$s/128' : '$s/32';
            }
            return s;
          },
          hint: '10.0.0.0/8\n2001:db8::/32',
          presets: kCidrPresets,
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: ipIsPrivate,
          onChanged: (v) => onIpIsPrivateChanged(v ?? false),
          title: Text(
            context.l.ruleEditPrivateIp,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            context.l.ruleEditPrivateIpSub,
            style: const TextStyle(fontSize: 11),
          ),
        ),
        // §030/new_fields — source-ось: по источнику пакета (AND с группой
        // назначения). Полезно для mixed-in прокси-клиентов (LAN) и source-
        // сегментов tun.
        ItemsField(
          label: 'Source IP CIDR',
          controller: sourceIpCidrCtrl,
          validator: v.isValidCidr,
          normalize: (s) {
            if (!s.contains('/')) {
              return s.contains(':') ? '$s/128' : '$s/32';
            }
            return s;
          },
          hint: '192.168.1.0/24\n10.0.0.5',
          presets: kCidrPresets,
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: sourceIpIsPrivate,
          onChanged: (v) => onSourceIpIsPrivateChanged(v ?? false),
          title: Text(
            context.l.ruleEditPrivateSourceIp,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            context.l.ruleEditPrivateSourceIpSub,
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }
}
