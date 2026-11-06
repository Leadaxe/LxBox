import 'package:flutter/material.dart';

import '../normalizers.dart' as norm;
import '../validators.dart' as v;
import '../widgets/items_field.dart';
import '../widgets/section_header.dart';
import '../../../services/l10n/locale_controller.dart';

/// §053 Stage 2 — APPS section: tap → AppPicker. Кнопка Clear.
class AppsSection extends StatelessWidget {
  const AppsSection({
    super.key,
    required this.packages,
    required this.onTap,
    required this.onClear,
    required this.packageRegexCtrl,
  });

  final List<String> packages;
  final VoidCallback onTap;
  final VoidCallback onClear;

  /// §712 — `package_name_regex`, по регулярке на строку (OR внутри поля).
  final TextEditingController packageRegexCtrl;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final empty = packages.isEmpty;
    final label = empty
        ? getLocalText.s("Select apps…")
        : packages.length == 1
            ? getLocalText.s("1 app selected — tap to edit")
            : getLocalText.plural(
                "%d apps selected — tap to edit", packages.length);
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
                    tooltip: getLocalText.s("Clear"),
                    onPressed: onClear,
                  ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
        ItemsField(
          label: 'Package name regex (one per line)',
          controller: packageRegexCtrl,
          validator: v.isValidRegex,
          split: norm.splitLines,
          helper: getLocalText.s(
              "Go RE2, matched anywhere in the package name, e.g. %s",
              r'^com\.oplus\.'),
          hint: r'^com\.oplus\.',
        ),
      ],
    );
  }
}
