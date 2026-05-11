import 'package:flutter/material.dart';

import '../../../models/custom_rule.dart' show kKnownProtocols;
import '../widgets/section_header.dart';

/// §053 Stage 2 — PROTOCOL section: L7 sniff matchers chips wrap.
///
/// `selected` — set of selected protocols. Toggle через callback.
class ProtocolSection extends StatelessWidget {
  const ProtocolSection({
    super.key,
    required this.selected,
    required this.onToggle,
  });

  final Set<String> selected;
  final void Function(String protocol, bool checked) onToggle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'PROTOCOL',
          hint: 'AND with match. L7 sniff.',
        ),
        Wrap(
          spacing: 4,
          runSpacing: -8,
          children: kKnownProtocols.map((p) {
            final checked = selected.contains(p);
            return SizedBox(
              width: 160,
              child: CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                visualDensity: VisualDensity.compact,
                title: Text(
                  p,
                  style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                ),
                value: checked,
                onChanged: (v) => onToggle(p, v ?? false),
              ),
            );
          }).toList(),
        ),
        if (selected.isNotEmpty)
          Text(
            '${selected.length} selected',
            style: TextStyle(
              fontSize: 12,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
