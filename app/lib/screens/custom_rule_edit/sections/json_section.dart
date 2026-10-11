import 'package:flutter/material.dart';

import '../../../widgets/lx_native_code_editor.dart';
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Rule body',
          hint: 'A raw sing-box route rule as one JSON object. The action '
              '(route / reject / hijack-dns / sniff / resolve …) is part of '
              'the body.',
        ),
        const SizedBox(height: 8),
        // §614 — редактор JSON с подсветкой; высота растёт от 6 до 20
        // строк, как у прежнего поля.
        LxNativeTextCodeField(
          controller: controller,
          onChanged: (_) => onChanged(),
          minLines: 6,
          maxLines: 20,
          fontSize: 13,
          errorText: errorText,
        ),
      ],
    );
  }
}
