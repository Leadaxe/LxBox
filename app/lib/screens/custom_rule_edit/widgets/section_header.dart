import 'package:flutter/material.dart';

/// §053 Stage 2 — section header (title + hint) для CustomRuleEditScreen
/// секций. Раньше был `_sectionHeader(t, title, hint)` метод на State.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    required this.hint,
  });

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: t.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: t.colorScheme.primary,
            ),
          ),
          Text(
            hint,
            style: TextStyle(
              fontSize: 12,
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
