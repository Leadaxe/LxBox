import 'package:flutter/material.dart';

import '../filter_widgets.dart';
import '../node_filter_view_model.dart';
import '../node_list_presenter.dart';

/// §048 — Filter panel (expanded). Composed: regex field + emoji chips +
/// protocol chips + subscription chips + ping field + Show-detour +
/// Show-non-matching.
///
/// §089 — извлечено из `_HomeScreenState._buildFilterPanel` без изменения
/// поведения. Все callbacks идут напрямую в [filter] (NodeFilterViewModel).
class FilterPanel extends StatelessWidget {
  const FilterPanel({
    super.key,
    required this.filter,
    required this.emojis,
    required this.availableProtocols,
    required this.subOptions,
  });

  final NodeFilterViewModel filter;
  final List<String> emojis;
  final List<String> availableProtocols;
  final List<(String, String)> subOptions;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withAlpha(128)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RegexFilterField(
            controller: filter.regexController,
            onChanged: filter.onRegexChanged,
            valid: filter.regexValid,
            enabled: filter.regexEnabled,
            onEnabledChanged: filter.setRegexEnabled,
            invert: filter.regexInvert,
            onInvertChanged: filter.setRegexInvert,
            onClear: filter.clearRegex,
          ),
          if (emojis.isNotEmpty) ...[
            const SizedBox(height: 6),
            EmojiChipsRow(emojis: emojis, onTap: filter.onEmojiChipTap),
          ],
          if (availableProtocols.isNotEmpty) ...[
            const SizedBox(height: 4),
            MultiSelectChipsRow(
              options: [
                for (final p in availableProtocols) (p, protoLabel(p)),
              ],
              enabled: filter.enabledProtocols,
              onToggle: filter.toggleProtocol,
            ),
          ],
          if (subOptions.isNotEmpty) ...[
            const SizedBox(height: 4),
            MultiSelectChipsRow(
              options: subOptions,
              enabled: filter.enabledSubscriptions,
              onToggle: filter.toggleSubscription,
            ),
          ],
          const SizedBox(height: 4),
          PingFilterField(
            controller: filter.pingController,
            onChanged: filter.onPingChanged,
            enabled: filter.pingEnabled,
            onEnabledChanged: filter.setPingEnabled,
            onClear: filter.clearPing,
          ),
          FilterCheckboxRow(
            label: 'Show detour servers',
            value: filter.showDetour,
            onChanged: filter.setShowDetour,
          ),
          FilterCheckboxRow(
            label: 'Show non-matching (dimmed)',
            value: filter.showNonMatching,
            onChanged: filter.setShowNonMatching,
          ),
        ],
      ),
    );
  }
}
