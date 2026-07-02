import 'package:flutter/material.dart';

import '../widgets/section_header.dart';

/// §225 (#17) — секция для raw-JSON правила (kind == json). Один monospace
/// TextField с телом правила route.rules + inline-валидация (parse-ошибка →
/// красный helper, Save заблокирован на уровне editor'а).
///
/// Действие правила — часть самого JSON, поэтому OutboundPicker и все
/// match-секции (domain/port/wifi/dns) при json-режиме скрыты в ParamsTab.
class JsonSection extends StatelessWidget {
  const JsonSection({
    super.key,
    required this.controller,
    required this.errorText,
    required this.onChanged,
  });

  final TextEditingController controller;

  /// `null` — тело валидно; иначе краткое описание ошибки под полем.
  final String? errorText;

  final VoidCallback onChanged;

  static const String _placeholder =
      '{ "protocol": "dns", "action": "hijack-dns" }';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Rule body',
          hint: 'A raw sing-box route rule. Enter a JSON object, or an array '
              'of objects for several rules. The action (route / reject / '
              'hijack-dns / sniff / resolve …) is part of the body.',
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          onChanged: (_) => onChanged(),
          minLines: 6,
          maxLines: 20,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: _placeholder,
            hintStyle: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            errorText: errorText,
            isDense: true,
          ),
        ),
      ],
    );
  }
}
