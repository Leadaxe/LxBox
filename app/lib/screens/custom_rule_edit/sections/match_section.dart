import 'package:flutter/material.dart';

import '../validators.dart' as v;
import '../widgets/items_field.dart';
import '../widgets/section_header.dart';

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
  });

  final TextEditingController domainCtrl;
  final TextEditingController domainSuffixCtrl;
  final TextEditingController domainKeywordCtrl;
  final TextEditingController ipCidrCtrl;
  final bool ipIsPrivate;
  final ValueChanged<bool> onIpIsPrivateChanged;

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
          normalize: (s) => s.toLowerCase(),
          hint: 'example.com',
        ),
        ItemsField(
          label: 'Domain suffix',
          controller: domainSuffixCtrl,
          validator: v.isValidDomain,
          normalize: (s) {
            var x = s.toLowerCase();
            if (x.startsWith('.')) x = x.substring(1);
            return x;
          },
          hint: 'google.com\n.ru',
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
        ),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: ipIsPrivate,
          onChanged: (v) => onIpIsPrivateChanged(v ?? false),
          title: const Text(
            'Private IP',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: const Text(
            'Match RFC1918 (10/8, 172.16/12, 192.168/16) + loopback + '
            'link-local',
            style: TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }
}
