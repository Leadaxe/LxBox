import 'package:flutter/material.dart';

import '../validators.dart' as v;
import '../widgets/items_field.dart';
import '../widgets/section_header.dart';

/// §053 Stage 2 — PORT section: exact ports + port_range.
class PortSection extends StatelessWidget {
  const PortSection({
    super.key,
    required this.portCtrl,
    required this.portRangeCtrl,
  });

  final TextEditingController portCtrl;
  final TextEditingController portRangeCtrl;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'PORT',
          hint: 'AND with match. Port OR port_range.',
        ),
        ItemsField(
          label: 'Port (exact)',
          controller: portCtrl,
          validator: v.isValidPort,
          hint: '443\n80',
        ),
        ItemsField(
          label: 'Port range',
          controller: portRangeCtrl,
          validator: v.isValidPortRange,
          hint: '8000:9000\n:3000',
        ),
      ],
    );
  }
}
