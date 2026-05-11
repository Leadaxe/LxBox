import 'package:flutter/material.dart';

import '../widgets/section_header.dart';

/// §053 Stage 2 — APPS section: tap → AppPicker. Кнопка Clear.
class AppsSection extends StatelessWidget {
  const AppsSection({
    super.key,
    required this.packages,
    required this.onTap,
    required this.onClear,
  });

  final List<String> packages;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final empty = packages.isEmpty;
    final label = empty
        ? 'Select apps…'
        : '${packages.length} ${packages.length == 1 ? 'app' : 'apps'} '
            'selected — tap to edit';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'APPS',
          hint: 'AND with match. Route selected packages only.',
        ),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.apps, size: 18, color: t.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: empty
                          ? t.colorScheme.onSurfaceVariant
                          : t.colorScheme.primary,
                    ),
                  ),
                ),
                if (!empty)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    tooltip: 'Clear',
                    onPressed: onClear,
                  ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
